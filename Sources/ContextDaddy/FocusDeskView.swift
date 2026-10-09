import ContextCore
import Charts
import SwiftUI

struct FocusDeskView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var showModels = false
    @State private var showProjects = false
    @State private var showAllProjects = false
    @State private var showSessions = false
    @State private var selectedPeriod: String?
    @State private var showSources = false
    @State private var showSelectedService = false
    @State private var showDiagnostics = false
    /// The visible page size, read from the scroll view itself so content never
    /// lays out wider than the area that can show it.
    @State private var pageSize = CGSize(width: 1000, height: 800)

    var body: some View {
        @Bindable var model = model
        let dashboard = model.usageDashboard
        let compact = pageSize.width < 860 || pageSize.height < 700
        let narrowFilters = pageSize.width < 600
        let serviceMenu = ContextChoiceMenu(
            title: "Service",
            selection: $model.usageService,
            choices: UsageService.allCases.map { ContextChoice($0, $0.menuTitle) },
            width: narrowFilters ? 300 : compact ? 164 : 186
        )
        let modelMenu = ContextChoiceMenu(
            title: "Model",
            selection: $model.usageModel,
            choices: [ContextChoice<String?>(nil, "All observed")] + model.usageModels.map { ContextChoice<String?>($0, $0) },
            width: narrowFilters ? 300 : compact ? 182 : 216
        ).disabled(model.usageModels.isEmpty)
        let rangeMenu = ContextChoiceMenu(
            title: "Range",
            selection: $model.usageRange,
            choices: UsageRange.allCases.map { ContextChoice($0, $0.title) },
            width: narrowFilters ? 300 : compact ? 132 : 150
        )
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: compact ? 22 : 30) {
                ScreenHeader(
                    eyebrow: "",
                    title: "usage",
                    subtitle: "What's left on your Codex, Claude and Grok accounts, and what your agents used locally. Recorded runs are in Run telemetry.",
                    art: .telemetry,
                    hero: !compact,
                    compact: compact
                )

                UsageAllowanceView(stacked: narrowFilters, sideBySide: pageSize.width >= 680)
                UnifiedUsageHistoryView()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showDiagnostics.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "chart.bar.xaxis")
                        Text(showDiagnostics ? "hide usage diagnostics" : "show usage diagnostics")
                        Spacer()
                        Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DaddyTheme.muted)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showDiagnostics ? "Hide usage diagnostics" : "Show usage diagnostics")

                if showDiagnostics {
                Panel(padding: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            serviceMenu
                            modelMenu
                            rangeMenu
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            serviceMenu
                            modelMenu
                            rangeMenu
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                chapter(title: "Selected-service summary", detail: "Local history · \(model.usageService.menuTitle)", icon: "chart.bar.xaxis", expanded: $showSelectedService) {
                    localHistoryPanel
                }

                chapter(title: "Model mix", detail: dashboard?.models.isEmpty == false ? "\(dashboard?.models.count ?? 0) observed · local history" : "No observed model data", icon: "cpu", expanded: $showModels) {
                    if let dashboard, !dashboard.models.isEmpty {
                        ForEach(dashboard.models) { item in
                            HStack(spacing: 8) {
                                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                if item.fallback || !item.priced {
                                    Text(item.priced ? "FALLBACK" : "UNPRICED")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(DaddyTheme.amber)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatTokens(item.generatedTokens))
                                    Text(item.priced ? "Est. \(item.costUSD.formatted(.currency(code: "USD")))" : "Cost incomplete")
                                        .foregroundStyle(item.priced ? DaddyTheme.muted : DaddyTheme.amber)
                                }
                                .font(.caption.monospacedDigit())
                            }
                            .padding(.vertical, 3)
                        }
                    } else {
                        emptyLine("No model breakdown is available for this service and range.")
                    }
                }

                chapter(title: "Projects in session history", detail: dashboard?.projects.isEmpty == false ? "\(dashboard?.projects.count ?? 0) attributed or unattributed projects" : "No session-level attribution", icon: "folder", expanded: $showProjects) {
                    if let dashboard, !dashboard.projects.isEmpty {
                        Text("Projects are attributed from sessions, not daily totals; the two views may not reconcile. Costs are estimates and can be incomplete.")
                            .font(.caption).foregroundStyle(DaddyTheme.amber)
                        ForEach(showAllProjects ? dashboard.projects : Array(dashboard.projects.prefix(12))) { item in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(UsageProjectIdentity.detail(item.path))
                                        .font(.caption2).foregroundStyle(DaddyTheme.muted).lineLimit(1)
                                        .help(UsageProjectIdentity.detail(item.path))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(item.sessions) sessions · \(formatTokens(item.generatedTokens))")
                                    Text("Est. \(item.costUSD.formatted(.currency(code: "USD")))")
                                }
                                .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                            }
                            .padding(.vertical, 3)
                        }
                        if dashboard.projects.count > 12 {
                            Button(showAllProjects ? "Show fewer projects" : "Show all \(dashboard.projects.count) projects") {
                                showAllProjects.toggle()
                            }
                        }
                    } else {
                        emptyLine("No project attribution is available for this selection.")
                    }
                }

                chapter(title: "Recent local sessions", detail: dashboard?.sessionCount == 0 ? "No indexed session detail" : "Latest \(dashboard?.recentSessions.count ?? 0) of \(dashboard?.sessionCount ?? 0)", icon: "clock.arrow.circlepath", expanded: $showSessions) {
                    if let dashboard, !dashboard.recentSessions.isEmpty {
                        ForEach(dashboard.recentSessions) { session in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.projectName).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(session.lastActivity.map(shortTime) ?? "Time unavailable")
                                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatTokens(session.generatedTokens))
                                    Text("Est. \(session.costUSD.formatted(.currency(code: "USD")))")
                                }
                                .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                            }
                            .padding(.vertical, 3)
                        }
                    } else {
                        emptyLine(model.usageService == .devin
                                  ? "Devin supplies window counts, not individual session rows in this source."
                                  : "No indexed sessions are available for this selection.")
                    }
                }

                chapter(title: "Sources, freshness & limits", detail: "What these numbers can—and cannot—say", icon: "info.circle", expanded: $showSources) {
                    sourceDetails
                }
                }
            }
            .padding(compact ? 18 : 28)
            .frame(maxWidth: 1220, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
    }

    private var localHistoryPanel: some View {
        let slice = model.usageSlice
        let hasData = (slice?.observations ?? 0) > 0
        let stale = model.usageService != .devin &&
            (model.usageReport?.stale == true || model.usageError != nil && model.usageReport != nil)
        return Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LOCAL HISTORY")
                        .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1)
                        .foregroundStyle(DaddyTheme.muted)
                    Spacer()
                    EvidenceBadge(quality: hasData ? (stale ? .partial : .derived) : .unavailable)
                }
                Text(hasData ? formatTokens(slice!.generatedTokens) : "—")
                    .font(.system(size: 39, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Text("Generated tokens · \(model.usageRange.title.lowercased())")
                    .font(.subheadline.weight(.semibold))
                if hasData, let slice {
                    Text("Input + cache creation + output. Cache reads are shown separately.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                    HStack(spacing: 18) {
                        smallFact("Cache read", formatTokens(slice.cacheReadTokens))
                        smallFact("Est. cost", slice.unpriced ? "Incomplete" : slice.costUSD.formatted(.currency(code: "USD")))
                    }
                    if slice.fallbackPricing || slice.unpriced {
                        Text(slice.unpriced ? "Some models are unpriced; cost is incomplete." : "Some model prices use fallback mapping.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                } else {
                    Text(localEmptyMessage)
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { historySource; Spacer(); refreshHistoryButton }
                    VStack(alignment: .leading, spacing: 8) { historySource; refreshHistoryButton }
                }
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func historyPanel(dashboard: UsageDashboardProjection?, compact: Bool) -> some View {
        @Bindable var model = model
        return Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 15) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        historyHeading
                        Spacer(minLength: 0)
                        historyControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        historyHeading
                        historyControls
                    }
                }

                if let dashboard, !dashboard.trend.isEmpty {
                    Chart(dashboard.trend) { point in
                        BarMark(x: .value("Period", point.period), y: .value(model.usageMetric.rawValue, point.value))
                            .foregroundStyle(DaddyTheme.mint)
                            .cornerRadius(2)
                            .accessibilityLabel(point.period)
                            .accessibilityValue(chartValue(point.value, metric: model.usageMetric))
                    }
                    .chartXSelection(value: $selectedPeriod)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(DaddyTheme.line)
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(chartValue(number, metric: model.usageMetric))
                                        .foregroundStyle(DaddyTheme.muted)
                                }
                            }
                        }
                    }
                    .frame(height: compact ? 160 : 190)
                    .accessibilityLabel("\(model.usageMetric.rawValue) by \(model.usageScale.rawValue.lowercased())")
                    HStack {
                        Text(dashboard.trend.first?.period ?? "")
                        Spacer()
                        Text(dashboard.trend.last?.period ?? "")
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    if let selected = dashboard.trend.first(where: { $0.period == selectedPeriod }) {
                        Text("\(selected.period) · \(selectedChartValue(selected.value, metric: model.usageMetric)) \(model.usageMetric.rawValue.lowercased())")
                            .font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
                    } else {
                        Text("Select a bar for its period and value.")
                            .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    }
                    if dashboard.chartTruncated {
                        Text("Chart shows the latest \(dashboard.trend.count) periods; the totals above still cover the selected range.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                } else {
                    Text(model.usageService == .devin
                         ? "Devin's indexed source supplies window totals but no daily trend."
                         : "No historical chart is available for this selection.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                }

                HStack(spacing: 14) {
                    smallFact("Sessions", (dashboard?.sessionCount ?? 0).formatted())
                    smallFact("Active days", (dashboard?.slice?.observations ?? 0).formatted())
                    Spacer(minLength: 0)
                    Text("Local history · not provider allowance")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historyHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HISTORICAL USAGE")
                .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1)
                .foregroundStyle(DaddyTheme.mint)
            Text("Where usage changed")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("Daily log accounting, grouped only for the chart. Costs are estimates.")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var historyControls: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            ContextChoiceMenu(title: "Metric", selection: $model.usageMetric,
                              choices: UsageChartMetric.allCases.map { ContextChoice($0, $0.rawValue) }, width: 152)
            ContextChoiceMenu(title: "Scale", selection: $model.usageScale,
                              choices: UsageChartScale.allCases.map { ContextChoice($0, $0.rawValue) }, width: 126)
        }
    }

    private var localEmptyMessage: String {
        if model.isUsageLoading { return "Reading bounded local usage history…" }
        if model.usageService == .cursor { return "No verified Cursor usage source is connected. Inventory is available elsewhere in the app." }
        if model.usageService == .devin, model.usageReport?.devin?.status != "unavailable" {
            return "No indexed Devin sessions were observed for this range."
        }
        if let error = model.usageError { return error }
        if model.usageReport == nil { return "Local ccusage history has not been loaded." }
        if model.usageReport?.status == "unavailable" { return model.usageReport?.error?.message ?? "Local history is unavailable." }
        return "No local usage was observed for this service, model, and range."
    }

    private var historySource: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.usageService == .devin ? "Devin · local session index" : "ccusage \(model.usageReport?.provenance.version ?? "")")
            if let generated = model.usageReport?.provenance.generatedAt {
                Text("Updated \(shortTime(generated))")
            }
        }
        .lineLimit(1)
    }

    private var refreshHistoryButton: some View {
        Button(model.isUsageLoading ? "Reading…" : "Refresh history") {
            Task { await model.refreshUsage(force: true) }
        }
        .disabled(model.isUsageLoading)
    }

    private var allowancePanel: some View {
        let status = model.quotaStatus
        let window = status?.windows.first
        return Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("PROVIDER ALLOWANCE")
                        .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1)
                        .foregroundStyle(DaddyTheme.muted)
                    Spacer()
                    if status == nil && model.quotaError == nil && model.usageService.quotaKey != nil {
                        Text(model.isQuotaLoading ? "CHECKING" : "NOT CHECKED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(DaddyTheme.muted)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(DaddyTheme.raised, in: Capsule())
                    } else {
                        EvidenceBadge(quality: status?.status == "ready"
                            ? (model.quotaError == nil ? .measured : .partial)
                            : .unavailable)
                    }
                }
                Text(model.usageService.rawValue)
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(1)
                if let window, status?.status == "ready" {
                    Text("\(Int(window.remainingPercent.rounded()))% remaining")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(DaddyTheme.mint)
                        .monospacedDigit()
                    GeometryReader { proxy in
                        Capsule().fill(DaddyTheme.raised)
                            .overlay(alignment: .leading) {
                                Capsule().fill(DaddyTheme.mint)
                                    .frame(width: proxy.size.width * min(1, max(0, window.remainingPercent / 100)))
                            }
                    }.frame(height: 6)
                    Text("\(window.label) · \(window.resetDescription ?? "Reset time unavailable")")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                } else {
                    Text(model.usageService.quotaKey == nil
                        ? "No verified allowance adapter for this service."
                    : status?.message ?? model.quotaError ?? "Check allowance for a live reading, or enable the opt-in check on Usage.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Text("Account-level, not token history; model and range filters do not apply. Checking may contact the provider.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
                if let error = model.quotaError, status != nil {
                    Text("Latest check failed; showing the previous reading. \(error)")
                        .font(.caption2).foregroundStyle(DaddyTheme.amber)
                }
                HStack {
                    if let status { Text("\(status.source) · \(shortTime(status.checkedAt))").lineLimit(1) }
                    Spacer(minLength: 0)
                    Button(model.isQuotaLoading ? "Checking…" : "Check allowance") {
                        Task { await model.refreshQuota() }
                    }
                    .disabled(model.isQuotaLoading || model.usageService.quotaKey == nil)
                }
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let report = model.usageReport {
                sourceLine("Local report", "\(report.provenance.engine) \(report.provenance.version) · \(report.status) · generated \(report.provenance.generatedAt)")
                if let agents = report.provenance.detectedAgents, !agents.isEmpty {
                    sourceLine("Detected agents", agents.joined(separator: ", "))
                }
                sourceLine("Sessions", "Local sessions are separate from daily totals. Project identities come from matching agent session reports; Claude reports an encoded slug. Session time buckets use last activity and may not reconcile to daily usage.")
                if let fingerprint = report.provenance.sourceFingerprint, !fingerprint.isEmpty {
                    sourceLine("Source ID", String(fingerprint.prefix(24)) + "…")
                }
                if let error = model.usageError { sourceLine("Local warning", error) }
                if !report.provenance.unpricedModels.isEmpty {
                    sourceLine("Unpriced models", report.provenance.unpricedModels.joined(separator: ", "))
                }
            } else {
                sourceLine("Local report", model.usageError ?? "No ccusage report loaded")
            }
            if let status = model.quotaStatus {
                sourceLine("Allowance", "\(status.source) · checked \(status.checkedAt) · \(status.status)")
            } else {
                sourceLine("Allowance", "No live check for the selected service")
            }
            sourceLine("OTEL", "Separate Codex and Claude 24-hour views when supplied by the local collector; Devin has no verified live adapter · \(model.telemetry.collectorReachable ? "reachable" : "unavailable")")
            sourceLine("Network", "Logical request events only; transferred internet bytes are not measured")
            sourceLine("Collection", "Local history uses bundled offline ccusage. Allowance checks use Codex app-server and Claude Code directly, manually or after opt-in.")
        }
    }

    private func smallFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.5).foregroundStyle(DaddyTheme.muted)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    private func emptyLine(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(DaddyTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLine(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 95, alignment: .leading)
            Text(detail).font(.caption).foregroundStyle(DaddyTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    private func chapter<Content: View>(title: String, detail: String, icon: String,
                                         expanded: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon).foregroundStyle(DaddyTheme.mint).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text(detail).font(.caption2).foregroundStyle(DaddyTheme.muted)
                        }
                        Spacer()
                        Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
                if expanded.wrappedValue { content() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatTokens(_ value: UInt64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return value.formatted()
    }

    private func chartValue(_ value: Double, metric: UsageChartMetric) -> String {
        if metric == .estimatedCost {
            if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
            return String(format: "$%.2f", value)
        }
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func selectedChartValue(_ value: Double, metric: UsageChartMetric) -> String {
        if metric == .estimatedCost { return "Est. \(value.formatted(.currency(code: "USD")))" }
        guard value.isFinite else { return "Unavailable" }
        if value >= Double(UInt64.max) { return UInt64.max.formatted() }
        return UInt64(max(0, value)).formatted()
    }

    private func shortTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
