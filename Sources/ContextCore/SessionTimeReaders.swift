import Foundation

/// Reads one JSONL file line by line, skipping lines over the byte limit.
enum SessionTimeLines {
    struct Deadline: Error {}

    /// Returns the number of oversized lines skipped.
    static func read(_ url: URL, maximumLineBytes: Int, deadline: Date, _ body: (Data) -> Bool) throws -> Int {
        guard let file = fopen(url.path, "rb") else { throw CocoaError(.fileReadNoPermission) }
        defer { fclose(file) }
        var pointer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(pointer) }
        var skipped = 0
        while true {
            if Date() >= deadline || Task.isCancelled { throw Deadline() }
            let count = getline(&pointer, &capacity, file)
            if count < 0 { break }
            if count > maximumLineBytes { skipped += 1; continue }
            guard let pointer else { continue }
            if !body(Data(bytesNoCopy: pointer, count: count, deallocator: .none)) { break }
        }
        if ferror(file) != 0 { throw CocoaError(.fileReadUnknown) }
        return skipped
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Parses `2026-09-29T07:19:26.967Z` without a formatter.
    static func timestamp(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count >= 19 else { return nil }
        func number(_ from: Int, _ length: Int) -> Int? {
            var result = 0
            for index in from..<(from + length) {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) else { return nil }
        var fraction = 0.0
        var index = 19
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            var scale = 0.1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        if index + 6 <= bytes.count, bytes[index] == 43 || bytes[index] == 45,
           let hours = number(index + 1, 2), let minutes = number(index + 4, 2) {
            offset = (hours * 3600 + minutes * 60) * (bytes[index] == 43 ? 1 : -1)
        }
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = Int32(second)
        return Double(timegm(&parts) - offset) + fraction
    }

    static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

// MARK: - Claude

/// Rebuilds a Claude Code session from its transcript. Only interactive sessions
/// (`entrypoint` "cli") are returned.
struct ClaudeSessionTimeReader {
    private enum Event {
        case assistant(toolUses: [String], ended: Bool, replyTail: String)
        case result(id: String, isError: Bool, timedOut: Bool, failure: Bool)
        case notification(toolUse: String?)
        case compact, compactSummary, interrupt, meta, agentMessage, human
    }

    private struct Tool {
        var activity: SessionTimeActivity
        var background: Bool
        var isMonitor: Bool
    }

    let url: URL
    let isSubagent: Bool
    let maximumLineBytes: Int
    let deadline: Date
    /// The session id of a non-interactive transcript, so prompt history can drop its prompts.
    private(set) var scriptedSession: String?

    mutating func read() throws -> (SessionTimeline?, skipped: Int) {
        var events: [(Double, Event)] = []
        var tools: [String: Tool] = [:]
        var seen = Set<String>()
        var entrypoint: String?
        var folder: String?
        var session: String?

        let skipped = try SessionTimeLines.read(url, maximumLineBytes: maximumLineBytes, deadline: deadline) { line in
            guard let row = SessionTimeLines.object(line) else { return true }
            if entrypoint == nil { entrypoint = row["entrypoint"] as? String }
            if folder == nil { folder = row["cwd"] as? String }
            if session == nil { session = row["sessionId"] as? String }
            let type = row["type"] as? String
            if type == "system" {
                if row["subtype"] as? String == "compact_boundary", let time = SessionTimeLines.timestamp(row["timestamp"]) {
                    events.append((time, .compact))
                }
                return true
            }
            guard type == "user" || type == "assistant", let time = SessionTimeLines.timestamp(row["timestamp"]) else { return true }
            if !isSubagent, row["isSidechain"] as? Bool == true { return true }
            if let uuid = row["uuid"] as? String, !seen.insert(uuid).inserted { return true }
            let message = row["message"] as? [String: Any] ?? [:]
            let content = message["content"]

            if type == "assistant" {
                var uses: [String] = []
                var reply = ""
                for block in content as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        tools[id] = Self.tool(name: name, input: input)
                        uses.append(id)
                    case "text":
                        reply += block["text"] as? String ?? ""
                    default: break
                    }
                }
                let stop = message["stop_reason"] as? String
                let ended = uses.isEmpty && (stop == nil || stop == "end_turn" || stop == "stop_sequence")
                events.append((time, .assistant(toolUses: uses, ended: ended, replyTail: String(reply.suffix(300)))))
                return true
            }

            if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                let result = row["toolUseResult"] as? [String: Any] ?? [:]
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    let activity = tools[id]?.activity
                    let failure = (activity == .ciWait || activity == .ciLogs)
                        && SessionCommandClassifier.reportsFailure(SessionTimeLines.text(block["content"]))
                    events.append((time, .result(id: id, isError: block["is_error"] as? Bool == true,
                                                 timedOut: result["timedOutAfterMs"] != nil, failure: failure)))
                }
                return true
            }

