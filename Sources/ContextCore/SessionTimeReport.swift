import Foundation

public enum SessionTimeScale: String, CaseIterable, Sendable, Identifiable {
    case day, week
    public var id: String { rawValue }
}

public struct SessionTimeFilter: Sendable, Equatable {
    public var agents: Set<SessionTimeAgent>
    /// A workspace key from `SessionTimeWorkspace.key`; nil means every folder.
    public var workspace: String?
    public var start: Date?
    public var end: Date?
    public var timeZone: TimeZone
    public var scale: SessionTimeScale

    public init(agents: Set<SessionTimeAgent> = Set(SessionTimeAgent.allCases), workspace: String? = nil,
                start: Date? = nil, end: Date? = nil, timeZone: TimeZone = .current, scale: SessionTimeScale = .week) {
        self.agents = agents
        self.workspace = workspace
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.scale = scale
    }
}

/// Groups session folders into workspaces: the first two folders below home,
/// so worktrees such as `~/Desktop/acme/web-fix` join `~/Desktop/acme`.
public enum SessionTimeWorkspace {
    public static let temporary = "Temporary folders"
    public static let unknown = "Unknown folder"

    public static func key(for folder: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard let folder, !folder.isEmpty else { return unknown }
        for prefix in ["/private/tmp", "/tmp", "/private/var", "/var/folders"] where folder.hasPrefix(prefix) { return temporary }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if folder == base { return "~" }
        if folder.hasPrefix(base + "/") {
            let parts = folder.dropFirst(base.count + 1).split(separator: "/").prefix(2)
            return "~/" + parts.joined(separator: "/")
        }
        return "/" + folder.split(separator: "/").prefix(2).joined(separator: "/")
    }
}

public struct SessionTimeSignalTotal: Sendable, Equatable {
    public var count = 0
    public var seconds = 0.0
    public init(count: Int = 0, seconds: Double = 0) {
        self.count = count
        self.seconds = seconds
    }
}

public struct SessionTimePeriod: Sendable, Identifiable, Equatable {
    public var id: Date { start }
    public var start: Date
    public var end: Date
    public var prompts = 0
    public var sessions = 0
    public var groupSeconds: [SessionTimeGroup: Double] = [:]
    public var stateSeconds: [SessionTimeState: Double] = [:]
    public var activeSeconds = 0.0
    public var activeLiveWeighted = 0.0
    public var peakLive = 0
    /// Prompt-history figures. Nil when Claude is not selected.
    public var historyPrompts: Int?
    public var historySessions: Int?
    public var historyActiveSeconds = 0.0
    public var historyLiveWeighted = 0.0
    public var historyPeakLive = 0
    var claudePrompts = 0

    /// Session time excluding time spent waiting on the person.
    public var sessionSeconds: Double { groupSeconds.filter { $0.key != .you }.values.reduce(0, +) }
    public var blockingShare: Double? {
        let total = sessionSeconds
        guard total > 0 else { return nil }
        return ((groupSeconds[.localRuns] ?? 0) + (groupSeconds[.ciCD] ?? 0)) / total
    }
    public var averageLiveWhileActive: Double? { activeSeconds > 0 ? activeLiveWeighted / activeSeconds : nil }
    public var historyAverageLive: Double? { historyActiveSeconds > 0 ? historyLiveWeighted / historyActiveSeconds : nil }
    /// Share of the period's prompt-history prompts whose full transcript survived.
    public var coverage: Double? {
        guard let historyPrompts, historyPrompts > 0 else { return nil }
        return min(1, Double(claudePrompts) / Double(historyPrompts))
    }
}

public struct SessionTimeFolderRow: Sendable, Identifiable, Equatable {
    public var id: String { folder }
    public var folder: String
    public var sessions: Int
    public var prompts: Int
    public var groupSeconds: [SessionTimeGroup: Double]
    public var sessionSeconds: Double { groupSeconds.filter { $0.key != .you }.values.reduce(0, +) }
}

