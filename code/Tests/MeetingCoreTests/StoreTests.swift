import XCTest
@testable import MeetingCore

final class StoreTests: XCTestCase {
    func withStore(_ body: (LocalStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(LocalStore(root: root))
    }
    func testPendingCannotDeleteConfirmedRecording() throws {
        try withStore { store in
            let pending = try store.create(title: "test", source: "Feishu", status: .pending)
            var confirmed = pending; confirmed.status = .recording; try store.save(confirmed)
            XCTAssertThrowsError(try store.discardPending(pending))
            XCTAssertEqual(try store.load().count, 1)
        }
    }
    func testRejectPendingRemovesOnlyItsFolder() throws {
        try withStore { store in
            let pending = try store.create(title: "候选", source: "飞书", status: .pending)
            let saved = try store.create(title: "保留", source: "文件")
            try store.discardPending(pending)
            XCTAssertEqual(try store.load().map(\.id), [saved.id])
        }
    }
    func testTraversalRejectedAndVersionsRetained() throws {
        try withStore { store in
            var s = try store.create(title: "测试", source: "file")
            var unsafe = s; unsafe.directory = "../outside"
            XCTAssertThrowsError(try store.directory(for: unsafe))
            let r = TranscriptResult(text: "hello", segments: [.init(start: 1, text: "hello")])
            try store.saveTranscript(r, profile: ASRProfile(), session: &s)
            try store.saveTranscript(r, profile: ASRProfile(), session: &s)
            XCTAssertEqual(s.transcriptVersions.count, 2)
            XCTAssertNotEqual(s.transcriptVersions[0].jsonFile, s.transcriptVersions[1].jsonFile)
            XCTAssertEqual(try store.loadTranscript(s.transcriptVersions[0], session: s).text, "hello")
        }
    }
}
