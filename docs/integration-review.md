# MeetingScribe integration review

Rechecked 2026-11-06 17:04 +08 against the current original working tree. **Seven findings: three P1 and four P2.** This is a static review of the current original working tree, not a patch review or runtime acceptance result. Implementation files were not changed; no agents were spawned.

Scope: `docs/spec.md`, `AppModel.swift`, `RecordingWorkflow.swift`, `ProcessingWorkflow.swift`, `MeetingDetector.swift`, `DetectionRules.swift`, and `LocalStore.swift`. Models, UI callers, existing detector/store tests, and audio/API public declarations were read only to establish contracts and reachable paths. Audio capture/conversion, API, and share-resolver internals are outside this review.

## Findings

### 1. [P1] Revalidate an automatic start after the microphone permission await

**Location:** [RecordingWorkflow.swift:11](../code/Sources/AutoMeetingRecorder/RecordingWorkflow.swift:11), lines 11–20. Related: [AppModel.swift:65](../code/Sources/AutoMeetingRecorder/AppModel.swift:65), lines 65–67.

An automatic start can suspend at `requestAccess` before setting `activeRecording` or `automaticSession`. If the meeting ends while the permission prompt is open, the detector's end callback returns because no recording is active. Once the user answers the prompt, the suspended start unconditionally creates a session and starts capture; it never checks whether that detection episode still exists. Disabling automatic detection during the await has the same problem. For a previously certain candidate, the resumed session is immediately `.recording`, so the unrelated system audio it captures is eligible for automatic transcription on a later stop. The already-consumed end event will not stop it.

**Required correction:** associate automatic starts with a detection generation; invalidate that generation on confirmed absence or detection disable, and revalidate it after permission waits and immediately before capture. Do not require fresh certainty to preserve an otherwise valid pending candidate.

### 2. [P1] A second stop returns before finalization, allowing Quit to terminate it

**Location:** [RecordingWorkflow.swift:57](../code/Sources/AutoMeetingRecorder/RecordingWorkflow.swift:57), lines 57–63. Reachable caller: [AutoMeetingRecorderApp.swift:64](../code/Sources/AutoMeetingRecorder/AutoMeetingRecorderApp.swift:64).

Start a stop/discard, let `capture.stop()` suspend, then quit and choose “保存并退出”. `activeRecording` remains non-nil throughout finalization, so the termination handler calls `endRecording()` again. The second call returns immediately because `isStopping` is true; the handler then replies that termination may proceed while the first call is still finalizing. The manifest update or pending-directory removal has not necessarily happened. A rejected pending recording can consequently remain on disk until a later launch. Explicit discard of a confirmed recording is worse: its durable pending marker is only written after the await at lines 65–67, so recovery can retain it as an interrupted/ready recording.

**Required correction:** callers must join one shared stop/finalization task, especially termination. Persist explicit discard intent before asynchronous finalization so interruption cannot reverse the user's deletion decision. This finding does not assume anything about the audio worker's internal flushing implementation.

### 3. [P1] AX query failures and incomplete scans are converted into confirmed absence

**Location:** [MeetingDetector.swift:25](../code/Sources/MeetingCore/MeetingDetector.swift:25), lines 25–29; [MeetingDetector.swift:83](../code/Sources/MeetingCore/MeetingDetector.swift:83), lines 83–90.

`attribute` turns any AX error into nil (lines 54–56), window/child failures become empty collections, and exceeding the 250 ms/500-node scan limits also leaves `inMeeting` false when the leave control was not reached. None of those outcomes means the meeting ended. If `pmset` succeeds but contains no attributable input assertion—for example, an ongoing meeting currently supported only by its AX window evidence—these failures produce `candidate = false`. After eight seconds, the detector emits `.ended` and the coordinator stops the recording. The nil-preserving presence machine only protects failures of `readActivity`, not failures of the other source used to establish presence. This violates the query-failure requirement in `docs/spec.md:6`.

