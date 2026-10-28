import CoreGraphics
import IOKit.pwr_mgt
import XCTest
@testable import AIHelper

/// Tests for Keep Awake.
///
/// The interesting question is not "did we set a Bool" but "does macOS agree that idle
/// display sleep is prevented right now". These tests therefore check the app's state
/// *and* the power-management state the kernel reports back, via
/// `IOPMCopyAssertionsByProcess` (what this process holds) and
/// `IOPMCopyAssertionsStatus` (the system-wide aggregate).
///
/// Each test gets its own `CaffeineManager` and its own settings. The tests run inside the
/// app, so `UserDefaults.standard` is your real AIHelper's preferences: a Keep Awake session
/// saved there would switch Keep Awake on the next time you launch the app.
///
/// On simulating display sleep: an idle-sleep assertion cannot be tested by forcing sleep.
/// `pmset displaysleepnow` and `IOPMSleepSystem` are *explicit* sleeps and deliberately
/// bypass every assertion, so a test built on them would fail no matter how correct the
/// code is. The only faithful end-to-end check is to sit through the real idle timeout
/// without touching the keyboard or mouse; that is `testDisplayStaysAwakeThroughIdleTimeout`,
/// which is opt-in because it takes minutes and needs the machine left alone.
@MainActor
final class CaffeineManagerTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var caffeine: CaffeineManager!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "CaffeineManagerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        caffeine = CaffeineManager(defaults: defaults)
    }

    override func tearDown() async throws {
        caffeine.stop()
        caffeine = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Power assertions

    func testStartHoldsADisplaySleepAssertion() throws {
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty,
                      "a previous test leaked an assertion")

        caffeine.start()

        XCTAssertTrue(caffeine.isActive)
        let held = Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep)
        XCTAssertEqual(held.count, 1, "Keep Awake should hold exactly one display-sleep assertion")
        XCTAssertEqual(held.first, "AIHelper keep awake", "assertion should be named so it is identifiable in `pmset -g assertions`")
    }

    /// The aggregate that `IOPMCopyAssertionsStatus` reports is a level, not a count, so it
    /// cannot show our contribution while something else already holds the same type. When a
    /// Caffeine/Amphetamine-style app is running, skip rather than report a false failure —
    /// `testStartHoldsADisplaySleepAssertion` still covers our own side.
    func testSystemReportsDisplaySleepPreventedWhileActive() throws {
        let baseline = Self.systemAssertionLevel(for: kIOPMAssertionTypePreventUserIdleDisplaySleep)
        try XCTSkipUnless(baseline == 0,
                          "another app is already preventing display sleep — quit it to exercise this check")

        caffeine.start()

        XCTAssertEqual(Self.systemAssertionLevel(for: kIOPMAssertionTypePreventUserIdleDisplaySleep), 1,
                       "macOS should report idle display sleep as prevented while Keep Awake is on")

        caffeine.stop()

        XCTAssertEqual(Self.systemAssertionLevel(for: kIOPMAssertionTypePreventUserIdleDisplaySleep), 0,
                       "macOS should let the display idle again once Keep Awake is off")
    }

    func testStopReleasesTheAssertion() throws {
        caffeine.start()
        XCTAssertFalse(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)

        caffeine.stop()

        XCTAssertFalse(caffeine.isActive)
        XCTAssertEqual(caffeine.remaining, 0)
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty,
                      "stopping must release the assertion, otherwise the Mac never sleeps again")
    }

    func testRepeatedStartDoesNotLeakAssertions() throws {
        caffeine.start()
        caffeine.start()
        caffeine.start()

        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1,
                       "restarting should replace the assertion, not stack a new one on top")
    }

    func testStopIsIdempotent() throws {
        caffeine.start()
        caffeine.stop()
        caffeine.stop()

        XCTAssertFalse(caffeine.isActive)
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)
    }

    func testToggleFlipsTheAssertion() throws {
        caffeine.toggle()
        XCTAssertTrue(caffeine.isActive)
        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1)

        caffeine.toggle()
        XCTAssertFalse(caffeine.isActive)
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)
    }

    /// The assertion must not outlive the process on its own — but it also must not be
    /// dropped while the app is still meant to be holding it. Nothing else in the app may
    /// release it behind Keep Awake's back.
    func testAssertionSurvivesAnUnrelatedRunLoopTurn() async throws {
        caffeine.start()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1)
        XCTAssertTrue(caffeine.isActive)
    }

    // MARK: - Countdown

    func testStartSetsTheFullDurationAndCountsDown() async throws {
        caffeine.duration = .hours(2)
        caffeine.start()

        XCTAssertEqual(caffeine.remaining, 2 * 3600, accuracy: 2,
                       "remaining should start at the chosen duration")

        let atStart = caffeine.remaining
        try await Task.sleep(for: .milliseconds(1_400))

        XCTAssertLessThan(caffeine.remaining, atStart, "the countdown timer should be running")
        XCTAssertTrue(caffeine.isActive, "it must not expire early")
    }

    func testRemainingTextFormatsHoursMinutesSeconds() throws {
        caffeine.duration = .hours(1)
        caffeine.start()

        XCTAssertEqual(caffeine.remainingText, "1:00:00")
        XCTAssertEqual(caffeine.timeLeftText, "1:00:00 left")
    }

    func testRemainingIsZeroWhenInactive() throws {
        XCTAssertFalse(caffeine.isActive)
        XCTAssertEqual(caffeine.remaining, 0)
        XCTAssertEqual(caffeine.remainingText, "0:00")
    }

    /// Runs out on its own, and a session that has ended is not resumed by the next launch.
    func testSessionEndsOnItsOwnAndIsForgotten() async throws {
        defaults.set(Date().addingTimeInterval(1.5), forKey: CaffeineManager.activeUntilKey)
        caffeine.restore()
        XCTAssertTrue(caffeine.isActive)

        try await Task.sleep(for: .milliseconds(4_000))

        XCTAssertFalse(caffeine.isActive, "Keep Awake should switch off once its time is up")
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)
        XCTAssertNil(defaults.object(forKey: CaffeineManager.activeUntilKey),
                     "an expired session must not come back on the next launch")
    }

    // MARK: - Until I turn it off

    func testUntilTurnedOffStaysOnWithoutACountdown() async throws {
        caffeine.duration = .untilTurnedOff
        caffeine.start()

        XCTAssertTrue(caffeine.isActive)
        XCTAssertNil(caffeine.endDate, "a session without a limit has no end date")
        XCTAssertEqual(caffeine.timeLeftText, "no time limit")
        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1)

        try await Task.sleep(for: .milliseconds(1_400))

        XCTAssertTrue(caffeine.isActive, "it must keep going until switched off")
        XCTAssertEqual(caffeine.remaining, 0)
        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1)
    }

    func testUntilTurnedOffStopsWhenSwitchedOff() throws {
        caffeine.duration = .untilTurnedOff
        caffeine.toggle()
        XCTAssertTrue(caffeine.isActive)

        caffeine.toggle()

        XCTAssertFalse(caffeine.isActive)
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)
    }

    // MARK: - Carrying on after a relaunch

    /// The next launch is a new `CaffeineManager` reading the same settings.
    func testATimedSessionCarriesOnAfterARelaunchWithItsOriginalEnd() throws {
        caffeine.duration = .hours(2)
        caffeine.start()
        let end = try XCTUnwrap(caffeine.endDate)

        let relaunched = CaffeineManager(defaults: defaults)
        defer { relaunched.stop() }
        relaunched.restore()

        XCTAssertTrue(relaunched.isActive)
        let resumedEnd = try XCTUnwrap(relaunched.endDate)
        XCTAssertEqual(resumedEnd.timeIntervalSince(end), 0, accuracy: 1,
                       "a relaunch should keep the original end time, not start the hours over")
    }

    func testUntilTurnedOffCarriesOnAfterARelaunch() throws {
        caffeine.duration = .untilTurnedOff
        caffeine.start()

        let relaunched = CaffeineManager(defaults: defaults)
        defer { relaunched.stop() }
        relaunched.restore()

        XCTAssertTrue(relaunched.isActive)
        XCTAssertNil(relaunched.endDate)
    }

    func testRestoreResumesASavedSession() throws {
        defaults.set(Date().addingTimeInterval(30 * 60), forKey: CaffeineManager.activeUntilKey)

        caffeine.restore()

        XCTAssertTrue(caffeine.isActive)
        XCTAssertEqual(caffeine.remaining, 30 * 60, accuracy: 2)
        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1,
                       "resuming must take the assertion again — macOS dropped it when the app quit")
    }

    func testStopForgetsTheSession() throws {
        caffeine.start()
        XCTAssertNotNil(defaults.object(forKey: CaffeineManager.activeUntilKey))

        caffeine.stop()

        XCTAssertNil(defaults.object(forKey: CaffeineManager.activeUntilKey))
        let relaunched = CaffeineManager(defaults: defaults)
        relaunched.restore()
        XCTAssertFalse(relaunched.isActive, "switched off means it stays off after a relaunch")
    }

    func testRestoreDoesNothingWhenKeepAwakeWasOff() throws {
        caffeine.restore()

        XCTAssertFalse(caffeine.isActive)
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)
    }

    func testRestoreSkipsASessionThatRanOutWhileTheAppWasClosed() throws {
        defaults.set(Date().addingTimeInterval(-60), forKey: CaffeineManager.activeUntilKey)

        caffeine.restore()

        XCTAssertFalse(caffeine.isActive)
        XCTAssertTrue(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).isEmpty)
        XCTAssertNil(defaults.object(forKey: CaffeineManager.activeUntilKey))
    }

    func testRestoreNeverRunsLongerThanTheLongestDuration() throws {
        defaults.set(Date().addingTimeInterval(48 * 3600), forKey: CaffeineManager.activeUntilKey)

        caffeine.restore()

        XCTAssertTrue(caffeine.isActive)
        XCTAssertLessThanOrEqual(caffeine.remaining, TimeInterval(KeepAwakeDuration.maxHours) * 3600 + 1)
    }

    // MARK: - Duration setting

    func testChoicesOfferEachHourThenUntilTurnedOff() throws {
        XCTAssertEqual(KeepAwakeDuration.choices,
                       [.hours(1), .hours(2), .hours(3), .hours(4), .hours(5), .untilTurnedOff])
        XCTAssertEqual(KeepAwakeDuration.hours(1).label, "1 hour")
        XCTAssertEqual(KeepAwakeDuration.hours(4).label, "4 hours")
        XCTAssertEqual(KeepAwakeDuration.untilTurnedOff.label, "Until I turn it off")
    }

    func testDurationDefaultsToOneHour() throws {
        XCTAssertEqual(caffeine.duration, .hours(1))
    }

    func testDurationIsClampedToTheSupportedRange() throws {
        caffeine.duration = .hours(0)
        XCTAssertEqual(caffeine.duration, .hours(KeepAwakeDuration.minHours))

        caffeine.duration = .hours(99)
        XCTAssertEqual(caffeine.duration, .hours(KeepAwakeDuration.maxHours))

        caffeine.duration = .hours(3)
        XCTAssertEqual(caffeine.duration, .hours(3))
    }

    func testDurationIsPersisted() throws {
        caffeine.duration = .hours(4)

        XCTAssertEqual(defaults.integer(forKey: CaffeineManager.durationKey), 4)
        XCTAssertEqual(CaffeineManager(defaults: defaults).duration, .hours(4),
                       "the chosen duration should survive a relaunch")
    }

    func testUntilTurnedOffIsPersisted() throws {
        caffeine.duration = .untilTurnedOff

        XCTAssertEqual(CaffeineManager(defaults: defaults).duration, .untilTurnedOff,
                       "the chosen duration should survive a relaunch")
    }

    // MARK: - Opt-in end-to-end check

    /// Sits through the machine's real display-sleep timeout with Keep Awake on and checks
    /// that the display never went to sleep. This is the only honest way to "simulate"
    /// display sleep: idle sleep is driven by the HID idle timer, so it cannot be triggered
    /// on demand, and forcing sleep bypasses assertions by design.
    ///
    /// Opt in with `AIHELPER_DISPLAY_SLEEP_SOAK=1`, and do not touch the keyboard, mouse or
    /// trackpad while it runs — any input resets the idle timer and the test proves nothing.
    /// Skipped unless the timeout is short enough to be worth waiting for.
    func testDisplayStaysAwakeThroughIdleTimeout() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIHELPER_DISPLAY_SLEEP_SOAK"] == "1",
                          "set AIHELPER_DISPLAY_SLEEP_SOAK=1 to run the multi-minute idle soak")

        let timeout = try XCTUnwrap(Self.displaySleepTimeoutMinutes(),
                                    "could not read the display sleep timeout from pmset")
        try XCTSkipUnless(timeout > 0, "display sleep is disabled on this Mac, so there is nothing to prevent")
        try XCTSkipUnless(timeout <= 3, "display sleep timeout is \(timeout) min — too long to wait for in a test")

        caffeine.duration = .hours(KeepAwakeDuration.maxHours)
        caffeine.start()

        let wait = Double(timeout) * 60 + 45
        try await Task.sleep(for: .seconds(wait))

        XCTAssertTrue(caffeine.isActive, "Keep Awake stopped on its own during the soak")
        XCTAssertEqual(Self.ownAssertions(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep).count, 1,
                       "the assertion was released during the soak")
        XCTAssertEqual(CGDisplayIsAsleep(CGMainDisplayID()), 0,
                       "the display slept after \(timeout) min even though Keep Awake was on")
    }

    // MARK: - Helpers

    /// Names of the assertions of `type` held by this process.
    private static func ownAssertions(ofType type: String) -> [String] {
        var copy: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copy) == kIOReturnSuccess,
              let byProcess = copy?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (byProcess[pid] ?? [])
            .filter { $0[kIOPMAssertionTypeKey] as? String == type }
            .compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    /// System-wide aggregate level for an assertion type: 1 when anything on the Mac holds it.
    private static func systemAssertionLevel(for type: String) -> Int {
        var copy: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&copy) == kIOReturnSuccess,
              let status = copy?.takeRetainedValue() as? [String: Int]
        else { return -1 }
        return status[type] ?? 0
    }

    /// `pmset -g` reports the timeout that is active for the current power source.
    private static func displaySleepTimeoutMinutes() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("displaysleep") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if let index = fields.firstIndex(of: "displaysleep"), fields.indices.contains(index + 1) {
                return Int(fields[index + 1])
            }
        }
        return nil
    }
}
