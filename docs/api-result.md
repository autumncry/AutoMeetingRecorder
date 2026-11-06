# API client and PLAUD importer result

Implemented the assigned services and tests. Final verification on 2026-11-06: package build succeeded; **23 APITests passed, 0 failures**. All HTTP traffic in these tests used local `URLProtocol` fixtures; no private API, PLAUD account, or remote audio was accessed.

## Files owned by this change

- `code/Sources/MeetingCore/AIClient.swift`
- `code/Sources/MeetingCore/ShareLinkResolver.swift`
- `code/Tests/MeetingCoreTests/APITests.swift`
- This report.

No package, model, UI, coordinator, audio implementation, or other test files were edited. No subagents, commits, or tool installations were used. Generated build/cache files are under `code/.build-api`.

## Implemented behavior

`AIClient` implements the exact public signatures in `api-brief.md` against the current shared models:

- HTTP/HTTPS endpoint validation; origin roots append `/v1`; `/v1` roots and complete endpoints retain their paths without duplicate endpoints. Complete endpoints without `/v1` are preserved. Query parameters are retained, fragments removed, embedded user/password credentials rejected.
- Multipart ASR with a fixed safe upload filename, required model, optional bearer key, and nonblank language/prompt/response_format fields. File size is checked against `maxUploadMB` before constructing the request.
- Chat ASR accepts WAV and supports the new `chatAudioFormat`: default `audio_url` uses `{ "type": "audio_url", "audio_url": { "url": "data:audio/wav;base64,..." } }`; explicit `input_audio` uses `{ "type": "input_audio", "input_audio": { "data": "...", "format": "wav" } }`. Unknown formats fail before HTTP. The prompt and optional language hint are text content; the transcription-only string `responseFormat` is not sent as the incompatible chat JSON-schema option.
- `{duration}` expands to the local file's duration in seconds with three decimal places. Audio metadata is opened only when that placeholder occurs. `{hotwords}` expands to empty because the shared model has no hotword field; no terms are invented. Literal hotwords can remain in the configured prompt.
- Standard text/segments/words, string and array chat content, fenced JSON, VibeVoice Start/End/Speaker/Content arrays, known Qwen `language …<asr_text>` framing, and readable malformed-text fallback. HTML and error objects are rejected. Offset is applied to timestamps; missing timestamps use the supplied chunk offset without inventing an end time.
- `rawResponse` is capped at 65,536 UTF-8 bytes, with a supplied bearer key redacted before returning the debug response. HTTP error messages include status but never echo server error bodies or keys.
- LLM input is split into at most 14,000-character chunks and recursively reduced before final synthesis. System prompt limit: 8,000 characters; intermediate response limit: 6,000 characters; reduction must shrink and is capped at 16 rounds. There is no cloud fallback or automatic retry.
- API request timeout is clamped to 10–1,800 seconds (NaN defaults to 300). HTTP response bodies are bounded to 2 MiB during reading. Async requests propagate cancellation.

`ShareLinkResolver` imports direct HTTP/HTTPS audio and public audio advertised by `plaud.cn` or its subdomains:

- Bounded 2 MiB share-page GET; audio/source elements, `og:audio` metadata, AudioObject JSON-LD, and explicit audio_url/audioUrl/download_url/recording_url keys in JSON or simple JSON assignments. Relative links and HTML entities are resolved. Scripts are parsed as data, never executed; summary strings and script-contained fake HTML tags are not audio candidates.
- Cross-host extracted audio must use HTTPS and be explicitly advertised by the PLAUD page. Signed query parameters are preserved. The first eligible candidate is selected.
- Uses `URLSession.download` for disk-backed downloads, checks advertised/progress/final size against 2 GiB, validates HTTP status, rejects HTML/JSON/text responses, and recognizes common audio/container signatures. Imports use unique `import-UUID.ext` filenames and never use a remote filename or overwrite an existing import.
- The dedicated import session removes **all inherited extra headers**, cookies, credential storage, and URL cache. No browser login or credential extraction is attempted. Authentication challenges other than normal TLS trust are cancelled.
- Redirects accept only HTTP/HTTPS URLs without embedded credentials, with an eight-redirect cap. **API POST redirects to a different scheme, host, or port are refused entirely**, so neither bearer keys nor request bodies can be forwarded cross-origin. Download redirects clear Authorization, Proxy-Authorization, and Cookie headers.
- Private, authenticated, expired, unsupported, or unextractable links return Chinese guidance to export audio from PLAUD and import the local file. Cancellation leaves no completed import behind.

## Verification

Executed from `code/`:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build-api/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-api/ModuleCache" \
swift test --disable-sandbox --cache-path .build-api/cache \
  --scratch-path .build-api --filter APITests
```

Final result: build succeeded in 3.75 seconds; 23 tests passed in 0.130 seconds. The cache settings and `--disable-sandbox` were needed because this workspace blocks the normal user cache and SwiftPM's nested manifest sandbox. No extra permissions or installations were required.

Coverage includes multipart body/headers and optional fields, endpoint normalization including complete paths and queries, both base64 audio formats, placeholder gating, response variants and offsets, raw output limits, HTTP/input errors, two-level summary reduction, oversized responses/prompts/partial summaries, HTML/JSON-LD/embedded-JSON link fixtures, signed/relative URLs, no-overwrite imports, fake audio, download size limits, inherited credential removal, redirect policy, and cancellation before/during API calls and downloads.

The parent-provided `Validation/tests.log` snapshot from 16:50:43 already showed **22 APITests passing**. Its five failures were three StoreTests and two AudioTests, not API tests. The two audio failures were `testDroppedHoldbackFramesBecomeSilenceInRawFile` and `testMicrophoneMuteDoesNotGateSystemOrClipRawFloatSamples`; those files were left to their owner. The final run above filters APITests and does not assert that the complete integration suite is green.

## Limits and integration notes

- Mocked transport proves request construction, parsing, bounds, and failure handling; it does not establish live provider compatibility, transcription accuracy, or universal PLAUD-link support.
- The caller still owns normalization, splitting, scheduling/concurrency, and transcript persistence. Multipart/base64 upload bodies are constructed in memory within the configured upload limit. WAV validation checks framing; ordinary uploads do not decode audio.
- Share extraction does not run JavaScript, log in, decrypt media, or refresh expired signed URLs. Unrecognized page structures and failed first candidates require local export/import. PLAUD paths without a known audio extension are treated as share pages; opaque direct-media endpoints on that domain may require local export/import.
- Download validation checks MIME and container signatures, not a complete audio decode or a guarantee that every container has a playable audio track. Playback/normalization remains with the native audio layer.
- `{hotwords}` has no configured source in the current model and therefore expands to empty. This can be wired to a dedicated model field later without changing the public client contracts.
