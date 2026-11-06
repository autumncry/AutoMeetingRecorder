# MeetingScribe scoped integration re-review

2026-11-06, Asia/Singapore. **Verdict: five of the seven original findings are closed by static inspection; two remain partially fixed, with one P2 residual each.** Review is limited to the seven fixes and their direct callers. No tests, builds, recording, network calls, or agents were run. Only this report was written.

## Remaining findings

### R1. [P2] Rejecting after detection is disabled does not retain suppression

**Location:** [AutomaticStartGate.swift:13](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingCore/AutomaticStartGate.swift:13). Related: [AppModel.swift:113](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/AppModel.swift:113) and [RecordingWorkflow.swift:67](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/RecordingWorkflow.swift:67). Residual of original finding 6.

Concrete sequence: an automatic pending recording is active; turn detection off; reject that recording; after finalization, turn detection back on while the same meeting remains present. Disabling calls `automaticGate.disabled()`, which sets `active = false`. The subsequent rejection calls `suppressCurrent()`, but its `if active` guard prevents setting `suppressed`. Finalization stops/resets the detector while detection is disabled. Re-enabling therefore emits another `began`, and the gate permits the same rejected meeting to start again without any observed departure. The new test covers rejection **before** disabling, which is fixed, but not this reverse ordering.

**Minimal correction:** preserve an identifiable current/rejectable episode across disable, or explicitly suppress the recording's episode on rejection even when automatic starts have been disabled. Suppression should still clear only after observed departure; do not indiscriminately suppress unrelated future episodes.

### R2. [P2] The AX node limit can discard the last queued node and report a complete scan

**Location:** [MeetingDetector.swift:32](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingCore/MeetingDetector.swift:32), with the completion check at [MeetingDetector.swift:50](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingCore/MeetingDetector.swift:50). Residual of original finding 3.

`while let (node, toolbar) = stack.popLast(), visited < 500, Date() < deadline` pops before checking the node budget. If 500 nodes have been processed and exactly one remains queued, the next condition removes that node and then exits. The post-loop `!stack.isEmpty` check is false; if the time deadline has not expired, `failed` stays false even though the node and its subtree were never inspected. If the missed node/subtree contains the leave control and there is no input assertion, the new presence mapper receives `uiValid = true, inMeeting = false` and returns false. Repeated snapshots can still end the ongoing recording after eight seconds. This includes a larger tree reached through a single remaining branch, not just a tree with exactly 501 nodes.

**Minimal correction:** check the node/time budget before removing the next node, leaving unprocessed work in the stack, or explicitly record budget exhaustion. The new presence-mapping test validates an already-invalid observation; it does not cover this producer-side boundary.

## Disposition of the original seven findings

| Original finding | Re-review result | Inspected fix |
| --- | --- | --- |
| 1. Stale start after permission wait | Closed in inspected flow | [RecordingWorkflow.swift:9](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/RecordingWorkflow.swift:9): generation permission checked before and after the await; end/disable invalidates the token. |
| 2. Quit bypasses in-flight stop | Closed in inspected flow | [RecordingWorkflow.swift:60](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/RecordingWorkflow.swift:60): later callers join through continuations; discard intent is saved before finalization; waiters resume after cleanup. [MeetingScribeApp.swift:64](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/MeetingScribeApp.swift:64) sets `terminating` before joining, and deferred starts/new stop-triggered ASR enqueue respect it. |
| 3. Failed/incomplete AX read becomes absence | Partial: R2 remains | AX failures now invalidate the observation and close the microphone gate; `DetectionRules.presence` preserves unknown observations. The node-budget boundary above can still produce a false valid observation. |
| 4. Transcript selection races processing | Closed in inspected flow | [ProcessingWorkflow.swift:150](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/ProcessingWorkflow.swift:150): selection returns before any file/session write while that session is processing. |
| 5. New meeting lost during finalization | Closed in inspected flow | [AppModel.swift:70](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/AppModel.swift:70) retains the new generation; [AppModel.swift:117](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/AppModel.swift:117) revalidates/replays after finalization and blocks replay during termination. |
| 6. Detection toggle forgets rejection | Partial: R1 remains | Existing suppression survives disable/restart, but disabling before rejection prevents suppression from being established. |
| 7. Library switch skips recovery | Closed in inspected flow | [AppModel.swift:143](/Users/ronny/Syncthings/ClaudeCodeOfficial/MeetingScribe/code/Sources/MeetingScribe/AppModel.swift:143): switching calls recovery after reload; pending-cleanup errors are surfaced. |

The four added detection tests were read, not executed. Suite/build results remain with the parent. This verdict establishes source-level disposition of the seven reported issues only; it is not live Feishu, microphone, audio-finalization, or endpoint acceptance. Audio/API internals were not re-reviewed.
