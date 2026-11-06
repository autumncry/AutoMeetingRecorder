# API / share resolver worker

Implement original Swift only in code/Sources/MeetingCore/AIClient.swift and ShareLinkResolver.swift; tests code/Tests/MeetingCoreTests/APITests.swift. Read Models.swift for shared types. Do not edit package/models/UI/audio. No other agents/commits.

Contracts:
```
public struct AIClient {
 public init(session: URLSession = .shared)
 public func transcribe(file: URL, profile: ASRProfile, apiKey: String?, offset: Double = 0) async throws -> TranscriptResult
 public func summarize(transcript: String, profile: LLMProfile, apiKey: String?) async throws -> String
 public static func parseTranscription(data: Data, offset: Double = 0) throws -> TranscriptResult
}
public struct ShareLinkResolver {
 public init(session: URLSession = .shared)
 public func importAudio(from shareURL: URL, to directory: URL) async throws -> URL
}
```

ASR supports OpenAI-compatible multipart /audio/transcriptions, or chat /chat/completions with base64 input_audio WAV. baseURL handling: allow complete endpoint, /v1 root, root URL append /v1; do not double endpoints. language/prompt/response_format only if nonempty; model required, optional bearer auth, validate http(s), no key logging. maxUploadMB file limit, timeout clamp. Large text LLM chunk recursively summarize <=~14000 characters chunks then final synthesis; avoid unbounded prompt. Non2xx clear status bounded error without echoing key, text response and content arrays; trim Qwen prefixes only known prefix; VibeVoice generated JSON arrays Start/End/Speaker/Content, standard text/segments, word/segment optional; fenced JSON parse; malformed usable text fallback but HTML/error object reject. Apply offset to segment positions, fallback coarse chunk start. rawResponse max64K for user test output. async cancellable URLSession no automatic cloud fallback.

Share links: accept user http(s) direct audio URL or plaud.cn/subdomain share URL. GET page with bounded size; parse audio/source tags, og:audio, JSON-LD/embedded JSON audio_url/audioUrl/download_url/recording_url; do not execute JS/credentials. Resolve relative URLs, support trusted signed HTTPS CDN audio. Stream downloads via URLSession.download, size max2GiB, validate response and reject HTML; use fixed safe filename/extension, no overwriting another import. Private/auth/expired/no extractable audio returns Chinese error explaining export then import. No claim all links work. Avoid treating summary strings as audio; no key extraction. Redirection only http(s). Add tests for response variants/offset, endpoint, multipart headers and body via URLProtocol, failures; link HTML fixture and no-audio failures. Use `swift test --scratch-path .build-api --filter APITests` after writing tests. Report docs/api-result.md with limits. No live user API calls or downloading private audio.
