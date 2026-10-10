import AppKit
import ContextCore
import SwiftUI
import SaaSMakerUI

/// A direct route to the local OTEL evidence. This is deliberately independent
/// of Usage's allowance, model, source, and date-range controls.
struct TelemetryView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            let compact = proxy.size.width < 850 || proxy.size.height < 700
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 13 : 19) {
                    VStack(alignment: .leading, spacing: 6) {
                        SMSectionHeader("run telemetry", size: 27).accessibilityLabel("Run telemetry")
                        Text("See what ran, where tokens went, and what to review next.")
                            .foregroundStyle(DaddyTheme.muted)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            agentPicker
                            Spacer(minLength: 8)
                            if [.codex, .claude].contains(model.selectedTelemetryRuntime) { refreshButton }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            agentPicker
                            if [.codex, .claude].contains(model.selectedTelemetryRuntime) { refreshButton }
                        }
                    }

                    ActivityAnswersView(runtime: model.selectedTelemetryRuntime)
                    DisclosureGroup("Recorded history and local source files") {
                        AgentRecordedActivityView(runtime: model.selectedTelemetryRuntime)
                    }
                    SMDisplay("live signals · separate last-24-hour source", size: 13).accessibilityLabel("Live signals · separate last-24-hour source")
                    Text("The folder and history filters above do not filter these aggregate signals. No per-folder trace attribution is supplied.").font(.caption).foregroundStyle(DaddyTheme.muted)

                    if [.codex, .claude].contains(model.selectedTelemetryRuntime) {
                    connectionStatus

                    if model.telemetry.collectorReachable && model.selectedTelemetryRuntime == .claude && !selectedAgentConnected {
                        missingClaudeTelemetry
                    } else if model.telemetry.collectorReachable && selectedAgentConnected {
                        OTelDashboardView(snapshot: model.telemetry, runtime: model.selectedTelemetryRuntime)
                    } else {
                        Panel {
                            VStack(alignment: .leading, spacing: 10) {
                                SMDisplay("activity is not available yet", size: 13).accessibilityLabel("Activity is not available yet")
                                Text("Connect the selected agent to the local collector, run a task, then check again. Missing telemetry does not mean the agent is idle.")
                                    .font(.callout).foregroundStyle(DaddyTheme.muted)
                                Button("copy connection checklist", systemImage: "doc.on.doc", action: copyConnectionChecklist).accessibilityLabel("Copy connection checklist")
                                Button("open recorded usage") { model.show(.overview) }.accessibilityLabel("Open recorded usage")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    } else {
                        Text("Live traces are not available for \(model.selectedTelemetryRuntime.rawValue) in this adapter. Recorded activity above is independent of the OTEL collector.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                    }
                    DisclosureGroup("How to interpret this data") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("What this view cannot prove", systemImage: "info.circle")
                                .font(.headline)
                            Text("Network calls are logical events, not internet bytes. A named skill injection does not prove the skill completed useful work. Claude tool and API calls are unavailable without a verified adapter.")
                                .font(.caption)
                                .foregroundStyle(DaddyTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(compact ? 18 : 28)
                .frame(maxWidth: 1220, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func copyConnectionChecklist() {
        let runtime = model.selectedTelemetryRuntime.rawValue
        let brief = """
        ContextDaddy activity connection check: \(runtime)
        Checked: \(model.telemetry.generatedAt.formatted())
        Local collector reachable: \(model.telemetry.collectorReachable)
        Selected agent data verified: \(selectedAgentConnected)
        Read-only endpoint: http://127.0.0.1:3000

        1. Check whether the user's existing local telemetry stack is running and its read-only endpoint responds.
        2. Inspect the selected agent's telemetry export status using its current official documentation. Do not borrow another agent's metrics.
        3. Identify the missing connection and propose the exact change. Do not edit credentials, launch settings or configuration without user review.
        4. After an approved repair, run a representative task and use Check telemetry in ContextDaddy. Verify new data for this agent, not only collector reachability.
        Claude tool/API events and non-Codex session traces are not supported by this adapter. Missing telemetry is not zero usage.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(brief, forType: .string)
    }

    private var agentPicker: some View {
        ContextChoiceMenu(
            title: "Agent",
            selection: Bindable(model).selectedTelemetryRuntime,
            choices: AgentRuntime.allCases.map { ContextChoice($0, $0.rawValue) },
            width: 180
        )
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshTelemetry() }
        } label: {
            Label(model.isTelemetryLoading ? "Checking…" : "Check telemetry", systemImage: "arrow.clockwise")
        }
        .disabled(model.isTelemetryLoading)
    }

    private var selectedAgentConnected: Bool {
        model.telemetry.agents.first { $0.runtime == model.selectedTelemetryRuntime }?.connected == true
    }

    private var missingClaudeTelemetry: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Claude telemetry unavailable", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundStyle(DaddyTheme.amber)
                Text("The local collector is running, but no verified Claude Code OTLP metrics were returned. This is missing coverage, not zero usage.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Check that Claude Code exports OTLP metrics to this collector, then use Check telemetry above. Local Claude history remains available separately on Usage.")
                    .font(.caption)
                    .foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("copy connection checklist", systemImage: "doc.on.doc", action: copyConnectionChecklist).accessibilityLabel("Copy connection checklist")
                Button("open usage history", systemImage: "chart.bar.xaxis") {
                    model.usageService = .claude
                    model.show(.overview)
                }.accessibilityLabel("Open Usage history")
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionStatus: some View {
        let collectorReachable = model.telemetry.collectorReachable
        let claudeMissing = collectorReachable && !selectedAgentConnected
        return Panel(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: collectorReachable && !claudeMissing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(collectorReachable && !claudeMissing ? DaddyTheme.mint : DaddyTheme.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(claudeMissing ? "Collector reachable · \(model.selectedTelemetryRuntime.rawValue) data unavailable" :
                         collectorReachable ? "Local OTEL source reachable" : "Local OTEL source unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text(claudeMissing
                         ? "The collector responded, but this agent has no verified data. Other agents may have different coverage."
                         : collectorReachable
                         ? "Last checked \(model.telemetry.generatedAt.formatted(date: .abbreviated, time: .shortened)). Codex and Claude evidence may still differ."
                         : "ContextDaddy cannot reach its read-only local telemetry endpoint at 127.0.0.1:3000. Start or repair the local stack, then check again. No activity is inferred from this outage.")
                        .font(.caption)
                        .foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.telemetry.collectorReachable, let detail = model.telemetry.notes.first {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(DaddyTheme.amber)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                EvidenceBadge(quality: collectorReachable && !claudeMissing ? .measured : .unavailable)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
