# Native audio subsystem result

Implemented and compiled on 2026-11-06. No live audio capture, device permission request, tool installation, subagent, or commit was performed.

## Validation

- **15/15 AudioTests passed**, zero failures; final focused run: 16:52:55 Asia/Singapore.
- **44/44 shared tests passed**, zero failures; final full run: 16:53:26 Asia/Singapore. Includes 22 API, 15 audio, 4 detection, and 3 store tests. The package executable compiled as part of this run; it was not launched by this worker.
- An explicit `swiftc -typecheck -swift-version 5 -target arm64-apple-macosx14.0` of Models.swift and the two audio implementation files passed without diagnostics. Tap implementation is guarded/annotated for macOS 14.2.
- Tests were written before the audio implementation. Initial failures were missing implementations, followed by a real EOF handling failure. The reader now checks remaining frames before reading. The later two AudioTests failures in `Validation/tests.log` are resolved: the test reader now loops over partial reads, and raw Float32 samples retain finite values above unity. The three LocalStore failures were fixed by the parent, without edits by this worker.
- Synthetic coverage: 48 kHz stereo and 44.1 kHz conversion, PCM16 WAV format and frame counts, source/hard-link protection, failure-safe destination replacement, chunk offsets/remainders/exact boundaries/empty input, timestamped gates, independent system gating, host-clock gaps/overlap trimming, mix headroom, two-second microphone holdback, stale-token rejection, mute/stop discard, bounded pending memory, and retained silence at dropped microphone positions.

Reproducible commands from `MeetingScribe/code` (cache flags keep the sandbox from writing global Swift caches):

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build-audio/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-audio/ModuleCache" \
swift test --disable-sandbox \
  --cache-path .build-audio/cache \
  --config-path .build-audio/config \
  --security-path .build-audio/security \
  --scratch-path .build-audio --filter AudioTests
```

Remove `--filter AudioTests` for the full suite. Logs: `code/.build-audio/audio-final-tests.log`, `code/.build-audio/full-suite.log`, and `code/.build-audio/availability-check.log` (empty output, successful exit).

## Public APIs and integration

All interfaces from `audio-brief.md` are implemented. The requested integration addition is:

```swift
public var onFatalIssue: ((String) -> Void)?
```

`onFatalIssue` runs on MainActor **after hardware is stopped and raw file handles are closed**. The parent should call `stop()`/`endRecording()` to mix retained tracks and clear its recording UI/timer. Repeated fatal notifications are suppressed. A fatal error during an already-running `stop()` is reported through `onIssue`; finalization continues or throws. If no fatal callback is installed, fatal messages fall back to `onIssue` so they are not silent. Ordinary warnings and microphone-start failures use `onIssue`; microphone-start failure leaves system capture running.

`onLevel` is **(microphone, system)**, linear RMS. Microphone levels reflect verified buffers and therefore have the holdback delay. `setPaused` gates both sources to silence and preserves host-clock positions/duration. A nonempty microphone UID selects exactly that device through `AudioUnitSetProperty`; an unavailable UID never silently falls back. An empty UID explicitly requests the current default input. No engine opens in `init`, and initially disabled microphone capture does not start an engine. Later enabling attempts microphone startup.

## Capture, storage, and privacy behavior

- Original Swift using a global stereo `CATapDescription`, private aggregate, and IOProc; excludes this app's audio process when Core Audio can resolve it. Failure to resolve exclusion generates a warning. Tap mute behavior is unmuted; no global output volume or mute is changed.
- Independent AVAudioEngine microphone input. Timestamped gates are applied to copied buffers before storage. The gate starts closed; a true start parameter or later explicit enable opens it. Disabled and paused intervals contain no retained microphone samples.
- **Microphone-only holdback:** each complete buffer ages at least two seconds before persistence. Disabling or pausing synchronously clears pending buffers and invalidates queued copies. Stop discards all unverified microphone buffers instead of flushing them. This can lose the final approximately two seconds (plus one callback/monitor interval). Dropped intervals remain silence at their original positions. System capture is not subject to the microphone holdback.
- This mitigates lag in the parent's experimental Feishu AX observations; it **cannot guarantee detection of unseen rapid mute toggles or an observation lag longer than the holdback**. The parent owns reliable/unknown mute decisions and its fail-closed policy.
- Native-rate Float32 `system.caf` and, when instantiated, `microphone.caf` are aligned to a common host-clock origin. A streaming `audio-timeline.jsonl` records clock positions. Gaps are zero-filled and overlaps trimmed; callbacks are not simply concatenated.
- The audio callback copies bounded PCM buffers and uses nonblocking lock/semaphore attempts. File IO, holdback draining, logging, and levels are serialized off the audio thread. At most 32 copied callbacks are queued; pending microphone audio is capped at 16 MiB/512 buffers. Callback lock contention can produce a clock-aligned gap; queue overflow stops capture explicitly.
- Stop closes raw files before bounded-memory normalization/mixing to `recording.wav` (16 kHz, mono PCM16). Two tracks receive fixed 0.5 gain each for headroom; a single track retains unity gain. Raw files remain if normalization or mixing fails. Temporary conversions are cleaned up and outputs published by same-directory rename.
- Device/format changes and missing callback heartbeats stop hardware, retain raw files, and invoke the fatal callback. This implementation chooses a clear retained-audio stop, rather than rebuilding capture during a meeting. The user can start a new recording after selecting the new configuration.
- System audio may include all apps. No echo-cancellation, speaker identity, or isolated Feishu/browser-tab capture is claimed.

## Runtime acceptance still required

Synthetic file tests and compilation do not verify Core Audio permission behavior, real IOProc delivery, microphone routing, device unplug/replug, audio quality, or AX timing in a real meeting. The app bundle must supply `NSAudioCaptureUsageDescription` and `NSMicrophoneUsageDescription`; the parent owns packaging and user permission flows. Native capture currently accepts Float32 device buffers and reports unsupported formats explicitly.

API references were checked against the installed SDK and Apple's [system audio tap documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) and [CATapDescription documentation](https://developer.apple.com/documentation/coreaudio/catapdescription).

## Files owned by this worker

- `code/Sources/MeetingCore/AudioCaptureService.swift`
- `code/Sources/MeetingCore/AudioFileTools.swift`
- `code/Tests/MeetingCoreTests/AudioTests.swift`
- `docs/audio-result.md` (this report)

Package.swift, Models.swift, UI, coordinator, and other workers' source/tests were not edited.
