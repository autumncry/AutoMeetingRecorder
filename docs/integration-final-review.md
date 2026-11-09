# MeetingScribe final scoped review

Reviewed 2026-11-06 17:15 +08. **R1 and R2 are closed by static inspection. No remaining findings within these two fixes.**

| Residual | Verdict | Source evidence |
| --- | --- | --- |
| R1: disable-before-reject loses suppression | Closed | [AutomaticStartGate.swift:11](../code/Sources/MeetingCore/AutomaticStartGate.swift:11), lines 11–19: `began()` establishes `rejectableEpisode`; `disabled()` preserves it; `suppressCurrent()` accepts `active || rejectableEpisode`. A rejected episode therefore remains suppressed across disable/re-enable. `ended()` clears the episode and suppression, and eight seconds of observed absence invokes that cleanup even when only `rejectableEpisode` remains. |
| R2: AX budget check consumes unprocessed work | Closed | [MeetingDetector.swift:38](../code/Sources/MeetingCore/MeetingDetector.swift:38), lines 38–39: node/time limits and nonempty stack are checked before `removeLast()`. At the limit, the unprocessed node remains queued. [MeetingDetector.swift:60](../code/Sources/MeetingCore/MeetingDetector.swift:60), lines 60–65: remaining work marks the observation invalid and mute unknown. The previously reported final-node loss no longer occurs. |

The added ordering assertions at [DetectionTests.swift:18](../code/Tests/MeetingCoreTests/DetectionTests.swift:18) cover disable-before-reject and departure-before-disable; the observed-absence assertions at line 26 remain present. Tests were read, not executed.

Final disposition across the review sequence: the five findings closed in `integration-rereview.md` remain the prior review result; this pass closes its two residuals. This is not a fresh audit of those five fixes or other concurrent edits, including unrelated AX traversal changes.

No implementation edits, tests, builds, agents, recording, or network calls were performed. Only this report was created. Full-suite/build and live-device acceptance remain with the parent; this review makes no claim that those validations passed.
