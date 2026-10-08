import Darwin
import Foundation

public enum SkillActivityEvidence: String, Codable, Sendable {
    case toolCall = "Skill tool call"
    case fileRead = "Skill file read"
    case pathReference = "Skill path in a tool call"
    /// A user-typed Claude `/name` command. The only route for manual-only skills.
    case slashCommand = "Slash command"
    /// A user-typed Codex `$name` mention in a user message (injected catalogs excluded).
    case explicitMention = "Explicit $skill mention"
}

public struct SkillActivityObservation: Codable, Sendable {
    public let name: String
    public let runtime: AgentRuntime
    public let evidence: SkillActivityEvidence
    public let session: String
    public let day: String
    public let project: String?
    public let skillPath: String?
    public let failed: Bool
}

public struct SkillActivityCoverage: Codable, Sendable {
    public let runtime: AgentRuntime
    public let files: Int
    public let partial: Bool
    public let note: String
    public let skippedRecords: Int
    public let unreadableFiles: Int
    /// Earliest and latest modification day (yyyy-MM-dd) of the scanned session files.
    public let firstDay: String?
    public let lastDay: String?

    public init(runtime: AgentRuntime, files: Int, partial: Bool, note: String,
                skippedRecords: Int = 0, unreadableFiles: Int = 0, firstDay: String? = nil, lastDay: String? = nil) {
        self.runtime = runtime
        self.files = files
        self.partial = partial
        self.note = note
        self.skippedRecords = skippedRecords
        self.unreadableFiles = unreadableFiles
        self.firstDay = firstDay
        self.lastDay = lastDay
    }

    public var dayRange: String? {
        guard let firstDay, let lastDay else { return nil }
        return firstDay == lastDay ? firstDay : "\(firstDay) to \(lastDay)"
    }
}

public struct SkillActivitySummary: Sendable {
    public let observations: [SkillActivityObservation]
    public init(observations: [SkillActivityObservation]) { self.observations = observations }
    public var toolCalls: Int { observations.filter { $0.evidence == .toolCall }.count }
    public var failedToolCalls: Int { observations.filter { $0.evidence == .toolCall && $0.failed }.count }
    public var fileReadSessions: Int { Set(observations.filter { $0.evidence == .fileRead }.map { "\($0.runtime.rawValue):\($0.session)" }).count }
    public var pathReferenceSessions: Int { Set(observations.filter { $0.evidence == .pathReference }.map { "\($0.runtime.rawValue):\($0.session)" }).count }
    /// User-typed invocations: Claude slash commands and Codex `$name` mentions.
    public var explicitInvocations: Int { observations.filter { $0.evidence == .slashCommand || $0.evidence == .explicitMention }.count }
    public var lastSeen: String? { observations.map(\.day).filter { !$0.isEmpty }.max() }
    public var isEmpty: Bool { observations.isEmpty }
}

public struct SkillActivitySnapshot: Codable, Sendable {
    public let observations: [SkillActivityObservation]
    public let coverage: [SkillActivityCoverage]
    public let scannedAt: Date

    public init(observations: [SkillActivityObservation], coverage: [SkillActivityCoverage], scannedAt: Date) {
        self.observations = observations
        self.coverage = coverage
        self.scannedAt = scannedAt
    }

