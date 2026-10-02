import Foundation
import Testing
@testable import ContextCore

struct AIContextProjectsTests {
    @Test func selectedDiscoveryRootsExcludeExternalSkillRootsAndLinkTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let personal = home.appendingPathComponent(".agents/skills/local")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\nname: local\n---\n".write(to: personal.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: external\n---\n".write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: personal.deletingLastPathComponent().appendingPathComponent("alias"), withDestinationURL: external)
        let restricted = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [], additionalSkillRoots: [external], allowedRoots: [home]))
        #expect(restricted.items.filter { $0.kind == .skill }.map(\.name) == ["local"])
        let existingDefaults = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [], additionalSkillRoots: [external]))
        #expect(existingDefaults.items.contains { $0.name == "external" })
    }

    @Test func groupsOwnedAndInheritedContextWithoutGlobalCacheNoise() throws {
        let app = "/work/app"
        let local = item(app + "/AGENTS.md", provider: .codex, kind: .instruction)
        let rule = item(app + "/.claude/rules/swift/style.md", provider: .claude, kind: .rule)
        let inherited = item("/work/AGENTS.md", provider: .codex, kind: .instruction)
        let global = item("/home/.codex/skills/global/SKILL.md", scope: .global, provider: .codex, kind: .skill)
        let cached = item("/home/.codex/plugins/cache/tool/SKILL.md", scope: .global, provider: .codex, kind: .skill, applicability: .installedOnly)
        let report = report([
            ranking(app, provider: .codex, sources: [contribution(local, .local), contribution(inherited, .inherited), contribution(global, .conditional), contribution(cached, .installedOnly)]),
            ranking(app, provider: .claude, sources: [contribution(rule, .conditional)]),
        ])

        let project = try #require(AIContextProjectCatalog.projects(from: report).first)
        #expect(project.providers == [.claude, .codex])
        #expect(project.projectItemCount == 2)
        #expect(project.locations.contains { $0.path == "/work" && $0.scope == .inherited })
        #expect(!project.locations.contains { $0.scope == .global || $0.scope == .installed })
    }

    @Test func retainsDistinctLogicalAliasesToOnePhysicalSkill() throws {
        let target = "/shared/demo/SKILL.md"
        let agents = item("/work/app/.agents/skills/demo/SKILL.md", resolvedPath: target, provider: .agents, kind: .skill)
        let codex = item("/work/app/.codex/skills/demo/SKILL.md", resolvedPath: target, provider: .codex, kind: .skill)
        let project = try #require(AIContextProjectCatalog.projects(from: report([
            ranking("/work/app", provider: .codex, sources: [contribution(agents, .conditional), contribution(codex, .conditional)]),
        ])).first)

        #expect(project.projectItemCount == 2)
        #expect(Set(project.locations.flatMap(\.items).map(\.path)) == Set([agents.path, codex.path]))
    }

    @Test func agentLoadsExcludeInstalledOnlyAndNonRuntimeProviders() {
        let local = item("/work/app/AGENTS.md", provider: .codex, kind: .instruction)
        let cached = item("/home/.codex/plugins/cache/tool/SKILL.md", scope: .global, provider: .codex, kind: .skill, applicability: .installedOnly)
        let loads = AIContextProjectCatalog.agentLoads(in: "/work/app", rankings: [
            ranking("/work/app", provider: .codex, sources: [contribution(local, .local)], bytes: 400),
            ranking("/work/app", provider: .cursor, sources: [contribution(cached, .installedOnly)], bytes: 900),
            ranking("/work/app", provider: .agents, sources: [contribution(local, .local)], bytes: 800),
        ])

        #expect(loads.map(\.provider) == [.codex])
        #expect(loads.first?.estimatedStartupTokens == 100)
    }

    private func item(_ path: String, resolvedPath: String? = nil, scope: AIContextScope = .project,
                      provider: AIContextProvider, kind: AIContextKind,
                      applicability: AIContextOrigin = .conditional) -> AIContextItem {
        AIContextItem(id: path, path: path, resolvedPath: resolvedPath, name: URL(fileURLWithPath: path).lastPathComponent,
                      scope: scope, kind: kind, provider: provider, logicalBytes: 10, allocatedBytes: 10,
                      modified: .distantPast, applicability: applicability)
    }

    private func contribution(_ item: AIContextItem, _ origin: AIContextOrigin) -> AIContextContribution {
        AIContextContribution(item: item, origin: origin)
    }

    private func ranking(_ path: String, provider: AIContextProvider, sources: [AIContextContribution], bytes: Int64 = 0) -> AIContextFolderRanking {
        AIContextFolderRanking(id: provider.rawValue + path, path: path, provider: provider,
                               instructionBytes: bytes, globalBytes: 0, inheritedBytes: 0, localBytes: bytes,
                               skillCount: 0, skillBytes: 0, conditionalCount: 0, installedOnlyCount: 0,
                               sources: sources, notes: [])
    }

    private func report(_ rankings: [AIContextFolderRanking]) -> AIContextDiscoveryReport {
        AIContextDiscoveryReport(items: [], folderRankings: rankings,
                                 coverage: AIContextCoverage(roots: [], visitedEntries: 0, itemLimitReached: false,
                                                            entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: []),
                                 elapsed: 0)
    }
}
