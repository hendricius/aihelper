import XCTest
@testable import AIHelper

final class SSHConfigParserTests: XCTestCase {

    // Fixture uses RFC 5737 documentation IPs (192.0.2.0/24) — not real hosts.
    private let fixture = """
    # a comment

    Host web-1
        HostName 192.0.2.10
        User deploy

    Host dev-vm-1
        HostName 192.0.2.11
        User dev
        Port 2222

    Host dev-vm-*

    Host alpha beta
        HostName 192.0.2.12
        User shared

    Host gamma delta          # Telegram: Gamma  (@some_bot)
        HostName 192.0.2.14

    Host weirdsyntax
        HostName=192.0.2.13

    Match host web-1
        User shouldNotApply
    """

    func testParsesBasicHost() {
        let hosts = SSHConfigParser.parse(fixture)
        let web = hosts.first { $0.alias == "web-1" }
        XCTAssertNotNil(web)
        XCTAssertEqual(web?.hostName, "192.0.2.10")
        XCTAssertEqual(web?.user, "deploy")
        XCTAssertNil(web?.port)
    }

    func testParsesCustomPort() {
        let hosts = SSHConfigParser.parse(fixture)
        let vm = hosts.first { $0.alias == "dev-vm-1" }
        XCTAssertEqual(vm?.port, 2222)
    }

    func testSkipsWildcardAliases() {
        let hosts = SSHConfigParser.parse(fixture)
        XCTAssertFalse(hosts.contains { $0.alias.contains("*") })
        XCTAssertFalse(hosts.contains { $0.alias.contains("?") })
    }

    func testUsesFirstAliasOnly() {
        // `Host alpha beta` should list once, under the primary (first) alias.
        let hosts = SSHConfigParser.parse(fixture)
        let alpha = hosts.first { $0.alias == "alpha" }
        XCTAssertEqual(alpha?.hostName, "192.0.2.12")
        XCTAssertEqual(alpha?.user, "shared")
        XCTAssertFalse(hosts.contains { $0.alias == "beta" })
    }

    func testStripsInlineComments() {
        // An inline `# Telegram: ...` comment must not become extra host entries, and only
        // the first alias is listed.
        let hosts = SSHConfigParser.parse(fixture)
        let gamma = hosts.first { $0.alias == "gamma" }
        XCTAssertEqual(gamma?.hostName, "192.0.2.14")
        XCTAssertFalse(hosts.contains { $0.alias == "delta" })
        XCTAssertFalse(hosts.contains { $0.alias.hasPrefix("#") })
        XCTAssertFalse(hosts.contains { $0.alias == "Telegram:" })
        XCTAssertFalse(hosts.contains { $0.alias.contains("bot") })
    }

    func testKeyEqualsValueSyntax() {
        let hosts = SSHConfigParser.parse(fixture)
        let weird = hosts.first { $0.alias == "weirdsyntax" }
        XCTAssertEqual(weird?.hostName, "192.0.2.13")
    }

    func testMatchBlockEndsHostScope() {
        // The `Match host web-1` block must NOT retroactively change the parsed `web-1` host.
        let hosts = SSHConfigParser.parse(fixture)
        let web = hosts.first { $0.alias == "web-1" }
        XCTAssertEqual(web?.user, "deploy")
    }

    func testMissingHostNameLeavesEmptyButKeepsAlias() {
        let config = """
        Host only-alias
            User someone
        """
        let hosts = SSHConfigParser.parse(config)
        let host = hosts.first { $0.alias == "only-alias" }
        XCTAssertNotNil(host)
        XCTAssertEqual(host?.hostName, "")
        XCTAssertEqual(host?.displayHost, "only-alias") // falls back to alias
    }

    func testEmptyOrMissingConfigReturnsEmpty() {
        XCTAssertTrue(SSHConfigParser.parse("").isEmpty)
        let missing = URL(fileURLWithPath: "/nonexistent/path/to/ssh/config")
        XCTAssertTrue(SSHConfigParser.loadHosts(from: missing).isEmpty)
    }

    func testSSHCommandFormat() {
        let host = SSHHost(alias: "web-1", hostName: "192.0.2.10", user: "deploy", port: nil)
        XCTAssertEqual(host.sshCommand, "ssh web-1")
    }
}
