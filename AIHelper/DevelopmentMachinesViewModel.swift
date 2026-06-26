import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "DevelopmentMachines")

/// Drives the Development Machines UI from `~/.ssh/config`. No network, no API key,
/// no polling — hosts are loaded on demand and via a manual refresh.
@MainActor
class DevelopmentMachinesViewModel: ObservableObject {
    @Published var hosts: [SSHHost] = []
    @Published var copiedItemId: String?
    /// Alias of the host used as the fallback target for the screenshot-transfer hotkey.
    @Published var screenshotTargetAlias: String?

    init() {
        screenshotTargetAlias = UserDefaults.standard.string(forKey: ScreenshotTransferService.defaultTargetHostKey)
        refresh()
    }

    // MARK: - Public

    func refresh() {
        hosts = SSHConfigParser.loadHosts()
        logger.info("Loaded \(self.hosts.count) host(s) from ~/.ssh/config")
    }

    func isScreenshotTarget(_ host: SSHHost) -> Bool {
        screenshotTargetAlias == host.alias
    }

    /// Toggle the given host as the default screenshot-transfer target.
    func toggleScreenshotTarget(_ host: SSHHost) {
        if screenshotTargetAlias == host.alias {
            screenshotTargetAlias = nil
            UserDefaults.standard.removeObject(forKey: ScreenshotTransferService.defaultTargetHostKey)
        } else {
            screenshotTargetAlias = host.alias
            UserDefaults.standard.set(host.alias, forKey: ScreenshotTransferService.defaultTargetHostKey)
        }
    }

    func copySSHCommand(for host: SSHHost) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host.sshCommand, forType: .string)

        copiedItemId = host.id
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedItemId == host.id {
                copiedItemId = nil
            }
        }
    }

    func openTerminalWithSSH(for host: SSHHost) {
        openTerminal(with: host.sshCommand, tabName: host.alias)
    }

    func openInBrowser(for host: SSHHost) {
        // Use the explicit HostName when present; otherwise resolve via `ssh -G` off the main thread.
        if !host.hostName.isEmpty {
            open(hostName: host.hostName)
            return
        }
        let alias = host.alias
        Task {
            let resolved = await Task.detached { SSHConfigParser.resolvedHostName(for: alias) }.value
            if let resolved, !resolved.isEmpty {
                open(hostName: resolved)
            } else {
                logger.warning("No resolvable hostname for \(alias)")
            }
        }
    }

    // MARK: - Private

    private func open(hostName: String) {
        guard let url = URL(string: "http://\(hostName):3000") else {
            logger.warning("Could not build URL for host \(hostName)")
            return
        }
        logger.info("Opening browser: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    private func openTerminal(with sshCommand: String, tabName: String) {
        // Open in iTerm2 in a new tab named after the host.
        let escapedName = tabName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm"
            activate
            tell current window
                set newTab to (create tab with default profile)
                tell current session of newTab
                    set name to "\(escapedName)"
                    write text "\(sshCommand)"
                end tell
            end tell
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                logger.error("Failed to open iTerm2: \(error)")
                // Fallback: create a new window if no window exists.
                let fallbackScript = """
                tell application "iTerm"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow
                        set name to "\(escapedName)"
                        write text "\(sshCommand)"
                    end tell
                end tell
                """
                if let fallbackScriptObject = NSAppleScript(source: fallbackScript) {
                    var fallbackError: NSDictionary?
                    fallbackScriptObject.executeAndReturnError(&fallbackError)
                    if let fallbackError = fallbackError {
                        logger.error("Failed to open iTerm2 (fallback): \(fallbackError)")
                    }
                }
            }
        }
    }
}