public struct SessionTimeReport: Sendable, Equatable {
    public var filter: SessionTimeFilter
    public var sessions = 0
    public var subagentSessions = 0
    public var prompts = 0
    /// Each session's own time, added across sessions. Overlapping sessions are not wall time.
    public var groupSeconds: [SessionTimeGroup: Double] = [:]
    public var activitySeconds: [SessionTimeActivity: Double] = [:]
    public var subagentGroupSeconds: [SessionTimeGroup: Double] = [:]
    /// One shared clock: each moment counted once under the highest-priority state.
    public var stateSeconds: [SessionTimeState: Double] = [:]
    public var liveWhileActive: [Int: Double] = [:]
    public var workingWhileActive: [Int: Double] = [:]
    public var periods: [SessionTimePeriod] = []
    public var folders: [SessionTimeFolderRow] = []
    public var signals: [SessionTimeSignalKind: SessionTimeSignalTotal] = [:]
    public var workspaces: [(key: String, prompts: Int)] = []
    public var earliestTranscript: Date?
    public var earliestHistory: Date?

    public static func == (lhs: SessionTimeReport, rhs: SessionTimeReport) -> Bool {
        lhs.filter == rhs.filter && lhs.groupSeconds == rhs.groupSeconds && lhs.stateSeconds == rhs.stateSeconds
            && lhs.periods == rhs.periods && lhs.prompts == rhs.prompts
    }

    public var sessionSeconds: Double { groupSeconds.filter { $0.key != .you }.values.reduce(0, +) }
    public var blockingSeconds: Double { (groupSeconds[.localRuns] ?? 0) + (groupSeconds[.ciCD] ?? 0) }
    public var blockingShare: Double? { sessionSeconds > 0 ? blockingSeconds / sessionSeconds : nil }
    public var liveSeconds: Double { stateSeconds.values.reduce(0, +) }
    public var averageLiveWhileActive: Double? { Self.mean(liveWhileActive) }
    public var averageWorkingWhileActive: Double? { Self.mean(workingWhileActive) }

    private static func mean(_ histogram: [Int: Double]) -> Double? {
        let total = histogram.values.reduce(0, +)
        guard total > 0 else { return nil }
        return histogram.reduce(0) { $0 + Double($1.key) * $1.value } / total
    }

