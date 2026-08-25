import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "AgentHandoff")

enum AgentHandoffError: LocalizedError {
    case emptySession
    case iTermFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySession:
            return "No screenshots in this session"
        case .iTermFailed(let reason):
            return "Could not talk to iTerm: \(reason)"
        }
    }
}

/// Hands the current session to Claude Code – either locally (new iTerm tab in
/// the session folder) or on the VM the current iTerm session is connected to.
@MainActor
enum AgentHandoffService {

    /// The prompt the agent receives. `notesPath` is where notes.md lives for the agent.
    static func prompt(for session: ScreenshotSession, notesPath: String) -> String {
        var parts: [String] = []
        parts.append("Read \(notesPath). It contains screenshots I took while browsing, with my notes: numbered red markers in the annotated images correspond to the numbered areas in the file, and every image is referenced by path – open them.")
        let task = session.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.isEmpty {
            parts.append("Summarize what you see and ask me what to do next.")
        } else {
            parts.append("Task: \(task)")
        }
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Local

    /// Opens a new iTerm tab, cds into the session folder and starts `claude` with the prompt.
    static func sendToLocalClaudeCode(store: ScreenshotNotesStore) async throws {
        guard !store.session.captures.isEmpty else { throw AgentHandoffError.emptySession }
        store.flush()
        try await sendToLocalClaudeCode(session: store.session, folder: store.sessionFolder)
    }

    /// Same for any session folder (used by the history for finished sessions).
    static func sendToLocalClaudeCode(session: ScreenshotSession, folder sessionFolder: URL) async throws {
        guard !session.captures.isEmpty else { throw AgentHandoffError.emptySession }
        try ScreenshotSessionExporter.writeNotes(for: session, folder: sessionFolder)

        let folder = sessionFolder.path
        let prompt = prompt(for: session, notesPath: "notes.md in the current directory")
        let shellCommand = "cd '\(folder.replacingOccurrences(of: "'", with: "'\\''"))' && claude \"\(prompt)\""
        let tabName = "Screenshot Notes: \(sessionFolder.lastPathComponent)"

        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            end if
            tell current window
                set newTab to (create tab with default profile)
                tell current session of newTab
                    set name to "\(appleScriptEscaped(tabName))"
                    write text "\(appleScriptEscaped(shellCommand))"
                end tell
            end tell
        end tell
        """
        try await run(script)
        logger.info("Started local Claude Code in \(folder)")
    }

    // MARK: - VM

    /// Copies a portable copy of the session to the VM behind the current iTerm
    /// session and types the prompt into that session (Claude Code is expected
    /// to be running there). Returns the host alias.
    static func sendToVM(store: ScreenshotNotesStore) async throws -> String {
        guard !store.session.captures.isEmpty else { throw AgentHandoffError.emptySession }
        store.flush()
        return try await sendToVM(session: store.session, folder: store.sessionFolder)
    }

    /// Same for any session folder (used by the history for finished sessions).
    static func sendToVM(session: ScreenshotSession, folder: URL) async throws -> String {
        guard !session.captures.isEmpty else { throw AgentHandoffError.emptySession }

        let host = try await ScreenshotTransferService.shared.detectCurrentHostAlias()
        let staging = try ScreenshotSessionExporter.stagePortableCopy(for: session, folder: folder)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        let remoteParent = "/tmp"
        try await ScreenshotTransferService.shared.transferDirectory(
            localURL: staging,
            hostAlias: host,
            remoteParent: remoteParent
        )

        let remoteNotes = "\(remoteParent)/\(staging.lastPathComponent)/\(ScreenshotNotesStore.notesFileName)"
        let prompt = prompt(for: session, notesPath: remoteNotes)
        await ScreenshotTransferService.shared.typeInTerminal(prompt)
        logger.info("Sent session to \(host) at \(remoteNotes)")
        return host
    }

    // MARK: - Helpers

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                script?.executeAndReturnError(&error)
                if let error {
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
                    continuation.resume(throwing: AgentHandoffError.iTermFailed(message))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
