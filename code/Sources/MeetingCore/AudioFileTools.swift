import AVFoundation
import Foundation
import Darwin

public enum AudioFileTools {
    static let sampleRate: Double = 16_000
    static let blockSize: AVAudioFrameCount = 8_192

    /// Converts off the caller's actor. The source (including aliases) is never overwritten.
    public static func prepareForASR(source: URL, destination: URL) async throws -> Double {
        let work = Task.detached(priority: .utility) {
            try normalize(source: source, destination: destination, pcm16: true)
            return try duration(of: destination)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { throw audioError("Audio has no valid sample rate.") }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    public static func splitForASR(source: URL, into directory: URL, seconds: Double) throws -> [AudioChunk] {
        let requestedFrames = (seconds * sampleRate).rounded()
        guard seconds.isFinite, requestedFrames >= 1, requestedFrames < Double(Int64.max) else {
            throw audioError("Chunk duration must be finite and at least one 16 kHz sample.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = "chunk-\(UUID().uuidString)"
        let normalized = directory.appendingPathComponent(".\(prefix).caf")
        defer { try? FileManager.default.removeItem(at: normalized) }
        try normalize(source: source, destination: normalized, pcm16: false)
        let input = try AVAudioFile(forReading: normalized)
        let chunkFrames = AVAudioFramePosition(requestedFrames)
        let buffer = try pcmBuffer(format: input.processingFormat, capacity: blockSize)
        var result: [AudioChunk] = []
        do {
            while input.framePosition < input.length {
                try Task.checkCancellation()
                let offset = input.framePosition
                let count = min(chunkFrames, input.length - offset)
                let url = directory.appendingPathComponent("\(prefix)-\(result.count).wav")
                do {
                    let output = try waveWriter(at: url)
                    var remaining = count
                    while remaining > 0 {
                        try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int64(blockSize))))
                        guard buffer.frameLength > 0 else { throw audioError("Unexpected end of audio while splitting.") }
                        try output.write(from: buffer)
                        remaining -= Int64(buffer.frameLength)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                result.append(AudioChunk(url: url, offset: Double(offset) / sampleRate, duration: Double(count) / sampleRate))
            }
            return result
        } catch {
            for chunk in result { try? FileManager.default.removeItem(at: chunk.url) }
            throw error
        }
    }

    /// Sources already carry zero-filled host-clock gaps. Read only a block per track.
    /// Two tracks get fixed 6 dB headroom each; a single track retains unity gain.
    static func mixAligned(system: URL?, microphone: URL?, destination: URL) throws {
        let sources = [system, microphone].compactMap { $0 }
        guard !sources.isEmpty else { throw audioError("No retained audio is available to mix.") }
        for source in sources { try requireDifferentFiles(source, destination) }
        let parent = destination.deletingLastPathComponent()
        let temporary = sources.map { _ in parent.appendingPathComponent(".mix-\(UUID()).caf") }
        defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
        for (source, target) in zip(sources, temporary) { try normalize(source: source, destination: target, pcm16: false) }
        let inputs = try temporary.map { try AVAudioFile(forReading: $0) }
        let buffers = try inputs.map { try pcmBuffer(format: $0.processingFormat, capacity: blockSize) }
        let mixed = try pcmBuffer(format: monoFormat(rate: sampleRate), capacity: blockSize)
        let total = inputs.map(\.length).max() ?? 0
        try atomicOutput(destination: destination, extension: "wav") { url in
            let output = try waveWriter(at: url)
            var position: Int64 = 0
            while position < total {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(Int64(blockSize), total - position))
                mixed.frameLength = count
                mixed.floatChannelData![0].update(repeating: 0, count: Int(count))
                for (input, buffer) in zip(inputs, buffers) {
                    let available = AVAudioFrameCount(min(Int64(count), input.length - input.framePosition))
                    buffer.frameLength = 0
                    if available > 0 { try input.read(into: buffer, frameCount: available) }
                    for frame in 0..<Int(buffer.frameLength) {
                        mixed.floatChannelData![0][frame] += AudioSamplePolicy.finiteSample(buffer.floatChannelData![0][frame]) / Float(inputs.count)
                    }
                }
                try output.write(from: mixed)
                position += Int64(count)
            }
        }
    }

    private static func normalize(source: URL, destination: URL, pcm16: Bool) throws {
        try requireDifferentFiles(source, destination)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFormat = input.processingFormat
        guard sourceFormat.sampleRate.isFinite, sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw audioError("Unsupported audio format.")
        }
        let monoInputFormat = try monoFormat(rate: sourceFormat.sampleRate)
        let outputFormat = try monoFormat(rate: sampleRate)
        let inputBuffer = try pcmBuffer(format: sourceFormat, capacity: blockSize)
        let mono = try pcmBuffer(format: monoInputFormat, capacity: blockSize)
        let expected = (Double(input.length) * sampleRate / sourceFormat.sampleRate).rounded()
        guard expected.isFinite, expected < Double(Int64.max) else { throw audioError("Audio is too long to convert.") }
        let expectedFrames = Int64(expected)

        func readMono(_ count: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
            let remaining = input.length - input.framePosition
            guard remaining > 0 else { return nil }
            try input.read(into: inputBuffer, frameCount: AVAudioFrameCount(min(Int64(min(count, blockSize)), remaining)))
            guard inputBuffer.frameLength > 0 else { return nil }
            mono.frameLength = inputBuffer.frameLength
            for frame in 0..<Int(mono.frameLength) {
                var value: Float = 0
                for channel in 0..<Int(sourceFormat.channelCount) {
                    value += AudioSamplePolicy.finiteSample(inputBuffer.floatChannelData![channel][frame]) / Float(sourceFormat.channelCount)
                }
                mono.floatChannelData![0][frame] = value
            }
            return mono
        }

        try atomicOutput(destination: destination, extension: pcm16 ? "wav" : "caf") { url in
            let output = try pcm16 ? waveWriter(at: url) : floatWriter(at: url, format: outputFormat)
            if sourceFormat.sampleRate == sampleRate {
                while let buffer = try readMono(blockSize) {
                    try Task.checkCancellation()
                    try output.write(from: buffer)
                }
                return
            }
            guard expectedFrames > 0 else { return }
            guard let converter = AVAudioConverter(from: monoInputFormat, to: outputFormat) else {
                throw audioError("Could not create the audio sample-rate converter.")
            }
            converter.primeMethod = .none
            let converted = try pcmBuffer(format: outputFormat, capacity: blockSize)
            var written: Int64 = 0
            var emptyPasses = 0
            while written < expectedFrames {
                try Task.checkCancellation()
                var conversionError: NSError?
                var readError: Error?
                let status = converter.convert(to: converted, error: &conversionError) { requested, state in
                    do {
                        guard let next = try readMono(requested) else { state.pointee = .endOfStream; return nil }
                        state.pointee = .haveData
                        return next
                    } catch {
                        readError = error
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                if let error = readError ?? conversionError { throw error }
                if status == .error { throw audioError("Audio conversion failed.") }
                converted.frameLength = AVAudioFrameCount(min(Int64(converted.frameLength), expectedFrames - written))
                if converted.frameLength > 0 {
                    try output.write(from: converted)
                    written += Int64(converted.frameLength)
                    emptyPasses = 0
                } else { emptyPasses += 1 }
                if status == .endOfStream || emptyPasses > 2 { break }
            }
            guard written == expectedFrames else { throw audioError("Audio conversion ended before all samples were written.") }
        }
    }

    static func monoFormat(rate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { throw audioError("Invalid audio sample rate.") }
        return format
    }

    static func pcmBuffer(format: AVAudioFormat, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw audioError("Could not allocate audio buffer.") }
        return buffer
    }

    static func floatWriter(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func waveWriter(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func requireDifferentFiles(_ source: URL, _ destination: URL) throws {
        let a = source.standardizedFileURL.resolvingSymlinksInPath()
        let b = destination.standardizedFileURL.resolvingSymlinksInPath()
        var sourceInfo = stat(), destinationInfo = stat()
        let sameInode = stat(a.path, &sourceInfo) == 0 && stat(b.path, &destinationInfo) == 0 &&
            sourceInfo.st_ino == destinationInfo.st_ino && sourceInfo.st_dev == destinationInfo.st_dev
        guard a != b, !sameInode else { throw audioError("Source and destination must be different files.") }
    }

    private static func atomicOutput(destination: URL, extension suffix: String, write: (URL) throws -> Void) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".audio-\(UUID()).\(suffix)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(temporary) // AVAudioFile must be released before publishing its finalized header.
        try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}

func audioError(_ message: String) -> MeetingError { .message(message) }

struct AudioGateEvent {
    let time: Double
    let microphoneEnabled: Bool
    let paused: Bool
}

enum AudioSamplePolicy {
    static func finiteSample(_ value: Float) -> Float { value.isFinite ? min(1, max(-1, value)) : 0 }

    /// Timestamped, fail-closed gate: delayed buffers cannot inherit a newer enabled state.
    static func applyGate(to buffer: AVAudioPCMBuffer, at time: Double, microphone: Bool, events: [AudioGateEvent]) {
        guard let channels = buffer.floatChannelData else { return }
        var eventIndex = 0
        var enabled = false
        for frame in 0..<Int(buffer.frameLength) {
            let sampleTime = time + Double(frame) / buffer.format.sampleRate
            while eventIndex < events.count && events[eventIndex].time <= sampleTime {
                let event = events[eventIndex]
                enabled = !event.paused && (!microphone || event.microphoneEnabled)
                eventIndex += 1
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                let value = channels[channel][frame]
                channels[channel][frame] = enabled && value.isFinite ? value : 0
            }
        }
    }
}

/// Serial-queue-owned raw writer. Host timestamps determine positions, including silence
/// for dropped/disabled intervals and overlap trimming for clock drift or delayed callbacks.
final class AudioTimelineWriter {
    private var file: AVAudioFile?
    let format: AVAudioFormat
    private(set) var frames: Int64 = 0

    init(url: URL, format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw audioError("Raw writer requires planar Float32 PCM.") }
        self.format = format
        file = try AudioFileTools.floatWriter(at: url, format: format)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: Double) throws {
        guard let file else { throw audioError("Raw audio file is already closed.") }
        guard time.isFinite, abs(time * format.sampleRate) < Double(Int64.max / 2), buffer.format == format else {
            throw audioError("Audio clock or format changed; retained audio was stopped.")
        }
        let position = Int64((time * format.sampleRate).rounded())
        try pad(toFrame: max(0, position))
        let skipped = min(Int64(buffer.frameLength), max(0, frames - position))
        let count = Int64(buffer.frameLength) - skipped
        guard count > 0 else { return }
        if skipped == 0 { try file.write(from: buffer) }
        else {
            let tail = try AudioFileTools.pcmBuffer(format: format, capacity: AVAudioFrameCount(count))
            tail.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(format.channelCount) {
                tail.floatChannelData![channel].update(from: buffer.floatChannelData![channel].advanced(by: Int(skipped)), count: Int(count))
            }
            try file.write(from: tail)
        }
        frames += count
    }

    func pad(to time: Double) throws {
        guard time.isFinite, time >= 0, time * format.sampleRate < Double(Int64.max / 2) else { throw audioError("Invalid recording end time.") }
        try pad(toFrame: Int64((time * format.sampleRate).rounded()))
    }

    private func pad(toFrame end: Int64) throws {
        guard let file, frames < end else { return }
        let silence = try AudioFileTools.pcmBuffer(format: format, capacity: AudioFileTools.blockSize)
        for channel in 0..<Int(format.channelCount) { silence.floatChannelData![channel].update(repeating: 0, count: Int(silence.frameCapacity)) }
        while frames < end {
            silence.frameLength = AVAudioFrameCount(min(Int64(silence.frameCapacity), end - frames))
            try file.write(from: silence)
            frames += Int64(silence.frameLength)
        }
    }

    func close() { file = nil }
}

/// Only microphone buffers are delayed. Epochs invalidate copies queued before mute.
/// Its lock is never acquired by an audio callback with a blocking wait.
final class AudioMicrophoneHoldback {
    struct Frame { let buffer: AVAudioPCMBuffer; let time: Double; let token: UInt64 }
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var pending: [Frame] = []
    private var pendingFrames = 0

    var token: UInt64? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return enabled ? generation : nil
    }

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard enabled != value else { return }
        enabled = value
        generation &+= 1
        if !value { pending.removeAll(); pendingFrames = 0 }
    }

    @discardableResult func append(_ buffer: AVAudioPCMBuffer, at time: Double, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, token == generation else { return true }
        // Normally two seconds; bound malformed timestamps and stalled drainers as well.
        let byteCount = (pendingFrames + Int(buffer.frameLength)) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
        guard pending.count < 512, byteCount <= 16 * 1_024 * 1_024 else { return false }
        pending.append(Frame(buffer: buffer, time: time, token: token))
        pendingFrames += Int(buffer.frameLength)
        return true
    }

    func takeVerified(at time: Double) -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return [] }
        var count = 0
        while count < pending.count && pending[count].time + Double(pending[count].buffer.frameLength) / pending[count].buffer.format.sampleRate <= time - 2 {
            pendingFrames -= Int(pending[count].buffer.frameLength)
            count += 1
        }
        let ready = Array(pending.prefix(count))
        pending.removeFirst(count)
        return ready
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && token == generation
    }

    func discardPending() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        pending.removeAll(); pendingFrames = 0
    }
}