            let text = SessionTimeLines.text(content)
            if text.contains("<task-notification>") {
                let id = text.range(of: "<tool-use-id>").flatMap { start in
                    text.range(of: "</tool-use-id>", range: start.upperBound..<text.endIndex).map { String(text[start.upperBound..<$0.lowerBound]) }
                }
                events.append((time, .notification(toolUse: id)))
            } else if text.hasPrefix("This session is being continued") || row["isCompactSummary"] as? Bool == true {
                events.append((time, .compactSummary))
            } else if text.hasPrefix("[Request interrupted") {
                events.append((time, .interrupt))
            } else if row["isMeta"] as? Bool == true || text.hasPrefix("<local-command") || text.hasPrefix("<system-reminder") || text.hasPrefix("Caveat:") {
                events.append((time, .meta))
            } else if text.contains("<agent-message") || text.hasPrefix("Another Claude session") || text.contains("<teammate-message") {
                events.append((time, .agentMessage))
            } else {
                events.append((time, .human))
            }
            return true
        }

        guard entrypoint == "cli", !events.isEmpty else {
            scriptedSession = isSubagent ? nil : session
            return (nil, skipped)
        }
        let id = session.map { isSubagent ? "\($0)/\(url.deletingPathExtension().lastPathComponent)" : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let timeline = attribute(events: events.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element),
                                 tools: tools, id: id, folder: folder)
        return (timeline, skipped)
    }

    private static func tool(name: String, input: [String: Any]) -> Tool {
        let background = input["run_in_background"] as? Bool == true
        switch name {
        case "Bash":
            return Tool(activity: SessionCommandClassifier.classify(input["command"] as? String ?? ""), background: background, isMonitor: false)
        case "Monitor":
            return Tool(activity: SessionCommandClassifier.classify(input["command"] as? String ?? ""), background: true, isMonitor: true)
        case "Read", "Edit", "Write", "Grep", "Glob", "NotebookEdit", "MultiEdit":
            return Tool(activity: .fileOps, background: false, isMonitor: false)
        case "Agent", "Task":
            return Tool(activity: .subagents, background: background, isMonitor: false)
        case "AskUserQuestion", "ExitPlanMode":
            return Tool(activity: .answeringQuestion, background: false, isMonitor: false)
        case "WebFetch", "WebSearch":
            return Tool(activity: .web, background: false, isMonitor: false)
        case "ScheduleWakeup", "SendMessage", "TaskStop", "TaskOutput", "ListAgents":
            return Tool(activity: .agentCoordination, background: false, isMonitor: false)
        default:
            return Tool(activity: name.hasPrefix("mcp__") ? .mcp : .otherTool, background: background, isMonitor: false)
        }
    }

    private func attribute(events: [(Double, Event)], tools: [String: Tool], id: String, folder: String?) -> SessionTimeline {
        var intervals: [SessionTimeInterval] = []
        var prompts: [Double] = []
        var signals: [SessionTimeSignal] = []
        var idle = false
        var replyTail = ""
        var lastMonitor: SessionTimeActivity = .otherTool
        var pendingFailure: Double?

        func add(_ start: Double, _ end: Double, _ activity: SessionTimeActivity, background: Bool = false) {
            guard end > start else { return }
            intervals.append(.init(start: start, end: end, activity: activity, background: background))
        }

        if let first = events.first, case .human = first.1 { prompts.append(first.0) }
        for index in 1..<max(events.count, 1) {
            let (start, previous) = events[index - 1]
            let (time, event) = events[index]
            let gap = max(0, time - start)
            if case let .assistant(_, ended, tail) = previous {
                idle = ended
                replyTail = tail
            }
            let previousIsQuiet: Bool = switch previous {
            case .human, .meta, .compactSummary, .interrupt: true
            default: false
            }
            switch event {
            case .assistant:
                add(start, time, .model)
            case let .result(toolID, isError, timedOut, failure):
                let tool = tools[toolID] ?? Tool(activity: .otherTool, background: false, isMonitor: false)
                if tool.background {
                    add(start, time, .otherTool)
                    if tool.isMonitor { lastMonitor = tool.activity }
                } else {
                    add(start, time, tool.activity)
                }
                if timedOut { signals.append(.init(time: time, kind: .commandTimeout, seconds: gap)) }
                if isError { signals.append(.init(time: time, kind: .toolError)) }
                if failure, pendingFailure == nil { pendingFailure = time }
                if tool.activity == .git, let failed = pendingFailure {
                    if time - failed < 3 * 3600 { signals.append(.init(time: time, kind: .ciFixCycle, seconds: time - failed)) }
                    pendingFailure = nil
                }
            case .human:
                prompts.append(time)
                pendingFailure = nil
                if idle || previousIsQuiet {
                    if gap <= SessionTimeRules.awayAfter {
                        add(start, time, SessionTimeRules.replyActivity(after: gap))
                        if case .assistant = previous, gap > 0, SessionCommandClassifier.mentionsPendingCI(replyTail) {
                            signals.append(.init(time: time, kind: .ciHandBack, seconds: gap))
                        }
                    }
                } else {
                    add(start, time, .midTurnInput)
                }
            case let .notification(toolID):
                let activity = toolID.flatMap { tools[$0]?.activity } ?? lastMonitor
                if idle {
                    if gap <= SessionTimeRules.awayAfter { add(start, time, activity, background: true) }
                } else {
                    add(start, time, .otherTool)
                }
            case .compact, .compactSummary:
                if case .compact = event { signals.append(.init(time: time, kind: .compaction)) }
                if idle {
                    if gap <= SessionTimeRules.awayAfter { add(start, time, SessionTimeRules.replyActivity(after: gap)) }
                } else {
                    add(start, time, .compaction)
                }
            case .interrupt:
                add(start, time, .interrupting)
                signals.append(.init(time: time, kind: .interrupt))
            case .agentMessage:
                if idle {
                    if gap <= SessionTimeRules.awayAfter { add(start, time, .agentCoordination, background: true) }
                } else {
                    add(start, time, .otherTool)
                }
            case .meta:
                if idle {
                    if gap <= SessionTimeRules.awayAfter { add(start, time, .replyUnderMinute) }
                } else {
                    add(start, time, .otherTool)
                }
            }
        }
        return SessionTimeline(id: id, agent: .claude, folder: folder, isSubagent: isSubagent,
                               intervals: intervals, prompts: prompts, signals: signals)
    }
}

