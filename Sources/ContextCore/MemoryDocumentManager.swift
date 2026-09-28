import Foundation
import CryptoKit

public struct MemoryEditPlan: Identifiable, Sendable {
    public let id: UUID
    public let entry: MemoryEntry
    public let before: String
    public let after: String
    public var archive = false
}

public struct MemoryEditReceipt: Identifiable, Codable, Sendable {
    public let id: UUID
    public let path: String
    public let date: Date
    public let beforeHash: String
    public let afterHash: String
    public var completed: Bool
    public var restored: Bool
    public var archived: Bool? = nil
}

/// Edits existing, explicitly selected documents. No instruction discovery or agent configuration is changed.
public actor MemoryDocumentManager {
    private let storage: URL
    private let home: URL
    private var plans: [UUID: MemoryEditPlan] = [:]
    public init(storage: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextDaddy/MemoryHistory"),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.storage = storage.standardizedFileURL; self.home = home.resolvingSymlinksInPath()
    }
    public func prepare(entry: MemoryEntry, text: String) throws -> MemoryEditPlan {
        guard entry.editable else { throw error("This source is managed by its agent or linked. Edit its owner instead.") }
        try writable(entry.path)
        let before = try MemoryInventory.read(entry)
        guard !before.truncated, text.utf8.count <= SkillDocumentReader.maximumBytes, !text.contains("\0") else {
            throw error("Only complete UTF-8 documents up to 256 KiB can be edited.")
        }
        guard before.text != text else { throw error("There are no changes to save.") }
        let plan = MemoryEditPlan(id: UUID(), entry: entry, before: before.text, after: text)
        plans[plan.id] = plan
        return plan
    }
    public func apply(_ id: UUID) throws -> MemoryEditReceipt {
        guard let plan = plans.removeValue(forKey: id) else { throw error("Preview expired. Review the changes again.") }
        try writable(plan.entry.path)
        guard try MemoryInventory.read(plan.entry).text == plan.before else { throw error("The file changed since preview. Reopen it before saving.") }
        try safeStorage()
        let backup = storage.appendingPathComponent(id.uuidString + ".md")
        var receipt = MemoryEditReceipt(id: id, path: plan.entry.path, date: Date(), beforeHash: hash(plan.before), afterHash: hash(plan.after), completed: false, restored: false)
        receipt.archived = plan.archive
        if !plan.archive {
            try Data(plan.before.utf8).write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try save(receipt)
        let file = URL(fileURLWithPath: plan.entry.path)
        if plan.archive {
            try FileManager.default.moveItem(at: file, to: backup)
            receipt.completed = true; try save(receipt); return receipt
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        try Data(plan.after.utf8).write(to: file, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        guard try MemoryInventory.read(plan.entry).text == plan.after else { throw error("Save verification failed. The backup is retained in History.") }
        receipt.completed = true
        try save(receipt)
        return receipt
    }
    public func prepareArchive(entry: MemoryEntry) throws -> MemoryEditPlan {
        guard entry.editable else { throw error("This source is managed or linked. Archive is unavailable.") }
        try writable(entry.path)
        let document = try MemoryInventory.read(entry)
        guard !document.truncated else { throw error("An oversized document cannot be archived through this preview.") }
        var plan = MemoryEditPlan(id: UUID(), entry: entry, before: document.text, after: "")
        plan.archive = true; plans[plan.id] = plan; return plan
    }
    public func history() throws -> [MemoryEditReceipt] {
        guard FileManager.default.fileExists(atPath: storage.path) else { return [] }
        try safeStorage()
        return try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                guard MemoryPaths.same($0.path, $0.resolvingSymlinksInPath().path) else { throw error("Linked history receipt rejected.") }
                return try JSONDecoder().decode(MemoryEditReceipt.self, from: Data(contentsOf: $0))
            }.sorted { $0.date > $1.date }
    }
    public func restore(_ id: UUID) throws {
        try safeStorage()
        guard var receipt = try history().first(where: { $0.id == id }), !receipt.restored else { throw error("Recovery receipt unavailable.") }
        if receipt.archived == true {
            try writable(receipt.path, mustExist: false)
            let destination = URL(fileURLWithPath: receipt.path)
            guard MemoryPaths.canonical(destination.path).hasPrefix(MemoryPaths.canonical(home.path) + "/"),
                  MemoryPaths.same(destination.deletingLastPathComponent().path, destination.deletingLastPathComponent().resolvingSymlinksInPath().path),
                  !FileManager.default.fileExists(atPath: destination.path),
                  (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else { throw error("The original location is occupied or linked. Restore will not overwrite it.") }
            let backup = storage.appendingPathComponent(id.uuidString + ".md")
            guard MemoryPaths.same(backup.path, backup.resolvingSymlinksInPath().path), hash(try String(contentsOf: backup, encoding: .utf8)) == receipt.beforeHash else { throw error("Backup integrity check failed.") }
            try FileManager.default.moveItem(at: backup, to: destination)
            receipt.restored = true; try save(receipt); return
        }
        try writable(receipt.path)
        let current = try SkillDocumentReader.read(url: URL(fileURLWithPath: MemoryPaths.canonical(receipt.path)), documentKind: .rule)
        guard !current.truncated, hash(current.text) == receipt.afterHash else { throw error("The document changed after this edit. Restore would overwrite newer work.") }
        let backup = storage.appendingPathComponent(id.uuidString + ".md")
        guard MemoryPaths.same(backup.path, backup.resolvingSymlinksInPath().path) else { throw error("Linked backup rejected.") }
        let original = try String(contentsOf: backup, encoding: .utf8)
        guard hash(original) == receipt.beforeHash else { throw error("Backup integrity check failed.") }
        let mode = try FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions]
        try Data(original.utf8).write(to: URL(fileURLWithPath: receipt.path), options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: receipt.path) }
        receipt.restored = true; try save(receipt)
    }
    private func writable(_ path: String, mustExist: Bool = true) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parts = url.pathComponents
        guard MemoryPaths.canonical(url.path).hasPrefix(MemoryPaths.canonical(home.path) + "/"), MemoryPaths.same(url.path, url.resolvingSymlinksInPath().path),
              !parts.contains(where: { ["plugins", ".git", ".ssh", ".aws", ".kube"].contains($0) }),
              !MemoryPaths.canonical(url.path).hasPrefix(MemoryPaths.canonical(home.appendingPathComponent(".codex/memories").path) + "/") else {
            throw error("This location is linked, managed or outside your home. Changes are unavailable here.")
        }
        let named = ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md", "GROK.md", ".cursorrules"].contains(url.lastPathComponent)
        let rule = (path.contains("/.claude/rules/") || path.contains("/.cursor/rules/")) && ["md", "mdc"].contains(url.pathExtension)
        let memory = MemoryPaths.canonical(path).hasPrefix(MemoryPaths.canonical(home.appendingPathComponent(".claude/projects").path) + "/") && path.contains("/memory/") && url.pathExtension == "md" && !parts.contains("team")
        guard named || rule || memory else { throw error("This document format has no supported editing adapter.") }
        guard mustExist else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw error("Only independent regular documents can be edited.") }
    }
    private func safeStorage() throws {
        guard MemoryPaths.same(storage.path, storage.resolvingSymlinksInPath().path) else { throw error("Linked history location rejected.") }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func save(_ receipt: MemoryEditReceipt) throws {
        try JSONEncoder().encode(receipt).write(to: storage.appendingPathComponent(receipt.id.uuidString + ".json"), options: .atomic)
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func error(_ text: String) -> SkillManagementError { .init(message: text) }
}
