import Foundation
import Testing
@testable import ContextCore

struct ManagedSkillHealthTests {
    private func report(problems: Int = 0, unmanaged: Int = 0, status: String = "ok",
                        maintenance: String = "healthy", scope: String = "all registered targets") throws -> ManagedSkillHealth {
        let object: [String: Any] = [
            "schemaVersion": 1, "generatedAt": "2026-10-24T00:00:00Z", "scope": scope, "repositoryDirty": true,
            "summary": ["entryCount": 1, "problemCount": problems, "unmanagedCount": unmanaged],
            "maintenance": ["status": maintenance, "scope": "non-Desktop targets", "lastExitCode": 0],
            "skills": [["name": "example", "type": "git-pinned", "physicalPath": "/tmp/managed-example",
                        "sourceURL": "https://github.com/example/skills.git", "revision": "abc123", "patch": "patches/example.patch",
                        "status": status, "targets": [["name": "codex", "path": "/tmp/skills/example", "status": "ok"]]]],
        ]
        return try ManagedSkillHealth.decode(JSONSerialization.data(withJSONObject: object))
    }

    @Test func fullHealthyReportDoesNotRequireCommittingUnrelatedWork() throws {
        let value = try report()
        #expect(value.healthy)
        #expect(value.repositoryDirty)
    }

    @Test func driftMissingMaintenanceAndPartialCoverageCannotGiveAllClear() throws {
        #expect(try !report(problems: 1, status: "STALE-RECIPE").healthy)
        #expect(try !report(unmanaged: 1).healthy)
        #expect(try !report(maintenance: "not-installed").healthy)
        #expect(try !report(maintenance: "failed").healthy)
        #expect(try !report(scope: "non-Desktop targets").healthy)
    }

    @Test func invalidOrContradictoryOutputIsUnavailable() {
        #expect(throws: (any Error).self) { try ManagedSkillHealth.decode(Data("not JSON".utf8)) }
        #expect(throws: (any Error).self) { try report(status: "LOCAL-EDITS") }
    }

    @Test func managerOwnershipIncludesPinPatchAndNestedDefinitions() throws {
        let value = try report()
        let evidence = value.sourceEvidence(skillPath: "/tmp/managed-example/upstream/leaf/SKILL.md")
        #expect(evidence?.kind == .managed)
        #expect(evidence?.owner == "agent-config")
        #expect(evidence?.note.contains("abc123") == true)
        #expect(evidence?.note.contains("patches/example.patch") == true)
        #expect(value.sourceEvidence(skillPath: "/tmp/managed-example-other/SKILL.md") == nil)
    }
}
