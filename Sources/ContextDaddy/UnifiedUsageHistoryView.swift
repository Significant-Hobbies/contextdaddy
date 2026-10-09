import Charts
import ContextCore
import SwiftUI

/// CodeVetter's history desk, expressed in ContextDaddy's existing visual system.
/// The chart and exact-value inspector always use the same daily-ledger projection.
struct UnifiedUsageHistoryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var selectedPeriod: String?
    @State private var showAllBreakdown = false

    var body: some View {
        @Bindable var model = model
        let history = model.usageHistory
        let agents = model.availableHistoryAgents
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                UsageSectionTitle(
                    title: "history",
                    detail: model.usageHistoryGrouping == .project
                        ? "Local history, not allowance. Projects come from agent sessions, bucketed by last activity."
                        : "Local history, not allowance. Generated tokens, cache reads and estimated costs across agents, including Devin."
                )
                Spacer(minLength: 12)
                Button(model.isUsageLoading ? "reading…" : "refresh") {
                    Task { await model.refreshUsage(force: true) }
                }.disabled(model.isUsageLoading)
            }
        Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 15) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        controls
                        Spacer(minLength: 0)
                        agentFilter(agents)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        controls
                        agentFilter(agents)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        stackedControls
                        agentFilter(agents)
                    }
                }

                if let history, !history.buckets.isEmpty {
                    legend(history)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            chart(history).frame(minWidth: 330)
                            Rectangle().fill(DaddyTheme.line).frame(width: 1)
                            breakdown(history).frame(width: 220)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            chart(history)
                            Rectangle().fill(DaddyTheme.line).frame(height: 1)
                            breakdown(history)
                        }
                    }
                    if model.usageHistoryGrouping == .project {
                        Text(history.unattributed > 0
                             ? "Session-project ledger: \(format(history.unattributed)) unattributed. Sessions are bucketed by last activity; these totals may not reconcile to daily usage."
                             : "Session-project ledger: project identities come from agent session reports. Buckets use last activity, so totals may not reconcile to daily usage.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    } else if model.usageHistoryGrouping == .provider {
                        Text("Model providers are inferred from reported model names; unknown or private aliases stay unknown. This is not a billing-provider claim.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                    if model.usageMetric == .estimatedCost,
                       model.usageReport?.provenance.pricingComplete == false {
                        Text("Pricing incomplete · known estimated costs only")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                } else {
                    Text("No available activity for these filters.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 130)
                }
                if !model.historySourceNotice.isEmpty {
                    Text(model.historySourceNotice)
                        .font(.caption2).foregroundStyle(DaddyTheme.amber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.usageHistoryGrouping) { selectedPeriod = nil; showAllBreakdown = false }
        .onChange(of: model.usageMetric) { selectedPeriod = nil }
        .onChange(of: model.usageRange) { selectedPeriod = nil }
        .onChange(of: model.usageScale) { selectedPeriod = nil }
        .onChange(of: model.usageHistoryAgents) { selectedPeriod = nil }
    }

    /// Range, scale, group and metric as one quiet control group.
    private var controls: some View {
        HStack(spacing: 0) {
            rangeMenu; controlDivider; scaleMenu; controlDivider; groupMenu; controlDivider; metricMenu
        }
        .controlGroupSurface()
    }

    private var stackedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) { rangeMenu; controlDivider; scaleMenu }.controlGroupSurface()
            HStack(spacing: 0) { groupMenu; controlDivider; metricMenu }.controlGroupSurface()
        }
    }

    private var controlDivider: some View {
        Rectangle().fill(DaddyTheme.line).frame(width: 1, height: 16)
    }

    private var rangeMenu: some View {
        @Bindable var model = model
        return QuietChoiceMenu(title: "range", selection: $model.usageRange,
                               choices: UsageRange.allCases.map { ContextChoice($0, $0.title) })
    }

    private var scaleMenu: some View {
        @Bindable var model = model
        return QuietChoiceMenu(title: "scale", selection: $model.usageScale,
                               choices: UsageChartScale.allCases.map { ContextChoice($0, $0.rawValue) })
    }

    private var groupMenu: some View {
        @Bindable var model = model
        return QuietChoiceMenu(title: "group", selection: $model.usageHistoryGrouping,
                               choices: UsageHistoryGrouping.allCases.map { ContextChoice($0, $0.rawValue) })
    }

    private var metricMenu: some View {
        @Bindable var model = model
        return QuietChoiceMenu(title: "metric", selection: $model.usageMetric,
                               choices: UsageChartMetric.allCases.map { ContextChoice($0, $0.rawValue) })
    }

    /// Agent filter as a plain toggle row: a filled dot means included.
    @ViewBuilder private func agentFilter(_ agents: [String]) -> some View {
        if !agents.isEmpty {
            HStack(spacing: 14) {
                ForEach(agents, id: \.self) { agent in
                    let included = model.usageHistoryAgents.isEmpty || model.usageHistoryAgents.contains(agent)
                    Button { toggle(agent, among: agents) } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .strokeBorder(included ? DaddyTheme.mint : DaddyTheme.muted.opacity(0.6), lineWidth: 1.5)
                                .background(Circle().fill(included ? DaddyTheme.mint : .clear))
                                .frame(width: 8, height: 8)
                            Text(agent.lowercased())
                                .foregroundStyle(included ? Color.white : DaddyTheme.muted)
                        }
                        .font(.caption.weight(.semibold))
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filter \(agent.capitalized)")
                    .accessibilityValue(included ? "Included" : "Excluded")
                }
            }
            .fixedSize()
        }
    }

    private func legend(_ history: UsageHistoryProjection) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(Array(history.visibleSeries.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(tone(index)).frame(width: 7, height: 7)
                    Text(item.label).lineLimit(1).help(item.label)
                }.font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
        }
    }

    private func chart(_ history: UsageHistoryProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(history.buckets) { bucket in
                    ForEach(Array(history.visibleSeries.enumerated()), id: \.element.id) { index, item in
                        BarMark(x: .value("Period", bucket.period),
                                y: .value("Usage", history.value(in: bucket, series: item)), stacking: .standard)
                            .foregroundStyle(tone(index))
                    }
                }
            }
            .chartXSelection(value: $selectedPeriod)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(DaddyTheme.line)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(format(amount)).foregroundStyle(DaddyTheme.muted) }
                    }
                }
            }
            .frame(height: 190)
            .accessibilityLabel("Historical usage by \(model.usageHistoryGrouping.rawValue.lowercased())")
            HStack {
                Text(history.buckets.first?.period ?? "")
                Spacer()
                Text(history.buckets.last?.period ?? "")
            }.font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
            Menu {
                Button("entire selected range") { selectedPeriod = nil }
                ForEach(history.buckets) { bucket in
                    Button(bucket.period) { selectedPeriod = bucket.period }
                }
            } label: {
                Text(selectedPeriod ?? "entire selected range")
            }
            .accessibilityLabel("Inspect usage period")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ history: UsageHistoryProjection) -> some View {
        let selected = history.buckets.first { $0.period == selectedPeriod }
        let rows: [(UsageHistorySeries, Double)] = history.series.map { item in
            (item, selected == nil ? item.value : (selected?.values[item.id] ?? 0))
        }.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        let total = selected?.total ?? history.total
        let visibleCount = showAllBreakdown ? rows.count : min(rows.count, 6)
        return VStack(alignment: .leading, spacing: 10) {
            Text(selected?.period ?? "selected range")
                .font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
            Text(format(total)).font(.title2.bold()).monospacedDigit()
            ForEach(0..<visibleCount, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 6) {
                    Rectangle().fill(tone(min(history.series.firstIndex { $0.id == row.0.id } ?? 4, 4)))
                        .frame(width: 6, height: 6)
                    Text(row.0.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 3)
                    Text(format(row.1)).monospacedDigit()
                }.font(.caption2)
            }
            if rows.count > 6 {
                Button(showAllBreakdown ? "show fewer" : "show all \(rows.count) \(model.usageHistoryGrouping.rawValue.lowercased())s") {
                    showAllBreakdown.toggle()
                }.font(.caption2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ agent: String, among agents: [String]) {
        let all = Set(agents)
        var chosen = model.usageHistoryAgents.isEmpty ? all : model.usageHistoryAgents
        if chosen.contains(agent) { chosen.remove(agent) } else { chosen.insert(agent) }
        model.usageHistoryAgents = chosen.isEmpty || chosen == all ? [] : chosen
    }

    private func tone(_ index: Int) -> Color {
        [DaddyTheme.mint, DaddyTheme.blue, DaddyTheme.amber, DaddyTheme.muted, DaddyTheme.coral][min(index, 4)]
    }

    private func format(_ value: Double) -> String {
        if model.usageMetric == .estimatedCost { return value.formatted(.currency(code: "USD")) }
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// A menu whose label reads inline, e.g. "range last 30 days ⌄", without a box of its own.
private struct QuietChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [ContextChoice<Value>]

    private var selectedTitle: String {
        choices.first { $0.value == selection }?.title ?? "Choose"
    }

    var body: some View {
        Menu {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                Button { selection = choice.value } label: {
                    if selection == choice.value {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).foregroundStyle(DaddyTheme.muted)
                Text(selectedTitle.lowercased()).fontWeight(.semibold).foregroundStyle(Color.white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(DaddyTheme.muted)
            }
            .font(.caption).lineLimit(1)
            .padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(selectedTitle)
    }
}

private extension View {
    func controlGroupSurface() -> some View {
        padding(2)
            .background(DaddyTheme.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DaddyTheme.line))
            .fixedSize()
    }
}
