import Foundation
import Testing
@testable import ContextCore

struct SkillLibraryManagerTests {
    private let text = "---\nname: example\ndescription: An example skill\n---\n\nOriginal instructions.\n"

    @Test func editIsPreviewedBackedUpAndRestorable() async throws {
        let f = try LibraryFixture()
        let skill = try f.skill(text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let updated = text.replacingOccurrences(of: "Original", with: "Updated")
        let plan = try await manager.prepareEdit(skill: skill, text: updated)
        #expect(try String(contentsOf: skill, encoding: .utf8) == text)
        let receipt = try await manager.apply(plan.id)
        #expect(try String(contentsOf: skill, encoding: .utf8) == updated)
        #expect(receipt.backupPath != nil)
        try await manager.restore(receipt.id)
        #expect(try String(contentsOf: skill, encoding: .utf8) == text)
        #expect(try await manager.history().first?.restored == true)
    }

    @Test func agentConfigCopiesAndAliasesCannotBeChangedThroughLibraryActions() async throws {
        let f = try LibraryFixture()
        let skill = try f.skill(text, name: ".local/share/agent-config/skills/example")
        let alias = f.root.appendingPathComponent("example-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: skill.deletingLastPathComponent())
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        await #expect(throws: SkillManagementError.self) { try await manager.prepareEdit(skill: skill, text: text + "Changed") }
        await #expect(throws: SkillManagementError.self) { try await manager.prepareInvocation(skill: alias.appendingPathComponent("SKILL.md"), runtime: .codex, automatic: false) }
        await #expect(throws: SkillManagementError.self) { try await manager.prepareUnlink(path: alias) }
        #expect(try String(contentsOf: skill, encoding: .utf8) == text)
        #expect(FileManager.default.fileExists(atPath: alias.path))
    }

    @Test func staleEditsAndRestoreNeverOverwriteNewWork() async throws {
        let f = try LibraryFixture(); let skill = try f.skill(text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareEdit(skill: skill, text: text + "Edited")
        try (text + "External").write(to: skill, atomically: true, encoding: .utf8)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(plan.id) }
        let fresh = try await manager.prepareEdit(skill: skill, text: text + "Saved")
        let receipt = try await manager.apply(fresh.id)
        try (text + "Newer").write(to: skill, atomically: true, encoding: .utf8)
        await #expect(throws: SkillManagementError.self) { try await manager.restore(receipt.id) }
        #expect(try String(contentsOf: skill, encoding: .utf8) == text + "Newer")
    }

    @Test func wholeFolderUpdatePreservesLinksAndCanBeRestored() async throws {
        let f = try LibraryFixture(); let skill = try f.skill(text)
        let source = try f.skill(text + "Replacement", name: "incoming")
        try Data("helper".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("helper.py"))
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: skill.deletingLastPathComponent())
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareUpdate(skill: skill, source: source.deletingLastPathComponent())
        let receipt = try await manager.apply(plan.id)
        #expect(try String(contentsOf: alias.appendingPathComponent("SKILL.md"), encoding: .utf8) == text + "Replacement")
        #expect(FileManager.default.fileExists(atPath: skill.deletingLastPathComponent().appendingPathComponent("helper.py").path))
        try await manager.restore(receipt.id)
        #expect(try String(contentsOf: alias.appendingPathComponent("SKILL.md"), encoding: .utf8) == text)
    }

    @Test func shareUnlinkAndArchiveAreRecoverable() async throws {
        let f = try LibraryFixture(); let skill = try f.skill(text)
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareLink(skill: skill, parent: f.root.appendingPathComponent("agent/skills"))
        let share = try await manager.apply(plan.id)
        let link = URL(fileURLWithPath: share.destination)
        #expect(try String(contentsOf: link.appendingPathComponent("SKILL.md"), encoding: .utf8) == text)
        let unlink = try await manager.prepareUnlink(path: link)
        let removal = try await manager.apply(unlink.id)
        #expect(FileManager.default.fileExists(atPath: skill.path))
        #expect(!FileManager.default.fileExists(atPath: link.path))
        try await manager.restore(removal.id)
        #expect(FileManager.default.fileExists(atPath: link.path))
        let archive = try await manager.prepareArchive(skill: skill)
        let archived = try await manager.apply(archive.id)
        #expect(!FileManager.default.fileExists(atPath: skill.path))
        try await manager.restore(archived.id)
        #expect(FileManager.default.fileExists(atPath: link.appendingPathComponent("SKILL.md").path))
    }

    @Test func createAndImportRejectOccupiedDestinations() async throws {
        let f = try LibraryFixture(); let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareCreate(parent: f.root, name: "example", text: text)
        _ = try f.skill(text)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(plan.id) }
        await #expect(throws: SkillManagementError.self) { try await manager.prepareImport(source: f.root.appendingPathComponent("example"), parent: f.root) }
        await #expect(throws: SkillManagementError.self) { try await manager.prepareCreate(parent: f.root, name: "../escape", text: text) }
    }

