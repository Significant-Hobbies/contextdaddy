import Foundation
import Testing
@testable import ContextCore

struct AllAgentInvocationTests {
    @Test func previewApplyRescanAndRestoreForEveryAgent() async throws {
        let home = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("ContextDaddy-invocation-" + UUID().uuidString)
        let roots: [(AgentRuntime, String)] = [(.codex, ".codex"), (.claude, ".claude"), (.cursor, ".cursor"), (.devin, ".config/devin"), (.grok, ".grok")]
        let original = "---\nname: sample\ndescription: Example\n---\nPreserve instructions.\n"
        let manager = SkillLibraryManager(storage: home.appendingPathComponent("history"))
        for (runtime, root) in roots {
            let folder = home.appendingPathComponent(root + "/skills/sample")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let skill = folder.appendingPathComponent("SKILL.md")
            try original.write(to: skill, atomically: true, encoding: .utf8)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("support.bin"))
            let plan = try await manager.prepareInvocation(skill: skill, runtime: runtime, automatic: false)
            let receipt = try await manager.apply(plan.id)
            let report = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: []))
            let record = try #require(SkillPolicyResolver.resolve(report: report).records.first { $0.id == skill.resolvingSymlinksInPath().path })
            #expect(record.policy(for: runtime)?.mode == .manualOnly)
            #expect(record.policy(for: runtime)?.invocation == (runtime == .codex ? "$sample" : "/sample"))
            #expect(try Data(contentsOf: folder.appendingPathComponent("support.bin")) == Data([1, 2, 3]))
            try await manager.restore(receipt.id)
            #expect(try String(contentsOf: skill, encoding: .utf8) == original)
            let restored = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: []))
            #expect(SkillPolicyResolver.resolve(report: restored).records.first { $0.id == skill.resolvingSymlinksInPath().path }?.policy(for: runtime)?.mode == .automatic)
        }
    }

    @Test func devinTriggersRemainSeparateAndGrokHiddenMeansDisabled() throws {
        let home = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent(UUID().uuidString)
        for (root, body) in [
            (".config/devin", "triggers: [model]\ndisable-model-invocation: true"),
            (".grok", "user-invocable: false\ndisable-model-invocation: true")
        ] {
            let path = home.appendingPathComponent(root + "/skills/sample/SKILL.md")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: sample\n\(body)\n---\nTest".write(to: path, atomically: true, encoding: .utf8)
        }
        let report = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: []))
        let records = SkillPolicyResolver.resolve(report: report).records
        #expect(records.first { $0.id.contains("/devin/") }?.policy(for: .devin)?.mode == .modelOnly)
        #expect(records.first { $0.id.contains("/.grok/") }?.policy(for: .grok)?.mode == .disabled)
        let ambiguous = Data("---\ntriggers: [model]\n---\nContent".utf8)
        #expect(throws: SkillManagementError.self) { try SkillInvocationEditor.edit(files: ["SKILL.md": ambiguous], runtime: .devin, automatic: false) }
        let block = Data("---\ntriggers:\n  - user\n  - model\npermissions:\n  deny: [exec]\n---\nContent".utf8)
        let edited = try SkillInvocationEditor.edit(files: ["SKILL.md": block], runtime: .devin, automatic: false)
        #expect(edited.after.contains("triggers: [user]\npermissions:\n  deny: [exec]"))
    }
}
