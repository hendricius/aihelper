import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ClipboardHistoryStore")

@MainActor
class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var items: [ClipboardItem] = []

    private let storageKey = "clipboardHistory"
    private let maxItems = 50
    private var pollTimer: Timer?
    private var lastChangeCount: Int

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        load()
        startPolling()
        logger.info("ClipboardHistoryStore initialized with \(self.items.count) items")
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        // Deduplicate consecutive identical copies
        if let last = items.first, last.text == text {
            return
        }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let item = ClipboardItem(text: text, sourceAppName: sourceApp)

        items.insert(item, at: 0)

        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        save()
        logger.debug("Captured clipboard item from \(sourceApp ?? "unknown") (\(text.count) chars)")
    }

    // MARK: - Actions

    func copyToClipboard(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        logger.debug("Copied item back to clipboard")
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
        logger.info("Cleared all clipboard history")
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(items)
            UserDefaults.standard.set(encoded, forKey: storageKey)
        } catch {
            logger.error("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            if let data = UserDefaults.standard.data(forKey: storageKey) {
                items = try JSONDecoder().decode([ClipboardItem].self, from: data)
                logger.info("Loaded \(self.items.count) clipboard items from storage")
            }
        } catch {
            logger.error("Failed to decode clipboard history: \(error.localizedDescription). Clearing corrupted data.")
            UserDefaults.standard.removeObject(forKey: storageKey)
            items = []
        }
    }
}
