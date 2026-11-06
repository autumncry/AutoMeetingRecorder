import Foundation

/// Imports public audio or audio explicitly advertised by a PLAUD China share page.
/// It does not log in, execute page scripts, or access the user's browser credentials.
public struct ShareLinkResolver {
    private let session: URLSession
    private static let maximumAudioBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private static let exportGuidance = "此链接可能私有、需要登录、已过期或未提供可直接下载的音频。请在 PLAUD 中导出音频文件，再通过本地文件导入。"

    public init(session: URLSession = .shared) { self.session = session }

    public func importAudio(from shareURL: URL, to directory: URL) async throws -> URL {
        try Task.checkCancellation()
        guard APIHTTP.validURL(shareURL), directory.isFileURL else {
            throw MeetingError.message("请输入有效的 HTTP/HTTPS 音频或 PLAUD 分享链接，并选择本地保存目录。" + Self.exportGuidance)
        }
        // Retain the injected transport configuration, but never use its cookies, credentials or auth headers.
        let configuration = session.configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        do {
            let audioURL: URL
            let extensions = ["wav", "mp3", "m4a", "mp4", "flac", "ogg", "opus", "webm", "aac", "aif", "aiff"]
            if Self.isPLAUD(shareURL), !extensions.contains(shareURL.pathExtension.lowercased()) {
                let (page, response) = try await APIHTTP.data(Self.request(shareURL), session: transport, limit: 2 * 1_048_576)
                guard let finalURL = response.url, Self.isPLAUD(finalURL) else { throw MeetingError.message("分享页面重定向到了不受支持的网站。") }
                guard let html = String(data: page, encoding: .utf8),
                      let extracted = Self.audioLinks(in: html, base: finalURL).first else { throw MeetingError.message("分享页面未提供可提取的音频。") }
                audioURL = extracted
            } else { audioURL = shareURL }
            return try await download(audioURL, directory: directory, transport: transport)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw error }
        catch let error as MeetingError { throw MeetingError.message(error.localizedDescription + "\n" + Self.exportGuidance) }
        catch { throw MeetingError.message("音频获取或保存失败。" + Self.exportGuidance) }
    }

    private func download(_ url: URL, directory: URL, transport: URLSession) async throws -> URL {
        try Task.checkCancellation()
        let delegate = APITransferDelegate(limit: Self.maximumAudioBytes)
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await transport.download(for: Self.request(url), delegate: delegate) }
        catch {
            if delegate.exceededLimit { throw MeetingError.message("音频超过 2 GiB 导入上限，请先分段导出。") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let http = try APIHTTP.response(response)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard !delegate.exceededLimit, size > 0, Int64(size) <= Self.maximumAudioBytes, http.expectedContentLength <= Self.maximumAudioBytes else {
            throw MeetingError.message("音频为空或超过 2 GiB 导入上限。")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4096) ?? Data()
        let mime = (http.mimeType ?? "").lowercased()
        guard !["text/html", "application/xhtml+xml", "application/json", "text/plain"].contains(mime),
              !AIClient.isHTML(String(decoding: prefix, as: UTF8.self)),
              let ext = Self.audioExtension(prefix) else { throw MeetingError.message("下载结果不是可识别的音频文件，可能是登录或错误页面。") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Ignore Content-Disposition and remote paths; copyItem refuses to overwrite an existing destination.
        let destination = directory.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: temporary, to: destination)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        return destination
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("audio/*, text/html, application/json;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        return request
    }

    private static func isPLAUD(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "plaud.cn" || host.hasSuffix(".plaud.cn")
    }

    private static func audioExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String { range.upperBound <= data.count ? String(decoding: data[range], as: UTF8.self) : "" }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(0..<4) == "OggS" { return "ogg" }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if ascii(4..<8) == "ftyp" { return "m4a" }
        if ascii(0..<4) == "FORM", ["AIFF", "AIFC"].contains(ascii(8..<12)) { return "aiff" }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return "webm" }
        if bytes.count >= 2, bytes[0] == 0xff {
            if bytes[1] & 0xf6 == 0xf0 { return "aac" }
            if bytes[1] & 0xe0 == 0xe0 { return "mp3" }
        }
        return nil
    }

    private static func audioLinks(in html: String, base: URL) -> [URL] {
        var candidates: [String] = []
        // Markup inside JSON/script strings or comments is not an audio element.
        let markup = html.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script\s*>|<!--.*?-->"#, with: "", options: .regularExpression)
        for match in matches(#"(?is)<(?:audio|source)\b[^>]*>"#, in: markup) {
            let attributes = attributes(match[0])
            if let src = attributes["src"] { candidates.append(src) }
        }
        for match in matches(#"(?is)<meta\b[^>]*>"#, in: markup) {
            let values = attributes(match[0])
            let property = (values["property"] ?? values["name"] ?? "").lowercased()
            if ["og:audio", "og:audio:url", "og:audio:secure_url"].contains(property), let content = values["content"] { candidates.append(content) }
        }
        func inspect(_ value: Any, depth: Int = 0) {
            guard depth <= 32, candidates.count < 64 else { return }
            if let object = value as? [String: Any] {
                for key in ["audio_url", "audioUrl", "download_url", "recording_url"] {
                    if let url = object[key] as? String { candidates.append(url) }
                }
                let types = (object["@type"] as? [String]) ?? (object["@type"] as? String).map { [$0] } ?? []
                if types.contains(where: { $0 == "AudioObject" || $0.hasSuffix("/AudioObject") }), let url = object["contentUrl"] as? String { candidates.append(url) }
                for child in object.values where child is [String: Any] || child is [Any] { inspect(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { inspect(child, depth: depth + 1) }
            }
        }
        if let value = try? JSONSerialization.jsonObject(with: Data(html.utf8)) { inspect(value) }
        for match in matches(#"(?is)<script\b[^>]*>(.*?)</script\s*>"#, in: html) {
            let body = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) { inspect(object); continue }
            // Accept only a simple JS assignment whose RHS is valid JSON. Never evaluate script text.
            if let assignment = matches(#"(?s)^\s*(?:(?:var|let|const)\s+)?[\w.$]+\s*=\s*(\{.*\}|\[.*\])\s*;?\s*$"#, in: body).first,
               let object = try? JSONSerialization.jsonObject(with: Data(assignment[1].utf8)) { inspect(object) }
        }
        var seen = Set<String>()
        return candidates.compactMap { raw in
            let raw = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }),
                  let url = URL(string: raw, relativeTo: base)?.absoluteURL, APIHTTP.validURL(url),
                  // A CDN is trusted only when explicitly advertised by the trusted PLAUD page and served over HTTPS.
                  url.host?.lowercased() == base.host?.lowercased() || url.scheme?.lowercased() == "https",
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in matches(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: tag) {
            result[match[1].lowercased()] = match[2].isEmpty ? (match[3].isEmpty ? match[4] : match[3]) : match[2]
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func decodeEntities(_ input: String) -> String {
        var text = input
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        for match in matches(#"&#(x[0-9a-fA-F]+|[0-9]+);"#, in: text) {
            let value = match[1]
            let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
            if let number, let scalar = UnicodeScalar(number) { text = text.replacingOccurrences(of: match[0], with: String(scalar)) }
        }
        return text
    }
}