**Required correction:** represent AX presence validity/completeness separately from absence. When no positive evidence is available and a required observation failed or was incomplete, feed unknown into the presence machine while keeping the microphone gate closed. A successfully observed absence can still start the normal end debounce.

### 4. [P2] Selecting a transcript version during processing causes conflicting persisted state

**Location:** [ProcessingWorkflow.swift:149](../code/Sources/AutoMeetingRecorder/ProcessingWorkflow.swift:149), lines 149–155. Related: [ProcessingWorkflow.swift:133](../code/Sources/AutoMeetingRecorder/ProcessingWorkflow.swift:133), lines 133–145; enabled caller at [SessionDetailView.swift:73](../code/Sources/AutoMeetingRecorder/SessionDetailView.swift:73).

With versions A and B present and B selected, start summarizing B. While `summarize` is suspended, select A. `selectVersion` writes A to `transcript.md` and saves selected ID A. The processing task subsequently saves its earlier copy of the session, restoring selected ID B without restoring B's `transcript.md`. The UI/manifest and the exported Markdown now disagree; even the processing error handler overwrites the selection this way. During retranscription, `saveTranscript` also persists the new version before publishing it to `sessions`, so a version selection during the following summary request can temporarily remove that new version from the manifest; interruption in that interval leaves its files orphaned from the version list.

**Required correction:** prevent version mutation for the session being processed, or merge job results into the latest session with an explicit transcript ID and update the Markdown alias consistently. The existing summary-edit guard demonstrates the intended exclusion, but version selection lacks it.

### 5. [P2] A new meeting beginning during the previous stop is permanently dropped

**Location:** [AppModel.swift:61](../code/Sources/AutoMeetingRecorder/AppModel.swift:61), lines 61–63. Related: [RecordingWorkflow.swift:61](../code/Sources/AutoMeetingRecorder/RecordingWorkflow.swift:61), lines 61–63; [DetectionRules.swift:55](../code/Sources/MeetingCore/DetectionRules.swift:55), lines 55–57.

After meeting A produces `.ended`, its recording remains active while asynchronous finalization runs. If meeting B becomes stable for three seconds before that finalization finishes, the presence machine sets itself active and emits B's sole `.began`. The coordinator drops it because `activeRecording`/`isStopping` is still set. Finishing A merely calls `configureDetection`; `detector.start()` is a no-op for the already-running detector. B remains present, so no new `.began` arrives and its recording never starts. This requires finalization to overlap B's start threshold; it does not depend on an audio implementation defect.

**Required correction:** retain/reconcile a newer detection episode after finalization, with generation-aware rejection suppression. Retrying every still-present episode indiscriminately would reintroduce recording after rejection.

### 6. [P2] Toggling automatic detection forgets that the current session was rejected

**Location:** [MeetingDetector.swift:97](../code/Sources/MeetingCore/MeetingDetector.swift:97). Caller: [AppModel.swift:99](../code/Sources/AutoMeetingRecorder/AppModel.swift:99), lines 99–101.

Reject a pending recording while its meeting signal remains present. With detection continuously enabled, `machine.active` correctly suppresses another start. Turn automatic detection off after cleanup, then back on without leaving that meeting: `stop()` resets the entire presence machine, and the same signal produces another start after three seconds. There is no separate rejected-episode state, so the requirement “until the signal leaves” is lost across this ordinary settings transition. If AX certainty improves meanwhile, the restarted session can also be a confirmed recording rather than another pending prompt.

**Required correction:** retain rejection suppression independently of the polling task's lifecycle and clear it only after observed departure. Starting a new detector task must not itself clear that decision.

### 7. [P2] Switching libraries skips recovery and leaves abandoned pending audio retained

**Location:** [AppModel.swift:123](../code/Sources/AutoMeetingRecorder/AppModel.swift:123). Compare startup at lines 54–55 and [AppModel.swift:108](../code/Sources/AutoMeetingRecorder/AppModel.swift:108), lines 108–117.

