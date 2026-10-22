import Foundation

/// Reads every local Claude Code and interactive Codex session into timelines.
/// Files are cached by path, size and modification date, so later scans parse only what changed.
public struct SessionTimeScanner: Sendable {
    public struct Limits: Sendable {
        public var maximumSeconds: TimeInterval = 600
        public var maximumLineBytes = 64_000_000
        public var maximumFiles = 60_000
        public init() {}
    }

    /// Bump when parsing or classification changes, so cached timelines are rebuilt.
    public static let cacheVersion = 2

    private struct CacheEntry: Codable {
        var size: Int64
        var modified: Double
        var skipped: Int
        var timeline: SessionTimeline?
        var scriptedSession: String?
    }

    private struct Cache: Codable {
        var version: Int
        var entries: [String: CacheEntry]
    }

    private enum Source { case claudeMain, claudeSubagent, codex }

    private let home: URL
    private let cacheURL: URL
    private let limits: Limits

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheDirectory: URL? = nil, limits: Limits = .init()) {
        self.home = home
        let base = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextDaddy", isDirectory: true)
        self.cacheURL = base.appendingPathComponent("session-time-cache.json")
        self.limits = limits
    }

    public func scan(progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) -> SessionTimeSnapshot {
        let deadline = Date().addingTimeInterval(limits.maximumSeconds)
        var cache = loadCache()
        var nextEntries: [String: CacheEntry] = [:]
        let files = claudeFiles() + codexFiles()
        var timelines: [SessionTimeline] = []
        var scriptedSessions = Set<String>()
        var stats: [SessionTimeAgent: (files: Int, cached: Int, skippedFiles: Int, skippedRecords: Int, overLimit: Bool)] = [:]
        for agent in SessionTimeAgent.allCases { stats[agent] = (0, 0, 0, 0, false) }

        for (index, file) in files.prefix(limits.maximumFiles).enumerated() {
            let agent: SessionTimeAgent = file.source == .codex ? .codex : .claude
            stats[agent]!.files += 1
            defer { progress?(index + 1, files.count) }
            guard let values = try? file.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate?.timeIntervalSince1970 else {
                stats[agent]!.skippedFiles += 1
                continue
            }
            let key = file.url.path
            if let entry = cache.entries[key], entry.size == Int64(size), entry.modified == modified {
                nextEntries[key] = entry
                stats[agent]!.cached += 1
                stats[agent]!.skippedRecords += entry.skipped
                if let timeline = entry.timeline { timelines.append(timeline) }
                if let scripted = entry.scriptedSession { scriptedSessions.insert(scripted) }
                continue
            }
            guard Date() < deadline, !Task.isCancelled else {
                stats[agent]!.skippedFiles += 1
                stats[agent]!.overLimit = true
                continue
            }
            do {
                var scripted: String?
                let timeline: SessionTimeline?
                let skipped: Int
                switch file.source {
                case .claudeMain, .claudeSubagent:
                    var reader = ClaudeSessionTimeReader(url: file.url, isSubagent: file.source == .claudeSubagent,
                                                         maximumLineBytes: limits.maximumLineBytes, deadline: deadline)
                    (timeline, skipped) = try reader.read()
                    scripted = reader.scriptedSession
                case .codex:
                    (timeline, skipped) = try CodexSessionTimeReader(url: file.url, maximumLineBytes: limits.maximumLineBytes, deadline: deadline).read()
                }
                if let scripted { scriptedSessions.insert(scripted) }
                nextEntries[key] = CacheEntry(size: Int64(size), modified: modified, skipped: skipped, timeline: timeline, scriptedSession: scripted)
                stats[agent]!.skippedRecords += skipped
                if let timeline { timelines.append(timeline) }
            } catch is SessionTimeLines.Deadline {
                stats[agent]!.skippedFiles += 1
                stats[agent]!.overLimit = true
            } catch {
                stats[agent]!.skippedFiles += 1
            }
        }
        for file in files.dropFirst(limits.maximumFiles) {
            let agent: SessionTimeAgent = file.source == .codex ? .codex : .claude
            stats[agent]!.files += 1
            stats[agent]!.skippedFiles += 1
            stats[agent]!.overLimit = true
        }

        cache = Cache(version: Self.cacheVersion, entries: nextEntries)
        saveCache(cache)

        let historyURL = home.appendingPathComponent(".claude/history.jsonl")
        let allHistory = (try? ClaudePromptHistoryReader.read(historyURL, maximumLineBytes: limits.maximumLineBytes,
                                                              deadline: Date().addingTimeInterval(60))) ?? []
        let history = Self.interactiveHistory(allHistory, scripted: scriptedSessions,
                                              interactive: Set(timelines.filter { $0.agent == .claude && !$0.isSubagent }.map(\.id)))

        let coverage = SessionTimeAgent.allCases.map { agent -> SessionTimeCoverage in
            let stat = stats[agent]!
            var reasons: [String] = []
            if stat.skippedFiles > 0 { reasons.append("\(stat.skippedFiles) files not read") }
            if stat.skippedRecords > 0 { reasons.append("\(stat.skippedRecords) oversized records skipped") }
            if stat.overLimit { reasons.append("scan limit reached") }
            let note = stat.files == 0 ? "No local session files"
                : reasons.isEmpty ? "\(stat.files) files read, \(stat.cached) from cache" : reasons.joined(separator: ", ")
            return SessionTimeCoverage(agent: agent, files: stat.files, cachedFiles: stat.cached, skippedFiles: stat.skippedFiles,
                                       skippedRecords: stat.skippedRecords, partial: !reasons.isEmpty || stat.files == 0, note: note)
        }
        return SessionTimeSnapshot(generatedAt: Date(), timelines: timelines, history: history, coverage: coverage)
    }

    /// Prompt history also records scripted runs. Drop sessions whose transcript is known to be
    /// scripted, and single-prompt sessions with no interactive transcript, which are almost always scripted.
    static func interactiveHistory(_ prompts: [SessionTimeHistoryPrompt], scripted: Set<String>, interactive: Set<String>) -> [SessionTimeHistoryPrompt] {
        let counts = Dictionary(grouping: prompts, by: \.session).mapValues(\.count)
        return prompts.filter { prompt in
            if scripted.contains(prompt.session) { return false }
            return interactive.contains(prompt.session) || (counts[prompt.session] ?? 0) > 1
        }
    }

    // MARK: Files

    private func claudeFiles() -> [(url: URL, source: Source)] {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        var files: [(URL, Source)] = []
        for project in directories(in: root) {
            for entry in contents(of: project) {
                if entry.pathExtension == "jsonl", isRegularFile(entry) {
                    files.append((entry, .claudeMain))
                } else if isDirectory(entry) {
                    let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                    for file in contents(of: subagents) where file.pathExtension == "jsonl" && isRegularFile(file) {
                        files.append((file, .claudeSubagent))
                    }
                }
            }
        }
        return files.map { (url: $0.0, source: $0.1) }
    }

    private func codexFiles() -> [(url: URL, source: Source)] {
        let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        guard !isLink(root), let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) else { return [] }
        var files: [(url: URL, source: Source)] = []
        for case let url as URL in enumerator {
            if isLink(url) { enumerator.skipDescendants(); continue }
            if url.pathExtension == "jsonl", isRegularFile(url) { files.append((url, .codex)) }
        }
        return files
    }

    private func contents(of directory: URL) -> [URL] {
        guard !isLink(directory) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
    }

    private func directories(in root: URL) -> [URL] { contents(of: root).filter(isDirectory) }

    private func isLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
    private func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    // MARK: Cache

    private func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == Self.cacheVersion else {
            return Cache(version: Self.cacheVersion, entries: [:])
        }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    }
}
