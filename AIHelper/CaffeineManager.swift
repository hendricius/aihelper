import Foundation
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "Caffeine")

/// How long Keep Awake runs once it is switched on.
enum KeepAwakeDuration: Hashable {
    case hours(Int)
    /// Stays on until the user switches it off, across app restarts.
    case untilTurnedOff

    static let minHours = 1
    static let maxHours = 5

    /// Every choice the duration pickers offer, shortest first.
    static let choices: [KeepAwakeDuration] =
        (minHours...maxHours).map { .hours($0) } + [.untilTurnedOff]

    /// "2 hours", "Until I turn it off"
    var label: String {
        switch self {
        case .hours(let hours): return "\(hours) hour\(hours == 1 ? "" : "s")"
        case .untilTurnedOff: return "Until I turn it off"
        }
    }

    /// "2h", "No limit"
    var shortLabel: String {
        switch self {
        case .hours(let hours): return "\(hours)h"
        case .untilTurnedOff: return "No limit"
        }
    }
}

/// Keeps the Mac awake for a chosen duration, or until switched off — like the classic
/// "Caffeine" app, built in.
///
/// Uses an IOKit power assertion (`kIOPMAssertionTypePreventUserIdleDisplaySleep`), the
/// same mechanism `caffeinate -d` uses. Because the display never idles, the screen saver
/// never starts and macOS therefore never reaches the idle screen lock — so while this is
/// active, **the screen will not lock on its own** (you can still lock it manually).
///
/// macOS drops the assertion when the app quits, so a running session is also saved and
/// `restore()` resumes it on the next launch with its original end time.
///
/// No special permission is required, and the assertion is always released on stop, on
/// expiry, and when the app quits.
@MainActor
final class CaffeineManager: ObservableObject {
    static let shared = CaffeineManager()

    /// Whether keep-awake is currently active.
    @Published private(set) var isActive = false
    /// Seconds remaining until auto-stop (0 when inactive or running until turned off).
    @Published private(set) var remaining: TimeInterval = 0
    /// When the running session stops on its own; nil when inactive or running until
    /// turned off.
    @Published private(set) var endDate: Date?
    /// The user's chosen duration (persisted). Hours are clamped to the supported range.
    @Published var duration: KeepAwakeDuration {
        didSet {
            let valid = Self.clamped(duration)
            if valid != duration { duration = valid }
            defaults.set(Self.storedValue(for: valid), forKey: Self.durationKey)
        }
    }

    /// The chosen duration: 1...5 hours, or 0 for "until I turn it off".
    static let durationKey = "caffeine_duration_hours"
    /// When the running session ends, so a relaunch can resume it. `Date.distantFuture`
    /// means it runs until turned off. Absent while Keep Awake is off.
    static let activeUntilKey = "caffeine_active_until"
    static let defaultDuration = KeepAwakeDuration.hours(1)

    private let defaults: UserDefaults
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        duration = Self.duration(fromStored: defaults.object(forKey: Self.durationKey) as? Int)
    }

    // MARK: - Public

    func toggle() {
        isActive ? stop() : start()
    }

    /// Begin keeping the Mac awake for `duration`. Restarts the countdown if already active.
    func start() {
        switch duration {
        case .hours(let hours):
            begin(until: Date().addingTimeInterval(TimeInterval(hours) * 3600))
        case .untilTurnedOff:
            begin(until: nil)
        }
    }

    /// Resumes the session that was running when the app last quit, keeping its original
    /// end time. Does nothing if Keep Awake was off, or its time ran out in the meantime.
    func restore() {
        guard !isActive, let until = defaults.object(forKey: Self.activeUntilKey) as? Date else { return }

        if until >= .distantFuture {
            logger.info("Resuming keep-awake until turned off")
            begin(until: nil)
        } else if until > Date() {
            // A clock change must not stretch a session past the longest duration offered.
            let latest = Date().addingTimeInterval(TimeInterval(KeepAwakeDuration.maxHours) * 3600)
            logger.info("Resuming keep-awake until \(until, privacy: .public)")
            begin(until: min(until, latest))
        } else {
            defaults.removeObject(forKey: Self.activeUntilKey)
        }
    }

    func stop() {
        releaseAssertion()
        timer?.invalidate()
        timer = nil
        endDate = nil
        remaining = 0
        defaults.removeObject(forKey: Self.activeUntilKey)
        if isActive { logger.info("Keep-awake stopped") }
        isActive = false
    }

    /// Human-readable countdown such as "1:59:58" or "59:58".
    var remainingText: String {
        let total = Int(remaining.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1:59:58 left", or "no time limit" for a session that runs until turned off.
    var timeLeftText: String {
        endDate == nil ? "no time limit" : "\(remainingText) left"
    }

    // MARK: - Private

    /// Takes the assertion and saves the session. `end` nil runs until turned off.
    private func begin(until end: Date?) {
        releaseAssertion()
        timer?.invalidate()
        timer = nil

        var id: IOPMAssertionID = 0
        let reason = "AIHelper keep awake" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )

        guard result == kIOReturnSuccess else {
            logger.error("Failed to create power assertion: \(result)")
            stop()
            return
        }

        assertionID = id
        endDate = end
        remaining = end.map { max($0.timeIntervalSinceNow, 0) } ?? 0
        isActive = true
        defaults.set(end ?? .distantFuture, forKey: Self.activeUntilKey)

        guard end != nil else {
            logger.info("Keep-awake started until turned off")
            return
        }
        logger.info("Keep-awake started, \(self.remainingText, privacy: .public) left")

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.5
        timer = t
    }

    private func tick() {
        guard let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            stop()
        } else {
            remaining = left
        }
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    // MARK: - Persistence

    private static func clamped(_ duration: KeepAwakeDuration) -> KeepAwakeDuration {
        guard case .hours(let hours) = duration else { return duration }
        return .hours(min(max(hours, KeepAwakeDuration.minHours), KeepAwakeDuration.maxHours))
    }

    private static func duration(fromStored value: Int?) -> KeepAwakeDuration {
        guard let value else { return defaultDuration }
        return value == 0 ? .untilTurnedOff : clamped(.hours(value))
    }

    private static func storedValue(for duration: KeepAwakeDuration) -> Int {
        switch duration {
        case .hours(let hours): return hours
        case .untilTurnedOff: return 0
        }
    }
}