// MARK: - Codex

/// Rebuilds an interactive Codex CLI session from its rollout file. Scripted
/// `codex exec` runs are not sessions anyone waited on and are skipped.
struct CodexSessionTimeReader {
    let url: URL
    let maximumLineBytes: Int
    let deadline: Date

    private struct Turn {
        var start: Double
        var end: Double?
        var fromPerson: Bool
    }

    func read() throws -> (SessionTimeline?, skipped: Int) {
        var interactive: Bool?
        var isSubagent = false
        var folder: String?
        var session: String?
        var turns: [String: Turn] = [:]
        var turnOrder: [String] = []
        var calls: [String: (start: Double, activity: SessionTimeActivity)] = [:]
        var tools: [(start: Double, end: Double, activity: SessionTimeActivity, failure: Bool)] = []
        var lastTime = 0.0
        var ownStart = 0.0

        let skipped = try SessionTimeLines.read(url, maximumLineBytes: maximumLineBytes, deadline: deadline) { line in
            guard let row = SessionTimeLines.object(line) else { return true }
            let payload = row["payload"] as? [String: Any] ?? [:]
            let type = row["type"] as? String
            if type == "session_meta" {
                // A forked thread replays its parent's metadata and turns after its own;
                // the first record describes this file, and earlier events belong to the parent.
                guard interactive == nil else { return true }
                ownStart = SessionTimeLines.timestamp(row["timestamp"]) ?? SessionTimeLines.timestamp(payload["timestamp"]) ?? 0
                folder = payload["cwd"] as? String
                session = payload["id"] as? String
                let tui = payload["originator"] as? String == "codex-tui"
                if let source = payload["source"] as? String {
                    interactive = tui && source == "cli"
                } else if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                    interactive = tui
                    isSubagent = true
                } else {
                    interactive = false
                }
                return interactive == true
            }
            guard let time = SessionTimeLines.timestamp(row["timestamp"]), time >= ownStart else { return true }
            lastTime = max(lastTime, time)
            let kind = payload["type"] as? String
            switch (type, kind) {
            case ("event_msg", "task_started"):
                guard let id = payload["turn_id"] as? String else { break }
                let trigger = (payload["turn_attribution"] as? [String: Any])?["turn_trigger"] as? String
                turns[id] = Turn(start: time, end: nil, fromPerson: trigger == "user")
                turnOrder.append(id)
            case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
                if let id = payload["turn_id"] as? String, turns[id] != nil { turns[id]?.end = time }
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"), ("response_item", "local_shell_call"):
                guard let id = payload["call_id"] as? String else { break }
                let name = payload["name"] as? String ?? ""
                let input = payload["input"] as? String ?? payload["arguments"] as? String ?? String(describing: payload["action"] ?? "")
                calls[id] = (time, Self.activity(name: name, input: input))
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                guard let id = payload["call_id"] as? String, let call = calls.removeValue(forKey: id) else { break }
                let failure = (call.activity == .ciWait || call.activity == .ciLogs)
                    && SessionCommandClassifier.reportsFailure(SessionTimeLines.text(payload["output"]))
                tools.append((call.start, time, call.activity, failure))
            default: break
            }
            return true
        }
        guard interactive == true else { return (nil, skipped) }

