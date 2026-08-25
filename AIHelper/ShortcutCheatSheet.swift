import SwiftUI

/// One place that lists every Screenshot Notes shortcut. Used as a popover in
/// the editor, in Settings and (shortened) in the menu bar popover.
struct ShortcutCheatSheet: View {
    struct Entry: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    struct Group: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let global = Group(title: "Anywhere", entries: [
        Entry(keys: ShortcutConfig.annotateScreenshot.displayString, action: "Screenshot of the front window → mark & note"),
        Entry(keys: ShortcutConfig.finishScreenshotSession.displayString, action: "Export right away (PDF → clipboard; notes.md + ZIP on disk)"),
        Entry(keys: ShortcutConfig.reviewScreenshotSession.displayString, action: "Review/edit everything first, ↩ there exports"),
        Entry(keys: ShortcutConfig.recording.displayString, action: "Dictate into the focused text box"),
    ])

    static let overlay = Group(title: "On the frozen screenshot", entries: [
        Entry(keys: "drag", action: "Mark an area"),
        Entry(keys: "↩", action: "Note for the whole page"),
        Entry(keys: "esc", action: "Cancel (empty capture is discarded)"),
    ])

    static let popup = Group(title: "Note popup", entries: [
        Entry(keys: "↩", action: "Save note and return to the browser"),
        Entry(keys: "⌥↩", action: "New line"),
        Entry(keys: "⌘D", action: "Start / stop dictation"),
        Entry(keys: "⌘N", action: "Save and mark another area on this page"),
        Entry(keys: "⌘E", action: "Save and open the editor"),
        Entry(keys: "esc", action: "Discard this area"),
    ])

    static let editor = Group(title: "Editor window", entries: [
        Entry(keys: "drag", action: "Mark an area on the screenshot"),
        Entry(keys: "⌘↩", action: "Save and close"),
        Entry(keys: "⇧⌘E", action: "Review & export (second press exports)"),
        Entry(keys: "⇧⌘K", action: "Send to Claude Code on this Mac"),
        Entry(keys: "⇧⌘C", action: "Copy Markdown"),
        Entry(keys: "⇧⌘Z", action: "Export ZIP…"),
        Entry(keys: "⇧⌘P", action: "Export PDF…"),
    ])

    static let all: [Group] = [global, overlay, popup, editor]

    var groups: [Group] = ShortcutCheatSheet.all
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    ForEach(group.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            KeyCap(text: entry.keys)
                            Text(entry.action)
                                .font(compact ? .caption : .callout)
                                .foregroundColor(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

/// Monospaced key label that looks like a key cap.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 54)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.gray.opacity(0.35), lineWidth: 1)
            )
    }
}
