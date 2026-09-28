import Foundation

public struct ActivityAnswers: Sendable {
    public let sessions: [UsageSession]
    public let missingDates: Int
    public let missingProjects: Int
    public let input: UInt64
    public let cached: UInt64
    public let output: UInt64
    public let largest: [UsageSession]

    public init(sessions: [UsageSession], runtime: AgentRuntime, folder: String = "", days: Int? = 7, now: Date = Date()) {
        let owned = sessions.filter { $0.agent.caseInsensitiveCompare(runtime.rawValue) == .orderedSame }
        let start = days.map { now.addingTimeInterval(-Double($0) * 86400) }
        let parser = ISO8601DateFormatter()
        func date(_ value: String?) -> Date? {
            guard let value else { return nil }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }
        missingDates = owned.filter { date($0.lastActivity) == nil }.count
        missingProjects = owned.filter { $0.project == nil }.count
        let path = folder.isEmpty ? "" : URL(fileURLWithPath: folder).standardizedFileURL.path
        let selected = owned.filter { session in
            if let start {
                guard let date = date(session.lastActivity), date >= start, date <= now else { return false }
            }
            guard !path.isEmpty else { return true }
            guard let project = session.project, project.hasPrefix("/") else { return false }
            let source = URL(fileURLWithPath: project).standardizedFileURL.path
            return source == path || source.hasPrefix(path + "/")
        }.sorted { ($0.lastActivity ?? "") > ($1.lastActivity ?? "") }
        self.sessions = selected
        func sum(_ value: (UsageTotals) -> UInt64) -> UInt64 {
            selected.reduce(0) { total, session in let (next, overflow) = total.addingReportingOverflow(value(session.totals)); return overflow ? .max : next }
        }
        input = sum(\.inputTokens); cached = sum(\.cacheReadTokens); output = sum(\.outputTokens)
        largest = selected.sorted { $0.totals.totalTokens > $1.totals.totalTokens }.prefix(3).map { $0 }
    }
}