    public static func build(snapshot: SessionTimeSnapshot, filter: SessionTimeFilter,
                             home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> SessionTimeReport {
        var report = SessionTimeReport(filter: filter)
        let lower = filter.start?.timeIntervalSince1970 ?? -Double.infinity
        let upper = filter.end?.timeIntervalSince1970 ?? Double.infinity
        let includesClaude = filter.agents.contains(.claude)
        func inWorkspace(_ folder: String?) -> Bool {
            filter.workspace == nil || SessionTimeWorkspace.key(for: folder, home: home) == filter.workspace
        }

        // Workspaces for the picker ignore the workspace filter but respect the agent filter.
        var workspacePrompts: [String: Int] = [:]
        for timeline in snapshot.timelines where !timeline.isSubagent && filter.agents.contains(timeline.agent) {
            workspacePrompts[SessionTimeWorkspace.key(for: timeline.folder, home: home), default: 0] += timeline.prompts.count
        }
        if includesClaude {
            var historyPrompts: [String: Int] = [:]
            for prompt in snapshot.history { historyPrompts[SessionTimeWorkspace.key(for: prompt.folder, home: home), default: 0] += 1 }
            workspacePrompts.merge(historyPrompts) { max($0, $1) }
        }
        report.workspaces = workspacePrompts.map { (key: $0.key, prompts: $0.value) }.sorted { ($0.prompts, $1.key) > ($1.prompts, $0.key) }

        let selected = snapshot.timelines.filter { filter.agents.contains($0.agent) && inWorkspace($0.folder) }
        let main = selected.filter { !$0.isSubagent }
        let history = includesClaude ? snapshot.history.filter { inWorkspace($0.folder) && $0.time >= lower && $0.time < upper } : []
        report.earliestTranscript = main.compactMap { $0.intervals.first?.start ?? $0.prompts.first }.min().map { Date(timeIntervalSince1970: $0) }
        report.earliestHistory = history.first.map { Date(timeIntervalSince1970: $0.time) }

        // Clip, and drop intervals copied into more than one transcript (resumed or forked sessions).
        var seen = Set<SessionTimeInterval>()
        var clippedMain: [(timeline: Int, interval: SessionTimeInterval)] = []
        for (index, timeline) in main.enumerated() {
            for var interval in timeline.intervals {
                interval.start = max(interval.start, lower)
                interval.end = min(interval.end, upper)
                guard interval.end > interval.start, seen.insert(interval).inserted else { continue }
                clippedMain.append((index, interval))
            }
        }
        let prompts = main.flatMap { timeline in timeline.prompts.filter { $0 >= lower && $0 < upper }.map { (time: $0, timeline: timeline) } }

        // Period boundaries cover the data inside the filter.
        let times = clippedMain.map(\.interval.start) + prompts.map(\.time) + history.map(\.time)
        guard let first = times.min() else { return report }
        let last = max(clippedMain.map(\.interval.end).max() ?? first, times.max() ?? first)
        let periods = Self.periodStarts(from: first, to: last, scale: filter.scale, timeZone: filter.timeZone)
        report.periods = zip(periods, periods.dropFirst()).map {
            SessionTimePeriod(start: Date(timeIntervalSince1970: $0), end: Date(timeIntervalSince1970: $1),
                              historyPrompts: includesClaude ? 0 : nil, historySessions: includesClaude ? 0 : nil)
        }
        func periodIndex(_ time: Double) -> Int? {
            var low = 0, high = periods.count - 2
            guard high >= 0, time >= periods[0], time < periods[periods.count - 1] else { return nil }
            while low < high {
                let mid = (low + high + 1) / 2
                if periods[mid] <= time { low = mid } else { high = mid - 1 }
            }
            return low
        }
        func split(_ start: Double, _ end: Double, _ body: (Int, Double) -> Void) {
            var cursor = start
            while cursor < end, let index = periodIndex(cursor) {
                let stop = min(end, periods[index + 1])
                body(index, stop - cursor)
                cursor = stop
            }
        }

        // Session time.
        report.sessions = main.count
        var folderRows: [String: (sessions: Set<Int>, prompts: Int, seconds: [SessionTimeGroup: Double])] = [:]
        for (index, interval) in clippedMain {
            let group = interval.activity.group
            report.groupSeconds[group, default: 0] += interval.duration
            report.activitySeconds[interval.activity, default: 0] += interval.duration
            split(interval.start, interval.end) { period, seconds in report.periods[period].groupSeconds[group, default: 0] += seconds }
            let folder = main[index].folder ?? SessionTimeWorkspace.unknown
            folderRows[folder, default: ([], 0, [:])].sessions.insert(index)
            folderRows[folder]!.seconds[group, default: 0] += interval.duration
        }
        for subagent in selected where subagent.isSubagent {
            var counted = false
            for interval in subagent.intervals {
                let duration = min(interval.end, upper) - max(interval.start, lower)
                guard duration > 0 else { continue }
                report.subagentGroupSeconds[interval.activity.group, default: 0] += duration
                counted = true
            }
            if counted { report.subagentSessions += 1 }
        }

        // Prompts and sessions touched.
        report.prompts = prompts.count
        var periodSessions: [Int: Set<String>] = [:]
        for prompt in prompts {
            guard let index = periodIndex(prompt.time) else { continue }
            report.periods[index].prompts += 1
            if prompt.timeline.agent == .claude { report.periods[index].claudePrompts += 1 }
            periodSessions[index, default: []].insert(prompt.timeline.agent.rawValue + prompt.timeline.id)
            let folder = prompt.timeline.folder ?? SessionTimeWorkspace.unknown
            folderRows[folder, default: ([], 0, [:])].prompts += 1
        }
        for (index, sessions) in periodSessions { report.periods[index].sessions = sessions.count }
        report.folders = folderRows.map { SessionTimeFolderRow(folder: $0.key, sessions: $0.value.sessions.count, prompts: $0.value.prompts, groupSeconds: $0.value.seconds) }
            .sorted { $0.sessionSeconds > $1.sessionSeconds }

        // Signals.
        for timeline in main {
            for signal in timeline.signals where signal.time >= lower && signal.time < upper {
                report.signals[signal.kind, default: .init()].count += 1
                report.signals[signal.kind, default: .init()].seconds += signal.seconds
            }
        }

        // Shared clock and parallel sessions.
        let active = Self.merged(prompts.map { ($0.time, min($0.time + SessionTimeRules.activeWindow, upper)) })
        Self.sweep(intervals: clippedMain.map(\.interval), active: active, split: split, report: &report)

        // Prompt history, which reaches further back than transcripts.
        if includesClaude, !history.isEmpty {
            var historySessions: [Int: Set<String>] = [:]
            for prompt in history {
                guard let index = periodIndex(prompt.time) else { continue }
                report.periods[index].historyPrompts! += 1
                historySessions[index, default: []].insert(prompt.session)
            }
            for (index, sessions) in historySessions { report.periods[index].historySessions = sessions.count }
            let bySession = Dictionary(grouping: history, by: \.session)
            let windows = bySession.values.flatMap { prompts in
                Self.merged(prompts.map { ($0.time, $0.time + SessionTimeRules.historyLiveWindow) })
            }
            let historyActive = Self.merged(history.map { ($0.time, $0.time + SessionTimeRules.activeWindow) })
            Self.historySweep(windows: windows, active: historyActive, split: split, report: &report)
        }
        return report
    }

    // MARK: Helpers

    static func periodStarts(from first: Double, to last: Double, scale: SessionTimeScale, timeZone: TimeZone) -> [Double] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        let component: Calendar.Component = scale == .day ? .day : .weekOfYear
        guard var cursor = calendar.dateInterval(of: component, for: Date(timeIntervalSince1970: first))?.start else { return [] }
        var starts: [Double] = []
        let stop = Date(timeIntervalSince1970: last)
        while cursor <= stop {
            starts.append(cursor.timeIntervalSince1970)
            guard let next = calendar.date(byAdding: scale == .day ? .day : .weekOfYear, value: 1, to: cursor) else { break }
            cursor = next
        }
        starts.append(cursor.timeIntervalSince1970)
        return starts
    }

