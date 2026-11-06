# Implementation ledger

- User authorized implementation; all code goes under MeetingScribe/code.
- New isolated feat/first-release repository. Design decisions retained from this conversation.
- Default Feishu-follow mic gate; unknown closes local mic. Auto-detection off on first launch until user enables it.
- Original independent audio and API modules completed; no PLAUD proprietary source or binaries used.
- Detection tests initially failed as expected, then passed. Audio tests caught EOF, frame-tail and raw amplitude issues and were corrected.
- Integration review found 7 lifecycle/privacy races; all closed by scoped re-review after fixes. Current core suite: 50 passing tests.
- UI validation: welcome, settings, ASR, Markdown, transcript versions/timestamps, local two-second WAV import. NavigationSplitView sidebar was invisible; replaced with explicit native HSplitView and visually revalidated.
- GUI used only Validation/Library and labeled synthetic fixtures. No microphone/system recording, external model calls, or permission grants performed.
- Build artifact: Builds/MeetingScribe.app, arm64, ad-hoc signed. Every source/test/resource/build script is in code/.
- Remaining acceptance: actual Feishu AX labels/mute timing, device routing and changes, system audio capture permissions, H800 API compatibility, real PLAUD share samples. These are not claimed verified.