Recovery runs only during initialization. Switching to a library left with `.pending`, `.recording`, or `.processing` manifests by an interrupted run calls only `reload()`. Pending audio in that library is consequently retained without a 120-second task or an active recording that can be rejected. Abandoned `.recording` entries also remain stuck with processing actions disabled. Opening the same library at app launch would clean/recover these records, so choosing it in Settings should not bypass that lifecycle step.

**Required correction:** run interrupted-session reconciliation when opening a different library, after ensuring it has no live jobs, and surface cleanup failures. This finding is independent of the already-known `LocalStore.directory` path failure.

## Boundaries that hold in the inspected control flow

- In follow-Feishu mode, `localMicAllowed` requires authorized audio access, `.unmuted`, `inMeeting`, and a sample younger than 1.8 seconds. Unknown/muted observations close the requested gate; the quarter-second clock also checks expiry. This is coordinator evidence only, not proof of physical mute-boundary timing or raw-track gating.
- Normal pending sessions are rejected by `enqueue` and `process`. `endRecording` discards a pending session even when a caller omits the discard flag, including the fatal-capture callback. Confirmation writes the recording state before canceling the timeout. No ordinary pending-to-upload route was found in these paths.
- `MeetingPresenceMachine.update(present: nil)` preserves active presence and resets debounce timers. A `pmset` query failure reaches that path. Continuous monitoring suppresses a rejected episode until observed absence; finding 6 concerns resetting the detector.
- `LocalStore.discardPending` checks both the supplied status and the on-disk ID/status before deletion. Transcript filenames are versioned. These checks do not resolve the coordinator races above.

## Validation and limits

No tests, builds, live recording, permission prompts, or network requests were run. Findings are reachable source-level scenarios; none is represented as a reproduced device failure. The existing `Validation/tests.log` at 16:50:43 is a historical failed run, not current integration status. The integration coordinator reports audio 15/15 passing, a previous full 44-test pass, a store URL canonical-comparison fix, and 45 expected tests after one API addition. Those reported results were not independently rerun and the old failures are not counted as findings. The coordinator also reports native UI/settings launch without capture. Fatal-capture handling and the 1.8-second/deduplicated microphone gate are present in the inspected AppModel, and the current ProcessingWorkflow moves copying/splitting off the main actor; these changes do not remove the seven findings above. The four inspected detector tests cover basic parsing, mute-label inversion/ambiguity, and a nil-query state-machine case; they do not establish the coordinator interleavings or AX-failure propagation above.

Real Feishu mute labels, AX timing, device changes, raw microphone privacy, audio finalization, ASR/LLM transport, and share-link behavior require their owners' validation. Other workers were active during this review; the source fingerprints below identify the inspected snapshot and are not a claim about later edits.

Snapshot fingerprints refreshed 2026-11-06 17:04 +08:

```text
c142a31c1a5ec8118e7661d8705f42c81c03e78a7c1c50ebe72ea877a4c39675  docs/spec.md
2c5736d98ed0af1b797b0f965c8561bc9376fe5a5ff943e1bb9d400f90f43d6b  code/Sources/AutoMeetingRecorder/AppModel.swift
77e9cfb605dc8fa6749dfe51fbd31b1aa2da7168f85efb223a88abde3edd5097  code/Sources/AutoMeetingRecorder/RecordingWorkflow.swift
83922f5789b5d6b83e8412e907131bc6e41bcda9056500dfcfb3ab5d40a8927b  code/Sources/AutoMeetingRecorder/ProcessingWorkflow.swift
37da6a4a1cce0bdd96e19b1e892fc927952ef0c648090b58ba0e439ac7c32c66  code/Sources/MeetingCore/MeetingDetector.swift
2f5ab5b2d36f11eb0ebdecd5b6d2a18a095409ff5aee7157f579b47aaa59c72c  code/Sources/MeetingCore/DetectionRules.swift
555090dabc69610060f6c0f177572766d3584239f3e2cbb41ca9e44bb564165d  code/Sources/MeetingCore/LocalStore.swift
```
