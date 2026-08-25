import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenCaptureService")

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noWindowFound
    case captureFailed(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission required"
        case .noWindowFound:
            return "No window to capture"
        case .captureFailed(let reason):
            return "Screenshot failed: \(reason)"
        case .invalidImage:
            return "Screenshot could not be read"
        }
    }
}

/// Metadata about the page/window that was captured.
struct CapturedPageInfo {
    var appName: String?
    var windowTitle: String?
    var pageURL: String?
}

struct CaptureResult {
    let pngData: Data
    let pixelSize: CGSize
    let info: CapturedPageInfo
    /// Screen rect of the captured window in Quartz coordinates (origin top-left
    /// of the main display). nil when the whole display was captured.
    let windowBounds: CGRect?
}

/// Captures the frontmost window (typically the browser) using the system
/// `screencapture` tool and collects the page URL/title via AppleScript.
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    private init() {}

    // MARK: - Permission

    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt (first time) or opens System Settings.
    func requestScreenRecordingPermission() {
        let granted = CGRequestScreenCaptureAccess()
        logger.info("Screen recording access request returned \(granted)")
        if !granted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Capture

    /// Captures the frontmost window that does not belong to this app.
    /// Falls back to the full main display if no suitable window is found.
    func captureFrontmostWindow() async throws -> CaptureResult {
        guard hasScreenRecordingPermission else {
            requestScreenRecordingPermission()
            throw ScreenCaptureError.permissionDenied
        }

        let target = frontmostForeignWindow()
        var info = CapturedPageInfo(
            appName: target?.appName,
            windowTitle: target?.title,
            pageURL: nil
        )

        // Collect URL/title from the browser (best effort, never fatal)
        if let app = target?.app {
            let browserInfo = await browserPageInfo(for: app)
            if let url = browserInfo.url, !url.isEmpty { info.pageURL = url }
            if let title = browserInfo.title, !title.isEmpty { info.windowTitle = title }
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihelper_capture_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var arguments = ["-x", "-t", "png"]
        if let windowID = target?.windowID {
            // -o: no window shadow, -l: specific window id
            arguments += ["-o", "-l", String(windowID)]
        }
        arguments.append(tmpURL.path)

        try await runScreencapture(arguments: arguments)

        guard let data = try? Data(contentsOf: tmpURL), !data.isEmpty else {
            throw ScreenCaptureError.captureFailed("no image written")
        }
        guard let rep = NSBitmapImageRep(data: data) else {
            throw ScreenCaptureError.invalidImage
        }

        let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        logger.info("Captured \(Int(pixelSize.width))x\(Int(pixelSize.height)) from \(info.appName ?? "screen")")

        return CaptureResult(pngData: data, pixelSize: pixelSize, info: info, windowBounds: target?.bounds)
    }

    // MARK: - Window lookup

    private struct WindowTarget {
        let windowID: CGWindowID
        let app: NSRunningApplication
        let appName: String?
        let title: String?
        let bounds: CGRect
    }

    /// Walks the on-screen window list (front to back) and returns the first
    /// normal-layer window that is not ours and has a reasonable size.
    private func frontmostForeignWindow() -> WindowTarget? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 200, bounds.height >= 150,
                  let app = NSRunningApplication(processIdentifier: pid)
            else { continue }

            let title = entry[kCGWindowName as String] as? String
            return WindowTarget(
                windowID: windowID,
                app: app,
                appName: app.localizedName ?? entry[kCGWindowOwnerName as String] as? String,
                title: title,
                bounds: bounds
            )
        }
        return nil
    }

    // MARK: - screencapture

    private func runScreencapture(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                let stderr = Pipe()
                process.standardError = stderr
                process.standardOutput = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                    logger.error("screencapture failed: \(message)")
                    continuation.resume(throwing: ScreenCaptureError.captureFailed(message))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Browser page info

    private enum BrowserFamily {
        case safari
        case chromium
    }

    private func browserFamily(for app: NSRunningApplication) -> BrowserFamily? {
        switch app.bundleIdentifier {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return .safari
        case "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
             "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
             "org.chromium.Chromium", "com.operasoftware.Opera":
            return .chromium
        default:
            return nil
        }
    }

    private func browserPageInfo(for app: NSRunningApplication) async -> (url: String?, title: String?) {
        guard let family = browserFamily(for: app), let appName = app.localizedName else {
            return (nil, nil)
        }

        // Use the bundle id so localized app names don't break the tell block
        let target = app.bundleIdentifier.map { "application id \"\($0)\"" } ?? "application \"\(appName)\""
        let script: String
        switch family {
        case .safari:
            script = """
            tell \(target)
                if (count of windows) = 0 then return ""
                set theTab to current tab of front window
                return (URL of theTab) & "\n" & (name of theTab)
            end tell
            """
        case .chromium:
            script = """
            tell \(target)
                if (count of windows) = 0 then return ""
                set theTab to active tab of front window
                return (URL of theTab) & "\n" & (title of theTab)
            end tell
            """
        }

        guard let result = await runAppleScript(script), !result.isEmpty else {
            return (nil, nil)
        }
        let parts = result.components(separatedBy: "\n")
        let url = parts.first?.trimmingCharacters(in: .whitespaces)
        let title = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (url, title.isEmpty ? nil : title)
    }

    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                if let error = error {
                    logger.warning("AppleScript for browser info failed: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result?.stringValue)
            }
        }
    }
}
