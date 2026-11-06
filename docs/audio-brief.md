# Audio implementation worker

Implement original Swift code only under `code/Sources/MeetingCore/AudioCaptureService.swift`, `AudioFileTools.swift`, and focused tests `code/Tests/MeetingCoreTests/AudioTests.swift`. Read shared Models.swift. Do not edit Package.swift/models/UI. No recording during tests; synthetic file tests only. No other agents/commits.

Public contract:

```
@MainActor public final class AudioCaptureService {
 public init()
 public var onLevel: ((Float, Float) -> Void)?
 public var onIssue: ((String) -> Void)?
 public static func inputDevices() -> [InputDevice]
 public func start(in directory: URL, microphoneUID: String, microphoneEnabled: Bool) throws
 public func setMicrophoneEnabled(_ enabled: Bool)
 public func setPaused(_ paused: Bool)
 public func stop() async throws -> CaptureResult
}
public enum AudioFileTools {
 public static func prepareForASR(source: URL, destination: URL) async throws -> Double
 public static func splitForASR(source: URL, into directory: URL, seconds: Double) throws -> [AudioChunk]
 public static func duration(of url: URL) throws -> Double
}
```

CoreAudio CATapDescription global stereo/mono with exclusion of this app output if practical, private aggregate and IOProc. macOS 14.2 API annotated @available as necessary but app deploy min14.2 in bundle; package min14.0. Mic independent AVAudioEngine input; selecting microphone via AudioUnitSetProperty kAudioOutputUnitProperty_CurrentDevice. No proprietary native binary. Retain raw system.caf and microphone.caf with common host-clock alignment and generate recording.wav 16k mono. Record clock positions rather than concatenate callbacks with arbitrary drift. Gate local samples BEFORE writing raw and mixed output; initial false must never leak mic buffers. A disabled mic can omit mic engine if unavailable but later enabling should attempt it. User can change gate at runtime. Unknown mute gate supplied by coordinator. Callback file IO off audio real-time thread; copied buffers, serialization, safe teardown; errors via onIssue. Stop must close files and mix; preserve raw if errors. Mixing memory bounded for long meetings, avoid clipping. Device configuration change should recover/rebuild or clearly stop with retained audio (not silent failure). Clean up aggregate/tap on start failure and stop. No implicit global system volume changes. Sound may include all apps; no claim echo cancellation. Own exact function availability via SDK and compile.

File normalization supports AVFoundation readable audio to WAV 16k mono PCM16, overwrite destination only if source differs; chunks fixed duration with correct offsets and no empty trailing chunk. Write synthetic audio meaningful tests (duration, mix/gate helper, chunk sizes/sample count) before implementation where possible. Use `swift test --scratch-path .build-audio --filter AudioTests` to avoid main build collision. Parent builds UI. Report APIs/issues/tests and files in docs/audio-result.md. Do not ask user for device permission or start capture.
