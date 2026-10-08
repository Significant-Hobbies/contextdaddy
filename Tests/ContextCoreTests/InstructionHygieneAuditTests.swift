import Foundation
import Testing
@testable import ContextCore

struct InstructionHygieneAuditTests {
    @Test func importTokensSkipCodeHandlesAndPunctuation() {
        let text = """
        @AGENTS.md
        See @docs/rules.md, and ping @team or email a@b.com.
        Install `@scope/pkg@1.2.3` and @v1.2 are not imports.
        ```
        @inside-fence.md
        ```
        Trailing (@~/.claude/RTK.md).
        """
        let tokens = InstructionImports.importTokens(in: text)
        #expect(tokens.map(\.raw) == ["AGENTS.md", "docs/rules.md"])
        #expect(tokens.map(\.line) == [1, 2])
    }

    @Test func missingAndCaseMismatchedImportsAreFindings() throws {
        let home = try fixture()
        let project = home.appendingPathComponent("app")
        try write(project.appendingPathComponent("AGENTS.md"), "rules")
        try write(project.appendingPathComponent("CLAUDE.md"), "@agents.md\n@missing/NOTES.md\n")
        let result = InstructionHygieneAudit.audit(home: home, projects: [project])
        let missing = result.issues.filter { $0.title == "Import target not found" }
        #expect(missing.count == 1)
        #expect(missing.first?.line == 2)
        #expect(missing.first?.severity == .error)
        let mismatch = result.issues.filter { $0.title == "Import case differs from the file name" }
        #expect(mismatch.count == 1)
        #expect(mismatch.first?.detail.contains("AGENTS.md") == true)
        // A case-mismatched import still counts as visible on this volume.
        #expect(!result.issues.contains { $0.title == "Project AGENTS.md is not visible to Claude" })
    }

    @Test func importClosureIsRecursiveRelativeHomeAndDepthLimited() throws {
        let home = try fixture()
        try write(home.appendingPathComponent(".claude/CLAUDE.md"), "@RTK.md\n@~/shared/a.md")
        try write(home.appendingPathComponent(".claude/RTK.md"), "rtk")
        var previous = "a.md"
        try write(home.appendingPathComponent("shared/a.md"), "@b.md")
        for name in ["b", "c", "d", "e", "f", "g"] {
            let next = name == "g" ? "end" : String(UnicodeScalar(name.unicodeScalars.first!.value + 1)!)
            try write(home.appendingPathComponent("shared/\(name).md"), "@\(next).md")
            previous = name
        }
        _ = previous
        let closure = InstructionImports.closure(of: home.appendingPathComponent(".claude/CLAUDE.md"), home: home)
        let names = closure.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        #expect(names.contains("RTK.md"))
        // a(1) b(2) c(3) d(4) e(5); f would be the sixth hop.
        #expect(names.contains("e.md"))
        #expect(!names.contains("f.md"))
        #expect(closure.allSatisfy { $0.depth <= InstructionImports.maximumDepth })
    }

