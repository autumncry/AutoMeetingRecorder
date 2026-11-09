import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Darwin

/// System and microphone acquisition are independent. No hardware is opened by init.
@MainActor public final class AudioCaptureService {
    /// Meter order is (microphone, system), in linear RMS amplitude.
    public var onLevel: ((Float, Float) -> Void)?
    /// Called on MainActor after hardware is stopped. Call stop() to finalize retained files.
    public var onFatalIssue: ((String) -> Void)?
    public var onIssue: ((String) -> Void)?
    private var hardware: AudioCaptureHardware?
    private var session: AudioCaptureSession?
    private var microphoneUID = ""
    private var stopping = false

    public init() {}

    public static func inputDevices() -> [InputDevice] { AudioDeviceQuery.inputs() }

    public func start(in directory: URL, microphoneUID: String, microphoneEnabled: Bool) throws {
        guard session == nil, !stopping else { throw audioError("A recording is already active or being finalized.") }
        guard #available(macOS 14.2, *) else { throw audioError("System audio capture requires macOS 14.2 or later.") }
        let id = UUID()
        let context = try AudioCaptureSession(id: id, directory: directory,
            issue: { [weak self] text, fatal in
                DispatchQueue.main.async {
                    guard let self, self.session?.id == id else { return }
                    if fatal {
                        guard !self.stopping else { self.onIssue?(text); return }
                        self.hardware?.stop(); self.hardware = nil
                        self.session?.closeAfterStartFailure()
                        self.onLevel?(0, 0)
                        if let onFatalIssue = self.onFatalIssue { onFatalIssue(text) }
                        else { self.onIssue?(text) }
                    } else {
                        self.onIssue?(text)
                    }
                }
            }, level: { [weak self] system, microphone in
                DispatchQueue.main.async {
                    guard let self, self.session?.id == id, !self.stopping else { return }
                    guard self.session?.isAccepting == true else { return }
                    self.onLevel?(microphone, system)
                }
            })
        let capture = NativeAudioCapture(session: context)
        self.session = context
        self.hardware = capture
        self.microphoneUID = microphoneUID
        do {
            try capture.startSystem()
            context.startMonitoring()
            // The gate is constructed closed; only this explicit request can open it.
            if microphoneEnabled { setMicrophoneEnabled(true) }
        } catch {
            context.end()
            capture.stop()
            context.closeAfterStartFailure()
            self.hardware = nil
            self.session = nil
            throw error
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        guard let session, !stopping, session.isAccepting else { return }
        session.setMicrophoneEnabled(enabled)
        if enabled {
            do { try hardware?.startMicrophone(uid: microphoneUID) }
            catch {
                session.setMicrophoneEnabled(false)
                onIssue?("Microphone could not start; system audio continues. \(error.localizedDescription)")
            }
        }
    }

    /// Pauses silence both tracks while preserving wall-clock positions.
    public func setPaused(_ paused: Bool) { if !stopping { session?.setPaused(paused) } }

    public func stop() async throws -> CaptureResult {
        guard let context = session, !stopping else { throw audioError("There is no active recording to stop.") }
        stopping = true
        context.end() // Close ingress and discard the unverified microphone tail first.
        hardware?.stop()
        hardware = nil
        defer { session = nil; stopping = false; onLevel?(0, 0) }
        return try await context.finish()
    }

    deinit {
        session?.end()
        hardware?.stop()
        session?.closeAfterStartFailure()
    }
}

private protocol AudioCaptureHardware: AnyObject {
    func startMicrophone(uid: String) throws
    func stop()
}

/// Bounded copied buffers cross to one file queue. Callbacks do not perform file IO,
/// resampling, dispatch synchronously, or wait for a mutex/semaphore.
private final class AudioCaptureSession: @unchecked Sendable {
    let id: UUID
    let directory: URL
    private let origin = mach_absolute_time()
    private let queue = DispatchQueue(label: "AutoMeetingRecorder.audio.files", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let stateLock = NSLock()
    private var accepting = true
    private var endTime: Double?
    private var events = [AudioGateEvent(time: 0, microphoneEnabled: false, paused: false)]
    private var microphoneEnabled = false
    private var paused = false
    private var failureReported = false
    private let microphonePending = AudioMicrophoneHoldback()
    private let issue: (String, Bool) -> Void
    private let level: (Float, Float) -> Void
    // Only the file queue touches these properties.
    private var systemWriter: AudioTimelineWriter?
    private var microphoneWriter: AudioTimelineWriter?
    private var clockLog: FileHandle?
    private var timer: DispatchSourceTimer?
    private var lastSystemCallback: Double?
    private var lastMicrophoneCallback: Double?
    private var micStartedAt: Double?
    private var systemLevel: Float = 0
    private var microphoneLevel: Float = 0
    private var lastLevelTime: Double = 0
    private var warnedSilence = false
    private var heardSystemAudio = false

    init(id: UUID, directory: URL, issue: @escaping (String, Bool) -> Void, level: @escaping (Float, Float) -> Void) throws {
        self.id = id; self.directory = directory; self.issue = issue; self.level = level
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["system.caf", "microphone.caf", "recording.wav", "audio-timeline.jsonl"] {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw audioError("Recording directory already contains \(name); use a new session directory.")
            }
        }
        let log = directory.appendingPathComponent("audio-timeline.jsonl")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw audioError("Could not create recording clock log.") }
        clockLog = try FileHandle(forWritingTo: log)
    }