        let ordered = turnOrder.compactMap { turns[$0] }.sorted { $0.start < $1.start }
        tools.sort { $0.start < $1.start }
        var intervals: [SessionTimeInterval] = []
        var signals: [SessionTimeSignal] = []
        var pendingFailure: Double?
        var firstTool = 0
        for (index, turn) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].start : lastTime
            let end = min(turn.end ?? next, max(next, turn.start))
            var cursor = turn.start
            while firstTool < tools.count, tools[firstTool].end <= turn.start { firstTool += 1 }
            var toolIndex = firstTool
            while toolIndex < tools.count, tools[toolIndex].start < end {
                let tool = tools[toolIndex]
                toolIndex += 1
                guard tool.end > turn.start else { continue }
                let from = max(tool.start, turn.start), to = min(tool.end, end)
                if from > cursor { intervals.append(.init(start: cursor, end: from, activity: .model)) }
                let begin = max(cursor, from)
                if to > begin {
                    intervals.append(.init(start: begin, end: to, activity: tool.activity, background: tool.activity == .subagents))
                }
                cursor = max(cursor, to)
                if tool.failure, pendingFailure == nil { pendingFailure = tool.end }
                if tool.activity == .git, let failed = pendingFailure {
                    if tool.end - failed < 3 * 3600 { signals.append(.init(time: tool.end, kind: .ciFixCycle, seconds: tool.end - failed)) }
                    pendingFailure = nil
                }
            }
            if end > cursor { intervals.append(.init(start: cursor, end: end, activity: .model)) }
            guard index + 1 < ordered.count else { continue }
            let following = ordered[index + 1]
            let gap = following.start - end
            if following.fromPerson { pendingFailure = nil }
            guard gap > 0, gap <= SessionTimeRules.awayAfter else { continue }
            intervals.append(following.fromPerson
                ? .init(start: end, end: following.start, activity: SessionTimeRules.replyActivity(after: gap))
                : .init(start: end, end: following.start, activity: .agentCoordination, background: true))
        }
        let prompts = ordered.filter(\.fromPerson).map(\.start)
        let id = session ?? url.deletingPathExtension().lastPathComponent
        return (SessionTimeline(id: id, agent: .codex, folder: folder, isSubagent: isSubagent,
                                intervals: intervals, prompts: prompts, signals: signals), skipped)
    }

    private static func activity(name: String, input: String) -> SessionTimeActivity {
        switch name {
        case "exec", "shell", "exec_command", "": SessionCommandClassifier.classify(input)
        case "js": .browser
        case "wait_agent", "send_message", "spawn_agent", "followup_task", "list_agents", "interrupt_agent": .subagents
        case "sleep": .sleepPoll
        case "wait": .longExec
        case "apply_patch": .fileOps
        default: name.hasPrefix("request_user_input") ? .answeringQuestion : .otherTool
        }
    }
}

// MARK: - Prompt history

/// Reads `~/.claude/history.jsonl`, which outlives transcripts. Keeps time, folder and session only.
enum ClaudePromptHistoryReader {
    static func read(_ url: URL, maximumLineBytes: Int, deadline: Date) throws -> [SessionTimeHistoryPrompt] {
        var prompts: [SessionTimeHistoryPrompt] = []
        _ = try SessionTimeLines.read(url, maximumLineBytes: maximumLineBytes, deadline: deadline) { line in
            guard let row = SessionTimeLines.object(line), let raw = row["timestamp"] as? Double,
                  let folder = row["project"] as? String else { return true }
            let time = raw > 1e12 ? raw / 1000 : raw
            prompts.append(.init(time: time, folder: folder, session: row["sessionId"] as? String ?? folder))
            return true
        }
        return prompts.sorted { $0.time < $1.time }
    }
}
