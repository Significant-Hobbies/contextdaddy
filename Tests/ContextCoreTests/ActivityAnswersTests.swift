import Foundation
import Testing
@testable import ContextCore

struct ActivityAnswersTests {
    @Test func filtersAgentFolderBoundaryAndDatesWithoutChangingSessionTotals() throws {
        let totals = UsageTotals(inputTokens: 10, cacheCreationTokens: 2, cacheReadTokens: 20, outputTokens: 3, totalTokens: 35, costUSD: 0)
        func session(_ id: String, agent: String = "codex", project: String?, date: String?) -> UsageSession {
            UsageSession(sessionID: id, agent: agent, lastActivity: date, project: project, reasoningOutputTokens: 0, totals: totals, models: [])
        }
        let sessions = [session("included", project: "/work/app/src", date: "2026-09-26T12:00:00Z"),
                        session("sibling", project: "/work/app-other", date: "2026-09-26T12:00:00Z"),
                        session("other-agent", agent: "claude", project: "/work/app", date: "2026-09-26T12:00:00Z"),
                        session("undated", project: "/work/app", date: nil),
                        session("unattributed", project: nil, date: "2026-09-26T12:00:00Z"),
                        session("old", project: "/work/app", date: "2026-08-01T12:00:00Z")]
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z"))
        let result = ActivityAnswers(sessions: sessions, runtime: .codex, folder: "/work/app", days: 7, now: now)
        #expect(result.sessions.map(\.sessionID) == ["included"])
        #expect(result.input == 10 && result.cached == 20 && result.output == 3)
        #expect(result.missingDates == 1 && result.missingProjects == 1)
        #expect(ActivityAnswers(sessions: sessions, runtime: .codex, days: nil, now: now).sessions.count == 5)
    }
}
