import AVFoundation
import Speech
import XCTest
@testable import AIHelper

/// The permission page is only useful if it tells the truth, so these tests pin down the
/// mapping from each platform API's raw status to what the page shows, and the wording of
/// the summary and the diagnostics report.
///
/// The live probes (`checkAll`) are deliberately checked only for shape, not for a specific
/// result: on any given Mac a permission may legitimately be granted or not, and a test that
/// asserted otherwise would fail for the wrong reason.
final class PermissionAuditTests: XCTestCase {

    // MARK: - Microphone / speech status mapping

    func testMicrophoneStatusMapping() {
        XCTAssertEqual(PermissionAudit.state(for: AVAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(PermissionAudit.state(for: AVAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionAudit.state(for: AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionAudit.state(for: AVAuthorizationStatus.restricted), .denied,
                       "restricted by policy is still unusable, so it must not read as granted")
    }

    func testSpeechRecognitionStatusMapping() {
        XCTAssertEqual(PermissionAudit.state(for: SFSpeechRecognizerAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(PermissionAudit.state(for: SFSpeechRecognizerAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionAudit.state(for: SFSpeechRecognizerAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionAudit.state(for: SFSpeechRecognizerAuthorizationStatus.restricted), .denied)
    }

    // MARK: - Apple Events status mapping

    func testAppleEventStatusMapping() {
        XCTAssertEqual(PermissionAudit.state(forAppleEventStatus: noErr), .granted)
        XCTAssertEqual(PermissionAudit.state(forAppleEventStatus: OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(PermissionAudit.state(forAppleEventStatus: OSStatus(errAEEventWouldRequireUserConsent)), .notDetermined)
    }

    /// A target that isn't running is not a permission failure, and must not be shown as one.
    func testAppleEventTargetNotRunningIsNotAFailure() {
        XCTAssertEqual(PermissionAudit.state(forAppleEventStatus: OSStatus(procNotFound)), .notApplicable)
        XCTAssertFalse(PermissionState.notApplicable.isBlocking)
    }

    func testUnknownAppleEventStatusIsTreatedAsDenied() {
        XCTAssertEqual(PermissionAudit.state(forAppleEventStatus: -12345), .denied,
                       "an unrecognised error must fail closed, not silently read as granted")
    }

    /// Probing must never raise a consent dialog — the page is for looking, not nagging.
    func testAppleEventProbeReturnsAStatusForAnUninstalledApp() {
        let status = PermissionAudit.appleEventPermission(forBundleID: "com.aihelper.definitely-not-installed")
        XCTAssertNotEqual(status, noErr, "a bundle id that cannot be running must not report as granted")
    }

    // MARK: - Blocking

    func testOnlyMissingPermissionsBlock() {
        XCTAssertTrue(PermissionState.denied.isBlocking)
        XCTAssertTrue(PermissionState.notDetermined.isBlocking)
        XCTAssertFalse(PermissionState.granted.isBlocking)
        XCTAssertFalse(PermissionState.notApplicable.isBlocking)
    }

    // MARK: - Summary

    func testSummaryCountsOnlyApplicableChecks() {
        let checks = [
            PermissionCheck(id: .microphone, state: .granted, detail: nil),
            PermissionCheck(id: .accessibility, state: .granted, detail: nil),
            PermissionCheck(id: .screenRecording, state: .denied, detail: nil),
            PermissionCheck(id: .automation, state: .notApplicable, detail: nil),
        ]

        XCTAssertEqual(PermissionAudit.summary(for: checks), "2 of 3 granted",
                       "a row that does not apply to this Mac must not count against the total")
    }

    func testSummaryWhenEverythingIsGranted() {
        let checks = PermissionCheck.Kind.allCases.map { PermissionCheck(id: $0, state: .granted, detail: nil) }

        XCTAssertEqual(PermissionAudit.summary(for: checks), "All \(PermissionCheck.Kind.allCases.count) granted")
    }

    func testSummaryWhenNothingApplies() {
        let checks = [PermissionCheck(id: .automation, state: .notApplicable, detail: nil)]

        XCTAssertEqual(PermissionAudit.summary(for: checks), "Nothing to check")
    }

    // MARK: - Diagnostics report

    func testDiagnosticsReportListsEveryCheckAndItsState() {
        let checks = [
            PermissionCheck(id: .microphone, state: .granted, detail: nil),
            PermissionCheck(id: .screenRecording, state: .denied, detail: nil),
            PermissionCheck(id: .automation, state: .notApplicable, detail: "Checked against iTerm2."),
        ]

        let report = PermissionAudit.diagnosticsReport(for: checks, appVersion: "1.3", build: "4")

        XCTAssertTrue(report.contains("Version: 1.3 (4)"))
        XCTAssertTrue(report.contains("[x] Microphone: granted"))
        XCTAssertTrue(report.contains("[ ] Screen Recording: denied"))
        XCTAssertTrue(report.contains("Checked against iTerm2."), "the detail line explains an otherwise puzzling row")
        XCTAssertTrue(report.contains("Path: "), "the bundle path matters: macOS scopes permissions per copy of the app")
    }

    // MARK: - Coverage of the app's real permissions

    /// Every permission listed in the README must have a row, or the page quietly lies about
    /// being a complete check.
    func testAuditCoversEveryPermissionTheAppUses() {
        let kinds = Set(PermissionCheck.Kind.allCases)

        XCTAssertTrue(kinds.isSuperset(of: [.microphone, .accessibility, .inputMonitoring, .speechRecognition, .screenRecording, .automation]))
        XCTAssertEqual(PermissionAudit.checkAll().count, PermissionCheck.Kind.allCases.count)
    }

    func testEveryKindHasUserFacingCopyAndASettingsPane() {
        for kind in PermissionCheck.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) has no title")
            XCTAssertFalse(kind.purpose.isEmpty, "\(kind) does not say what breaks without it")
            XCTAssertFalse(kind.symbol.isEmpty, "\(kind) has no icon")
            XCTAssertTrue(kind.settingsPane.hasPrefix("Privacy_"), "\(kind) has no Privacy & Security pane to open")
        }
    }

    func testSettingsPanesAreDistinct() {
        let panes = PermissionCheck.Kind.allCases.map(\.settingsPane)

        XCTAssertEqual(Set(panes).count, panes.count, "two permissions point at the same System Settings pane")
    }

    /// Live probe: whatever this Mac's answers are, every kind must come back exactly once.
    func testCheckAllReturnsOneResultPerKindWithoutPrompting() {
        let checks = PermissionAudit.checkAll()

        XCTAssertEqual(Set(checks.map(\.id)).count, PermissionCheck.Kind.allCases.count)
        for kind in PermissionCheck.Kind.allCases {
            XCTAssertNotNil(checks.first { $0.id == kind }, "no result for \(kind)")
        }
    }

    /// Only the automation row can report "not applicable" — the rest are always gradable.
    func testOnlyAutomationCanBeNotApplicable() {
        for check in PermissionAudit.checkAll() where check.id != .automation {
            XCTAssertNotEqual(check.state, .notApplicable, "\(check.id) should always be gradable")
        }
    }
}
