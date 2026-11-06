import XCTest
@testable import MeetingCore

final class DetectionTests: XCTestCase {
    func testIncompleteAXObservationDoesNotBecomeAbsence() {
        XCTAssertNil(DetectionRules.presence(inputActive: false, appRunning: true, uiValid: false, inMeeting: false))
        XCTAssertEqual(DetectionRules.presence(inputActive: false, appRunning: true, uiValid: true, inMeeting: false), false)
        XCTAssertEqual(DetectionRules.presence(inputActive: nil, appRunning: true, uiValid: false, inMeeting: true), true)
        XCTAssertEqual(DetectionRules.presence(inputActive: nil, appRunning: false, uiValid: false, inMeeting: false), false)
    }
    func testDelayedAutomaticStartInvalidatedByEndOrDisable() {
        var gate = AutomaticStartGate(); let token = gate.began()
        XCTAssertTrue(gate.permits(token, enabled: true))
        gate.ended(); XCTAssertFalse(gate.permits(token, enabled: true))
        let next = gate.began(); gate.disabled()
        XCTAssertFalse(gate.permits(next, enabled: true))
    }
    func testDisableBeforeRejectionStillSuppressesOnlyUntilDeparture() {
        var gate = AutomaticStartGate(); _ = gate.began(); gate.disabled(); gate.suppressCurrent()
        XCTAssertTrue(gate.suppressed)
        let repeated = gate.began(); XCTAssertFalse(gate.permits(repeated, enabled: true))
        gate.ended(); gate.disabled(); gate.suppressCurrent()
        XCTAssertFalse(gate.suppressed)
        let next = gate.began(); XCTAssertTrue(gate.permits(next, enabled: true))
    }
    func testRejectionSurvivesPollingRestartUntilObservedDeparture() {
        var gate = AutomaticStartGate(); _ = gate.began(); gate.suppressCurrent(); gate.disabled()
        let repeated = gate.began(); XCTAssertFalse(gate.permits(repeated, enabled: true))
        let t = Date(); gate.observe(false, at: t); gate.observe(nil, at: t.addingTimeInterval(9))
        XCTAssertTrue(gate.suppressed)
        gate.observe(false, at: t.addingTimeInterval(10)); gate.observe(false, at: t.addingTimeInterval(18))
        XCTAssertFalse(gate.suppressed)
        let next = gate.began(); XCTAssertTrue(gate.permits(next, enabled: true))
    }
    func testDeferredNewEpisodeDoesNotReusePreviousPermissionToken() {
        var gate = AutomaticStartGate(); let first = gate.began(); gate.ended(); let second = gate.began()
        XCTAssertFalse(gate.permits(first, enabled: true)); XCTAssertTrue(gate.permits(second, enabled: true))
    }
    func testAttributesCoreAudioInputToClientAndExcludesOutput() {
        let raw = """
        pid 100(coreaudiod): [0x1] PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInMicrophoneDevice.context.preventuseridlesleep"
          Created for PID: 456.
        pid 100(coreaudiod): [0x2] PreventUserIdleSystemSleep named: "com.apple.audio.audio-out.context"
          Created for PID: 789.
        pid 333(Feishu): [0x3] PreventUserIdleSystemSleep named: "video preview"
        """
        XCTAssertEqual(DetectionRules.parseAssertions(raw).map(\.pid), [456])
    }
    func testDirectInputAndNoOutputOrIrrelevantAssertions() {
        let raw = "pid 20(Feishu): [0x1] named: \"audio-in\"\npid 30(Music): [0x2] named: \"audio-playing\""
        XCTAssertEqual(DetectionRules.parseAssertions(raw).map(\.pid), [20])
    }
    func testMuteActionIsInvertedAndAmbiguousIsClosed() {
        XCTAssertEqual(DetectionRules.muteState(labels: ["取消静音 (⌘D)"]), .muted)
        XCTAssertEqual(DetectionRules.muteState(labels: ["关闭麦克风"]), .unmuted)
        XCTAssertEqual(DetectionRules.muteState(labels: ["全员静音"]), .unknown)
        XCTAssertEqual(DetectionRules.muteState(labels: ["静音", "取消静音"]), .unknown)
        XCTAssertEqual(DetectionRules.muteState(labels: ["Unmute microphone"]), .muted)
    }
    func testUnknownQueryDoesNotEndMeeting() {
        var m = MeetingPresenceMachine(); let t = Date(timeIntervalSince1970: 100)
        XCTAssertNil(m.update(present: true, now: t))
        XCTAssertEqual(m.update(present: true, now: t.addingTimeInterval(3)), .began)
        XCTAssertNil(m.update(present: nil, now: t.addingTimeInterval(60)))
        XCTAssertTrue(m.active)
        XCTAssertNil(m.update(present: false, now: t.addingTimeInterval(61)))
        XCTAssertEqual(m.update(present: false, now: t.addingTimeInterval(69)), .ended)
    }
}
