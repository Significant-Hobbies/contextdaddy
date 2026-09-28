import Foundation
import Testing
@testable import ContextCore

struct SkillOrganizationTests {
    private let text = "---\nname: example\ndescription: Test skill\n---\nUse references/guide.md.\n"

    @Test func movePreservesLinksAndRejectsStaleUndo() async throws {
        let f = try OrganizationFixture()
        let source = try f.skill("first/example", text)
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareMove(skill: source, parent: f.root.appendingPathComponent("shared"))
        #expect(FileManager.default.fileExists(atPath: source.path))
        let receipt = try await manager.apply(plan.id)
        #expect(try String(contentsOf: alias.appendingPathComponent("SKILL.md"), encoding: .utf8) == text)
        let moved = URL(fileURLWithPath: receipt.destination).appendingPathComponent("SKILL.md")
        try (text + "New work").write(to: moved, atomically: true, encoding: .utf8)
        await #expect(throws: SkillManagementError.self) { try await manager.restore(receipt.id) }
        try text.write(to: moved, atomically: true, encoding: .utf8)
        try await manager.restore(receipt.id)
        #expect(try source.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try String(contentsOf: alias.appendingPathComponent("SKILL.md"), encoding: .utf8) == text)
    }

    @Test func consolidationChecksSupportFilesPermissionsAndStaleCanonical() async throws {
        let f = try OrganizationFixture()
        let source = try f.skill("shared/example", text), copy = try f.skill("agent/example", text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let helper = source.deletingLastPathComponent().appendingPathComponent("run.sh")
        try Data("echo example".utf8).write(to: helper)
        await #expect(throws: SkillManagementError.self) { try await manager.prepareConsolidation(duplicate: copy, canonical: source) }
        let other = copy.deletingLastPathComponent().appendingPathComponent("run.sh")
        try FileManager.default.copyItem(at: helper, to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        await #expect(throws: SkillManagementError.self) { try await manager.prepareConsolidation(duplicate: copy, canonical: source) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
        let stale = try await manager.prepareConsolidation(duplicate: copy, canonical: source)
        try (text + "New work").write(to: source, atomically: true, encoding: .utf8)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(stale.id) }
        #expect(try copy.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        try text.write(to: source, atomically: true, encoding: .utf8)
        let plan = try await manager.prepareConsolidation(duplicate: copy, canonical: source)
        let receipt = try await manager.apply(plan.id)
        #expect(try copy.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try String(contentsOf: copy, encoding: .utf8) == text)
        try (text + "New work").write(to: source, atomically: true, encoding: .utf8)
        await #expect(throws: SkillManagementError.self) { try await manager.restore(receipt.id) }
        try text.write(to: source, atomically: true, encoding: .utf8)
        try await manager.restore(receipt.id)
        #expect(try copy.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try String(contentsOf: copy, encoding: .utf8) == text)
    }

    @Test func moveRejectsOccupiedNestedManagedAndStaleSources() async throws {
        let f = try OrganizationFixture()
        let source = try f.skill("first/example", text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        await #expect(throws: SkillManagementError.self) { try await manager.prepareMove(skill: source, parent: source.deletingLastPathComponent()) }
        await #expect(throws: SkillManagementError.self) { try await manager.prepareMove(skill: source, parent: f.root.appendingPathComponent("plugins/cache")) }
        let plan = try await manager.prepareMove(skill: source, parent: f.root.appendingPathComponent("shared"))
        _ = try f.skill("shared/example", text)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(plan.id) }
        let changed = try await manager.prepareMove(skill: source, parent: f.root.appendingPathComponent("other"))
        try (text + "New").write(to: source, atomically: true, encoding: .utf8)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(changed.id) }
    }

