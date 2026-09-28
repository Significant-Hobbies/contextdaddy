import Foundation
import Testing
@testable import ContextCore

struct AgentSetupAuditTests {
    @Test func allAgentsHaveIsolatedChecksAndNoConfigValuesEscape() throws {
        let home = try fixture()
        let cases: [(AgentRuntime, String, String)] = [
            (.codex, ".codex/config.toml", "[mcp_servers.private_name]\ncommand = 'missing-executable'\nargs = ['secret-argument']"),
            (.claude, ".claude/settings.json", "{\"mcpServers\":{\"private_name\":{\"command\":\"missing-executable\",\"env\":{\"KEY\":\"secret-env\"}}}}"),
            (.cursor, ".cursor/mcp.json", "{\"mcpServers\":{\"private_name\":{\"command\":\"missing-executable\",\"args\":[\"secret-argument\"]}}}"),
            (.devin, ".config/devin/mcp_config.json", "{/* comment */\"mcpServers\":{\"private_name\":{\"command\":\"missing-executable\"}}}"),
            (.grok, ".grok/config.toml", "[mcp_servers.private_name]\ncommand = \"missing-executable\"\nurl_secret = \"secret-url\"")
        ]
        for (_, path, body) in cases { try write(home.appendingPathComponent(path), body) }
        let report = AgentSetupAudit.audit(home: home, executableSearchPaths: [])
        #expect(report.issues.count == 5)
        for runtime in AgentRuntime.allCases {
            let selected = report.forAgent(runtime)
            #expect(selected.issues.count == 1)
            #expect(selected.files.allSatisfy { $0.runtime == runtime })
            #expect(selected.scannedFiles.count == 1)
        }
        let brief = IssueBriefFormatter.configuration(report.issues)
        for value in ["secret-env", "secret-argument", "secret-url", "private_name", "missing-executable"] {
            #expect(!brief.contains(value))
        }
    }

    @Test func failedReadsAndSyntaxCannotClearPriorFindings() throws {
        let home = try fixture()
        let file = home.appendingPathComponent(".cursor/mcp.json")
        try write(file, "{\"mcpServers\":{\"test\":{\"command\":\"not-installed\"}}}")
        let initial = AgentSetupAudit.audit(home: home, executableSearchPaths: [])
        let baseline = ConfigurationIssueBaseline(issues: initial.issues)
        try write(file, "{\"secret-token\": invalid JSON}")
        let malformed = AgentSetupAudit.audit(home: home)
        #expect(malformed.forAgent(.cursor).issues.count == 1)
        #expect(!malformed.scannedFiles.contains(file.path))
        #expect(baseline.verify(against: malformed).unverified.count == 1)
        #expect(!IssueBriefFormatter.configuration(malformed.issues).contains("secret-token"))
        try write(file, "{\"mcpServers\":{}}")
        #expect(baseline.verify(against: AgentSetupAudit.audit(home: home)).cleared.count == 1)
        let oversized = AgentSetupAudit.audit(home: home, maximumBytes: 1)
        #expect(oversized.forAgent(.cursor).files.contains { $0.path == file.path && $0.status == .unverified })
    }

    @Test func commentsDisabledServersAndURLsDoNotProduceFalseFailures() throws {
        let home = try fixture()
        let file = home.appendingPathComponent(".config/devin/mcp_config.json")
        try write(file, #"""
        {
          // preserve URL slashes and escaped quotes
          "mcpServers": {
            "remote": { "url": "https://example.invalid/a//b", "headers": {"x": "a\"b"} },
            "disabled": { "command": "missing", "disabled": true },
            "relative": { "command": "./scripts/server" },
            "substituted": { "command": "${SERVER}" }
          } /* ending comment */
        }
        """#)
        let report = AgentSetupAudit.audit(home: home, executableSearchPaths: [])
        #expect(report.issues.isEmpty)
        #expect(report.scannedFiles.contains(file.path))
        try write(file, "{} /* unterminated")
        #expect(AgentSetupAudit.audit(home: home).issues.count == 1)
    }

    @Test func selectedProjectDoesNotScanSiblingAndLinksAreNotFollowed() throws {
        let home = try fixture()
        let selected = home.appendingPathComponent("selected")
        let sibling = home.appendingPathComponent("sibling")
        try write(selected.appendingPathComponent(".devin/config.json"), "{}")
        try write(sibling.appendingPathComponent(".devin/config.json"), "malformed")
        let source = home.appendingPathComponent("private-file")
        try write(source, "do not read")
        let link = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let report = AgentSetupAudit.audit(home: home, project: selected)
        #expect(report.issues.isEmpty)
        #expect(!report.files.contains { $0.path.contains("/sibling/") })
        #expect(report.forAgent(.grok).files.contains { $0.path == link.path && $0.status == .unverified })
        #expect(report.forAgent(.devin).scannedFiles == [selected.appendingPathComponent(".devin/config.json").path])
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-audit-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
