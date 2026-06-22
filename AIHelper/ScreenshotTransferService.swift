import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotTransferService")

// Debug file logging
private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "[\(timestamp)] \(message)\n"
    let logPath = "/tmp/aihelper_screenshot_debug.log"

    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(logLine.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: logLine.data(using: .utf8))
    }

    logger.info("\(message)")
    print("[ScreenshotTransfer] \(message)")
}

/// Result of a successful screenshot transfer
struct TransferResult {
    let hostAlias: String
    let remotePath: String
}

/// Errors that can occur during screenshot transfer
enum TransferError: LocalizedError {
    case noImageInClipboard
    case noActiveTerminal
    case noSSHSession
    case hostNotFound(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImageInClipboard:
            return "No image in clipboard"
        case .noActiveTerminal:
            return "No active iTerm2 window"
        case .noSSHSession:
            return "Terminal is not on a known host. Open a dev machine from the Development Machines window, or set a default target."
        case .hostNotFound(let name):
            return "Host not found in ~/.ssh/config: \(name)"
        case .transferFailed(let msg):
            return "Transfer failed: \(msg)"
        }
    }
}

/// Transfers a clipboard screenshot to a development machine over SCP.
///
/// The target is resolved from `~/.ssh/config`: the active iTerm2 session title is
/// matched against host aliases, falling back to a user-configured default host. The
/// SCP itself runs `scp <localfile> <alias>:<path>`, letting `~/.ssh/config` supply the
/// HostName, User, Port, IdentityFile, and any ProxyJump.
actor ScreenshotTransferService {
    static let shared = ScreenshotTransferService()

    /// UserDefaults key holding a fallback target host alias, used when the active
    /// terminal session can't be matched to an `~/.ssh/config` host.
    static let defaultTargetHostKey = "screenshot_target_host"

    /// Main entry point - transfers clipboard screenshot to the current dev machine.
    func transferClipboardScreenshot() async throws -> TransferResult {
        logger.info("Starting clipboard screenshot transfer")

        // 1. Get image from clipboard
        let imageData = try await getClipboardImageData()
        logger.info("Got image from clipboard: \(imageData.count) bytes")

        // 2. Resolve the target SSH host alias
        let alias = try await resolveTargetAlias()
        logger.info("Resolved target host alias: \(alias)")

        // 3. Generate remote path with timestamp
        let timestamp = Int(Date().timeIntervalSince1970)
        let remotePath = "/tmp/screenshot_\(timestamp).png"

        // 4. Transfer the image via SCP
        try await transferImage(imageData: imageData, toHost: alias, remotePath: remotePath)
        logger.info("Image transferred to \(alias):\(remotePath)")

        // 5. Type the prompt in the terminal
        let prompt = "See this screenshot: \(remotePath)"
        debugLog("Will type prompt: '\(prompt)' (remotePath='\(remotePath)')")
        await typeInCurrentTerminal(prompt)
        debugLog("Typed prompt in terminal")

        return TransferResult(hostAlias: alias, remotePath: remotePath)
    }

    // MARK: - Private Methods

    /// Read PNG image data from the macOS clipboard
    private func getClipboardImageData() async throws -> Data {
        let imageData: Data? = await MainActor.run {
            let pasteboard = NSPasteboard.general

            // Try to read NSImage from pasteboard
            guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil),
                  let image = images.first as? NSImage else {
                return nil
            }

            // Convert NSImage to PNG data
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }

            return pngData
        }

        guard let data = imageData else {
            throw TransferError.noImageInClipboard
        }

        return data
    }

    /// Resolve which SSH host to transfer to. Matches the active iTerm2 session title
    /// against `~/.ssh/config` aliases, falling back to a user-configured default host.
    private func resolveTargetAlias() async throws -> String {
        let hosts = SSHConfigParser.loadHosts()
        let sessionName = (try? await getCurrentiTermSessionName()) ?? ""
        logger.info("Current iTerm session name: '\(sessionName)'")

        if let alias = matchAlias(sessionName: sessionName, hosts: hosts) {
            logger.info("Matched session to host alias: \(alias)")
            return alias
        }

        // Fallback: a user-configured default target host (set from the Development Machines UI).
        if let configured = UserDefaults.standard.string(forKey: Self.defaultTargetHostKey),
           !configured.isEmpty {
            guard hosts.contains(where: { $0.alias == configured }) else {
                throw TransferError.hostNotFound(configured)
            }
            logger.info("Using configured default screenshot target host: \(configured)")
            return configured
        }

        throw TransferError.noSSHSession
    }

    /// Match an iTerm session title to a host alias from `~/.ssh/config`.
    private func matchAlias(sessionName: String, hosts: [SSHHost]) -> String? {
        guard !sessionName.isEmpty, !hosts.isEmpty else { return nil }

        // Clean legacy "VM: " / "Agent: " prefixes and "(ssh)"-style suffixes.
        var cleaned = sessionName
        for prefix in ["VM: ", "Agent: "] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
        }
        if let paren = cleaned.firstIndex(of: "(") {
            cleaned = String(cleaned[..<paren])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        // Exact alias match first.
        if let exact = hosts.first(where: { $0.alias == cleaned }) {
            return exact.alias
        }

        // Otherwise, any alias appearing as a token in the session title.
        let separators: Set<Character> = [" ", "\t", ":", "(", ")", "@"]
        let tokens = Set(sessionName.split(whereSeparator: { separators.contains($0) }).map(String.init))
        return hosts.first(where: { tokens.contains($0.alias) })?.alias
    }

    /// Get the current iTerm2 session name via AppleScript
    private func getCurrentiTermSessionName() async throws -> String {
        let script = """
        tell application "iTerm"
            if (count of windows) = 0 then
                error "No iTerm windows"
            end if
            tell current session of current window
                return name
            end tell
        end tell
        """

        let result = await runAppleScript(script)

        guard let sessionName = result, !sessionName.isEmpty else {
            throw TransferError.noActiveTerminal
        }

        return sessionName
    }

    /// Transfer image data to the host via SCP, using `~/.ssh/config` for connection details.
    private func transferImage(imageData: Data, toHost alias: String, remotePath: String) async throws {
        logger.info("Starting SCP transfer to \(alias):\(remotePath)")

        // Write image to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let localPath = tempDir.appendingPathComponent("aihelper_screenshot_\(UUID().uuidString).png")
        logger.info("Writing \(imageData.count) bytes to temp file: \(localPath.path)")

        do {
            try imageData.write(to: localPath)
        } catch {
            logger.error("Failed to write temp file: \(error.localizedDescription)")
            throw TransferError.transferFailed("Failed to write temp file: \(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: localPath)
            logger.debug("Cleaned up temp file")
        }

        // Run scp to "<alias>:<remotePath>" — ~/.ssh/config supplies HostName, User, Port,
        // IdentityFile and any ProxyJump.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=30",
            localPath.path,
            "\(alias):\(remotePath)"
        ]

        logger.info("Running: scp \(localPath.lastPathComponent) \(alias):\(remotePath)")

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run SCP process: \(error.localizedDescription)")
            throw TransferError.transferFailed("Failed to run SCP: \(error.localizedDescription)")
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errorMessage = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("SCP failed with exit code \(process.terminationStatus): \(errorMessage)")
            throw TransferError.transferFailed(errorMessage.isEmpty ? "SCP exit code \(process.terminationStatus)" : errorMessage)
        }

        if !errorOutput.isEmpty {
            logger.info("SCP stderr (success): \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        logger.info("SCP transfer completed successfully")
    }

    /// Type text in the current iTerm2 terminal
    private func typeInCurrentTerminal(_ text: String) async {
        debugLog("Typing in terminal: '\(text)'")

        // Escape the text for AppleScript
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        debugLog("Escaped text: '\(escapedText)'")

        let script = """
        tell application "iTerm"
            tell current session of current window
                write text "\(escapedText)"
            end tell
        end tell
        """

        debugLog("AppleScript to execute:\n\(script)")

        let result = await runAppleScript(script)
        debugLog("AppleScript result: \(result ?? "nil")")
    }

    /// Run an AppleScript and return the result
    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)

                if let error = error {
                    logger.error("AppleScript error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: result?.stringValue)
            }
        }
    }
}
