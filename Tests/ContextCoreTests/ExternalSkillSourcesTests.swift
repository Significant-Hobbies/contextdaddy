import CryptoKit
import Foundation
import Testing
@testable import ContextCore

struct ExternalSkillSourcesTests {
    @Test func verifiedReceiptRequiresTheAuditedFileDigest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let skill = folder.appendingPathComponent("SKILL.md")
        let text = "---\nname: archify\n---\nverified body"
        try text.write(to: skill, atomically: true, encoding: .utf8)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let receiptFile = folder.appendingPathComponent("receipts.json")
        let receipt: [String: Any] = ["schema": 1, "sources": [[
            "repository": "https://github.com/tt-a1i/archify", "revision": "test-commit",
            "evidence": "exact SKILL.md", "digests": [digest]
        ]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptFile)
        let sources = VerifiedSkillSources(fileURL: receiptFile)
        #expect(sources.lookup(skillPath: folder.path)?.kind == .verified)
        #expect(sources.lookup(skillPath: folder.path)?.sourceURL == "https://github.com/tt-a1i/archify")
        try (text + "\nlocal edit").write(to: skill, atomically: true, encoding: .utf8)
        #expect(sources.lookup(skillPath: folder.path) == nil)

        var unsafe = receipt
        unsafe["sources"] = [["repository": "https://token@github.com/tt-a1i/archify",
            "revision": "test", "evidence": "untrusted", "digests": [digest]]]
        try JSONSerialization.data(withJSONObject: unsafe).write(to: receiptFile)
        #expect(VerifiedSkillSources(fileURL: receiptFile).lookup(skillPath: folder.path) == nil)

        let tool: [String: Any] = ["schema": 1, "sources": [[
            "sourceType": "tool", "owner": "Example CLI", "revision": "v1",
            "evidence": "bundled skill matches", "digests": [digest]
        ]]]
        try JSONSerialization.data(withJSONObject: tool).write(to: receiptFile)
        try text.write(to: skill, atomically: true, encoding: .utf8)
        let bundled = VerifiedSkillSources(fileURL: receiptFile).lookup(skillPath: folder.path)
        #expect(bundled?.kind == .tool)
        #expect(bundled?.owner == "Example CLI")
        #expect(bundled?.sourceURL == nil)
    }

    @Test func requiresMatchingPhysicalPathAndSafeRepositoryURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a/skills/example")
        let b = root.appendingPathComponent("b/skills/example")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = try JSONSerialization.data(withJSONObject: [
            ["name": "example", "path": a.path, "sourceUrl": "https://github.com/owner/repo.git"],
            ["name": "example", "path": b.path, "sourceUrl": "https://token@github.com/owner/other?key=secret"]
        ])
        let aEvidence = ExternalSkillSources.resolve(skillPath: a.appendingPathComponent("SKILL.md").path, asm: Data(), skillsLists: [listing])
        #expect(aEvidence.kind == .github)
        #expect(aEvidence.sourceURL == "https://github.com/owner/repo")
        let bEvidence = ExternalSkillSources.resolve(skillPath: b.path, asm: Data(), skillsLists: [listing])
        #expect(bEvidence.kind == .unresolved)
    }

    @Test func pluginFilesStayWithPluginOwner() throws {
        let path = "/tmp/external-skill-sources-plugin/skills/demo"
        let asm = try JSONSerialization.data(withJSONObject: [
            ["path": path, "provider": "plugin", "providerLabel": "Plugin (example)"]
        ])
        let evidence = ExternalSkillSources.resolve(skillPath: path, asm: asm, skillsLists: [])
        #expect(evidence.kind == .plugin)
        #expect(evidence.owner == "Plugin (example)")
    }

    @Test func gitOriginRequiresTrackedSkillFileAndSafeGitHubRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        let tracked = root.appendingPathComponent("skills/tracked/SKILL.md")
        let untracked = root.appendingPathComponent("skills/untracked/SKILL.md")
        try FileManager.default.createDirectory(at: tracked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untracked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: tracked\n---\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "---\nname: untracked\n---\n".write(to: untracked, atomically: true, encoding: .utf8)
        try git(["add", "skills/tracked/SKILL.md"])
        try git(["remote", "add", "origin", "git@github.com:owner/repo.git"])
        let found = await ExternalSkillSources.repositorySource(skillPath: tracked.path)
        #expect(found?.kind == .repository)
        #expect(found?.sourceURL == "https://github.com/owner/repo")
        #expect(await ExternalSkillSources.repositorySource(skillPath: untracked.path) == nil)
    }
}