    public func summary(for skill: SkillRecord, runtime: AgentRuntime? = nil, folder: String? = nil,
                        sinceDay: String? = nil) -> SkillActivitySummary {
        let names = Set([Self.normalized(skill.name),
                         Self.normalized(URL(fileURLWithPath: skill.id).deletingLastPathComponent().lastPathComponent)])
        let paths = Set(([skill.id] + skill.exposures.flatMap { [$0.logicalPath, $0.resolvedPath] })
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        let selectedFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillActivitySummary(observations: observations.filter { observation in
            guard names.contains(Self.normalized(observation.name)),
                  runtime == nil || runtime == observation.runtime else { return false }
            if let sinceDay, observation.day < sinceDay { return false }
            if let path = observation.skillPath {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                guard paths.contains(resolved) else { return false }
            }
            if let selectedFolder, !selectedFolder.isEmpty {
                guard let project = observation.project else { return false }
                let root = URL(fileURLWithPath: selectedFolder).standardizedFileURL.path
                let actual = URL(fileURLWithPath: project).standardizedFileURL.path
                guard actual == root || actual.hasPrefix(root + "/") else { return false }
            }
            return true
        })
    }

    private static func normalized(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }
}

/// An on-demand, local-only backfill. It reads structured tool metadata from
/// transcripts and retains neither prompts, responses, nor command bodies.
public struct SkillActivityHistory: Sendable {
    public struct Limits: Sendable {
        public var maximumFiles = 12_000
        public var maximumBytes: Int64 = 20_000_000_000
        public var maximumSeconds: TimeInterval = 90
        public var maximumLineBytes = 8_000_000
        public init() {}
    }

    private let home: URL
    private let limits: Limits

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, limits: Limits = .init()) {
        self.home = home
        self.limits = limits
    }

    public func scan() -> SkillActivitySnapshot {
        var reader = Reader(home: home, limits: limits)
        return reader.scan()
    }
}

