import Foundation
import Testing
@testable import ContextCore

struct PluginActionTests {
    @Test func ownerActionIsScopedPreviewedAndRecordedWithoutRawOutput() async throws {
        let home = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // An isolated fake owner CLI records argv. It never touches real agent configuration.
        try write(".local/bin/claude", "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(home.path)/arguments.txt'\nprintf 'private output must not appear in receipt'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent(".local/bin/claude").path)
        let cache = home.appendingPathComponent(".claude/plugins/cache/official/demo/v1").path
        try write(".claude/plugins/cache/official/demo/v1/.claude-plugin/plugin.json", "{\"description\":\"Example\"}")
        try write(".claude/plugins/installed_plugins.json", "{\"version\":2,\"plugins\":{\"demo@official\":[{\"scope\":\"user\",\"installPath\":\"\(cache)\"}]}}")
        let entry = try #require(try PluginInventory.scan(home: home).entries.first)
        let manager = PluginActionManager(home: home, storage: home.appendingPathComponent("history"))
        let plan = try await manager.prepare(entry: entry, action: .disable, registration: entry.registrations[0])
        #expect(plan.arguments == ["plugin", "disable", "demo@official", "--scope", "user", "--json"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("arguments.txt").path))
        let receipt = try await manager.apply(plan.id)
        #expect(receipt.status == "Owner command completed · rescan required")
        #expect(!receipt.status.contains("private output"))
        #expect(try String(contentsOf: home.appendingPathComponent("arguments.txt"), encoding: .utf8).contains("disable\ndemo@official\n--scope\nuser"))
        try await manager.recordVerification(receipt.id, verified: false)
        #expect(try await manager.history().first?.status.contains("not verified") == true)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(plan.id) }
        let stale = try await manager.prepare(entry: entry, action: .uninstall, registration: entry.registrations[0])
        #expect(stale.arguments.contains("--keep-data"))
        try write(".claude/settings.json", "{\"enabledPlugins\":{\"demo@official\":false}}")
        await #expect(throws: SkillManagementError.self) { try await manager.apply(stale.id) }
    }
}
