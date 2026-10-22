import Foundation

/// Agents whose local transcripts carry enough timing to rebuild a session timeline.
public enum SessionTimeAgent: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    public var id: String { rawValue }
}

/// What a stretch of session time was spent on. Derived from event types and
/// command text read in memory; the text itself is never retained.
public enum SessionTimeActivity: String, Codable, CaseIterable, Sendable {
    case model, compaction
    case replyUnderMinute, replyFewMinutes, replyHalfHour, replyLong, answeringQuestion, interrupting, midTurnInput
    case ciWait, ciLogs, ciRerun, deployCheck
    case unitTests, e2e, lintFormat, buildCodegen, install, localStack, database
    case git, github, browser, scripts, shellRead, shellOther, sleepPoll, longExec, fileOps, web, mcp
    case subagents, agentCoordination, otherTool

    public var group: SessionTimeGroup {
        switch self {
        case .model, .compaction: .model
        case .replyUnderMinute, .replyFewMinutes, .replyHalfHour, .replyLong, .answeringQuestion, .interrupting, .midTurnInput: .you
        case .ciWait, .ciLogs, .ciRerun, .deployCheck: .ciCD
        case .unitTests, .e2e, .lintFormat, .buildCodegen, .install, .localStack, .database: .localRuns
        case .subagents, .agentCoordination: .subagents
        default: .otherTools
        }
    }

    public var title: String {
        switch self {
        case .model: "Model generating"
        case .compaction: "Context compaction"
        case .replyUnderMinute: "Replied within a minute"
        case .replyFewMinutes: "Replied in 1–5 min"
        case .replyHalfHour: "Replied in 5–30 min"
        case .replyLong: "Replied after 30 min – 2 h"
        case .answeringQuestion: "Answering a question or plan"
        case .interrupting: "Interrupting"
        case .midTurnInput: "Typing during a turn"
        case .ciWait: "Waiting on CI checks"
        case .ciLogs: "Reading CI status and logs"
        case .ciRerun: "Rerunning CI"
        case .deployCheck: "Deploy checks"
        case .unitTests: "Unit tests"
        case .e2e: "E2E and device runs"
        case .lintFormat: "Lint, typecheck, format"
        case .buildCodegen: "Build and codegen"
        case .install: "Installs"
        case .localStack: "Local stack and servers"
        case .database: "Database"
        case .git: "git"
        case .github: "GitHub (other)"
        case .browser: "Browser"
        case .scripts: "Scripts"
        case .shellRead: "Shell reads and searches"
        case .shellOther: "Other shell"
        case .sleepPoll: "Sleeping and polling"
        case .longExec: "Long-running commands"
        case .fileOps: "File reads and edits"
        case .web: "Web"
        case .mcp: "MCP tools"
        case .subagents: "Subagents"
        case .agentCoordination: "Agent messages and wake-ups"
        case .otherTool: "Other tools"
        }
    }
}

public enum SessionTimeGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case localRuns, ciCD, model, subagents, otherTools, you
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .localRuns: "Local tests, builds, stack"
        case .ciCD: "CI/CD"
        case .model: "Model thinking and writing"
        case .subagents: "Waiting on subagents"
        case .otherTools: "Other tools"
        case .you: "Waiting on you"
        }
    }
    /// Groups that block on machines rather than on the model or the person.
    public var isBlockingRun: Bool { self == .localRuns || self == .ciCD }
}

/// The single state a session is in, used for the shared-clock view.
/// Priority when several sessions overlap: working, then waiting on you, then CI, then background.
public enum SessionTimeState: String, Codable, CaseIterable, Sendable, Identifiable {
    case working, waitingOnYou, ciOnly, backgroundOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .working: "Claude or Codex working"
        case .waitingOnYou: "Waiting on you"
        case .ciOnly: "Waiting on CI/CD only"
        case .backgroundOnly: "Waiting on background agents only"
        }
    }
}

