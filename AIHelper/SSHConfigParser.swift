import Foundation

/// A single host entry parsed from `~/.ssh/config`.
struct SSHHost: Identifiable, Equatable {
    let alias: String
    /// Explicit `HostName` from the config. May be empty if not specified in the file
    /// (e.g. it is supplied by an `Include` or a `Match` block) — use
    /// `SSHConfigParser.resolvedHostName(for:)` to resolve it via `ssh -G` when needed.
    let hostName: String
    /// Explicit `User`, or empty if not specified.
    let user: String
    /// Explicit `Port`, or nil (SSH defaults to 22).
    let port: Int?

    var id: String { alias }

    /// `ssh <alias>` — relies on `~/.ssh/config` to resolve HostName/User/Port/IdentityFile/ProxyJump.
    var sshCommand: String { "ssh \(alias)" }

    /// Best-effort host string for display: the explicit HostName, falling back to the alias.
    var displayHost: String { hostName.isEmpty ? alias : hostName }
}

/// Parses `~/.ssh/config` into a list of concrete hosts.
///
/// This is intentionally a lightweight parser for *listing* hosts. It does not expand
/// `Include` directives or apply `Match` blocks — `ssh` itself does that when you actually
/// connect with `ssh <alias>`. For the browser-URL case where an explicit `HostName` is
/// missing, `resolvedHostName(for:)` shells out to `ssh -G` to get the effective value.
enum SSHConfigParser {

    /// Default user-level SSH config path (`~/.ssh/config`).
    static var defaultConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    /// Load and parse the SSH config. Returns `[]` if the file is missing or unreadable.
    static func loadHosts(from url: URL? = nil) -> [SSHHost] {
        let configURL = url ?? defaultConfigURL
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }
        return parse(contents)
    }

    /// Pure parser over SSH config file contents.
    ///
    /// - Recognizes `Host`, `HostName`, `User`, `Port` (case-insensitively).
    /// - Expands a multi-alias `Host` line (e.g. `Host a b c`) into one entry per alias.
    /// - Skips wildcard/pattern aliases (those containing `*` or `?`).
    /// - Treats a `Match` line as ending the current `Host` block.
    static func parse(_ contents: String) -> [SSHHost] {
        var hosts: [SSHHost] = []

        var currentAliases: [String] = []
        var currentHostName = ""
        var currentUser = ""
        var currentPort: Int?

        func flush() {
            for alias in currentAliases where !alias.contains("*") && !alias.contains("?") {
                hosts.append(SSHHost(alias: alias,
                                     hostName: currentHostName,
                                     user: currentUser,
                                     port: currentPort))
            }
            currentAliases = []
            currentHostName = ""
            currentUser = ""
            currentPort = nil
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let (keyword, value) = splitDirective(line)
            switch keyword.lowercased() {
            case "host":
                flush()
                currentAliases = value
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
            case "match":
                // End the current host block; Match-scoped settings are ignored for listing.
                flush()
            case "hostname":
                currentHostName = value
            case "user":
                currentUser = value
            case "port":
                currentPort = Int(value)
            default:
                break
            }
        }
        flush()
        return hosts
    }

    /// Resolve the effective hostname for an alias via `ssh -G`, which applies `Include`,
    /// `Match`, wildcards and defaults. Returns nil on failure. Runs a subprocess — call it
    /// off the main thread (or lazily on a user action), never while building the list.
    static func resolvedHostName(for alias: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "hostname" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Private

    /// Split `Keyword value` or `Keyword=value` (and `Keyword = value`) into a
    /// `(keyword, value)` pair, stripping surrounding quotes from the value.
    private static func splitDirective(_ line: String) -> (String, String) {
        guard let idx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line, "")
        }
        let keyword = String(line[line.startIndex..<idx])
        var value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("=") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return (keyword, stripQuotes(value))
    }

    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
