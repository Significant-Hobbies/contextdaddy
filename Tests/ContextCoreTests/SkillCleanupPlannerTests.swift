import Foundation
import Testing
@testable import ContextCore

struct SkillCleanupPlannerTests {
    @Test func slowDirectoryReadReturnsWithoutWaitingForFilesystem() throws {
        let started = Date()
        #expect(throws: SkillManagementError.self) {
            try BoundedDirectoryReader.children(URL(fileURLWithPath: "/unused"), timeout: 0.02) { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return []
            }
        }
        #expect(Date().timeIntervalSince(started) < 0.25)
        let expected = URL(fileURLWithPath: "/healthy/SKILL.md")
        #expect(try BoundedDirectoryReader.children(URL(fileURLWithPath: "/healthy")) { _ in [expected] } == [expected])
    }

    @Test func differentVersionsInSiblingProjectsAreNotPresentedAsConflicts() async throws {
        let f = try CleanupFixture()
        func record(_ project: String, fingerprint: String) throws -> SkillRecord {
            let path = try f.skill("home/\(project)/.codex/skills/example").path
            return SkillRecord(id: path, name: "example", description: "Example", logicalBytes: 100, modified: Date(),
                exposures: [.init(logicalPath: path, resolvedPath: path, source: "Project", scope: .project, provider: .codex, applicability: .conditional)],
                policies: [.init(runtime: .codex, mode: .automatic, explicit: false, reason: "Discovered", invocation: "$example")], contentFingerprint: fingerprint)
        }
        let a = try record("a", fingerprint: "one"), b = try record("b", fingerprint: "two")
        let assessment = await SkillCleanupPlanner.assess(records: [a, b], manager: SkillLibraryManager(storage: f.root.appendingPathComponent("history")))
        #expect(assessment.recommendations.count == 1)
        #expect(assessment.recommendations.first?.category == .independent)
        #expect(assessment.readyPlans.isEmpty)
    }
    @Test func folderContextExcludesSiblingDescendantAndCacheAndDeduplicatesAliases() throws {
        let f = try CleanupFixture()
        let global = try f.skill("home/.agents/skills/shared")
        let parent = try f.skill("home/work/.claude/skills/parent")
        let local = try f.skill("home/work/app/.codex/skills/local")
        _ = try f.skill("home/work/sibling/.claude/skills/unrelated")
        _ = try f.skill("home/work/app/child/.claude/skills/descendant")
        _ = try f.skill("home/.codex/plugins/cache/test/1/skills/cached")
        let alias = f.root.appendingPathComponent("home/.codex/skills/shared")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: global.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("home/work/app/.git"), withIntermediateDirectories: true)
        let directory = f.root.appendingPathComponent("home/work/app")
        let report = try AIContextDiscovery.discoverFolder(directory, home: f.root.appendingPathComponent("home"))
        let context = SkillFolderContext.resolve(report: report, directory: directory)
        let codex = try #require(context.agents.first { $0.runtime == .codex })
        let claude = try #require(context.agents.first { $0.runtime == .claude })
        #expect(Set(codex.records.map(\.id)) == [global.resolvingSymlinksInPath().path, local.resolvingSymlinksInPath().path])
        #expect(Set(claude.records.map(\.id)) == [parent.resolvingSymlinksInPath().path])
        #expect(report.items.allSatisfy { !$0.path.contains("/sibling/") && !$0.path.contains("/child/") && !$0.path.contains("/plugins/cache/") })
        #expect(context.agents.count == AgentRuntime.allCases.count)
        #expect(codex.globalCount == 1)
    }

    @Test func scopedPoliciesDoNotLeakFromOtherProjects() throws {
        let f = try CleanupFixture()
        let source = try f.skill("home/a/.claude/skills/shared")
        let alias = f.root.appendingPathComponent("home/b/.codex/skills/shared")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source.deletingLastPathComponent())
        let report = try AIContextDiscovery.discover(configuration: .init(home: f.root.appendingPathComponent("home"), projectRoots: [f.root.appendingPathComponent("home")]))
        let context = SkillFolderContext.resolve(report: report, directory: f.root.appendingPathComponent("home/a"))
        let record = try #require(context.records.first { $0.id == source.resolvingSymlinksInPath().path })
        #expect(record.policy(for: .claude)?.isExposed == true)
        #expect(record.policy(for: .codex)?.isExposed == false)
    }

    @Test func folderContextRetainsGlobalAndProjectAliasesForRescoping() async throws {
        let f = try CleanupFixture()
        let source = try f.skill("home/app/.agents/skills/example")
        let global = f.root.appendingPathComponent("home/.agents/skills/example")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: global, withDestinationURL: source.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("home/app/.git"), withIntermediateDirectories: true)
        let folder = f.root.appendingPathComponent("home/app")
        let report = try AIContextDiscovery.discoverFolder(folder, home: f.root.appendingPathComponent("home"))
        let context = SkillFolderContext.resolve(report: report, directory: folder)
        let codex = try #require(context.agents.first { $0.runtime == .codex })
        #expect(codex.records.count == 1)
        let record = try #require(codex.records.first)
        #expect(record.exposures.count == 2)
        #expect(Set(record.exposures.map(\.scope)) == [.global, .project])
        let assessment = await SkillCleanupPlanner.assess(records: context.records, manager: SkillLibraryManager(storage: f.root.appendingPathComponent("history")))
        #expect(assessment.recommendations.contains { $0.action == .scope })
    }

    @Test func verifiedRecommendationsApplyAndRestoreWithoutLosingAgentRoute() async throws {
        let f = try CleanupFixture()
        let shared = try f.skill("home/.agents/skills/example")
        let duplicate = try f.skill("home/.claude/skills/example")
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let assessment = await SkillCleanupPlanner.assess(records: [f.record(shared), f.record(duplicate)], manager: manager)
        #expect(assessment.localNames == 1)
        #expect(assessment.localRecords.count == 2)
        #expect(assessment.readyPlans.count == 1)
        let plan = try #require(assessment.readyPlans.first)
        let receipt = try await manager.apply(plan.id)
        #expect(duplicate.resolvingSymlinksInPath() == shared.resolvingSymlinksInPath())
        try await manager.restore(receipt.id)
        #expect(try duplicate.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try String(contentsOf: duplicate, encoding: .utf8) == f.text)
    }

    @Test func mismatchedSupportFilesAndExternalReferencesNeverBecomeReady() async throws {
        let f = try CleanupFixture()
        let shared = try f.skill("home/.agents/skills/example")
        let duplicate = try f.skill("home/.claude/skills/example")
        try Data("extra".utf8).write(to: duplicate.deletingLastPathComponent().appendingPathComponent("reference.md"))
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let result = await SkillCleanupPlanner.assess(records: [f.record(shared), f.record(duplicate)], manager: manager)
        #expect(result.readyPlans.isEmpty)
        #expect(result.recommendations.first?.category == .decision)
        let other = try f.skill("elsewhere/example", text: f.text + "Read ../outside.md")
        let otherCopy = try f.skill("another/example", text: f.text + "Read ../outside.md")
        let external = await SkillCleanupPlanner.assess(records: [f.record(other), f.record(otherCopy)], manager: manager)
        #expect(external.readyPlans.isEmpty)
    }

    @Test func cachesArchivesAndIndependentCheckoutsDoNotBecomeReady() async throws {
        let f = try CleanupFixture()
        let a = try f.skill("a/.codex/skills/example"), b = try f.skill("b/.codex/skills/example")
        for root in ["a", "b"] { try FileManager.default.createDirectory(at: f.root.appendingPathComponent(root + "/.git"), withIntermediateDirectories: true) }
        let archived = try f.skill("fleet-archive/old/.codex/skills/example")
        let cache = try f.skill("home/.codex/plugins/cache/test/1/skills/example")
        let cache2 = try f.skill("home/.codex/plugins/cache/test/2/skills/example")
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let result = await SkillCleanupPlanner.assess(records: [f.record(a), f.record(b), f.record(archived), f.record(cache), f.record(cache2)], manager: manager)
        #expect(result.readyPlans.isEmpty)
        #expect(result.localRecords.count == 2)
        #expect(result.archiveCount == 1)
        #expect(result.cacheCount == 2)
        #expect(result.recommendations.contains { $0.category == .independent })
    }

    @Test func scopeRecommendationRemovesOnlyGlobalAliasWithExistingProjectAccess() async throws {
        let f = try CleanupFixture()
        let source = try f.skill("home/project/.agents/skills/example")
        let global = f.root.appendingPathComponent("home/.agents/skills/example")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: global, withDestinationURL: source.deletingLastPathComponent())
        let exposures = [
            SkillExposure(logicalPath: source.path, resolvedPath: source.path, source: "Project", scope: .project, provider: .agents, applicability: .conditional),
            SkillExposure(logicalPath: global.appendingPathComponent("SKILL.md").path, resolvedPath: source.path, source: "Global", scope: .global, provider: .agents, applicability: .conditional)
        ]
        let record = f.record(source, exposures: exposures)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let result = await SkillCleanupPlanner.assess(records: [record], manager: manager)
        let scope = try #require(result.recommendations.first { $0.action == .scope })
        #expect(scope.category == .decision)
        #expect(scope.globalLinks == [global.path])
        #expect(result.readyPlans.isEmpty)
        let preview = try await manager.prepareUnlink(path: global)
        let receipt = try await manager.apply(preview.id)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: global.path))
        try await manager.restore(receipt.id)
        #expect(global.appendingPathComponent("SKILL.md").resolvingSymlinksInPath() == source.resolvingSymlinksInPath())
    }
}

private struct CleanupFixture {
    let root: URL
    let text = "---\nname: example\ndescription: A useful local workflow\n---\nFollow the workflow.\n"
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("cleanup-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func skill(_ path: String, text: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try (text ?? self.text).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    func record(_ url: URL, exposures: [SkillExposure] = []) -> SkillRecord {
        SkillRecord(id: url.path, name: "example", description: "A useful local workflow", logicalBytes: 100,
                    modified: Date(timeIntervalSince1970: 0), exposures: exposures, policies: [], contentFingerprint: "matching")
    }
}
