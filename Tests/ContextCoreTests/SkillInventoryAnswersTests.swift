import Foundation
import Testing
@testable import ContextCore

struct SkillInventoryAnswersTests {
    @Test func duplicateReviewIncludesCounterpartsAndDoesNotTreatAliasesAsCopies() {
        func record(_ id: String, _ hash: String?) -> SkillRecord {
            SkillRecord(id: id, name: "example", description: "", logicalBytes: 1, modified: Date(), exposures: [], policies: [], contentFingerprint: hash)
        }
        let a = record("/global/a/SKILL.md", "same")
        let b = record("/project/b/SKILL.md", "same")
        let other = record("/other/c/SKILL.md", "different")
        let unknown = record("/other/d/SKILL.md", nil)
        #expect(SkillInventoryAnswers.matchingCopyIDs(near: [a.id], records: [a, a, b, other, unknown]) == [a.id, b.id])
        #expect(SkillInventoryAnswers.matchingCopyIDs(near: [a.id], records: [a, a]).isEmpty)
        #expect(SkillInventoryAnswers.matchingCopyIDs(near: [unknown.id], records: [a, b, unknown]).isEmpty)
        #expect(SkillInventoryAnswers.matchingCopyIDs(near: [other.id], records: [a, b, other]).isEmpty)
    }

    @Test func countsDefinitionsWithoutInflatingLinksOrAssumingUnknownContentIsUnique() {
        func record(_ id: String, name: String = "Example", hash: String?, scope: AIContextScope = .global, agents: [AgentRuntime] = [.codex]) -> SkillRecord {
            SkillRecord(id: id, name: name, description: "", logicalBytes: 1, modified: Date(),
                exposures: [.init(logicalPath: id, resolvedPath: id, source: "Test", scope: scope, provider: .codex, applicability: .conditional)],
                policies: agents.map { .init(runtime: $0, mode: .automatic, explicit: true, reason: "Test", invocation: "$example") }, contentFingerprint: hash)
        }
        let a = record("/home/.codex/skills/a/SKILL.md", hash: "same", agents: [.codex, .claude])
        let b = record("/project/.claude/skills/b/SKILL.md", name: "example", hash: "same", scope: .project)
        let unknown = record("/home/notes/c/SKILL.md", name: "Other", hash: nil, agents: [])
        let plugin = record("/home/.codex/plugins/cache/test/1/skills/d/SKILL.md", hash: "same")
        let archived = record("/home/archives/e/SKILL.md", hash: "same")
        let answer = SkillInventoryAnswers(records: [a, a, b, unknown, plugin, archived])
        #expect(answer.local.count == 3)
        #expect(answer.uniqueNames == 2)
        #expect(answer.uniqueInstructions == 1)
        #expect(answer.unverifiedInstructions == 1)
        #expect(answer.extraInstructionCopies == 1)
        #expect(answer.pluginCount == 1)
        #expect(answer.archivedCount == 1)
        #expect(answer.count(for: .codex) == 2)
        #expect(answer.count(for: .claude) == 1)
        #expect(answer.noAccessCount == 1)
        #expect(answer.projectOnlyCount == 1)
    }
}
