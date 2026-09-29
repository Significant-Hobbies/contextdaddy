import CryptoKit
import Foundation
import Testing
@testable import ContextCore

struct PluginInventoryTests {
    @Test func groupsByOwnerAndMarketplaceAndSeparatesReferencesFromActivation() throws {
        let home = try fixture()
        let old = home.appendingPathComponent(".claude/plugins/cache/official/design/old")
        let current = home.appendingPathComponent(".claude/plugins/cache/official/design/new")
        let codex = home.appendingPathComponent(".codex/plugins/cache/official/design/new")
        let text = "---\nname: visual\n---\nInstructions"
        for root in [old, current, codex] { try write(root.appendingPathComponent("skills/visual/SKILL.md"), text) }
        try write(current.appendingPathComponent(".claude-plugin/plugin.json"), #"{"name":"design","description":"Design interfaces"}"#)
        try write(home.appendingPathComponent(".claude/plugins/installed_plugins.json"), """
        {"version":2,"plugins":{"design@official":[{"scope":"user","installPath":"\(current.path)","version":"new"}]}}
        """)
        try write(home.appendingPathComponent(".claude/settings.json"), #"{"enabledPlugins":{"design@official":false},"env":{"SECRET":"never-display"}}"#)
        try write(home.appendingPathComponent(".codex/config.toml"), "[plugins.\"design@official\"]\nenabled = true\n")
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let local = SkillRecord(id: home.appendingPathComponent(".agents/skills/visual/SKILL.md").path, name: "visual", description: "", logicalBytes: 10, modified: Date(), exposures: [], policies: [], contentFingerprint: hash)
        let result = try PluginInventory.scan(home: home, localSkills: [local])
        #expect(result.entries.count == 2)
        #expect(result.versionCount == 3)
        let claude = try #require(result.entries.first { $0.owner == .claude })
        #expect(claude.registryVerified)
        #expect(claude.unreferencedVersions.map(\.version) == ["old"])
        #expect(claude.preferences.map(\.enabled) == [false])
        #expect(claude.skillNames == ["visual"])
        #expect(claude.localMatches == [local.id])
        #expect(claude.bytes > 0 && claude.sizeComplete)
        #expect(!claude.managementBrief.contains("never-display"))
        let c = try #require(result.entries.first { $0.owner == .codex })
        #expect(!c.registryVerified && c.unreferencedVersions.isEmpty)
        #expect(c.preferences.map(\.enabled) == [true])
    }

    @Test func malformedRegistryNeverEstablishesObsoleteVersionsAndToolsRemainVisible() throws {
        let home = try fixture()
        try write(home.appendingPathComponent(".claude/plugins/cache/official/tools/v1/.mcp.json"), "{}")
        try write(home.appendingPathComponent(".claude/plugins/installed_plugins.json"), #"{"version":2,"plugins":{"tools@official":[{"scope":"user"}]}}"#)
        let scan = try PluginInventory.scan(home: home)
        let entry = try #require(scan.entries.first)
        #expect(entry.skillNames.isEmpty)
        #expect(entry.versions[0].components == ["MCP"])
        #expect(!entry.registryVerified)
        #expect(entry.unreferencedVersions.isEmpty)
        #expect(scan.notes.contains { $0.contains("registry is unavailable") })
    }

    @Test func settingsAreScopedAndNumericValuesAreNotBooleanEvidence() throws {
        let home = try fixture()
        let project = home.appendingPathComponent("projects/selected")
        try write(home.appendingPathComponent(".claude/plugins/cache/official/tool/v1/.mcp.json"), "{}")
        try write(home.appendingPathComponent(".claude/settings.json"), #"{"enabledPlugins":{"tool@official":1}}"#)
        try write(project.appendingPathComponent(".claude/settings.json"), #"{"enabledPlugins":{"tool@official":true}}"#)
        try write(project.appendingPathComponent(".claude/settings.local.json"), #"{"enabledPlugins":{"tool@official":false}}"#)
        try write(home.appendingPathComponent("projects/sibling/.claude/settings.json"), #"{"enabledPlugins":{"tool@official":true}}"#)
        let scan = try PluginInventory.scan(home: home, folder: project)
        let entry = try #require(scan.entries.first)
        #expect(entry.preferences.count == 2)
        #expect(entry.settingLabel == "Mixed settings")
        #expect(entry.preferences.allSatisfy { $0.path.hasPrefix(project.path + "/") })
        #expect(!scan.checkedSources.contains { $0.contains("sibling") })
    }

    @Test func boundsAndLinksAreNotMisrepresentedAsCompleteSizes() throws {
        let home = try fixture()
        let version = home.appendingPathComponent(".claude/plugins/cache/official/tool/v1")
        try write(version.appendingPathComponent("skills/tool/SKILL.md"), "hello")
        let outside = home.appendingPathComponent("outside")
        try write(outside.appendingPathComponent("private.txt"), "private content")
        try FileManager.default.createSymbolicLink(at: version.appendingPathComponent("linked"), withDestinationURL: outside)
        let scan = try PluginInventory.scan(home: home)
        let entry = try #require(scan.entries.first)
        #expect(!entry.sizeComplete)
        #expect(entry.bytes == 5)
        let bounded = try PluginInventory.scan(home: home, maximumEntries: 1)
        #expect(bounded.notes.contains { $0.contains("limit") })
        let root = home.appendingPathComponent(".codex/plugins/cache")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        #expect(try PluginInventory.scan(home: home).entries.allSatisfy { $0.owner == .claude })
    }

    @Test func ambiguousCodexDeclarationsAreNotActivationEvidence() {
        #expect(PluginInventory.codexPreferences("[plugins.\"x@official\"]\nenabled = false # note")["x@official"] == false)
        #expect(PluginInventory.codexPreferences("[plugins.\"x@official\"]\nenabled = true\nenabled = false").isEmpty)
        #expect(PluginInventory.codexPreferences("[plugins.\"x@official\"]\nenabled = true\n[plugins.\"x@official\"]\nenabled = true").isEmpty)
        #expect(PluginInventory.codexPreferences("note = \"\"\"\n[plugins.\"x@official\"]\nenabled = true\n\"\"\"").isEmpty)
    }

    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-plugins-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
