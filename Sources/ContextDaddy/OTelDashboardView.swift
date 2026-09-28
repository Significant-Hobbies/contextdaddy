import AppKit
import ContextCore
import SwiftUI

struct OTelDashboardView: View {
    let snapshot: ObservabilitySnapshot
    let runtime: AgentRuntime

    private var agent: AgentTelemetry? { snapshot.agents.first { $0.runtime == runtime } }
    private var runs: [OTelRun] { runtime == .codex ? snapshot.recentRuns ?? [] : [] }
    private var sections: [TelemetryBreakdownSection] {
        runtime == .claude ? snapshot.claudeBreakdowns ?? [] : snapshot.breakdowns ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(runtime.rawValue) · " + (runtime == .codex ? "\(runs.count) recorded \(runs.count == 1 ? "session" : "sessions") · " : "") + "\(EfficiencyOpportunityAnalyzer.telemetry(snapshot: snapshot, runtime: runtime).count) review signals")
                .font(.headline)
            Text(runtime == .claude ? "Session traces and tool/API events are not available for Claude in this adapter." : "Recorded sessions reflect returned traces, not every task you ran. Review signals describe aggregates, not a failure diagnosis for a specific run.")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
            if runtime == .codex {
                RecentRunsPanel(runs: runs, collectorReachable: snapshot.collectorReachable)
            }

            EfficiencyOpportunityPanel(
                title: "What needs attention",
                sourceNote: "Observed last-24-hour events, with limits kept visible.",
                opportunities: EfficiencyOpportunityAnalyzer.telemetry(snapshot: snapshot, runtime: runtime),
                columnCount: 1,
                onCopyAll: copyTelemetryIssues)
            if !EfficiencyOpportunityAnalyzer.telemetry(snapshot: snapshot, runtime: runtime).isEmpty {
                Text("A lower rolling count alone cannot verify an OTEL fix. Compare a new observation window with representative activity.")
                    .font(.caption2).foregroundStyle(DaddyTheme.amber)
            }

            DisclosureGroup("Measurements and breakdowns") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                ForEach(TelemetrySignal.allCases) { signal in
                    if let value = agent?.signals[signal] {
                        Panel(padding: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(signal.rawValue).font(.caption.weight(.semibold))
                                Text(value.value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                                    .font(.title3.bold()).monospacedDigit()
                                Text(value.unit).font(.caption2).foregroundStyle(DaddyTheme.muted)
                                Text(value.note).font(.caption2).foregroundStyle(DaddyTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(sections) { section in
                    BreakdownPanel(section: section)
                }
            }

            }
            if snapshot.collectorReachable && runtime == .codex {
                DisclosureGroup("Source notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Interpretation boundaries", systemImage: "ruler")
                            .font(.headline).foregroundStyle(DaddyTheme.amber)
                        ForEach(snapshot.notes, id: \.self) { note in
                            Text("• \(note)").font(.caption).foregroundStyle(DaddyTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func copyTelemetryIssues() {
        let issues = EfficiencyOpportunityAnalyzer.telemetry(snapshot: snapshot, runtime: runtime)
        guard !issues.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(IssueBriefFormatter.telemetry(issues), forType: .string)
    }
}

private struct RecentRunsPanel: View {
    let runs: [OTelRun]
    let collectorReachable: Bool
    @State private var expanded = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent recorded runs").font(.headline)
                        Text("Root-session traces from the last 24 hours. Finished spans can arrive after a run ends.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                    }
                    Spacer()
                    EvidenceBadge(quality: collectorReachable ? .measured : .unavailable)
                }
                if runs.isEmpty {
                    Text(collectorReachable ? "No completed session roots were returned in this window." : "The local Tempo session source is not reachable.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted).padding(.vertical, 8)
                } else {
                    ForEach(Array(runs.prefix(expanded ? 20 : 5))) { run in
                        ViewThatFits(in: .horizontal) {
                            runRow(run, compact: false)
                            runRow(run, compact: true)
                        }
                        DisclosureGroup("Run evidence and investigation") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Trace ID: " + run.traceID).font(.caption.monospaced()).textSelection(.enabled)
                                Text("The source supplies timing and span count, but no verified task name, project, outcome or per-run failure attribution.")
                                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                                Button("Copy run investigation", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("Investigate this recorded Codex trace in the existing local telemetry stack. Trace ID: \(run.traceID). Started: \(run.startedAt.formatted()). Root service: \(run.rootService). Operation: \(run.rootOperation). Duration: \(run.durationMilliseconds) ms. Spans: \(run.spanCount). Establish the task, outcome and any errors from trace evidence. Do not attribute aggregate 24-hour failures to this run without correlation; ContextDaddy has not verified its outcome.", forType: .string)
                                }.font(.caption)
                            }.padding(.top, 6)
                        }.font(.caption)
                        if run.id != runs.prefix(expanded ? 20 : 5).last?.id { Divider().overlay(DaddyTheme.line) }
                    }
                    if runs.count > 5 {
                        Button(expanded ? "Show fewer sessions" : "Show all \(runs.count) sessions") { expanded.toggle() }
                            .font(.caption)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runRow(_ run: OTelRun, compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(DaddyTheme.blue).frame(width: 7, height: 7)
                        Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(duration(run.durationMilliseconds)).font(.caption.monospacedDigit())
                    }
                    Text("\(run.rootService) · \(run.rootOperation)")
                        .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text("\(run.spanCount) spans").font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
            } else {
                HStack(spacing: 12) {
                            Circle().fill(DaddyTheme.blue).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.subheadline.weight(.semibold))
                                Text("\(run.rootService) · \(run.rootOperation)")
                                    .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer()
                            Text(duration(run.durationMilliseconds)).font(.subheadline.monospacedDigit())
                            Text("\(run.spanCount) spans").font(.caption).foregroundStyle(DaddyTheme.muted)
                        }
            }
        }
    }

    private func duration(_ milliseconds: Double) -> String {
        let seconds = milliseconds / 1_000
        if seconds >= 60 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f s", seconds)
    }
}

private struct BreakdownPanel: View {
    let section: TelemetryBreakdownSection
    @State private var expanded = false

    private var visibleItems: [TelemetryBreakdownItem] {
        Array(section.items.prefix(expanded ? 20 : 6))
    }
    private var maximum: Double { max(section.items.map(\.value).max() ?? 0, 1) }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(section.title).font(.headline)
                        Spacer()
                        EvidenceBadge(quality: section.items.first?.quality ?? .derived)
                    }
                    Text(section.note).font(.caption2).foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if section.items.isEmpty {
                    Text("No measured events in this window.").font(.caption).foregroundStyle(DaddyTheme.muted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(visibleItems) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.caption.weight(.semibold)).lineLimit(1)
                                    if let detail = item.detail {
                                        Text(detail).font(.caption2).foregroundStyle(DaddyTheme.muted)
                                    }
                                }
                                Spacer()
                                Text(format(item.value) + " " + item.unit)
                                    .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                            }
                            GeometryReader { proxy in
                                Capsule().fill(DaddyTheme.raised)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(DaddyTheme.blue)
                                            .frame(width: proxy.size.width * max(0, min(1, item.value / maximum)))
                                    }
                            }.frame(height: 4)
                        }
                    }
                    if section.items.count > 6 {
                        Button(expanded ? "Show fewer" : "Show all \(section.items.count)") { expanded.toggle() }
                            .font(.caption)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func format(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        if value.rounded() == value { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
