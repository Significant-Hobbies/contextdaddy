import ContextCore
import Foundation

enum SessionTimeAgentChoice: String, CaseIterable, Identifiable {
    case all = "All agents"
    case claude = "Claude"
    case codex = "Codex"
    var id: String { rawValue }
    var agents: Set<SessionTimeAgent> {
        switch self {
        case .all: Set(SessionTimeAgent.allCases)
        case .claude: [.claude]
        case .codex: [.codex]
        }
    }
}

enum SessionTimeRange: String, CaseIterable, Identifiable {
    case week, month, quarter, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .quarter: "Last 90 days"
        case .all: "All available"
        }
    }
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }
}

extension ContextDaddyModel {
    var sessionTimeZone: TimeZone { TimeZone(identifier: sessionTimeZoneID) ?? .current }

    var sessionTimeFilter: SessionTimeFilter {
        let zone = sessionTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = sessionTimeRange.days.flatMap { calendar.date(byAdding: .day, value: -($0 - 1), to: calendar.startOfDay(for: Date())) }
        return SessionTimeFilter(agents: sessionTimeAgent.agents, workspace: sessionTimeWorkspace.isEmpty ? nil : sessionTimeWorkspace,
                                 start: start, end: nil, timeZone: zone, scale: sessionTimeScale)
    }

    /// Reads every local session. Unchanged files come from the per-file cache.
    func refreshSessionTime() async {
        guard !isSessionTimeLoading else { return }
        isSessionTimeLoading = true
        sessionTimeFilesRead = 0
        sessionTimeFilesTotal = 0
        let snapshot = await Task.detached(priority: .utility) { [weak self] in
            SessionTimeScanner().scan { done, total in
                guard done % 20 == 0 || done == total else { return }
                Task { @MainActor in
                    self?.sessionTimeFilesRead = done
                    self?.sessionTimeFilesTotal = total
                }
            }
        }.value
        sessionTimeSnapshot = snapshot
        isSessionTimeLoading = false
        rebuildSessionTimeReport()
    }

    func rebuildSessionTimeReport() {
        guard let snapshot = sessionTimeSnapshot else { return }
        let filter = sessionTimeFilter
        sessionTimeBuild?.cancel()
        sessionTimeBuild = Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { SessionTimeReport.build(snapshot: snapshot, filter: filter) }.value
            guard !Task.isCancelled, let self, self.sessionTimeFilter == filter else { return }
            self.sessionTimeReport = report
        }
    }
}