    var isAccepting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return accepting }
    private var now: Double { elapsed(mach_absolute_time()) }
    private func elapsed(_ hostTime: UInt64) -> Double {
        hostTime >= origin ? AVAudioTime.seconds(forHostTime: hostTime - origin) : -AVAudioTime.seconds(forHostTime: origin - hostTime)
    }

    func configure(format: AVAudioFormat, microphone: Bool) throws {
        try queue.sync {
            if microphone {
                if let writer = microphoneWriter {
                    guard writer.format == format || writer.frames == 0 else { throw audioError("Microphone format changed during recording.") }
                    if writer.format != format {
                        writer.close()
                        microphoneWriter = try AudioTimelineWriter(url: directory.appendingPathComponent("microphone.caf"), format: format)
                    }
                } else {
                    microphoneWriter = try AudioTimelineWriter(url: directory.appendingPathComponent("microphone.caf"), format: format)
                }
                micStartedAt = now
            } else {
                systemWriter = try AudioTimelineWriter(url: directory.appendingPathComponent("system.caf"), format: format)
            }
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        stateLock.lock()
        guard accepting else { stateLock.unlock(); return }
        if microphoneEnabled != enabled {
            microphoneEnabled = enabled
            events.append(AudioGateEvent(time: now, microphoneEnabled: enabled, paused: paused))
            if enabled { queue.async { [self] in micStartedAt = now } }
        }
        // Synchronously clear held frames; tokens also reject older queued copies.
        microphonePending.setEnabled(enabled && !paused)
        stateLock.unlock()
    }

    func setPaused(_ value: Bool) {
        stateLock.lock()
        guard accepting else { stateLock.unlock(); return }
        if paused != value {
            paused = value
            events.append(AudioGateEvent(time: now, microphoneEnabled: microphoneEnabled, paused: value))
            if !value { queue.async { [self] in micStartedAt = now } }
        }
        microphonePending.setEnabled(microphoneEnabled && !value)
        stateLock.unlock()
    }

    func receive(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, frames: AVAudioFrameCount, hostTime: UInt64, microphone: Bool) {
        guard frames > 0 else { return }
        // Never block the hardware thread. A missed callback becomes a clock-aligned gap.
        guard stateLock.try() else { return }
        let active = accepting
        let gateEvents = events
        let token = microphone ? microphonePending.token : nil
        stateLock.unlock()
        guard active, !microphone || token != nil else { return }
        guard slots.wait(timeout: .now()) == .success else {
            signalRealtimeFailure("Audio storage queue overran; capture stopped and existing raw audio was retained.")
            return
        }
        do {
            guard hostTime > 0 else { throw audioError("Audio callback has no host-clock timestamp.") }
            let time = elapsed(hostTime)
            guard time.isFinite, time <= now + 1 else { throw audioError("Invalid audio host-clock position.") }
            let buffer = try Self.copyPCM(list, format: format, frames: frames)
            AudioSamplePolicy.applyGate(to: buffer, at: time, microphone: microphone, events: gateEvents)
            queue.async { [self] in
                defer { slots.signal() }
                do {
                    if microphone {
                        guard let token, microphonePending.isCurrent(token) else { return }
                        lastMicrophoneCallback = now
                        guard microphonePending.append(buffer, at: time, token: token) else {
                            throw audioError("Microphone holdback exceeded its memory bound.")
                        }
                        try drainMicrophone()
                    } else {
                        lastSystemCallback = now
                        try systemWriter?.append(buffer, at: time)
                        systemLevel = Self.rms(buffer)
                        heardSystemAudio = heardSystemAudio || systemLevel > 0.00001
                        try log(track: "system", hostTime: hostTime, time: time, buffer: buffer)
                    }
                    publishLevels()
                } catch { fail("Audio storage failed; raw files were retained. \(error.localizedDescription)") }
            }
        } catch {
            slots.signal()
            signalRealtimeFailure(error.localizedDescription)
        }
    }

    private func signalRealtimeFailure(_ text: String) {
        // A one-shot state transition avoids unbounded error blocks if callbacks continue.
        guard stateLock.try() else { return }
        let first = !failureReported
        failureReported = true
        accepting = false
        endTime = endTime ?? now
        stateLock.unlock()
        if first {
            queue.async { [self] in
                microphonePending.setEnabled(false)
                issue(text, true)
            }
        }
    }

    func warn(_ text: String) { issue(text, false) }

    func fail(_ text: String) {
        stateLock.lock()
        let first = !failureReported
        failureReported = true
        accepting = false
        endTime = endTime ?? now
        microphonePending.setEnabled(false)
        stateLock.unlock()
        if first { issue(text, true) }
    }

    func startMonitoring() {
        queue.async { [self] in
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 0.25, repeating: 0.25)
            source.setEventHandler { [weak self] in self?.monitor() }
            timer = source
            source.resume()
        }
    }

    private func monitor() {
        guard isAccepting else { return }
        do { try drainMicrophone() }
        catch { fail("Microphone storage failed; raw audio was retained. \(error.localizedDescription)"); return }
        let time = now
        if time - (lastSystemCallback ?? 0) > 8 {
            fail("System audio callbacks stopped or never started. Check capture permission and devices; existing audio was retained.")
            return
        }
        if microphonePending.token != nil, let start = micStartedAt, time - max(lastMicrophoneCallback ?? start, start) > 8 {
            fail("Microphone callbacks stopped. Capture stopped with existing audio retained.")
            return
        }
        if time > 10, !heardSystemAudio, !warnedSilence {
            warnedSilence = true
            warn("System audio has been silent. This may be normal; verify system-audio permission if sound should be present.")
        }
        publishLevels()
    }

    private func drainMicrophone() throws {
        for frame in microphonePending.takeVerified(at: now) {
            guard microphonePending.isCurrent(frame.token) else { continue }
            try microphoneWriter?.append(frame.buffer, at: frame.time)
            microphoneLevel = Self.rms(frame.buffer)
            try log(track: "microphone", hostTime: nil, time: frame.time, buffer: frame.buffer)
        }
    }

    private func log(track: String, hostTime: UInt64?, time: Double, buffer: AVAudioPCMBuffer) throws {
        let row: [String: Any] = ["track": track, "hostOrigin": String(origin), "hostTime": hostTime.map(String.init) ?? "",
                                  "seconds": time, "sampleRate": buffer.format.sampleRate, "frames": buffer.frameLength]
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(10)
        try clockLog?.write(contentsOf: data)
    }

    private func publishLevels() {
        let time = now
        guard time - lastLevelTime >= 0.1 else { return }
        lastLevelTime = time
        if microphonePending.token == nil { microphoneLevel = 0 }
        level(systemLevel, microphoneLevel)
    }

    func end() {
        stateLock.lock()
        accepting = false
        endTime = endTime ?? now
        microphonePending.setEnabled(false)
        microphonePending.discardPending()
        stateLock.unlock()
    }

    func closeAfterStartFailure() {
        queue.sync { closeFiles() }
    }

    private func closeFiles() {
        timer?.cancel(); timer = nil
        systemWriter?.close(); microphoneWriter?.close()
        try? clockLog?.close(); clockLog = nil
    }

    func finish() async throws -> CaptureResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    stateLock.lock(); let end = endTime ?? now; stateLock.unlock()
                    // Holdback is deliberately NOT drained here; the last ~2 seconds are unverified.
                    microphonePending.discardPending()
                    try systemWriter?.pad(to: end)
                    try microphoneWriter?.pad(to: end)
                    closeFiles()
                    let system = systemWriter == nil ? nil : directory.appendingPathComponent("system.caf")
                    let microphone = microphoneWriter == nil ? nil : directory.appendingPathComponent("microphone.caf")
                    let output = directory.appendingPathComponent("recording.wav")
                    try AudioFileTools.mixAligned(system: system, microphone: microphone, destination: output)
                    continuation.resume(returning: CaptureResult(audioURL: output, microphoneURL: microphone, systemURL: system,
                                                                 duration: try AudioFileTools.duration(of: output)))
                } catch {
                    closeFiles()
                    issue("Could not finalize recording; raw files remain in \(directory.path). \(error.localizedDescription)", false)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        var sum: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { let value = Double(buffer.floatChannelData![channel][frame]); sum += value * value }
        }
        return Float(sqrt(sum / Double(max(1, Int(buffer.frameLength) * Int(buffer.format.channelCount)))))
    }

    private static func copyPCM(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard frames <= 16_384, format.channelCount > 0, format.channelCount <= 32,
              format.commonFormat == .pcmFormatFloat32 else { throw audioError("Unsupported capture format or buffer size.") }
        let planar = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount)!
        let output = try AudioFileTools.pcmBuffer(format: planar, capacity: frames)
        output.frameLength = frames
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let count = Int(format.channelCount)
        guard buffers.count == (format.isInterleaved ? 1 : count) else { throw audioError("Capture stream layout changed.") }
        for channel in 0..<count {
            let input = buffers[format.isInterleaved ? 0 : channel]
            let stride = format.isInterleaved ? count : 1
            guard let data = input.mData, Int(input.mDataByteSize) >= Int(frames) * stride * MemoryLayout<Float>.size else {
                throw audioError("Capture buffer is smaller than its declared frame count.")
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(frames) { output.floatChannelData![channel][frame] = samples[frame * stride + (format.isInterleaved ? channel : 0)] }
        }
        return output
    }
}