    @Test func rejectsManagedDefinitionsLinksAndProtectedContents() async throws {
        let f = try LibraryFixture(); let skill = try f.skill(text)
        let managed = try f.skill(text, name: "plugins/cache/owned")
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        await #expect(throws: SkillManagementError.self) { try await manager.prepareEdit(skill: managed, text: text) }
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: skill.deletingLastPathComponent())
        await #expect(throws: SkillManagementError.self) { try await manager.prepareEdit(skill: alias.appendingPathComponent("SKILL.md"), text: text) }
        try Data("fixture only".utf8).write(to: skill.deletingLastPathComponent().appendingPathComponent(".env"))
        await #expect(throws: SkillManagementError.self) { try await manager.prepareArchive(skill: skill) }
    }

    @Test func createsAndImportsCompleteSkillFoldersAndRestoresThem() async throws {
        let f = try LibraryFixture()
        let manager = SkillLibraryManager(storage: f.root.appendingPathComponent("history"))
        let plan = try await manager.prepareCreate(parent: f.root, name: "new-skill", text: text)
        let receipt = try await manager.apply(plan.id)
        #expect(receipt.completed)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new-skill/SKILL.md").path))
        try await manager.restore(receipt.id)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new-skill").path))
        let source = try f.skill(text)
        try Data("print('fixture')".utf8).write(to: source.deletingLastPathComponent().appendingPathComponent("helper.py"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.deletingLastPathComponent().appendingPathComponent("helper.py").path)
        let imported = try await manager.prepareImport(source: source.deletingLastPathComponent(), parent: f.root.appendingPathComponent("destination"))
        #expect(imported.fileChanges.contains("Added: helper.py"))
        let installed = try await manager.apply(imported.id)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("destination/example/helper.py").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("destination/example/helper.py").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
        try await manager.restore(installed.id)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func explicitAgentRootKeepsPolicyAndDoesNotDuplicateKnownExposures() throws {
        let f = try LibraryFixture()
        _ = try f.skill(text, name: "home/.claude/skills/example")
        let root = f.root.appendingPathComponent("home/.claude/skills")
        let report = try AIContextDiscovery.discover(configuration: .init(home: f.root.appendingPathComponent("home"), projectRoots: [], additionalSkillRoots: [root]))
        let catalog = SkillPolicyResolver.resolve(report: report)
        #expect(catalog.records.count == 1)
        #expect(catalog.records[0].exposures.count == 1)
        #expect(catalog.records[0].policy(for: .claude)?.isExposed == true)
        _ = try f.skill(text, name: "deep/project/.cursor/skills/example")
        let deep = try AIContextDiscovery.discover(configuration: .init(home: f.root.appendingPathComponent("empty"), projectRoots: [], additionalSkillRoots: [f.root.appendingPathComponent("deep/project/.cursor/skills")]))
        #expect(SkillPolicyResolver.resolve(report: deep).records[0].policy(for: .cursor)?.isExposed == true)
    }

    @Test func addedSkillRootsAreLibraryEvidenceNotAgentAccess() throws {
        let f = try LibraryFixture(); _ = try f.skill(text, name: "collection/example")
        let report = try AIContextDiscovery.discover(configuration: .init(home: f.root.appendingPathComponent("home"), projectRoots: [], additionalSkillRoots: [f.root.appendingPathComponent("collection")]))
        let catalog = SkillPolicyResolver.resolve(report: report)
        #expect(catalog.records.count == 1)
        #expect(catalog.records[0].exposedRuntimes.isEmpty)
        #expect(SkillLibraryIndex.matching(catalog.records, query: "example collection").count == 1)
        #expect(SkillLibraryIndex.matching(catalog.records, query: "", runtime: .codex).isEmpty)
    }
}

private final class LibraryFixture {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent("skill-library-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func skill(_ text: String, name: String = "example") throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("SKILL.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