    static func merged(_ windows: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for window in windows.sorted(by: { $0.0 < $1.0 }) where window.1 > window.0 {
            if let last = result.last, window.0 <= last.1 { result[result.count - 1].1 = max(last.1, window.1) }
            else { result.append(window) }
        }
        return result
    }

    private static func sweep(intervals: [SessionTimeInterval], active: [(Double, Double)],
                              split: (Double, Double, (Int, Double) -> Void) -> Void,
                              report: inout SessionTimeReport) {
        enum Mark { case state(SessionTimeState), active }
        var points: [(time: Double, delta: Int, mark: Mark)] = []
        points.reserveCapacity(intervals.count * 2 + active.count * 2)
        for interval in intervals {
            points.append((interval.start, 1, .state(interval.state)))
            points.append((interval.end, -1, .state(interval.state)))
        }
        for window in active {
            points.append((window.0, 1, .active))
            points.append((window.1, -1, .active))
        }
        points.sort { ($0.time, $0.delta) < ($1.time, $1.delta) }
        var counts: [SessionTimeState: Int] = [:]
        var activeDepth = 0
        var previous: Double?
        for point in points {
            if let previous, point.time > previous {
                let live = counts.values.reduce(0, +)
                if live > 0 {
                    let working = counts[.working] ?? 0
                    let state: SessionTimeState = working > 0 ? .working : (counts[.waitingOnYou] ?? 0) > 0 ? .waitingOnYou
                        : (counts[.ciOnly] ?? 0) > 0 ? .ciOnly : .backgroundOnly
                    let isActive = activeDepth > 0
                    report.stateSeconds[state, default: 0] += point.time - previous
                    if isActive {
                        report.liveWhileActive[live, default: 0] += point.time - previous
                        report.workingWhileActive[working, default: 0] += point.time - previous
                    }
                    split(previous, point.time) { index, seconds in
                        report.periods[index].stateSeconds[state, default: 0] += seconds
                        report.periods[index].peakLive = max(report.periods[index].peakLive, live)
                        if isActive {
                            report.periods[index].activeSeconds += seconds
                            report.periods[index].activeLiveWeighted += seconds * Double(live)
                        }
                    }
                }
            }
            switch point.mark {
            case let .state(state): counts[state, default: 0] += point.delta
            case .active: activeDepth += point.delta
            }
            previous = point.time
        }
    }

    private static func historySweep(windows: [(Double, Double)], active: [(Double, Double)],
                                     split: (Double, Double, (Int, Double) -> Void) -> Void, report: inout SessionTimeReport) {
        var points: [(time: Double, live: Int, active: Int)] = []
        for window in windows { points.append((window.0, 1, 0)); points.append((window.1, -1, 0)) }
        for window in active { points.append((window.0, 0, 1)); points.append((window.1, 0, -1)) }
        points.sort { ($0.time, $0.live + $0.active) < ($1.time, $1.live + $1.active) }
        var live = 0, depth = 0
        var previous: Double?
        for point in points {
            if let previous, point.time > previous, live > 0 {
                let current = live, isActive = depth > 0
                split(previous, point.time) { index, seconds in
                    report.periods[index].historyPeakLive = max(report.periods[index].historyPeakLive, current)
                    if isActive {
                        report.periods[index].historyActiveSeconds += seconds
                        report.periods[index].historyLiveWeighted += seconds * Double(current)
                    }
                }
            }
            live += point.live
            depth += point.active
            previous = point.time
        }
    }
}