private struct Reader {
    let home: URL
    let limits: SkillActivityHistory.Limits
    init(home: URL, limits: SkillActivityHistory.Limits) {
        self.home = home
        self.limits = limits
    }
    private let manager = FileManager.default
    private let pathPattern = try! NSRegularExpression(pattern: #"(/[\w .~+@%()\-]+(?:/[\w .~+@%()\-]+)*/skills/([^/\s"'`]+)/SKILL\.md)"#, options: [.caseInsensitive])
    private var observations: [SkillActivityObservation] = []
    private var coverage: [SkillActivityCoverage] = []
    private var seen = Set<String>()
    private var claudeCalls: [String: SkillActivityObservation] = [:]
    private var claudeFailures = Set<String>()
    private var totalFiles = 0
    private var totalBytes: Int64 = 0
    private var deadline: Date { started.addingTimeInterval(limits.maximumSeconds) }
    private let started = Date()

    mutating func scan() -> SkillActivitySnapshot {
        for runtime in AgentRuntime.allCases {
            scan(runtime)
        }
        for (id, call) in claudeCalls {
            record(.init(name: call.name, runtime: .claude, evidence: .toolCall, session: call.session,
                         day: call.day, project: call.project, skillPath: nil, failed: claudeFailures.contains(id)), key: "claude:\(id)")
        }
        return SkillActivitySnapshot(observations: observations, coverage: coverage, scannedAt: Date())
    }

    private mutating func scan(_ runtime: AgentRuntime) {
        let relative: String = switch runtime {
        case .codex: ".codex/sessions"
        case .claude: ".claude/projects"
        case .cursor: ".cursor/projects"
        case .devin: ".local/share/devin/cli/transcripts"
        case .grok: ".grok/sessions"
        }
        let root = home.appendingPathComponent(relative, isDirectory: true)
        guard manager.fileExists(atPath: root.path) else {
            coverage.append(.init(runtime: runtime, files: 0, partial: true, note: "No local history folder"))
            return
        }
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                                                  options: [.skipsPackageDescendants]) else {
            coverage.append(.init(runtime: runtime, files: 0, partial: true, note: "History folder is linked or unreadable"))
            return
        }
        var files = 0
        var firstModified: Date?
        var lastModified: Date?
        var partial = false
        var skippedRecords = 0
        var unreadableFiles = 0
        var limitReached = false
        for case let url as URL in enumerator {
            if Task.isCancelled || Date() >= deadline || totalFiles >= limits.maximumFiles || totalBytes >= limits.maximumBytes {
                partial = true; limitReached = true; break
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else {
                partial = true; unreadableFiles += 1; continue
            }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, accepts(url, runtime: runtime) else { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size >= 0, size <= limits.maximumBytes - totalBytes else { partial = true; limitReached = true; break }
            totalFiles += 1; totalBytes += size; files += 1
            if let modified = values.contentModificationDate {
                firstModified = min(firstModified ?? modified, modified)
                lastModified = max(lastModified ?? modified, modified)
            }
            do {
                if runtime == .devin { try scanDevinFile(url) }
                else {
                    let skipped = try scanLines(url, runtime: runtime)
                    skippedRecords += skipped
                    if skipped > 0 { partial = true }
                }
            } catch { partial = true; unreadableFiles += 1 }
        }
        var reasons: [String] = []
        if skippedRecords > 0 { reasons.append("\(skippedRecords) oversized records skipped") }
        if unreadableFiles > 0 { reasons.append("\(unreadableFiles) files unreadable") }
        if limitReached { reasons.append("scan limit reached") }
        coverage.append(.init(runtime: runtime, files: files, partial: partial,
                              note: partial ? reasons.joined(separator: ", ") : files == 0 ? "No matching local session files" : "Local session files scanned",
                              skippedRecords: skippedRecords, unreadableFiles: unreadableFiles,
                              firstDay: firstModified.map(localDay), lastDay: lastModified.map(localDay)))
    }

    private func accepts(_ url: URL, runtime: AgentRuntime) -> Bool {
        switch runtime {
        case .codex, .claude: url.pathExtension == "jsonl"
        case .cursor: url.pathExtension == "jsonl" && url.path.contains("/agent-transcripts/")
        case .devin: url.pathExtension == "json"
        case .grok: url.pathExtension == "jsonl" && url.lastPathComponent != "prompt_history.jsonl"
        }
    }

    /// Returns the number of oversized lines skipped.
    private mutating func scanLines(_ url: URL, runtime: AgentRuntime) throws -> Int {
        guard let file = fopen(url.path, "rb") else { throw CocoaError(.fileReadNoPermission) }
        defer { fclose(file) }
        var pointer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(pointer) }
        var codexProject: String?
        var codexHeaderLines = 0
        var skippedLines = 0
        var lineNumber = 0
        while Date() < deadline && !Task.isCancelled {
            let count = getline(&pointer, &capacity, file)
            if count < 0 { break }
            lineNumber += 1
            if count > limits.maximumLineBytes { skippedLines += 1; continue }
            guard let pointer else { continue }
            let line = Data(bytesNoCopy: pointer, count: count, deallocator: .none)
            switch runtime {
            case .codex:
                if codexProject == nil && codexHeaderLines < 4 {
                    codexHeaderLines += 1
                    if let row = object(line), string(row["type"]) == "session_meta" {
                        codexProject = string(dict(row["payload"])?["cwd"])
                    }
                }
                if line.range(of: Data("SKILL.md".utf8)) != nil { scanCodex(line, url: url, project: codexProject) }
                if line.range(of: Data("$".utf8)) != nil, line.range(of: Data("\"user\"".utf8)) != nil {
                    scanCodexMentions(line, url: url, project: codexProject, lineNumber: lineNumber)
                }
            case .claude:
                if line.range(of: Data("\"Skill\"".utf8)) != nil || line.range(of: Data("tool_use_id".utf8)) != nil
                    || line.range(of: Data("<command-name>".utf8)) != nil {
                    scanClaude(line, url: url)
                }
            case .cursor, .grok:
                if line.range(of: Data("SKILL.md".utf8)) != nil {
                    if runtime == .cursor { scanCursor(line, url: url) }
                    else { scanGrok(line, url: url) }
                }
            case .devin: break
            }
        }
        if Date() >= deadline || Task.isCancelled { throw CocoaError(.fileReadUnknown) }
        if ferror(file) != 0 { throw CocoaError(.fileReadUnknown) }
        return skippedLines
    }

    private mutating func scanCodex(_ line: Data, url: URL, project: String?) {
        guard let row = object(line), string(row["type"]) == "response_item",
              let payload = dict(row["payload"]), ["function_call", "custom_tool_call"].contains(string(payload["type"]) ?? "") else { return }
        let input = string(payload["arguments"]) ?? string(payload["input"]) ?? ""
        for (path, name) in skillPaths(in: input) {
            let session = url.path
            record(.init(name: name, runtime: .codex, evidence: .pathReference, session: session,
                         day: day(row["timestamp"]), project: project, skillPath: path, failed: false),
                   key: "codex:\(session):\(path)")
        }
    }

    private mutating func scanCodexMentions(_ line: Data, url: URL, project: String?, lineNumber: Int) {
        guard let row = object(line), string(row["type"]) == "response_item", let payload = dict(row["payload"]),
              string(payload["type"]) == "message", string(payload["role"]) == "user",
              let blocks = payload["content"] as? [Any] else { return }
        for case let block as [String: Any] in blocks {
            guard let text = string(block["text"]), !Self.isInjectedCodexContext(text) else { continue }
            for name in Self.dollarMentions(in: text) {
                record(.init(name: name, runtime: .codex, evidence: .explicitMention, session: url.path,
                             day: day(row["timestamp"]), project: project, skillPath: nil, failed: false),
                       key: "codex-mention:\(url.path):\(lineNumber):\(name)")
            }
        }
    }

    /// Codex injects the skill catalog, AGENTS.md and environment blocks as user-role text.
    static func isInjectedCodexContext(_ text: String) -> Bool {
        ["<skills_instructions>", "AGENTS.md instructions", "<environment_context>", "<user_instructions>",
         "<permissions instructions>", "<INSTRUCTIONS>"].contains { text.contains($0) }
    }

    static func dollarMentions(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"(?<![\w$])\$([a-z][a-z0-9_-]{1,63}(?::[a-z][a-z0-9_-]{1,63})?)(?![\w-])"#)
        let range = NSRange(text.startIndex..., in: text)
        var names: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange].split(separator: ":").last ?? "")
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    static func slashCommands(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"<command-name>/?([A-Za-z0-9][A-Za-z0-9:_.-]{0,120})</command-name>"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let name = text[nameRange].split(separator: ":").last, !name.isEmpty else { return nil }
            return String(name)
        }
    }

    private mutating func scanClaude(_ line: Data, url: URL) {
        guard let row = object(line), let message = dict(row["message"]) else { return }
        let type = string(row["type"])
        if type == "user" {
            let texts = (message["content"] as? String).map { [$0] }
                ?? ((message["content"] as? [Any]) ?? []).compactMap { dict($0).flatMap { string($0["type"]) == "text" ? string($0["text"]) : nil } }
            let session = string(row["sessionId"]) ?? url.path
            for (index, text) in texts.enumerated() where text.contains("<command-name>") {
                for name in Self.slashCommands(in: text) {
                    record(.init(name: name, runtime: .claude, evidence: .slashCommand, session: session,
                                 day: day(row["timestamp"]), project: string(row["cwd"]), skillPath: nil, failed: false),
                           key: "claude-command:\(session):\(string(row["uuid"]) ?? string(row["timestamp"]) ?? url.path):\(index):\(name)")
                }
            }
        }
        guard let blocks = message["content"] as? [Any] else { return }
        for value in blocks {
            guard let block = dict(value) else { continue }
            if type == "assistant", string(block["type"]) == "tool_use", string(block["name"]) == "Skill",
               let id = string(block["id"]), let input = dict(block["input"]), let name = skillName(string(input["skill"])) {
                claudeCalls[id] = .init(name: name, runtime: .claude, evidence: .toolCall,
                                        session: string(row["sessionId"]) ?? url.path, day: day(row["timestamp"]),
                                        project: string(row["cwd"]), skillPath: nil, failed: false)
            } else if type == "user", string(block["type"]) == "tool_result", string(block["tool_use_id"]) != nil,
                      block["is_error"] as? Bool == true, let id = string(block["tool_use_id"]) {
                claudeFailures.insert(id)
            }
        }
    }

    private mutating func scanDevinFile(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 32_000_000, let root = object(data), let steps = root["steps"] as? [Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let session = string(root["session_id"]) ?? url.path
        for value in steps {
            guard let step = dict(value), let calls = step["tool_calls"] as? [Any] else { continue }
            for item in calls {
                guard let call = dict(item), string(call["function_name"]) == "skill",
                      let arguments = dict(call["arguments"]), let name = skillName(string(arguments["skill"])) else { continue }
                let id = string(call["tool_call_id"]) ?? "\(session):\(string(step["step_id"]) ?? ""):\(name)"
                record(.init(name: name, runtime: .devin, evidence: .toolCall, session: session,
                             day: day(step["timestamp"]), project: nil, skillPath: nil, failed: false), key: "devin:\(id)")
            }
        }
    }

    private mutating func scanCursor(_ line: Data, url: URL) {
        guard let row = object(line), let message = dict(row["message"]), let blocks = message["content"] as? [Any] else { return }
        for value in blocks {
            guard let block = dict(value), string(block["type"]) == "tool_use", string(block["name"]) == "Read",
                  let input = dict(block["input"]) else { continue }
            for candidate in input.values.compactMap(string) {
                for (path, name) in skillPaths(in: candidate) {
                    let session = url.path
                    record(.init(name: name, runtime: .cursor, evidence: .fileRead, session: session,
                                 day: fileDay(url), project: nil, skillPath: path, failed: false),
                           key: "cursor:\(session):\(path)")
                }
            }
        }
    }

    private mutating func scanGrok(_ line: Data, url: URL) {
        guard let row = object(line), let params = dict(row["params"]), let update = dict(params["update"]),
              let metadata = dict(update["_meta"]), let tool = dict(metadata["x.ai/tool"]),
              string(tool["name"]) == "read_file", let input = dict(update["rawInput"]) else { return }
        let session = string(params["sessionId"]) ?? url.path
        for candidate in input.values.compactMap(string) {
            for (path, name) in skillPaths(in: candidate) {
                let id = string(update["toolCallId"]) ?? path
                record(.init(name: name, runtime: .grok, evidence: .fileRead, session: session,
                             day: day(row["timestamp"]), project: nil, skillPath: path, failed: false),
                       key: "grok:\(session):\(id)")
            }
        }
    }

    private mutating func record(_ observation: SkillActivityObservation, key: String) {
        if seen.insert(key).inserted { observations.append(observation) }
    }

    private func skillPaths(in text: String) -> [(String, String)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pathPattern.matches(in: text, range: range).compactMap { match in
            guard let pathRange = Range(match.range(at: 1), in: text), let nameRange = Range(match.range(at: 2), in: text) else { return nil }
            let path = String(text[pathRange])
            guard path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
            return (path, String(text[nameRange]))
        }
    }

    private func skillName(_ value: String?) -> String? {
        guard let value, let name = value.split(separator: ":").last, !name.isEmpty, name.utf8.count <= 120 else { return nil }
        return String(name)
    }

    private func day(_ value: Any?) -> String {
        if let text = string(value), text.count >= 10, text[text.index(text.startIndex, offsetBy: 4)] == "-" {
            return String(text.prefix(10))
        }
        if let number = value as? NSNumber {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date(timeIntervalSince1970: number.doubleValue))
        }
        return ""
    }

    private func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func fileDay(_ url: URL) -> String {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func object(_ data: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return value as? [String: Any]
    }
    private func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private func string(_ value: Any?) -> String? { value as? String }
}
