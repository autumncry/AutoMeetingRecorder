import Foundation
import XCTest
@testable import MeetingCore

final class APITests: XCTestCase {
    private var session: URLSession!
    private var fixtureID = ""
    private var directory: URL!

    override func setUpWithError() throws {
        fixtureID = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-APITest-ID": fixtureID]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingScribe-API-\(fixtureID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        APIFixtureProtocol.remove(fixtureID)
        try FileManager.default.removeItem(at: directory)
    }

    private func mock(_ handler: @escaping (URLRequest) throws -> APIFixtureProtocol.Reply) {
        APIFixtureProtocol.register(fixtureID, handler: handler)
    }

    private func audio(_ data: Data = Data("RIFF1234WAVEfmt fixture".utf8), name: String = "fixture.wav") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func asr(_ base: String = "https://api.invalid") -> ASRProfile {
        var profile = ASRProfile()
        profile.baseURL = base
        profile.model = "fixture-asr"
        return profile
    }

    private func llm() -> LLMProfile {
        var profile = LLMProfile()
        profile.baseURL = "https://api.invalid/v1"
        profile.model = "fixture-llm"
        return profile
    }

    func testStandardSegmentsWordsAndOffset() throws {
        let result = try AIClient.parseTranscription(data: Data(#"{"text":"你好 world","language":"zh","segments":[{"start":1.25,"end":2.5,"text":"你好","speaker":"A"},{"text":"world"}]}"#.utf8), offset: 300)
        XCTAssertEqual(result.text, "你好 world")
        XCTAssertEqual(result.language, "zh")
        XCTAssertEqual(result.segments.map(\.start), [301.25, 300])
        XCTAssertEqual(result.segments.first?.end, 302.5)
        XCTAssertEqual(result.segments.first?.speaker, "A")
        let words = try AIClient.parseTranscription(data: Data(#"{"segments":[],"words":[{"start":0.1,"end":0.5,"word":"hello"}]}"#.utf8), offset: 10)
        XCTAssertEqual(words.text, "hello")
        XCTAssertEqual(words.segments.first?.start, 10.1)
    }

    func testVibeVoiceFencedChatContentAndQwenPrefix() throws {
        let generated = "```json\n[{\"Start\":\"1.5\",\"End\":3,\"Speaker\":0,\"Content\":\"讨论方案\"}]\n```"
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": [["type": "text", "text": generated]]]]]])
        let result = try AIClient.parseTranscription(data: data, offset: 20)
        XCTAssertEqual(result.text, "讨论方案")
        XCTAssertEqual(result.segments.first?.start, 21.5)
        XCTAssertEqual(result.segments.first?.end, 23)
        XCTAssertEqual(result.segments.first?.speaker, "0")
        let qwen = try AIClient.parseTranscription(data: Data(#"{"text":"language Chinese<asr_text>你好 English"}"#.utf8), offset: 5)
        XCTAssertEqual(qwen.text, "你好 English")
        XCTAssertEqual(qwen.segments.first?.start, 5)
        XCTAssertEqual(try AIClient.parseTranscription(data: Data("language is important: keep this".utf8)).text, "language is important: keep this")
    }

    func testTextFallbackRejectsHTMLAndErrorObjectsAndBoundsRawResponse() throws {
        XCTAssertEqual(try AIClient.parseTranscription(data: Data("{broken but readable transcript".utf8)).text, "{broken but readable transcript")
        for invalid in ["<!DOCTYPE html><html>login</html>", #"{"error":{"message":"bad key"}}"#, #"{"message":"unauthorized"}"#, "", #"{"text":"<html>login</html>"}"#] {
            XCTAssertThrowsError(try AIClient.parseTranscription(data: Data(invalid.utf8)))
        }
        let large = try AIClient.parseTranscription(data: Data(String(repeating: "中", count: 30_000).utf8))
        XCTAssertLessThanOrEqual(large.rawResponse?.utf8.count ?? Int.max, 65_536)
        XCTAssertFalse(large.rawResponse?.contains("�") ?? true)
    }

    func testEndpointNormalizationAndMultipartBody() async throws {
        let file = try audio()
        let cases = ["https://api.invalid", "https://api.invalid/", "https://api.invalid/v1/", "https://api.invalid/v1/audio/transcriptions", "https://api.invalid/proxy/v1", "https://api.invalid/audio/transcriptions"]
        for base in cases {
            mock { request in
                let expected = base.contains("proxy") ? "/proxy/v1/audio/transcriptions" : (base == "https://api.invalid/audio/transcriptions" ? "/audio/transcriptions" : "/v1/audio/transcriptions")
                XCTAssertEqual(request.url?.path, expected)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
                XCTAssertEqual(request.timeoutInterval, 10)
                let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
                XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
                let body = String(decoding: APIFixtureProtocol.body(request), as: UTF8.self)
                XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nfixture-asr"))
                XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\""))
                XCTAssertTrue(body.contains("Content-Type: audio/wav"))
                XCTAssertTrue(body.contains("RIFF1234WAVEfmt fixture"))
                XCTAssertFalse(body.contains("name=\"language\""))
                XCTAssertFalse(body.contains("name=\"prompt\""))
                XCTAssertFalse(body.contains("name=\"response_format\""))
                return .text(#"{"text":"ok"}"#)
            }
            var profile = asr(base)
            profile.prompt = "  "
            profile.responseFormat = ""
            profile.timeoutSeconds = -1
            let result = try await AIClient(session: session).transcribe(file: file, profile: profile, apiKey: "fixture-secret")
            XCTAssertEqual(result.text, "ok")
        }
    }

    func testChatAudioJSONOptionalFieldsAndNoAuth() async throws {
        let file = try audio()
        mock { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.timeoutInterval, 1800)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: APIFixtureProtocol.body(request)) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "fixture-asr")
            XCTAssertNil(json["response_format"])
            XCTAssertNil(json["language"])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            let input = try XCTUnwrap(content.first(where: { $0["type"] as? String == "input_audio" })?["input_audio"] as? [String: Any])
            XCTAssertEqual(input["format"] as? String, "wav")
            XCTAssertEqual(Data(base64Encoded: input["data"] as? String ?? ""), try Data(contentsOf: file))
            return .text(#"{"choices":[{"message":{"content":"language English<asr_text>hello"}}]}"#)
        }
        var profile = asr()
        profile.interface = .chatAudio
        profile.chatAudioFormat = "input_audio"
        profile.timeoutSeconds = .infinity
        let result = try await AIClient(session: session).transcribe(file: file, profile: profile, apiKey: "")
        XCTAssertEqual(result.text, "hello")
    }

    func testValidationAndHTTPFailuresDoNotEchoSecrets() async throws {
        let file = try audio()
        mock { _ in .text(#"{"error":"fixture-secret"}"#, status: 401) }
        do {
            _ = try await AIClient(session: session).transcribe(file: file, profile: asr(), apiKey: "fixture-secret")
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
        }
        mock { _ in XCTFail("Invalid input must fail before networking"); return .text("unexpected") }
        var invalid = asr("file:///tmp/no")
        await assertFails { _ = try await AIClient(session: self.session).transcribe(file: file, profile: invalid, apiKey: nil) }
        invalid = asr(); invalid.model = " "
        await assertFails { _ = try await AIClient(session: self.session).transcribe(file: file, profile: invalid, apiKey: nil) }
        invalid = asr(); invalid.maxUploadMB = 0.000001
        await assertFails { _ = try await AIClient(session: self.session).transcribe(file: file, profile: invalid, apiKey: nil) }
        invalid = asr(); invalid.interface = .chatAudio
        let mp3 = try audio(Data("ID3fixture".utf8), name: "fixture.mp3")
        await assertFails { _ = try await AIClient(session: self.session).transcribe(file: mp3, profile: invalid, apiKey: nil) }
    }

    func testRecursiveSummaryBoundsPromptsAndAcceptsContentArrays() async throws {
        let requests = APILockedCounter()
        mock { request in
            requests.increment()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: APIFixtureProtocol.body(request)) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.last?["content"] as? String)
            XCTAssertLessThanOrEqual(content.count, 14_000)
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            return .text(#"{"choices":[{"message":{"content":[{"type":"text","text":"总结保留证据"}]}}]}"#)
        }
        let result = try await AIClient(session: session).summarize(transcript: String(repeating: "会议记录。", count: 7_000), profile: llm(), apiKey: nil)
        XCTAssertEqual(result, "总结保留证据")
        XCTAssertEqual(requests.value, 4)
    }

    func testPLAUDFixtureResolvesRelativeAudioAndDoesNotOverwrite() async throws {
        mock { request in
            if request.url?.path == "/share/test" {
                return .text("<html><audio controls><source src='../media/clip.wav?sig=one&amp;part=2' type='audio/wav'></audio></html>", mime: "text/html")
            }
            XCTAssertEqual(request.url?.absoluteString, "https://web.plaud.cn/media/clip.wav?sig=one&part=2")
            return .init(status: 200, headers: ["Content-Type": "audio/wav"], data: Data("RIFF1234WAVEfmt fixture".utf8))
        }
        let resolver = ShareLinkResolver(session: session)
        let first = try await resolver.importAudio(from: URL(string: "https://web.plaud.cn/share/test")!, to: directory)
        let second = try await resolver.importAudio(from: URL(string: "https://web.plaud.cn/share/test")!, to: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pathExtension, "wav")
        XCTAssertEqual(first.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
    }

    func testShareMetadataJSONLDAndEmbeddedJSONSupportSignedCDN() async throws {
        let fixtures = [
            "<meta content='https://cdn.invalid/signed?id=1&amp;sig=2' property='og:audio'>",
            #"<script type="application/ld+json">{"@type":"AudioObject","contentUrl":"https://cdn.invalid/signed?id=1&sig=2"}</script>"#,
            #"<script id="__NEXT_DATA__" type="application/json">{"props":{"audioUrl":"https://cdn.invalid/signed?id=1&sig=2"}}</script>"#,
            #"<script>window.__DATA__ = {"recording_url":"https:\/\/cdn.invalid\/signed?id=1&sig=2"};</script>"#
        ]
        for fixture in fixtures {
            mock { request in
                if request.url?.host == "plaud.cn" { return .text(fixture, mime: "text/html") }
                XCTAssertEqual(request.url?.absoluteString, "https://cdn.invalid/signed?id=1&sig=2")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return .init(status: 200, headers: ["Content-Type": "audio/mpeg"], data: Data("ID3fixture audio".utf8))
            }
            let imported = try await ShareLinkResolver(session: session).importAudio(from: URL(string: "https://plaud.cn/share/test")!, to: directory)
            XCTAssertEqual(imported.pathExtension, "mp3")
        }
    }

    func testNoAudioPrivateExpiredHTMLAndUnsafeLinksFailClearly() async throws {
        for page in ["<html>请登录</html>", #"<script type="application/json">{"summary":"https://cdn.invalid/not-a-recording.mp3"}</script>"#, #"<script type="application/json">{"summary":"<audio src='https://cdn.invalid/a.mp3'>"}</script>"#, #"<audio src="file:///tmp/private.wav"></audio>"#, #"<audio src="http://cdn.invalid/audio.mp3"></audio>"#] {
            mock { _ in .text(page, mime: "text/html") }
            do {
                _ = try await ShareLinkResolver(session: session).importAudio(from: URL(string: "https://plaud.cn/share/private")!, to: directory)
                XCTFail("Expected no audio")
            } catch { XCTAssertTrue(error.localizedDescription.contains("导出")); XCTAssertTrue(error.localizedDescription.contains("导入")) }
        }
        for status in [200, 401, 403, 404, 410] {
            mock { _ in .text("<html>expired</html>", status: status, mime: "text/html") }
            await assertFails { _ = try await ShareLinkResolver(session: self.session).importAudio(from: URL(string: "https://cdn.invalid/fake.mp3")!, to: self.directory) }
        }
        mock { _ in XCTFail("Must not request unsafe scheme"); return .text("") }
        await assertFails { _ = try await ShareLinkResolver(session: self.session).importAudio(from: URL(string: "ftp://cdn.invalid/a.wav")!, to: self.directory) }
    }

    func testResponseAndPageSizeLimits() async throws {
        mock { _ in .init(status: 200, headers: ["Content-Type": "text/html", "Content-Length": "999999999"], data: Data("<html>huge</html>".utf8)) }
        await assertFails { _ = try await ShareLinkResolver(session: self.session).importAudio(from: URL(string: "https://plaud.cn/share/huge")!, to: self.directory) }
        let file = try audio()
        mock { _ in .init(status: 200, headers: ["Content-Type": "application/json", "Content-Length": "999999999"], data: Data(#"{"text":"large"}"#.utf8)) }
        await assertFails { _ = try await AIClient(session: self.session).transcribe(file: file, profile: self.asr(), apiKey: nil) }
    }

    func testCancellationDoesNotStartAnotherRequest() async throws {
        mock { _ in XCTFail("Cancelled operation must not start"); return .text("") }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await AIClient(session: self.session).summarize(transcript: "hello", profile: self.llm(), apiKey: nil)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }

    func testInFlightCancellationReachesTransport() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "transport cancelled")
        mock { _ in
            started.fulfill()
            return .init(status: 200, headers: [:], data: Data(), hold: true, onStop: { stopped.fulfill() })
        }
        let task = Task { try await AIClient(session: self.session).summarize(transcript: "hello", profile: self.llm(), apiKey: nil) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testDownloadCancellationLeavesNoImport() async throws {
        let started = expectation(description: "download started")
        let stopped = expectation(description: "download cancelled")
        mock { _ in
            started.fulfill()
            return .init(status: 200, headers: [:], data: Data(), hold: true, onStop: { stopped.fulfill() })
        }
        let task = Task { try await ShareLinkResolver(session: self.session).importAudio(from: URL(string: "https://cdn.invalid/clip.wav")!, to: self.directory) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testImporterDoesNotInheritCredentialHeaders() async throws {
        let configuration = session.configuration
        configuration.httpAdditionalHeaders = ["X-APITest-ID": fixtureID, "Authorization": "Bearer fixture-secret", "X-API-Key": "fixture-key", "Cookie": "private=cookie", "Proxy-Authorization": "Basic private"]
        let authenticated = URLSession(configuration: configuration)
        defer { authenticated.invalidateAndCancel() }
        mock { request in
            for name in ["Authorization", "X-API-Key", "Cookie", "Proxy-Authorization"] { XCTAssertNil(request.value(forHTTPHeaderField: name)) }
            return .init(status: 200, headers: ["Content-Type": "audio/wav"], data: Data("RIFF1234WAVEfixture".utf8))
        }
        _ = try await ShareLinkResolver(session: authenticated).importAudio(from: URL(string: "https://cdn.invalid/clip.wav")!, to: directory)
    }

    func testRedirectPolicyRejectsUnsafeSchemesAndCredentialForwarding() {
        var original = URLRequest(url: URL(string: "https://api.invalid/v1/chat/completions")!)
        original.httpMethod = "POST"
        original.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        for target in ["file:///tmp/private", "ftp://api.invalid/file", "https://other.invalid/chat", "http://api.invalid/chat"] {
            APITransferDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { redirected in
                XCTAssertNil(redirected)
            }
        }
        APITransferDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: original) { redirected in
            XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        }
        let download = session.downloadTask(with: URL(string: "https://cdn.invalid/clip")!)
        var redirected = URLRequest(url: URL(string: "https://signed.invalid/clip")!)
        redirected.setValue("Bearer unwanted", forHTTPHeaderField: "Authorization")
        redirected.setValue("private=cookie", forHTTPHeaderField: "Cookie")
        APITransferDelegate().urlSession(session, task: download, willPerformHTTPRedirection: response, newRequest: redirected) { safe in
            XCTAssertNotNil(safe)
            XCTAssertNil(safe?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(safe?.value(forHTTPHeaderField: "Cookie"))
        }
    }

    func testDownloadLimitAndFakeAudioRejection() async throws {
        mock { _ in .init(status: 200, headers: ["Content-Type": "audio/wav", "Content-Length": "2147483649"], data: Data("RIFF1234WAVEfixture".utf8)) }
        await assertFails { _ = try await ShareLinkResolver(session: self.session).importAudio(from: URL(string: "https://cdn.invalid/large.wav")!, to: self.directory) }
        mock { _ in .init(status: 200, headers: ["Content-Type": "audio/mpeg"], data: Data("<html>login page with fake audio mime</html>".utf8)) }
        await assertFails { _ = try await ShareLinkResolver(session: self.session).importAudio(from: URL(string: "https://cdn.invalid/fake.mp3")!, to: self.directory) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testActualResponseLimitAndNonShrinkingSummaryFailure() async throws {
        mock { _ in .text(String(repeating: "x", count: 2 * 1_048_576 + 1), mime: "text/plain") }
        await assertFails { _ = try await AIClient(session: self.session).summarize(transcript: "hello", profile: self.llm(), apiKey: nil) }
        mock { _ in .text(String(repeating: "x", count: 6001), mime: "text/plain") }
        await assertFails { _ = try await AIClient(session: self.session).summarize(transcript: String(repeating: "x", count: 14_001), profile: self.llm(), apiKey: nil) }
    }

    func testMultipartOptionalFieldsAndCompleteEndpointQuery() async throws {
        let file = try audio()
        mock { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.invalid/v1/audio/transcriptions?version=1")
            let body = String(decoding: APIFixtureProtocol.body(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh"))
            XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\n保留术语"))
            XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
            return .text(#"{"text":"ok"}"#)
        }
        var profile = asr("https://api.invalid/v1/audio/transcriptions?version=1")
        profile.language = "zh"
        profile.prompt = "保留术语"
        profile.responseFormat = "verbose_json"
        _ = try await AIClient(session: session).transcribe(file: file, profile: profile, apiKey: nil)
    }

    func testMultiLevelSummaryAndBoundedInstructions() async throws {
        let count = APILockedCounter()
        mock { request in
            count.increment()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: APIFixtureProtocol.body(request)) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertLessThanOrEqual((messages.last?["content"] as? String)?.count ?? Int.max, 14_000)
            return .text(String(repeating: "a", count: 5000), mime: "text/plain")
        }
        let result = try await AIClient(session: session).summarize(transcript: String(repeating: "x", count: 56_000), profile: llm(), apiKey: nil)
        XCTAssertEqual(result.count, 5000)
        XCTAssertEqual(count.value, 7) // four chunks, two reduced chunks, final synthesis
        var profile = llm()
        profile.prompt = String(repeating: "x", count: 8001)
        mock { _ in XCTFail("Overlong instructions must fail before a request"); return .text("") }
        await assertFails { _ = try await AIClient(session: self.session).summarize(transcript: "hello", profile: profile, apiKey: nil) }
    }

    func testSummaryErrorsAndChatEmptyOptionalContent() async throws {
        for invalid in [#"{"error":"do not echo fixture-secret"}"#, "<div>authentication required</div>", #"{"choices":[]}"#] {
            mock { _ in .text(invalid) }
            await assertFails { _ = try await AIClient(session: self.session).summarize(transcript: "hello", profile: self.llm(), apiKey: "fixture-secret") }
        }
        let file = try audio()
        mock { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: APIFixtureProtocol.body(request)) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            XCTAssertEqual(content.count, 1)
            XCTAssertEqual(content.first?["type"] as? String, "input_audio")
            return .text("hello", mime: "text/plain")
        }
        var profile = asr("https://api.invalid/v1/chat/completions/")
        profile.interface = .chatAudio
        profile.chatAudioFormat = "input_audio"
        profile.prompt = ""
        profile.responseFormat = ""
        _ = try await AIClient(session: session).transcribe(file: file, profile: profile, apiKey: nil)
    }

    func testDefaultAudioURLFormatDoesNotDecodeAudioWithoutPlaceholders() async throws {
        let file = try audio() // Header fixture deliberately cannot be decoded by AVAudioFile.
        mock { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: APIFixtureProtocol.body(request)) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            XCTAssertFalse(content.contains(where: { $0["type"] as? String == "input_audio" }))
            let audio = try XCTUnwrap(content.first(where: { $0["type"] as? String == "audio_url" })?["audio_url"] as? [String: Any])
            XCTAssertEqual(audio["url"] as? String, "data:audio/wav;base64," + (try Data(contentsOf: file)).base64EncodedString())
            return .text(#"{"text":"ok"}"#)
        }
        var profile = asr()
        profile.interface = .chatAudio
        XCTAssertEqual(profile.chatAudioFormat, "audio_url")
        _ = try await AIClient(session: session).transcribe(file: file, profile: profile, apiKey: nil)
        profile.chatAudioFormat = "unsupported"
        mock { _ in XCTFail("Invalid format must fail before a request"); return .text("") }
        await assertFails { _ = try await AIClient(session: self.session).transcribe(file: file, profile: profile, apiKey: nil) }
    }

    func testPromptDurationExpandsOnlyWhenRequested() async throws {
        var wav = Data()
        func text(_ value: String) { wav.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var number = value.littleEndian; withUnsafeBytes(of: &number) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var number = value.littleEndian; withUnsafeBytes(of: &number) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(32_036); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(32_000)
        wav.append(Data(repeating: 0, count: 32_000))
        let file = try audio(wav)
        mock { request in
            let body = String(decoding: APIFixtureProtocol.body(request), as: UTF8.self)
            XCTAssertTrue(body.contains("duration=1.000;hotwords="))
            XCTAssertFalse(body.contains("{duration}"))
            XCTAssertFalse(body.contains("{hotwords}"))
            return .text(#"{"text":"ok"}"#)
        }
        var profile = asr()
        profile.prompt = "duration={duration};hotwords={hotwords}"
        _ = try await AIClient(session: session).transcribe(file: file, profile: profile, apiKey: nil)
    }

    private func assertFails(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected error", file: file, line: line) } catch {}
    }
}

private final class APILockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class APIFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var data: Data
        var hold = false
        var onStop: (() -> Void)?
        static func text(_ text: String, status: Int = 200, mime: String = "application/json") -> Reply {
            .init(status: status, headers: ["Content-Type": mime], data: Data(text.utf8))
        }
    }
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> Reply] = [:]
    private var onStop: (() -> Void)?
    static func register(_ id: String, handler: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); defer { lock.unlock() }; handlers[id] = handler
    }
    static func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; handlers[id] = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        // The importer deliberately strips all inherited headers. XCTest runs this class serially;
        // fall back only when exactly one fixture is registered, never to a real network request.
        let handler = Self.handlers[request.value(forHTTPHeaderField: "X-APITest-ID") ?? ""] ?? (Self.handlers.count == 1 ? Self.handlers.values.first : nil)
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let reply = try handler(request)
            onStop = reply.onStop
            if reply.hold { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { onStop?() }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}
