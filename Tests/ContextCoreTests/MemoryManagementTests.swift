import Foundation
import Testing
@testable import ContextCore

struct MemoryManagementTests {
    @Test func metadataComparisonAndGuardedEditRecovery() async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AGENTS.md"), copy = root.appendingPathComponent("CLAUDE.md")
        try Data("Original guidance\n".utf8).write(to: file); try Data("Original guidance\n".utf8).write(to: copy)
        let items = [file, copy].map { AIContextItem(id: $0.path, path: $0.path, name: $0.lastPathComponent, scope: .project, kind: .instruction, provider: .codex, logicalBytes: 18, allocatedBytes: 18, modified: Date()) }
        let inventory = try MemoryInventory.scan(items: items, home: root)
        #expect(inventory.entries.count == 2)
        #expect(try MemoryInventory.compare(inventory.entries).groups.count == 1)
        let entry = try #require(inventory.entries.first { $0.path == file.path })
        let manager = MemoryDocumentManager(storage: root.appendingPathComponent("history"), home: root)
        let stale = try await manager.prepare(entry: entry, text: "Revised")
        try Data("External edit".utf8).write(to: file)
        await #expect(throws: SkillManagementError.self) { try await manager.apply(stale.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "External edit")
        let plan = try await manager.prepare(entry: entry, text: "Useful concise guidance")
        let receipt = try await manager.apply(plan.id)
        #expect(receipt.completed)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Useful concise guidance")
        try await manager.restore(receipt.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == "External edit")
        #expect(try await manager.history().first?.restored == true)
        let later = try await manager.prepare(entry: entry, text: "Another change")
        let changed = try await manager.apply(later.id)
        try Data("Newer work".utf8).write(to: file)
        await #expect(throws: SkillManagementError.self) { try await manager.restore(changed.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "Newer work")
        let archive = try await manager.prepareArchive(entry: entry)
        let archived = try await manager.apply(archive.id)
        #expect(archived.archived == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try MemoryInventory.scan(items: items, home: root).entries.count == 1)
        try await manager.restore(archived.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Newer work")
        #expect(try MemoryInventory.scan(items: items, home: root).entries.count == 2)
    }

    @Test func managedMemoryAndLinksCannotBeEditedAndBodiesAreBounded() async throws {
        let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path.replacingOccurrences(of: "/var/", with: "/private/var/")).appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent(".codex/memories/MEMORY.md")
        let claude = root.appendingPathComponent(".claude/projects/project/memory/MEMORY.md")
        for file in [codex, claude] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("Memory".utf8).write(to: file) }
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try MemoryInventory.scan(items: [], home: root)
        #expect(inventory.entries.count == 2)
        let managed = try #require(inventory.entries.first { $0.agent == .codex })
        let editable = try #require(inventory.entries.first { $0.agent == .claude })
        let manager = MemoryDocumentManager(storage: root.appendingPathComponent("history"), home: root)
        await #expect(throws: SkillManagementError.self) { try await manager.prepare(entry: managed, text: "Must not write") }
        let plan = try await manager.prepare(entry: editable, text: "Updated note")
        _ = try await manager.apply(plan.id)
        #expect(try String(contentsOf: codex, encoding: .utf8) == "Memory")
        let linked = root.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: codex)
        let linkEntry = MemoryEntry(path: linked.path, category: "Instructions", agent: .codex, scope: "Global", access: "", bytes: 6, modified: Date(), editable: true)
        await #expect(throws: SkillManagementError.self) { try await manager.prepare(entry: linkEntry, text: "Must not write") }
        try Data(repeating: 65, count: SkillDocumentReader.maximumBytes + 2).write(to: claude)
        #expect(try MemoryInventory.read(editable).truncated)
        await #expect(throws: SkillManagementError.self) { try await manager.prepare(entry: editable, text: "Cannot truncate on save") }
    }
}
