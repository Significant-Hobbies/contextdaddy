import Foundation
import CryptoKit

public struct MemoryEntry: Identifiable, Sendable, Equatable {
    public let path: String
    public let category: String
    public let agent: AgentRuntime?
    public let scope: String
    public let access: String
    public let bytes: Int64
    public let modified: Date
    public let editable: Bool
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct MemoryInventory: Sendable {
    public let entries: [MemoryEntry]
    public let notes: [String]
    public let checkedAt: Date
    public init(entries: [MemoryEntry], notes: [String], checkedAt: Date) { self.entries = entries; self.notes = notes; self.checkedAt = checkedAt }

    /// Only metadata is read here. Contents are opened explicitly in the inspector or comparison.
    public static func scan(items: [AIContextItem], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            folder: URL? = nil, limit: Int = 3000) throws -> Self {
        let home = home.resolvingSymlinksInPath()
        var entries = items.filter { [.instruction, .rule].contains($0.kind) }.compactMap { item -> MemoryEntry? in
            guard let metadata = try? FileManager.default.attributesOfItem(atPath: item.path) else { return nil }
            return MemoryEntry(path: item.path, category: item.kind == .rule ? "Rule" : "Instructions",
                agent: AgentRuntime(rawValue: item.provider.rawValue), scope: item.scope.rawValue,
                access: "\(item.applicability.rawValue) · potential access", bytes: (metadata[.size] as? NSNumber)?.int64Value ?? item.logicalBytes,
                modified: metadata[.modificationDate] as? Date ?? item.modified, editable: item.resolvedPath == nil && !item.path.contains("/plugins/") && item.provider != .gemini)
        }
        var notes = ["Files show potential availability, not what a running agent loaded. Imports, managed policies, custom memory roots and cloud memories are not resolved.",
                     "Codex memory storage is indexed as local evidence and is read-only here. Cursor, Devin and Grok managed memory has no verified local adapter; use their own memory controls."]
        var visited = 0
        let deadline = Date().addingTimeInterval(10)
        func walk(_ root: URL, agent: AgentRuntime, scope: String, depth: Int = 0) throws {
            try Task.checkCancellation()
            guard depth < 5, visited < limit, Date() < deadline else { notes.append("Partial memory scan: depth, time or entry limit reached."); return }
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { notes.append("Linked memory location skipped: \(root.path)"); return }
            let children: [URL]
            do { children = try BoundedDirectoryReader.children(root) }
            catch { notes.append("Memory directory unavailable: \(root.path)"); return }
            for file in children.sorted(by: { $0.path < $1.path }) {
                visited += 1
                guard visited <= limit, Date() < deadline else { notes.append("Partial memory scan: entry or time limit reached."); return }
                let metadata = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard let metadata, metadata.isSymbolicLink != true else { continue }
                if metadata.isDirectory == true {
                    guard !["rollout_summaries", "skills", "team", ".git"].contains(file.lastPathComponent) else { continue }
                    try walk(file, agent: agent, scope: scope, depth: depth + 1)
                } else if metadata.isRegularFile == true, file.pathExtension.lowercased() == "md" {
                    entries.append(MemoryEntry(path: MemoryPaths.canonical(file.path), category: "Saved memory", agent: agent, scope: scope,
                        access: "Agent-owned store · loading unverified", bytes: Int64(metadata.fileSize ?? 0),
                        modified: metadata.contentModificationDate ?? .distantPast, editable: agent == .claude))
                }
            }
        }
        try walk(home.appendingPathComponent(".codex/memories"), agent: .codex, scope: "User store")
        let claudeProjects = home.appendingPathComponent(".claude/projects")
        if FileManager.default.fileExists(atPath: claudeProjects.path), claudeProjects.path == claudeProjects.resolvingSymlinksInPath().path {
            // Folder names are lossy encodings. Do not guess repository ownership from them.
            if let roots = try? BoundedDirectoryReader.children(claudeProjects) {
                for root in roots.prefix(500) {
                    try walk(root.appendingPathComponent("memory"), agent: .claude, scope: "Project store · folder mapping unverified")
                }
                if roots.count > 500 { notes.append("Partial memory scan: only 500 Claude project stores checked.") }
            } else { notes.append("Claude memory stores could not be listed.") }
        }
        if folder != nil { notes.append("Instructions use the selected folder's applicable sources. Saved stores remain visible separately because folder ownership is not verified; do not assume they load in this folder.") }
        let unique = Dictionary(grouping: entries, by: \.path).compactMap { $0.value.first }.sorted { $0.path < $1.path }
        return Self(entries: unique, notes: Array(Set(notes)).sorted(), checkedAt: Date())
    }

    public static func read(_ entry: MemoryEntry) throws -> SkillDocument {
        try SkillDocumentReader.read(url: URL(fileURLWithPath: MemoryPaths.canonical(entry.path)), documentKind: .rule)
    }

    public static func compare(_ entries: [MemoryEntry]) throws -> (groups: [[MemoryEntry]], skipped: Int) {
        var hashes: [String: [MemoryEntry]] = [:], skipped = 0
        for entry in entries {
            try Task.checkCancellation()
            guard let document = try? read(entry), !document.truncated else { skipped += 1; continue }
            let hash = SHA256.hash(data: Data(document.text.utf8)).map { String(format: "%02x", $0) }.joined()
            hashes[hash, default: []].append(entry)
        }
        return (hashes.values.filter { $0.count > 1 }.sorted { $0[0].path < $1[0].path }, skipped)
    }
}

/// Normalize only macOS's two system aliases; arbitrary user symlinks remain rejected.
enum MemoryPaths {
    static func canonical(_ path: String) -> String {
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }
    static func same(_ lhs: String, _ rhs: String) -> Bool { canonical(lhs) == canonical(rhs) }
}