@available(macOS 14.2, *)
private final class NativeAudioCapture: AudioCaptureHardware {
    private let session: AudioCaptureSession
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var microphoneHasTap = false
    private var systemStarted = false

    init(session: AudioCaptureSession) { self.session = session }

    func startSystem() throws {
        do {
            var pid = getpid()
            var ownProcess: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioDeviceQuery.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
            let excluded = status == noErr && ownProcess != 0 ? [ownProcess] : []
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
            description.name = "AutoMeetingRecorder system audio"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            if excluded.isEmpty { session.warn("Could not identify this app's audio process for exclusion; system capture may include its playback.") }
            try AudioDeviceQuery.check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")
            var stream = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            address = AudioDeviceQuery.address(kAudioTapPropertyFormat)
            try AudioDeviceQuery.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream), "Read system tap format")
            guard let format = AVAudioFormat(streamDescription: &stream), format.commonFormat == .pcmFormatFloat32,
                  format.sampleRate > 0, format.channelCount > 0,
                  let planar = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) else {
                throw audioError("System tap did not supply supported Float32 audio.")
            }
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "AutoMeetingRecorder private capture",
                kAudioAggregateDeviceUIDKey: "AutoMeetingRecorder.\(UUID())",
                kAudioAggregateDeviceIsPrivateKey: true,
                // Do not wait synchronously for some other app to begin playing sound.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try AudioDeviceQuery.check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate), "Create private audio aggregate")
            try session.configure(format: planar, microphone: false)
            let context = session
            let bytesPerFrame = stream.mBytesPerFrame
            try AudioDeviceQuery.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, inputTime, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, bytesPerFrame > 0 else { return }
                let frames = first.mDataByteSize / bytesPerFrame
                guard inputTime.pointee.mFlags.contains(.hostTimeValid) else {
                    context.receive(input, format: format, frames: frames, hostTime: 0, microphone: false)
                    return
                }
                context.receive(input, format: format, frames: frames, hostTime: inputTime.pointee.mHostTime, microphone: false)
            }, "Create audio IO callback")
            try AudioDeviceQuery.check(AudioDeviceStart(aggregate, ioProc), "Start system audio capture")
            systemStarted = true
            try listen(tap, selector: kAudioTapPropertyFormat)
            try listen(aggregate, selector: kAudioDevicePropertyDeviceIsAlive)
            try listen(aggregate, selector: kAudioDevicePropertyNominalSampleRate)
            try listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        } catch { stop(); throw error }
    }

    func startMicrophone(uid: String) throws {
        guard engine == nil else { return }
        let device: AudioObjectID
        if uid.isEmpty { device = try AudioDeviceQuery.defaultInput() }
        else {
            guard let selected = AudioDeviceQuery.inputs().first(where: { $0.uid == uid }) else { throw audioError("The selected microphone UID is unavailable; no fallback device was selected.") }
            device = selected.id
        }
        let candidate = AVAudioEngine()
        let input = candidate.inputNode
        guard let unit = input.audioUnit else { throw audioError("Microphone audio unit is unavailable.") }
        var selectedDevice = device
        try AudioDeviceQuery.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                      &selectedDevice, UInt32(MemoryLayout<AudioObjectID>.size)), "Select microphone")
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
              let planar = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) else {
            throw audioError("Selected microphone has no supported input format.")
        }
        // Configure the writer before callbacks can arrive; a failed start leaves the raw file intact.
        try session.configure(format: planar, microphone: true)
        engine = candidate
        let context = session
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
            context.receive(buffer.audioBufferList, format: buffer.format, frames: buffer.frameLength,
                            hostTime: time.isHostTimeValid ? time.hostTime : 0, microphone: true)
        }
        microphoneHasTap = true
        let originalListenerCount = listeners.count
        do {
            candidate.prepare()
            try candidate.start()
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: candidate, queue: nil) { _ in
                context.fail("Microphone configuration changed. Capture stopped; existing raw audio is retained. Start a new recording after selecting the device.")
            }
            try listen(device, selector: kAudioDevicePropertyDeviceIsAlive)
            try listen(device, selector: kAudioDevicePropertyNominalSampleRate)
            if uid.isEmpty { try listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice) }
        } catch {
            for (object, property, block) in listeners.dropFirst(originalListenerCount) {
                var address = property
                AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
            }
            listeners.removeLast(listeners.count - originalListenerCount)
            stopMicrophone()
            throw error
        }
    }

    private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        var address = AudioDeviceQuery.address(selector)
        let context = session
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            context.fail("Audio device or stream configuration changed. Capture stopped with raw audio retained; start a new recording to use the new configuration.")
        }
        try AudioDeviceQuery.check(AudioObjectAddPropertyListenerBlock(object, &address, .main, block), "Monitor audio device configuration")
        listeners.append((object, address, block))
    }

    private func stopMicrophone() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.stop()
        if microphoneHasTap { engine?.inputNode.removeTap(onBus: 0); microphoneHasTap = false }
        engine = nil
    }

    func stop() {
        for (object, property, block) in listeners {
            var address = property
            let status = AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
            if status != noErr { session.warn("Could not remove an audio configuration listener (\(status)).") }
        }
        listeners.removeAll()
        stopMicrophone()
        if aggregate != 0, let ioProc {
            if systemStarted {
                let status = AudioDeviceStop(aggregate, ioProc)
                if status != noErr { session.warn("Stopping audio device reported \(status).") }
            }
            let status = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            if status != noErr { session.warn("Destroying audio callback reported \(status).") }
        }
        ioProc = nil; systemStarted = false
        if aggregate != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregate)
            if status != noErr { session.warn("Destroying private audio aggregate reported \(status).") }
            aggregate = 0
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status != noErr { session.warn("Destroying system audio tap reported \(status).") }
            tap = 0
        }
    }

    deinit { stop() }
}

private enum AudioDeviceQuery {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw audioError("\(operation) failed (Core Audio \(status)).") }
    }

    static func defaultInput() throws -> AudioObjectID {
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device), "Read default microphone")
        guard device != 0 else { throw audioError("No default microphone is available.") }
        return device
    }

    static func inputs() -> [InputDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        guard size >= MemoryLayout<AudioObjectID>.size else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return devices.compactMap { device in
            var streamProperty = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
            var byteCount: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamProperty, 0, nil, &byteCount) == noErr,
                  byteCount >= MemoryLayout<AudioBufferList>.size else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            guard AudioObjectGetPropertyData(device, &streamProperty, 0, nil, &byteCount, storage) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.reduce(0, { $0 + $1.mNumberChannels }) > 0,
                  let uid = string(device, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(id: device, uid: uid, name: string(device, selector: kAudioObjectPropertyName) ?? uid)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func string(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