    @Test func consolidationPreservesIndependentRepositoriesAndWorktrees() async throws {
        let f = try OrganizationFixture()
        let source = try f.skill("repository/.agents/skills/example", text)
        let copy = try f.skill("worktree/.agents/skills/example", text)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("repository/.git"), withIntermediateDirectories: true)
        try Data("gitdir: unused-test-path".utf8).write(to: f.root.appendingPathComponent("worktree/.git"))
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        await #expect(throws: SkillManagementError.self) {
            try await manager.prepareConsolidation(duplicate: copy, canonical: source)
        }
        let global = try f.skill("global/example", text)
        // A local agent route may use a repository-owned source without changing the repository.
        let plan = try await manager.prepareConsolidation(duplicate: global, canonical: source)
        let receipt = try await manager.apply(plan.id)
        #expect(try String(contentsOf: global, encoding: .utf8) == text)
        try await manager.restore(receipt.id)
        #expect(try global.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        // The reverse direction would make the repository depend on a machine-local folder.
        await #expect(throws: SkillManagementError.self) {
            try await manager.prepareConsolidation(duplicate: source, canonical: global)
        }
    }

    @Test func consolidationRechecksRepositoryBoundaryAtApply() async throws {
        let f = try OrganizationFixture()
        let source = try f.skill("shared/example", text), copy = try f.skill("agent/example", text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareConsolidation(duplicate: copy, canonical: source)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("agent/.git"), withIntermediateDirectories: true)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(plan.id) }
        #expect(try copy.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try String(contentsOf: copy, encoding: .utf8) == text)
    }

    @Test func invocationPreservesSupportFilesAndHasRecoverableAgentPolicy() async throws {
        let f = try OrganizationFixture(); let skill = try f.skill("example", text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let helper = skill.deletingLastPathComponent().appendingPathComponent("helper.sh")
        try Data("echo fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let codex = try await manager.prepareInvocation(skill: skill, runtime: .codex, automatic: false)
        let receipt = try await manager.apply(codex.id)
        let policy = skill.deletingLastPathComponent().appendingPathComponent("agents/openai.yaml")
        #expect(try String(contentsOf: policy, encoding: .utf8).contains("allow_implicit_invocation: false"))
        #expect(try String(contentsOf: skill, encoding: .utf8) == text)
        #expect((try FileManager.default.attributesOfItem(atPath: helper.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        try await manager.restore(receipt.id)
        #expect(!FileManager.default.fileExists(atPath: policy.path))
        let claude = try await manager.prepareInvocation(skill: skill, runtime: .claude, automatic: false)
        #expect(claude.detail.contains("Claude, Cursor and Grok"))
        let updated = try await manager.apply(claude.id)
        #expect(try String(contentsOf: skill, encoding: .utf8).contains("disable-model-invocation: true"))
        try await manager.restore(updated.id)
        #expect(try String(contentsOf: skill, encoding: .utf8) == text)
    }

    @Test func policyEditorRefusesAmbiguousMapsAndUnsupportedAgents() throws {
        let files = ["SKILL.md": Data(text.utf8), "agents/openai.yaml": Data("policy: {allow_implicit_invocation: true}\n".utf8)]
        #expect(throws: SkillManagementError.self) { try SkillInvocationEditor.edit(files: files, runtime: .codex, automatic: false) }
        #expect(try SkillInvocationEditor.edit(files: files, runtime: .devin, automatic: false).after.contains("triggers: [user]"))
        let original = "interface:\n  display_name: Example\npolicy:\n  allow_implicit_invocation: true\n"
        let result = try SkillInvocationEditor.edit(files: ["agents/openai.yaml": Data(original.utf8)], runtime: .codex, automatic: false)
        #expect(result.after == original.replacingOccurrences(of: "invocation: true", with: "invocation: false"))
        let hidden = text.replacingOccurrences(of: "name: example", with: "name: example\nuser-invocable: false")
        #expect(throws: SkillManagementError.self) { try SkillInvocationEditor.edit(files: ["SKILL.md": Data(hidden.utf8)], runtime: .claude, automatic: false) }
    }

    @Test func policyApplyAndRecoveryProtectPermissionsAndEmptyFolders() async throws {
        let f = try OrganizationFixture(); let skill = try f.skill("example", text)
        let folder = skill.deletingLastPathComponent()
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let originalEmpty = folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: originalEmpty, withIntermediateDirectories: true)
        let stale = try await manager.prepareInvocation(skill: skill, runtime: .codex, automatic: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: skill.path)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(stale.id) }
        let fresh = try await manager.prepareInvocation(skill: skill, runtime: .codex, automatic: false)
        let receipt = try await manager.apply(fresh.id)
        #expect(FileManager.default.fileExists(atPath: originalEmpty.path))
        let newEmpty = folder.appendingPathComponent("new-work")
        try FileManager.default.createDirectory(at: newEmpty, withIntermediateDirectories: true)
        await #expect(throws: SkillManagementError.self) { try await manager.restore(receipt.id) }
        #expect(FileManager.default.fileExists(atPath: newEmpty.path))
    }

    @Test func bulkPreviewsDoNotExpireAtTwentyItems() async throws {
        let f = try OrganizationFixture(); let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        var plans: [SkillChangePlan] = []
        for index in 0..<25 {
            let skill = try f.skill("first/skill-\(index)", text)
            plans.append(try await manager.prepareMove(skill: skill, parent: f.root.appendingPathComponent("shared")))
        }
        for plan in plans { #expect(try await manager.apply(plan.id).completed) }
        #expect(try await manager.history().count == 25)
    }

    @Test func oldReceiptsDecodeAndMixedPoliciesStayDistinct() throws {
        let data = Data("{\"id\":\"\(UUID())\",\"title\":\"Edit\",\"destination\":\"/tmp/example\",\"date\":0,\"kind\":\"edit\",\"restored\":false,\"completed\":true}".utf8)
        #expect(try JSONDecoder().decode(SkillChangeReceipt.self, from: data).sourcePath == nil)
        let mixed = SkillRecord(id: "/tmp/example/SKILL.md", name: "example", description: "", logicalBytes: 1, modified: Date(), exposures: [], policies: [
            .init(runtime: .codex, mode: .manualOnly, explicit: true, reason: "Policy", invocation: "$example"),
            .init(runtime: .claude, mode: .automatic, explicit: true, reason: "Policy", invocation: "/example")
        ])
        #expect(SkillOrganizationIndex.matching([mixed], runtime: nil, invocation: .unsupported, scope: nil, sort: .name, ascending: true, duplicateCounts: [:]).isEmpty)
        #expect(SkillOrganizationIndex.invocation(mixed, runtime: nil) == "Mixed · per agent")
        #expect(SkillOrganizationIndex.matching([mixed], runtime: .codex, invocation: .automatic, scope: nil, sort: .name, ascending: true, duplicateCounts: [:]).isEmpty)
        #expect(SkillOrganizationIndex.matching([mixed], runtime: nil, invocation: .automatic, scope: nil, sort: .name, ascending: true, duplicateCounts: [:]).count == 1)
    }
}

private final class OrganizationFixture {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("skill-organization-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func skill(_ path: String, _ text: String) throws -> URL {
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("SKILL.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