public struct SessionTimeInterval: Sendable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    public var activity: SessionTimeActivity
    /// Idle time while a background task (subagent, background command, monitor) ran.
    public var background: Bool

    public init(start: Double, end: Double, activity: SessionTimeActivity, background: Bool = false) {
        self.start = start
        self.end = end
        self.activity = activity
        self.background = background
    }

    public var duration: Double { max(0, end - start) }

    public var state: SessionTimeState {
        switch activity.group {
        case .you: .waitingOnYou
        case .ciCD: .ciOnly
        default: background ? .backgroundOnly : .working
        }
    }
}

extension SessionTimeInterval: Codable {
    // Compact array form keeps the per-file cache small.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        start = try container.decode(Double.self)
        end = try container.decode(Double.self)
        activity = try container.decode(SessionTimeActivity.self)
        background = try container.decode(Bool.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(start)
        try container.encode(end)
        try container.encode(activity)
        try container.encode(background)
    }
}

public enum SessionTimeSignalKind: String, Codable, CaseIterable, Sendable {
    /// From a CI result that reported a failure to the next git operation in the same turn.
    case ciFixCycle
    /// A turn ended saying CI was still running, and the session then waited on the person.
    case ciHandBack
    case commandTimeout, interrupt, toolError, compaction
}

public struct SessionTimeSignal: Codable, Sendable, Equatable {
    public var time: Double
    public var kind: SessionTimeSignalKind
    public var seconds: Double

    public init(time: Double, kind: SessionTimeSignalKind, seconds: Double = 0) {
        self.time = time
        self.kind = kind
        self.seconds = seconds
    }
}

/// One session's rebuilt timeline. Holds durations, categories and counts only.
public struct SessionTimeline: Codable, Sendable, Equatable {
    public var id: String
    public var agent: SessionTimeAgent
    public var folder: String?
    public var isSubagent: Bool
    public var intervals: [SessionTimeInterval]
    public var prompts: [Double]
    public var signals: [SessionTimeSignal]

    public init(id: String, agent: SessionTimeAgent, folder: String?, isSubagent: Bool,
                intervals: [SessionTimeInterval], prompts: [Double], signals: [SessionTimeSignal]) {
        self.id = id
        self.agent = agent
        self.folder = folder
        self.isSubagent = isSubagent
        self.intervals = intervals
        self.prompts = prompts
        self.signals = signals
    }
}

/// A prompt recorded in Claude Code's prompt history. Only time, folder and session are kept.
public struct SessionTimeHistoryPrompt: Codable, Sendable, Equatable {
    public var time: Double
    public var folder: String
    public var session: String

    public init(time: Double, folder: String, session: String) {
        self.time = time
        self.folder = folder
        self.session = session
    }
}

public struct SessionTimeCoverage: Codable, Sendable, Equatable {
    public var agent: SessionTimeAgent
    public var files: Int
    public var cachedFiles: Int
    public var skippedFiles: Int
    public var skippedRecords: Int
    public var partial: Bool
    public var note: String
}

public struct SessionTimeSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var timelines: [SessionTimeline]
    public var history: [SessionTimeHistoryPrompt]
    public var coverage: [SessionTimeCoverage]

    public init(generatedAt: Date, timelines: [SessionTimeline], history: [SessionTimeHistoryPrompt], coverage: [SessionTimeCoverage]) {
        self.generatedAt = generatedAt
        self.timelines = timelines
        self.history = history
        self.coverage = coverage
    }

    public static let empty = SessionTimeSnapshot(generatedAt: .distantPast, timelines: [], history: [], coverage: [])
}

/// Thresholds shared by the readers.
public enum SessionTimeRules {
    /// A gap longer than this means the person was away, not being waited on.
    public static let awayAfter: TimeInterval = 2 * 60 * 60
    /// The person counts as active within this window after any prompt.
    public static let activeWindow: TimeInterval = 15 * 60
    /// Prompt-history sessions count as live for this long after each prompt.
    public static let historyLiveWindow: TimeInterval = 30 * 60

    static func replyActivity(after gap: TimeInterval) -> SessionTimeActivity {
        if gap < 60 { return .replyUnderMinute }
        if gap < 300 { return .replyFewMinutes }
        if gap < 1800 { return .replyHalfHour }
        return .replyLong
    }
}
