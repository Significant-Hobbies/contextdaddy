import Foundation
import Testing
@testable import ContextCore

struct SkillPrecedenceTests {
    @Test func claudePersonalShadowsProjectIndependentOfInputOrderAndPreservesAliases() throws {
        let home = try fixture()
        let personal = try skill(home, ".claude/skills/shared")
        let project = try skill(home, "work/.claude/skills/shared")
        let alias = home.appendingPathComponent("work/.claude/skills/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: personal.deletingLastPathComponent())
        let namedAlias = home.appendingPathComponent("alias-work/.claude/skills/shared")
        try FileManager.default.createDirectory(at: namedAlias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: namedAlias, withDestinationURL: personal.deletingLastPathComponent())
        let report = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [home.appendingPathComponent("work"), home.appendingPathComponent("alias-work")]))
        let forward = SkillPolicyResolver.resolve(report: report)
        let reversed = SkillPolicyResolver.resolve(report: AIContextDiscoveryReport(items: report.items.reversed(), folderRankings: report.folderRankings, coverage: report.coverage, elapsed: report.elapsed))
        let winner = try #require(forward.records.first { $0.id == personal.path })
        let loser = try #require(forward.records.first { $0.id == project.path })
        // An alias with a different directory name is deliberately unqualified.
        #expect(winner.exposures.count == 3)
        #expect(winner.policy(for: .claude)?.precedence?.state == .unverified)
        #expect(loser.policy(for: .claude)?.mode == .unverified)
        #expect(forward.records == reversed.records)

        let directItems = report.items.filter { !$0.path.contains("/alias/") }
        let direct = SkillPolicyResolver.resolve(report: AIContextDiscoveryReport(items: directItems, folderRankings: [], coverage: report.coverage, elapsed: 0))
        let preferred = try #require(direct.records.first { $0.id == personal.path }?.policy(for: .claude))
        let shadowed = try #require(direct.records.first { $0.id == project.path }?.policy(for: .claude))
        #expect(preferred.precedence?.state == .preferred)
        #expect(direct.records.first { $0.id == personal.path }?.exposures.count == 2)
        #expect(shadowed.precedence?.state == .shadowed)
        #expect(shadowed.precedence?.preferredDefinitionID == personal.path)
        #expect(shadowed.mode == .unverified)
        #expect(shadowed.evidence == .unavailable)
        #expect(shadowed.reason.contains("Shadowed"))
        #expect(shadowed.isExposed) // Physical route remains discoverable; not an active winner.
        #expect(direct.governance(for: .claude).automaticCount == 1)
    }

    @Test func codexDuplicatesCoexistAndUnknownVendorNeverGetsAnInventedWinner() throws {
        let home = try fixture()
        _ = try skill(home, ".agents/skills/shared")
        _ = try skill(home, "work/.agents/skills/shared")
        _ = try skill(home, ".cursor/skills/shared")
        _ = try skill(home, "work/.cursor/skills/shared")
        let records = SkillPolicyResolver.resolve(report: try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [home.appendingPathComponent("work")]))).records
        let codex = records.compactMap { $0.policy(for: .codex) }.filter(\.isExposed)
        let cursor = records.compactMap { $0.policy(for: .cursor) }.filter(\.isExposed)
        #expect(codex.count == 2)
        #expect(codex.allSatisfy { $0.precedence?.state == .coexisting && $0.precedence?.preferredDefinitionID == nil })
        #expect(cursor.count == 2)
        #expect(cursor.allSatisfy { $0.mode == .unverified && $0.precedence?.preferredDefinitionID == nil })
    }

    @Test func projectOnlyCollisionsRemainUnverifiedAndLegacyPoliciesStillDecode() throws {
        let home = try fixture()
        _ = try skill(home, "one/.claude/skills/shared")
        _ = try skill(home, "two/.claude/skills/shared")
        let records = SkillPolicyResolver.resolve(report: try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [home.appendingPathComponent("one"), home.appendingPathComponent("two")]))).records
        #expect(records.allSatisfy { $0.policy(for: .claude)?.precedence?.state == .unverified })
        let old = Data(#"{"runtime":"Claude","mode":"Manual only","explicit":true,"reason":"Fixture","invocation":"/shared","isExposed":true}"#.utf8)
        let policy = try JSONDecoder().decode(SkillRuntimePolicy.self, from: old)
        #expect(policy.precedence == nil)
        #expect(policy.mode == .manualOnly)
    }

    @Test func caseOnlyNameCollisionsRemainUnverifiedIndependentOfInputOrder() throws {
        let home = try fixture()
        let personal = try skill(home, ".claude/skills/Shared", name: "Shared")
        let project = try skill(home, "work/.claude/skills/shared", name: "shared")
        let report = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [home.appendingPathComponent("work")]))
        let forward = SkillPolicyResolver.resolve(report: report)
        let reversed = SkillPolicyResolver.resolve(report: AIContextDiscoveryReport(items: report.items.reversed(), folderRankings: report.folderRankings, coverage: report.coverage, elapsed: report.elapsed))
        let records = [try #require(forward.records.first { $0.id == personal.path }), try #require(forward.records.first { $0.id == project.path })]
        #expect(records.allSatisfy { $0.definitionConflictCount == 2 })
        #expect(records.allSatisfy { $0.policy(for: .claude)?.mode == .unverified })
        #expect(records.allSatisfy { $0.policy(for: .claude)?.precedence?.state == .unverified })
        #expect(records.allSatisfy { $0.policy(for: .claude)?.precedence?.preferredDefinitionID == nil })
        #expect(forward.records == reversed.records)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-precedence-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func skill(_ root: URL, _ relative: String, name: String = "shared") throws -> URL {
        let file = root.appendingPathComponent(relative + "/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Synthetic precedence fixture\n---\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
