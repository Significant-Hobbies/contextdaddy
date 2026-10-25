import AppKit
import Charts
import ContextCore
import SaaSMakerUI
import SwiftUI

/// Where session time went across every local Claude and Codex session.
/// Commands and replies are read in memory to pick a category; only durations are kept.
struct SessionTimeView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("contextDaddySessionTimeRead") private var hasRead = false
    @State private var visibility = SessionTimeVisibility()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                SMDisplay("session time · every local session", size: 13).accessibilityLabel("Session time, every local session")
                Text("Where Claude and Codex session time went: model work, local runs, CI, subagents, and waiting on you.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            }
            controls
            if let report = model.sessionTimeReport, report.liveSeconds > 0 || report.prompts > 0 {
                content(report)
            } else {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.isSessionTimeLoading ? progressText : model.sessionTimeSnapshot == nil ? "Session time has not been read yet" : "No sessions match these filters")
                            .font(.headline)
                        Text(model.sessionTimeSnapshot == nil
                             ? "Reads local transcripts under ~/.claude/projects and ~/.codex/sessions. The first read can take a minute; later reads use a cache."
                             : "Try a longer range, another folder, or all agents.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                        if model.isSessionTimeLoading { ProgressView(value: progressFraction).frame(maxWidth: 320) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(SessionTimeWindowReader(view: visibility).frame(width: 0, height: 0))
        .task {
            // Re-read while visible; unchanged files come from the scan cache.
            if hasRead, model.sessionTimeSnapshot == nil, visibility.allowsAutomaticRead { await model.refreshSessionTime() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                if hasRead, visibility.allowsAutomaticRead { await model.refreshSessionTime() }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        @Bindable var model = model
        let workspaces = model.sessionTimeReport?.workspaces.prefix(15).map(\.key) ?? []
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { menus(workspaces); Spacer(minLength: 8); readButton }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { agentMenu; workspaceMenu(workspaces) }
                HStack(spacing: 10) { rangeMenu; scaleMenu; zoneMenu; readButton }
            }
        }
    }

    private func menus(_ workspaces: [String]) -> some View {
        HStack(spacing: 10) { agentMenu; workspaceMenu(workspaces); rangeMenu; scaleMenu; zoneMenu }
    }

    private var agentMenu: some View {
        ContextChoiceMenu(title: "Agent", selection: Bindable(model).sessionTimeAgent,
                          choices: SessionTimeAgentChoice.allCases.map { ContextChoice($0, $0.rawValue) }, width: 150)
    }

    private func workspaceMenu(_ workspaces: [String]) -> some View {
        var keys = workspaces
        if !model.sessionTimeWorkspace.isEmpty, !keys.contains(model.sessionTimeWorkspace) { keys.insert(model.sessionTimeWorkspace, at: 0) }
        return ContextChoiceMenu(title: "Folder", selection: Bindable(model).sessionTimeWorkspace,
                                 choices: [ContextChoice("", "All folders")] + keys.map { ContextChoice($0, $0) }, width: 210)
    }

    private var rangeMenu: some View {
        ContextChoiceMenu(title: "Range", selection: Bindable(model).sessionTimeRange,
                          choices: SessionTimeRange.allCases.map { ContextChoice($0, $0.title) }, width: 160)
    }

    private var scaleMenu: some View {
        ContextChoiceMenu(title: "By", selection: Bindable(model).sessionTimeScale,
                          choices: [ContextChoice(.day, "Day"), ContextChoice(.week, "Week")], width: 110)
    }

    private var zoneMenu: some View {
        let system = TimeZone.current
        let zones = ["Asia/Kolkata", "Asia/Dubai", "Europe/London", "America/New_York", "UTC"].filter { $0 != system.identifier }
        return ContextChoiceMenu(title: "Time zone", selection: Bindable(model).sessionTimeZoneID,
                                 choices: [ContextChoice("", "System (\(system.abbreviation() ?? system.identifier))")]
                                    + zones.map { ContextChoice($0, Self.zoneTitle($0)) },
                                 width: 170)
    }

    private static func zoneTitle(_ identifier: String) -> String {
        switch identifier {
        case "Asia/Kolkata": "IST (India)"
        case "Asia/Dubai": "GST (Dubai)"
        case "Europe/London": "London"
        case "America/New_York": "New York"
        default: identifier
        }
    }

    private var readButton: some View {
        Button {
            hasRead = true
            Task { await model.refreshSessionTime() }
        } label: {
            Label(model.isSessionTimeLoading ? progressText : model.sessionTimeSnapshot == nil ? "Read sessions" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isSessionTimeLoading)
    }

    private var progressText: String {
        model.sessionTimeFilesTotal > 0 ? "Reading \(model.sessionTimeFilesRead) of \(model.sessionTimeFilesTotal) files…" : "Reading sessions…"
    }

    private var progressFraction: Double {
        model.sessionTimeFilesTotal > 0 ? Double(model.sessionTimeFilesRead) / Double(model.sessionTimeFilesTotal) : 0
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ report: SessionTimeReport) -> some View {
        answer(report)
        tiles(report)
        periodChart(report)
        periodTable(report)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { sharedClock(report); parallel(report) }
            VStack(alignment: .leading, spacing: 14) { sharedClock(report); parallel(report) }
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { blockingDetail(report); signals(report) }
            VStack(alignment: .leading, spacing: 14) { blockingDetail(report); signals(report) }
        }
        folders(report)
        notes(report)
    }

    private func answer(_ report: SessionTimeReport) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("What took the time?").font(.headline)
                Text("\(hours(report.blockingSeconds)) on CI and local runs").font(.title3.bold())
                Text("\(percent(report.blockingShare)) of session time · CI alone stopped all work for \(hours(report.stateSeconds[.ciOnly])) · \(report.sessions) sessions, \(report.prompts.formatted()) prompts")
                    .font(.callout).foregroundStyle(DaddyTheme.muted)
                Text("Session time adds each session separately, so two sessions running together count twice. It is not wall time; the shared clock below is.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tiles(_ report: SessionTimeReport) -> some View {
        let total = report.sessionSeconds
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach([SessionTimeGroup.localRuns, .ciCD, .model, .subagents, .otherTools]) { group in
                tile(group.title, hours(report.groupSeconds[group]),
                     total > 0 ? "\(percent((report.groupSeconds[group] ?? 0) / total)) of session time" : "No session time",
                     color: Self.color(group))
            }
            tile("Live while you work", report.averageLiveWhileActive.map { String(format: "%.2f", $0) } ?? "—",
                 "Average sessions live", color: DaddyTheme.blue)
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, color: Color) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.lowercased()).font(.caption2.weight(.bold)).foregroundStyle(DaddyTheme.muted)
                Text(value).font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(color)
                Text(detail).font(.caption).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func periodChart(_ report: SessionTimeReport) -> some View {
        let groups: [SessionTimeGroup] = [.localRuns, .ciCD, .model, .subagents, .otherTools]
        // Idle periods are dropped so a quiet stretch does not leave a run of empty slots.
        let periods = report.periods.filter { $0.sessionSeconds > 0 }
        let titles = Dictionary(uniqueKeysWithValues: periods.map { (periodKey($0), periodTitle($0, report)) })
        let stride = max(1, (periods.count + 7) / 8)
        let labelled = Set(periods.enumerated().filter { $0.offset % stride == 0 }.map { periodKey($0.element) })
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Session time by \(report.filter.scale.rawValue)").font(.headline)
                Chart {
                    ForEach(periods) { period in
                        ForEach(groups) { group in
                            BarMark(x: .value("Period", periodKey(period)),
                                    y: .value("Hours", (period.groupSeconds[group] ?? 0) / 3600))
                                .foregroundStyle(by: .value("Activity", group.title))
                                .opacity((period.coverage ?? 1) < 0.8 ? 0.35 : 1)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        if let key = value.as(String.self), labelled.contains(key) {
                            AxisValueLabel(collisionResolution: .disabled) { Text(titles[key] ?? "") }
                        }
                    }
                }
                .chartForegroundStyleScale(domain: groups.map(\.title), range: groups.map(Self.color))
                .chartYAxisLabel("hours")
                .environment(\.timeZone, report.filter.timeZone)
                .frame(height: 220)
                Text("Faded bars are partial: Claude Code had already deleted most of that period’s transcripts.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func periodTable(_ report: SessionTimeReport) -> some View {
        let rows = report.periods.filter { $0.prompts > 0 || ($0.historyPrompts ?? 0) > 0 || $0.sessionSeconds > 0 }.reversed()
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text(report.filter.scale == .day ? "Every day" : "Every week").font(.headline)
                ScrollView([.vertical, .horizontal]) {
                    Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            ForEach(["Period", "Prompts", "Sessions", "Live", "Peak", "Local runs", "CI/CD", "Model", "CI + local", "Coverage"], id: \.self) { title in
                                Text(title).font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
                            }
                        }
                        Divider()
                        ForEach(Array(rows)) { period in
                            let partial = (period.coverage ?? 1) < 0.8
                            GridRow {
                                Text(periodTitle(period, report)).gridColumnAlignment(.leading)
                                Text((partial ? period.historyPrompts ?? period.prompts : period.prompts).formatted())
                                Text("\(partial ? period.historySessions ?? period.sessions : period.sessions)")
                                Text(live(period, partial: partial))
                                Text("\(partial ? period.historyPeakLive : period.peakLive)")
                                Text(hours(period.groupSeconds[.localRuns])).foregroundStyle(partial ? DaddyTheme.muted : .primary)
                                Text(hours(period.groupSeconds[.ciCD])).foregroundStyle(partial ? DaddyTheme.muted : .primary)
                                Text(hours(period.groupSeconds[.model])).foregroundStyle(partial ? DaddyTheme.muted : .primary)
                                Text(percent(period.blockingShare)).foregroundStyle(partial ? DaddyTheme.muted : .primary)
                                Text(period.coverage.map(percent) ?? "—").foregroundStyle(partial ? DaddyTheme.amber : DaddyTheme.muted)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
                .frame(maxHeight: 340)
                Text("Partial periods take prompts, sessions and parallelism from Claude prompt history, which outlives transcripts; their time columns cover only the surviving transcripts.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sharedClock(_ report: SessionTimeReport) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("What held everything up").font(.headline)
                Text("One shared clock, each moment counted once: working beats waiting on you, which beats CI, which beats background agents. \(hours(report.liveSeconds)) with a session live.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                bars(SessionTimeState.allCases.map { ($0.title, (report.stateSeconds[$0] ?? 0) / 3600, Self.color($0)) }, unit: "h")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parallel(_ report: SessionTimeReport) -> some View {
        let total = report.liveWhileActive.values.reduce(0, +)
        let buckets = [(1, "1 session"), (2, "2 sessions"), (3, "3 sessions"), (4, "4 or more")].map { count, title in
            (title, total > 0 ? report.liveWhileActive.filter { count == 4 ? $0.key >= 4 : $0.key == count }.values.reduce(0, +) / total * 100 : 0, DaddyTheme.blue)
        }
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Parallel sessions while you work").font(.headline)
                Text("\(report.averageLiveWhileActive.map { String(format: "%.2f", $0) } ?? "—") live on average, \(report.averageWorkingWhileActive.map { String(format: "%.2f", $0) } ?? "—") actually executing. You count as active for 15 minutes after a prompt.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                bars(buckets, unit: "%")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func blockingDetail(_ report: SessionTimeReport) -> some View {
        let rows = report.activitySeconds.filter { $0.key.group.isBlockingRun }.sorted { $0.value > $1.value }.prefix(10)
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("The blocking part").font(.headline)
                bars(rows.map { ($0.key.title, $0.value / 3600, Self.color($0.key.group)) }, unit: "h")
                if !report.subagentGroupSeconds.isEmpty {
                    Text("Subagents ran another \(hours(report.subagentGroupSeconds[.localRuns])) of local runs and \(hours(report.subagentGroupSeconds[.ciCD])) of CI across \(report.subagentSessions) subagent sessions, alongside their parents.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signals(_ report: SessionTimeReport) -> some View {
        let rows: [(SessionTimeSignalKind, String)] = [
            (.ciFixCycle, "Fixing after a CI failure"), (.ciHandBack, "Turns that ended with CI still running"),
            (.commandTimeout, "Commands that hit a timeout"), (.interrupt, "Turns you interrupted"),
            (.toolError, "Failed tool calls"), (.compaction, "Context compactions"),
        ]
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Friction").font(.headline)
                ForEach(rows, id: \.0) { kind, title in
                    let total = report.signals[kind] ?? .init()
                    HStack {
                        Text(title).font(.callout)
                        Spacer()
                        Text(total.seconds > 0 ? "\(total.count) · \(hours(total.seconds))" : "\(total.count)")
                            .font(.callout.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    }
                }
                Text("Fix time runs from a CI result reporting a failure to the next git operation in the same turn. Hand-back time is the wait on you that followed.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func folders(_ report: SessionTimeReport) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Folders").font(.headline)
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Folder", "Sessions", "Prompts", "Session time", "CI + local"], id: \.self) { title in
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
                        }
                    }
                    Divider()
                    ForEach(report.folders.prefix(12)) { row in
                        let blocking = (row.groupSeconds[.localRuns] ?? 0) + (row.groupSeconds[.ciCD] ?? 0)
                        GridRow {
                            Text(row.folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).gridColumnAlignment(.leading)
                            Text("\(row.sessions)")
                            Text(row.prompts.formatted())
                            Text(hours(row.sessionSeconds))
                            Text(row.sessionSeconds > 0 ? percent(blocking / row.sessionSeconds) : "—")
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notes(_ report: SessionTimeReport) -> some View {
        DisclosureGroup("Sources, coverage and limits") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.sessionTimeSnapshot?.coverage ?? [], id: \.agent) { coverage in
                    Label("\(coverage.agent.rawValue): \(coverage.note)", systemImage: coverage.partial ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(coverage.partial ? DaddyTheme.amber : DaddyTheme.muted)
                }
                if let transcript = report.earliestTranscript {
                    Text("Earliest surviving transcript in range: \(transcript.formatted(date: .abbreviated, time: .omitted)). Claude Code deletes transcripts after cleanupPeriodDays (30 by default); raise it in ~/.claude/settings.json to keep more.")
                }
                if let history = report.earliestHistory {
                    Text("Claude prompt history reaches back to \(history.formatted(date: .abbreviated, time: .omitted)).")
                }
                Text("Commands, tool output and replies are read in memory only to choose a category; no text is stored or shown. Categories come from command text, so a push chained with a CI wait counts as CI.")
                Text("Waiting on you is time a session sat idle; transcripts cannot show whether you were reading, testing or away. Gaps over 2 hours count as away. Scripted codex exec runs are excluded.")
            }
            .font(.caption).foregroundStyle(DaddyTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func bars(_ rows: [(String, Double, Color)], unit: String) -> some View {
        let maximum = max(rows.map(\.1).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 10) {
                    Text(row.0).font(.caption).frame(width: 190, alignment: .leading).lineLimit(1)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3).fill(row.2)
                            .frame(width: max(2, proxy.size.width * row.1 / maximum))
                    }
                    .frame(height: 10)
                    Text(unit == "%" ? String(format: "%.0f%%", row.1) : String(format: "%.1f h", row.1))
                        .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted).frame(width: 60, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Stable categorical key for a period; titles alone can repeat across years.
    private func periodKey(_ period: SessionTimePeriod) -> String {
        String(Int(period.start.timeIntervalSince1970))
    }

    private func periodTitle(_ period: SessionTimePeriod, _ report: SessionTimeReport) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: report.filter.timeZone)
        if report.filter.scale == .day {
            return period.start.formatted(Date.FormatStyle(timeZone: report.filter.timeZone).weekday(.abbreviated).day().month(.abbreviated))
        }
        let last = period.end.addingTimeInterval(-1)
        return "\(period.start.formatted(style)) – \(last.formatted(Date.FormatStyle(timeZone: report.filter.timeZone).day().month(.abbreviated)))"
    }

    private func live(_ period: SessionTimePeriod, partial: Bool) -> String {
        if partial, let estimate = period.historyAverageLive { return String(format: "≈%.1f", estimate) }
        return period.averageLiveWhileActive.map { String(format: "%.1f", $0) } ?? "—"
    }

    private func hours(_ seconds: Double?) -> String {
        String(format: "%.1f h", (seconds ?? 0) / 3600)
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    static func color(_ group: SessionTimeGroup) -> Color {
        switch group {
        case .localRuns: DaddyTheme.coral
        case .ciCD: DaddyTheme.amber
        case .model: DaddyTheme.mint
        case .subagents: DaddyTheme.blue
        case .otherTools: DaddyTheme.muted.opacity(0.6)
        case .you: DaddyPalette.cyan
        }
    }

    static func color(_ state: SessionTimeState) -> Color {
        switch state {
        case .working: DaddyTheme.mint
        case .waitingOnYou: DaddyPalette.cyan
        case .ciOnly: DaddyTheme.amber
        case .backgroundOnly: DaddyTheme.muted.opacity(0.6)
        }
    }
}

@MainActor final class SessionTimeVisibility: NSView {
    var allowsAutomaticRead: Bool {
        guard let window else { return false }
        return !NSApplication.shared.isHidden && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }
}

private struct SessionTimeWindowReader: NSViewRepresentable {
    let view: SessionTimeVisibility

    func makeNSView(context: Context) -> SessionTimeVisibility { view }
    func updateNSView(_ nsView: SessionTimeVisibility, context: Context) {}
}
