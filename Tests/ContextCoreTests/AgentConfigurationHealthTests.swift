import Foundation
import Testing
@testable import ContextCore

struct AgentConfigurationHealthTests {
    @Test func reportsMisplacedCodexKeysAndMissingEnabledMCPCommand() throws {
        let fixture = try Fixture()
        try fixture.write("""
        [otel]
        exporter = "none"
        approvals_reviewer = "user"
        personality = "pragmatic"

        [mcp_servers.spacefast]
        command = "sf"
        args = ["mcp", "proxy"]
        """)

        let report = AgentConfigurationAuditor.audit(configuration: .init(
            home: fixture.root,
            configURLs: [fixture.config],
            executableSearchPaths: [fixture.bin.path]
        ))

        #expect(report.issues.count == 3)
        #expect(report.warningCount == 2)
        #expect(report.errorCount == 1)
        #expect(report.issues.contains { $0.id.contains("approvals_reviewer") && $0.line == 3 })
        #expect(report.issues.contains { $0.id.contains("personality") && $0.line == 4 })
        #expect(report.issues.contains { $0.title == "MCP launcher not found" && $0.line == 7 })
    }

    @Test func acceptsTopLevelKeysAvailableCommandsAndDisabledServers() throws {
        let fixture = try Fixture()
        let executable = fixture.bin.appendingPathComponent("available")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fixture.write("""
        approvals_reviewer = "user"
        personality = "pragmatic"

        [otel]
        exporter = "none"

        [mcp_servers.healthy]
        command = "available"

        [mcp_servers.stale]
        command = "missing"
        enabled = false
        """)

        let report = AgentConfigurationAuditor.audit(configuration: .init(
            home: fixture.root,
            configURLs: [fixture.config],
            executableSearchPaths: [fixture.bin.path]
        ))

        #expect(report.issues.isEmpty)
    }

    @Test func ignoresCommentedAndCredentialShapedValues() throws {
        let fixture = try Fixture()
        try fixture.write("""
        [otel]
        # personality = "pragmatic"
        endpoint = "https://example.com/#fragment"

        [mcp_servers.remote]
        url = "https://example.com/mcp"
        bearer_token_env_var = "SECRET_TOKEN"
        """)

        let report = AgentConfigurationAuditor.audit(configuration: .init(
            home: fixture.root,
            configURLs: [fixture.config],
            executableSearchPaths: []
        ))

        #expect(report.issues.isEmpty)
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var config: URL { root.appendingPathComponent("config.toml") }
    var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    func write(_ body: String) throws {
        try body.write(to: config, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
