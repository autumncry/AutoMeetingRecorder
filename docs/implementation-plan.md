# MeetingScribe Implementation Plan

**Goal:** deliver a runnable personal Mac meeting recorder and ASR/LLM client.
**Architecture:** SwiftPM MeetingCore + SwiftUI app, Core Audio tap, pmset/AX detector, atomic local session folders.
**Tech Stack:** Swift, SwiftUI, CoreAudio, AVFoundation, URLSession, Security; no third-party package.
**Spec:** docs/spec.md

## Constraints and review focus

All implementation code/scripts/tests under code/. No server, no proprietary PLAUD code. Unknown mute closes local mic. Pending recordings never upload. Query failures are not absence. Treat AX action label inversion carefully. Chunk offsets, long uploads, recovery, key redaction, and original-audio preservation require tests.

## Tasks

- [x] Shared models, settings/keychain, atomic session persistence.
- [x] pmset parser + detector state machine + read-only Feishu AX probe; regression tests for ambiguous labels, self/output exclusion and rejection suppression.
- [x] Native capture and audio conversion/chunk/mix utility; independent worker with synthetic-audio tests.
- [x] ASR/LLM HTTP and Plaud resolver; independent worker with request/response/error tests.
- [x] Coordinator, pending notifications, queues, recovery, Markdown library/player and settings.
- [x] Compile, test, package/sign, GUI validation, review, documentation. Live permission/device/endpoint acceptance remains explicitly separate.

Shared types in code/Sources/MeetingCore/Models.swift are authoritative. Native and API worker briefs define method interfaces; each worker owns disjoint files and tests. Parent integrates and performs final checks. No repeated approval gate: user explicitly requested completed software.
