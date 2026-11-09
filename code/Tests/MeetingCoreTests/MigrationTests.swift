import XCTest
@testable import MeetingCore

final class MigrationTests: XCTestCase {
    func withPaths(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root.appendingPathComponent("new/settings.json"), root.appendingPathComponent("old.json"))
    }
    func testMigrationPreservesLibraryProfileIDsAndOriginalBytes() throws {
        try withPaths { current, legacy in
            var old = AppSettings(); old.libraryPath = "/Users/example/Documents/MeetingScribe"; old.asrProfiles[0].model = "my-local-model"; old.selectedASRID = old.asrProfiles[0].id
            let data = try JSONEncoder().encode(old); try data.write(to: legacy)
            let migrated = try SettingsMigration.load(current: current, legacy: legacy)
            XCTAssertEqual(migrated, old)
            XCTAssertEqual(try Data(contentsOf: legacy), data)
            XCTAssertEqual(try Data(contentsOf: current), data)
            XCTAssertEqual(SettingsMigration.keychainService, "local.MeetingScribe.api")
            XCTAssertEqual(SettingsMigration.bundleIdentifier, "local.MeetingScribe")
        }
    }
    func testExistingDestinationWinsAndCorruptLegacyIsNotCopied() throws {
        try withPaths { current, legacy in
            try Data("invalid json".utf8).write(to: legacy)
            XCTAssertThrowsError(try SettingsMigration.load(current: current, legacy: legacy))
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
            let settings = AppSettings()
            try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: current)
            XCTAssertEqual(try SettingsMigration.load(current: current, legacy: legacy), settings)
        }
    }
    func testNewInstallUsesNewLibraryName() throws {
        try withPaths { current, _ in
            let fresh = try SettingsMigration.load(current: current, legacy: nil)
            XCTAssertEqual((fresh.libraryPath as NSString).lastPathComponent, "AutoMeetingRecorder")
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        }
    }
}
