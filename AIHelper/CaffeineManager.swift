import Foundation
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "Caffeine")

/// Keeps the Mac awake for a chosen duration, then automatically lets it sleep again —
/// like the classic "Caffeine" app, built in.
///
/// Uses an IOKit power assertion (`kIOPMAssertionTypePreventUserIdleDisplaySleep`), the
/// same mechanism `caffeinate -d` uses. Because the display never idles, the screen saver
/// never starts and macOS therefore never reaches the idle screen lock — so while this is
/// active, **the screen will not lock on its own** (you can still lock it manually).
///
/// No special permission is required, and the assertion is always released on stop, on
/// expiry, and when the app quits.
@MainActor
final class CaffeineManager: ObservableObject {
    static let shared = CaffeineManager()

    /// Whether keep-awake is currently active.
    @Published private(set) var isActive = false
    /// Seconds remaining until auto-stop (0 when inactive).
    @Published private(set) var remaining: TimeInterval = 0
    /// User's chosen duration in hours (persisted). Clamped to 1...5.
    @Published var durationHours: Int {
        didSet {
            let clamped = min(max(durationHours, Self.minHours), Self.maxHours)
            if clamped != durationHours { durationHours = clamped; return }
            UserDefaults.standard.set(durationHours, forKey: Self.durationKey)
        }
    }

    static let durationKey = "caffeine_duration_hours"
    static let minHours = 1
    static let maxHours = 5
    static let defaultDurationHours = 1

    private var assertionID: IOPMAssertionID = 0
    private var endDate: Date?
    private var timer: Timer?

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.durationKey) as? Int
        durationHours = min(max(stored ?? Self.defaultDurationHours, Self.minHours), Self.maxHours)
    }

    // MARK: - Public

    func toggle() {
        isActive ? stop() : start()
    }

    /// Begin keeping the Mac awake for `durationHours`. Restarts the timer if already active.
    func start() {
        releaseAssertion()

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
            return
        }

        assertionID = id
        let duration = TimeInterval(durationHours) * 3600
        endDate = Date().addingTimeInterval(duration)
        remaining = duration
        isActive = true
        logger.info("Keep-awake started for \(self.durationHours)h")

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.5
        timer = t
    }

    func stop() {
        releaseAssertion()
        timer?.invalidate()
        timer = nil
        endDate = nil
        remaining = 0
        if isActive { logger.info("Keep-awake stopped") }
        isActive = false
    }

    /// Human-readable countdown such as "1:59:58" or "59:58".
    var remainingText: String {
        let total = Int(remaining.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Private

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
}