    @Test func claudeStartupEstimateCountsImportedAgentsFile() throws {
        // Unresolved temp path: inventory and rankings both keep the /var spelling.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-hygiene-" + UUID().uuidString)
        let project = home.appendingPathComponent("Projects/app")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let agents = String(repeating: "a", count: 4_000)
        try write(project.appendingPathComponent("AGENTS.md"), agents)
        try write(project.appendingPathComponent("CLAUDE.md"), "@AGENTS.md\n")
        let report = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: [home.appendingPathComponent("Projects")]))
        let claude = try #require(report.folderRankings.first { $0.provider == .claude && $0.path.hasSuffix("/Projects/app") })
        #expect(claude.instructionBytes == 4_000 + 11)
        #expect(claude.sources.contains { $0.item.source.hasPrefix(InstructionImports.sourcePrefix) && $0.item.path.hasSuffix("/AGENTS.md") })
    }

    @Test func importedAgentsFileIsAttributedToClaudeInProjects() throws {
        let date = Date(timeIntervalSince1970: 0)
        let agents = AIContextItem(id: "/work/app/AGENTS.md", path: "/work/app/AGENTS.md", name: "AGENTS.md", scope: .project, kind: .instruction,
                                   provider: .codex, logicalBytes: 10, allocatedBytes: 10, modified: date, applicability: .inherited)
        let imported = AIContextItem(id: agents.path, path: agents.path, name: "AGENTS.md", scope: .project, kind: .instruction,
                                     provider: .claude, source: InstructionImports.sourcePrefix + "CLAUDE.md", logicalBytes: 10, allocatedBytes: 10, modified: date, applicability: .inherited)
        func ranking(_ provider: AIContextProvider, _ item: AIContextItem) -> AIContextFolderRanking {
            AIContextFolderRanking(id: provider.rawValue, path: "/work/app", provider: provider, instructionBytes: 10, globalBytes: 0, inheritedBytes: 0,
                                   localBytes: 10, skillCount: 0, skillBytes: 0, conditionalCount: 0, installedOnlyCount: 0,
                                   sources: [.init(item: item, origin: .local)], notes: [])
        }
        let report = AIContextDiscoveryReport(items: [agents], folderRankings: [ranking(.codex, agents), ranking(.claude, imported)],
            coverage: AIContextCoverage(roots: [], visitedEntries: 0, itemLimitReached: false, entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: []),
            elapsed: 0)
        let project = try #require(AIContextProjectCatalog.projects(from: report).first)
        #expect(project.providers.contains(.claude))
        #expect(project.providers.contains(.codex))
    }

    @Test func unimportedInstructionReferenceIsReviewLevel() throws {
        let home = try fixture()
        try write(home.appendingPathComponent(".codex/AGENTS.md"), "shared rules")
        try write(home.appendingPathComponent(".claude/CLAUDE.md"), "Use the same working rules as ~/.codex/AGENTS.md.\nSee https://example.com/x/AGENTS.md too.")
        let result = InstructionHygieneAudit.audit(home: home, projects: [])
        let findings = result.issues.filter { $0.title == "Referenced instructions are not imported" }
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.line == 1)

        try write(home.appendingPathComponent(".claude/CLAUDE.md"), "@~/.codex/AGENTS.md\nUse the same working rules as ~/.codex/AGENTS.md.")
        #expect(!InstructionHygieneAudit.audit(home: home, projects: []).issues.contains { $0.title == "Referenced instructions are not imported" })
    }

    @Test func projectAgentsFileWithoutClaudeImportIsReported() throws {
        let home = try fixture()
        let bare = home.appendingPathComponent("bare"), unlinked = home.appendingPathComponent("unlinked"), linked = home.appendingPathComponent("linked")
        for folder in [bare, unlinked, linked] { try write(folder.appendingPathComponent("AGENTS.md"), "rules") }
        try write(unlinked.appendingPathComponent("CLAUDE.md"), "Claude-only notes")
        try write(linked.appendingPathComponent("CLAUDE.md"), "@AGENTS.md")
        let findings = InstructionHygieneAudit.audit(home: home, projects: [bare, unlinked, linked]).issues
            .filter { $0.title == "Project AGENTS.md is not visible to Claude" }
        #expect(Set(findings.map(\.path)) == [bare.appendingPathComponent("AGENTS.md").path, unlinked.appendingPathComponent("AGENTS.md").path])
        #expect(findings.allSatisfy { $0.runtime == .claude && $0.severity == .warning })
    }

    @Test func skillTriggerHygiene() throws {
        let home = try fixture()
        let skills = home.appendingPathComponent(".claude/skills")
        try write(skills.appendingPathComponent("empty/SKILL.md"), "---\nname: empty\ndescription: \"\"\n---\nbody")
        try write(skills.appendingPathComponent("none/SKILL.md"), "no frontmatter")
        try write(skills.appendingPathComponent("manual/SKILL.md"), "---\nname: manual\ndisable-model-invocation: true\n---\n")
        try write(skills.appendingPathComponent("greedy/SKILL.md"), "---\nname: greedy\ndescription: Use for anything. When in doubt, trigger automatically.\n---\n")
        try write(skills.appendingPathComponent("fine/SKILL.md"), "---\nname: fine\ndescription: Formats SQL migrations.\n---\n")
        try write(home.appendingPathComponent(".claude/CLAUDE.md"), "When the user types /manual, invoke the Skill tool with `skill: \"manual\"` first.\nThe fine skill is fine.")
        let issues = InstructionHygieneAudit.audit(home: home, projects: []).issues
        let missing = issues.filter { $0.title == "Skill has no description" }
        #expect(Set(missing.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent }) == ["empty", "none"])
        #expect(missing.allSatisfy { $0.severity == .error })
        let greedy = issues.filter { $0.title == "Skill description asks to trigger broadly" }
        #expect(greedy.count == 1)
        #expect(greedy.first?.severity == .warning)
        let disabled = issues.filter { $0.title == "Instruction invokes a skill the model cannot use" }
        #expect(disabled.count == 1)
        #expect(disabled.first?.line == 1)
        #expect(disabled.first?.severity == .error)
    }

    @Test func brokenSkillLinksAreOneCountedFindingPerFolder() throws {
        let home = try fixture()
        let skills = home.appendingPathComponent(".agents/skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        for index in 0..<30 {
            try FileManager.default.createSymbolicLink(at: skills.appendingPathComponent("gone-\(index)"), withDestinationURL: home.appendingPathComponent("missing-\(index)"))
        }
        try write(skills.appendingPathComponent("ok/SKILL.md"), "---\nname: ok\ndescription: Works.\n---\n")
        let result = InstructionHygieneAudit.audit(home: home, projects: [])
        let broken = result.issues.filter { $0.title.contains("broken skill link") }
        #expect(broken.count == 1)
        #expect(broken.first?.title == "30 broken skill links")
        #expect(broken.first?.detail.contains("and 5 more") == true)
        #expect(result.files.contains { $0.path == skills.path && $0.status == .checked })

        // Discovery no longer caps link evidence at 20 notes.
        let discovery = try AIContextDiscovery.discover(configuration: .init(home: home, projectRoots: []))
        #expect(discovery.coverage.brokenSkillLinks == 30)
        #expect(!discovery.coverage.notes.contains { $0.hasPrefix("Broken or unreadable skill link:") })
    }

    @Test func memoryBloatReportsMeasuredSizes() throws {
        let home = try fixture()
        let index = home.appendingPathComponent(".claude/projects/-Users-me-app/memory/MEMORY.md")
        try write(index, (0..<250).map { "- entry \($0)" }.joined(separator: "\n"))
        try write(home.appendingPathComponent(".claude/projects/-Users-me-small/memory/MEMORY.md"), "- one\n")
        try write(home.appendingPathComponent(".codex/memories/memory_summary.md"), String(repeating: "s", count: 9 * 1_024))
        try write(home.appendingPathComponent(".codex/memories/MEMORY.md"), String(repeating: "m", count: 1_024))
        let issues = InstructionHygieneAudit.audit(home: home, projects: []).issues
        let claude = issues.filter { $0.title == "Memory index exceeds Claude's startup limit" }
        #expect(claude.map(\.path) == [index.path])
        #expect(claude.first?.detail.contains("250 lines") == true)
        let codex = issues.filter { $0.runtime == .codex && $0.title == "Codex memory file is large" }
        #expect(codex.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["memory_summary.md"])
        #expect(codex.first?.detail.contains("9216 bytes") == true)
        #expect(issues.allSatisfy { $0.severity == .warning })
    }

    @Test func lowGlobalReasoningEffortIsReviewFindingWithLine() throws {
        let home = try fixture()
        let config = home.appendingPathComponent(".codex/config.toml")
        try write(config, "model = \"gpt-5\"\nmodel_reasoning_effort = \"low\"\n[profiles.quick]\nmodel_reasoning_effort = \"minimal\"\n")
        let issues = AgentSetupAudit.audit(home: home, executableSearchPaths: []).issues.filter { $0.title == "Low global reasoning effort" }
        #expect(issues.count == 1)
        #expect(issues.first?.line == 2)
        #expect(issues.first?.severity == .warning)
        try write(config, "model_reasoning_effort = \"high\"\n")
        #expect(!AgentSetupAudit.audit(home: home, executableSearchPaths: []).issues.contains { $0.title == "Low global reasoning effort" })
    }

    @Test func setupAuditMergesHygieneFindingsSoRescanCanClearThem() throws {
        let home = try fixture()
        let claude = home.appendingPathComponent(".claude/CLAUDE.md")
        try write(claude, "@missing.md")
        let initial = AgentSetupAudit.audit(home: home)
        let baseline = ConfigurationIssueBaseline(issues: initial.forAgent(.claude).issues)
        #expect(baseline.issues.count == 1)
        try write(claude, "No imports.")
        #expect(baseline.verify(against: AgentSetupAudit.audit(home: home)).cleared.count == 1)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-hygiene-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
