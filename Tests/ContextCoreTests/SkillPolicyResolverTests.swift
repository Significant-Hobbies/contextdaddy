import Foundation
import Testing
@testable import ContextCore

struct SkillPolicyResolverTests {
    @Test func claudeFrontmatterDoesNotDisableCodexImplicitInvocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill = root.appendingPathComponent(".agents/skills/manual/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: manual\ndescription: Manual test\ndisable-model-invocation: true\n---\n".write(to: skill, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: [], additionalRoots: [root]))
        let record = try #require(SkillPolicyResolver.resolve(report: report).records.first)
        #expect(record.policy(for: .codex)?.mode == .automatic)
        #expect(record.policy(for: .codex)?.desiredMode == .manualOnly)
        #expect(record.needsReview)
        #expect(SkillOrganizationIndex.matching([record], runtime: .codex, invocation: .unverified, scope: nil, sort: .name, ascending: true, duplicateCounts: [:]).count == 1)
        #expect(record.policies.filter { !$0.isExposed }.allSatisfy { $0.mode == .unsupported })
        #expect(record.policy(for: .codex)?.explicit == false)
    }

    @Test func codexRuntimeOverrideIsSpecific() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skillRoot = root.appendingPathComponent(".agents/skills/example")
        try FileManager.default.createDirectory(at: skillRoot.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "---\nname: example\ndescription: Example\n---\n".write(to: skillRoot.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "policy:\n  allow_implicit_invocation: false\n".write(to: skillRoot.appendingPathComponent("agents/openai.yaml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: [], additionalRoots: [root]))
        let record = try #require(SkillPolicyResolver.resolve(report: report).records.first)
        #expect(record.policies.first { $0.runtime == .codex }?.mode == .manualOnly)
        #expect(record.policies.first { $0.runtime == .claude }?.mode == .unsupported)
    }

    @Test func readsFoldedDescriptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill = root.appendingPathComponent(".agents/skills/folded/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: folded\ndescription: >\n  First line.\n  Second line.\n---\n".write(to: skill, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: [], additionalRoots: [root]))
        let record = try #require(SkillPolicyResolver.resolve(report: report).records.first)
        #expect(record.description == "First line. Second line.")
    }

    @Test func flagsSameNameDefinitionsThatOverlapInOneRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("work")
        for skill in [
            root.appendingPathComponent(".codex/skills/shared-name/SKILL.md"),
            project.appendingPathComponent(".codex/skills/shared-name/SKILL.md"),
        ] {
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: shared-name\ndescription: Codex copy\n---\n".write(to: skill, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: [project]))
        let records = SkillPolicyResolver.resolve(report: report).records
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.definitionConflictCount == 2 })
        #expect(records.allSatisfy { $0.contentFingerprint != nil })
        #expect(Set(records.compactMap(\.contentFingerprint)).count == 1)
    }

    @Test func sameNameAcrossSeparateRuntimesIsNotAConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for provider in [".codex", ".claude"] {
            let skill = root.appendingPathComponent("\(provider)/skills/shared-name/SKILL.md")
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: shared-name\ndescription: \(provider) copy\n---\n".write(to: skill, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let records = SkillPolicyResolver.resolve(report: try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: []))).records
        #expect(records.count == 2)
        #expect(records.allSatisfy { !$0.hasDefinitionConflict })
    }

    @Test func installedPluginCacheDoesNotClaimActiveExposure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill = root.appendingPathComponent(".codex/plugins/cache/vendor/1.0/skills/cached/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: cached\ndescription: Cached only\n---\n".write(to: skill, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: []))
        let record = try #require(SkillPolicyResolver.resolve(report: report).records.first)
        let codex = try #require(record.policy(for: .codex))
        #expect(!codex.isExposed)
        #expect(codex.mode == .unsupported)
        #expect(codex.reason.contains("installed cache"))
    }

    @Test func reportsBrokenSkillLinksInCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skills = root.appendingPathComponent(".codex/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("missing"))
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try AIContextDiscovery.discover(configuration: .init(home: root, projectRoots: []))
        #expect(report.coverage.skippedLinks > 0)
        #expect(report.coverage.notes.contains { $0.contains("broken") })
    }

    @Test func governanceSummarySeparatesInvocationStatesForOneRuntime() {
        let records = [
            record("explicit-auto", codex: policy(.automatic, explicit: true)),
            record("default-auto", codex: policy(.automatic, explicit: false)),
            record("manual", codex: policy(.manualOnly, explicit: true)),
            record("model", codex: policy(.modelOnly, explicit: true)),
            record("disabled", codex: policy(.disabled, explicit: true)),
            record("hidden", codex: policy(.unsupported, explicit: true, exposed: false)),
            record("conflict", codex: policy(.automatic, explicit: true), conflicts: 2),
        ]

        let summary = SkillGovernanceSummary(records: records, runtime: .codex)
        #expect(summary.totalCount == 7)
        #expect(summary.exposedCount == 6)
        #expect(summary.automaticCount == 3)
        #expect(summary.defaultAutomaticCount == 1)
        #expect(summary.manualOnlyCount == 1)
        #expect(summary.modelOnlyCount == 1)
        #expect(summary.disabledCount == 1)
        #expect(summary.notExposedCount == 1)
        #expect(summary.reviewCount == 2)
    }

    @Test func sharingSummaryDistinguishesPortableAndIsolatedSkills() {
        let every = AgentRuntime.allCases.map { policy(.automatic, runtime: $0, explicit: false) }
        let two = [policy(.automatic, runtime: .codex, explicit: false), policy(.manualOnly, runtime: .claude, explicit: true)]
        let records = [
            record("every", policies: every),
            record("two", policies: two),
            record("one", policies: [policy(.automatic, runtime: .codex, explicit: false)]),
            record("conflict", policies: [policy(.automatic, runtime: .codex, explicit: true)], conflicts: 3),
        ]

        let summary = SkillSharingSummary(records: records)
        #expect(summary.totalCount == 4)
        #expect(summary.everyRuntimeCount == 1)
        #expect(summary.multipleRuntimeCount == 1)
        #expect(summary.singleRuntimeCount == 2)
        #expect(summary.definitionConflictCount == 1)
    }

    private func policy(
        _ mode: InvocationMode,
        runtime: AgentRuntime = .codex,
        explicit: Bool,
        exposed: Bool = true
    ) -> SkillRuntimePolicy {
        SkillRuntimePolicy(runtime: runtime, mode: mode, explicit: explicit, reason: "Fixture", invocation: "$fixture", isExposed: exposed)
    }

    private func record(
        _ name: String,
        codex: SkillRuntimePolicy? = nil,
        policies: [SkillRuntimePolicy]? = nil,
        conflicts: Int = 1
    ) -> SkillRecord {
        var byRuntime = Dictionary(uniqueKeysWithValues: (policies ?? []).map { ($0.runtime, $0) })
        if let codex { byRuntime[.codex] = codex }
        let complete = AgentRuntime.allCases.map { runtime in
            byRuntime[runtime] ?? policy(.unsupported, runtime: runtime, explicit: true, exposed: false)
        }
        return SkillRecord(
            id: "/skills/\(name)/SKILL.md",
            name: name,
            description: "Fixture",
            logicalBytes: 1,
            modified: .distantPast,
            exposures: [],
            policies: complete,
            definitionConflictCount: conflicts
        )
    }
}
