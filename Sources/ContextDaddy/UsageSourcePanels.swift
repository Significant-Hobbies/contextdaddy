import ContextCore
import SwiftUI

struct UsageAllowanceView: View {
    @Environment(ContextDaddyModel.self) private var model
    let stacked: Bool
    private let providers = ["codex", "claude", "grok"]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PROVIDER ALLOWANCE").font(.caption.weight(.bold)).tracking(1).foregroundStyle(DaddyTheme.mint)
                Spacer()
                Button(model.isQuotaLoading ? "Checking…" : "Check allowances") {
                    Task { await model.refreshAllQuotas() }
                }.disabled(model.isQuotaLoading)
            }
            Panel(padding: stacked ? 12 : 18) {
                Grid(alignment: .topLeading, horizontalSpacing: stacked ? 12 : 20, verticalSpacing: 14) {
                    row("Allowance") { provider in
                        providerHeading(provider)
                    }
                    rule
                    row("5-hour remaining") { provider in
                        percentageCell(provider, kind: "short")
                    }
                    row("Weekly remaining") { provider in
                        percentageCell(provider, kind: "weekly")
                    }
                    if providers.contains(where: { windows(for: $0, kind: "other").isEmpty == false }) {
                        row("Other windows") { provider in
                            percentageCell(provider, kind: "other")
                        }
                    }
                    rule
                    row("Scheduled resets") { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            if let status = readyStatus(provider), !status.windows.isEmpty {
                                ForEach(status.windows, id: \.id) { window in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(window.label).font(.caption.weight(.semibold))
                                        Text(Self.windowResetText(window) ?? "Reset time not reported")
                                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                                    }
                                }
                            } else if let end = readyStatus(provider)?.grokBilling?.periodEnd {
                                Text("Resets · \(end)").font(.caption).foregroundStyle(DaddyTheme.muted)
                            } else { missingValue(provider) }
                        }
                    }
                    rule
                    row("Credit balance") { provider in
                        VStack(alignment: .leading, spacing: 4) {
                            if let status = readyStatus(provider) {
                                Text(Self.creditText(status) ?? "Not reported").font(.callout.weight(.medium))
                                Text(provider == "claude" ? "Paid usage credits" : provider == "grok" ? "Prepaid balance · USD" : "Codex credit units")
                                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
                            } else { missingValue(provider) }
                        }
                    }
                    row("Reset grants & expiry") { provider in
                        VStack(alignment: .leading, spacing: 6) {
                            if let status = readyStatus(provider) {
                                if let grants = status.claudeResetGrants, provider == "claude" {
                                    claudeGrantRows(grants)
                                } else {
                                    Text(Self.resetCountText(status)).font(.callout.weight(.medium))
                                }
                                if provider == "codex", status.resetCredits != nil { resetExpiry(status) }
                                if let error = status.resetGrantError {
                                    Text(error).font(.caption2).foregroundStyle(DaddyTheme.amber)
                                }
                                if provider == "claude", status.claudeResetGrants == nil, status.resetCredits == nil {
                                    claudeUsageLink
                                }
                            } else { missingValue(provider) }
                        }
                    }
                    if readyStatus("grok")?.grokBilling != nil {
                        row("Pay as you go") { provider in
                            if let billing = readyStatus(provider)?.grokBilling {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(billing.onDemandEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not reported")
                                    if let used = billing.onDemandUsedUSD {
                                        Text("Used · \(used.formatted(.currency(code: "USD")))")
                                    }
                                    if let cap = billing.onDemandCapUSD {
                                        Text("Cap · \(cap.formatted(.currency(code: "USD")))")
                                    }
                                }.font(.caption)
                            } else { Text("Not reported").font(.caption).foregroundStyle(DaddyTheme.muted) }
                        }
                    }
                    rule
                    row("Source & details") { provider in
                        readingDetails(provider)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Check allowances when opening Usage", isOn: $model.autoCheckAllowance)
                .font(.caption).toggleStyle(.switch).controlSize(.small)
                .onChange(of: model.autoCheckAllowance) { _, enabled in
                    if enabled { Task { await model.autoRefreshQuotasIfNeeded() } }
                }
            Text("Account allowance is separate from local token history. Checks may contact Codex, Claude and Grok using their existing sign-in. Automatic checks are opt-in, at most once every 15 minutes.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task { await model.autoRefreshQuotasIfNeeded() }
    }

    private var rule: some View {
        GridRow { Divider().overlay(DaddyTheme.line).gridCellColumns(4) }
    }

    private func row<Cell: View>(_ label: String, @ViewBuilder cell: @escaping (String) -> Cell) -> some View {
        GridRow(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(DaddyTheme.muted)
                .frame(width: stacked ? 108 : 145, alignment: .leading)
            ForEach(providers, id: \.self) { provider in
                cell(provider).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("\(provider.capitalized), \(label)")
            }
        }
    }

    private func readyStatus(_ provider: String) -> ProviderQuotaStatus? {
        guard let status = model.quotaStatus(for: provider), status.status == "ready" else { return nil }
        return status
    }

    private func providerHeading(_ provider: String) -> some View {
        let status = readyStatus(provider)
        let error = model.quotaErrors[provider]
        let remaining = status?.windows.map(\.remainingPercent).min()
        return VStack(alignment: .leading, spacing: 5) {
            Text(provider.capitalized).font(.title3.weight(.semibold))
            if let plan = status?.plan { Text(plan).font(.caption).foregroundStyle(DaddyTheme.muted) }
            Text(error != nil ? (status == nil ? "Unavailable" : "Stale") : status == nil ? "Not checked" : remaining.map { health($0).0 } ?? "Ready")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(error != nil ? DaddyTheme.amber : remaining.map { health($0).1 } ?? DaddyTheme.muted)
        }
    }

    @ViewBuilder private func missingValue(_ provider: String) -> some View {
        Text(readyStatus(provider) != nil ? "Not reported" : model.quotaErrors[provider] != nil ? "Unavailable" : "Not checked")
            .font(.caption).foregroundStyle(DaddyTheme.muted)
    }

    static func windowKind(_ window: ProviderQuotaWindow) -> String {
        if window.windowDurationMinutes == 300 || window.id == "current" || window.label == "5-hour window" { return "short" }
        if window.windowDurationMinutes == 10_080 || window.id == "weekly" || window.label == "Weekly window" { return "weekly" }
        return "other"
    }

    private func windows(for provider: String, kind: String) -> [ProviderQuotaWindow] {
        readyStatus(provider)?.windows.filter { Self.windowKind($0) == kind } ?? []
    }

    @ViewBuilder private func percentageCell(_ provider: String, kind: String) -> some View {
        let readings = windows(for: provider, kind: kind)
        if readings.isEmpty { missingValue(provider) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(readings, id: \.id) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        if kind == "other" { Text(window.label).font(.caption).foregroundStyle(DaddyTheme.muted) }
                        Text("\(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: stacked ? 25 : 31, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(health(window.remainingPercent).1)
                        if let pace = paceLabel(window) { Text(pace).font(.caption2).foregroundStyle(DaddyTheme.muted) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func readingDetails(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.quotaErrors[provider] {
                Text("Latest check failed. \(error)").font(.caption2).foregroundStyle(DaddyTheme.amber)
            }
            if let status = model.quotaStatus(for: provider) {
                DisclosureGroup("Reading details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.source)
                        Text("Checked · \(status.checkedAt)")
                        if model.quotaErrors[provider] != nil { Text("Saved reading may be stale.").foregroundStyle(DaddyTheme.amber) }
                        if let message = status.message { Text(message) }
                        if let grants = status.claudeResetGrants { Text("Reset grants checked · \(grants.checkedAt)") }
                        if let latest = status.latestReportedResetCreditExpiryUnix {
                            Text("Latest reported grant expiry · \(Date(timeIntervalSince1970: TimeInterval(latest)).formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let count = status.resetCreditsWithoutExpiryCount, count > 0 {
                            Text("\(count) reported grants have no expiry.")
                        }
                        if let billing = status.grokBilling {
                            if let unified = billing.unifiedBilling { Text(unified ? "Shared usage pool" : "Legacy billing") }
                            if let start = billing.periodStart { Text("Period start · \(start)") }
                            if let end = billing.periodEnd { Text("Period end · \(end)") }
                            if let type = billing.periodType { Text("Reported period · \(type)") }
                            if let used = billing.includedUsedUSD { Text("Included used · \(used.formatted(.currency(code: "USD")))") }
                            if let limit = billing.includedLimitUSD { Text("Included limit · \(limit.formatted(.currency(code: "USD")))") }
                        }
                    }.font(.caption2).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                        .padding(.top, 6)
                }.font(.caption).foregroundStyle(DaddyTheme.muted)
            } else {
                Text("Check allowances for an account reading.").font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
        }
    }

    private func health(_ remaining: Double) -> (String, Color) {
        if remaining <= 20 { return ("Low", DaddyTheme.coral) }
        if remaining <= 40 { return ("Watch", DaddyTheme.amber) }
        return ("Healthy", DaddyTheme.mint)
    }

    private func paceLabel(_ window: ProviderQuotaWindow) -> String? {
        guard let minutes = window.windowDurationMinutes, minutes > 0, let reset = window.resetsAtUnix else { return nil }
        let remaining = (Double(reset) - Date().timeIntervalSince1970) / (Double(minutes) * 60)
        guard remaining > 0, remaining <= 1 else { return nil }
        let delta = window.remainingPercent - remaining * 100
        if abs(delta) < 1 { return "On even-use pace" }
        return "\(delta > 0 ? "+" : "")\(Int(delta.rounded())) pts \(delta > 0 ? "ahead of" : "behind") even pace"
    }

    static func creditText(_ status: ProviderQuotaStatus) -> String? {
        if status.provider == "grok" {
            return status.grokBilling?.prepaidUSD.map { $0.formatted(.currency(code: "USD")) } ?? "Not reported"
        }
        if status.provider == "codex" {
            guard let credits = status.credits else { return "Credit balance not reported" }
            if credits.unlimited == true { return "Unlimited credits" }
            if let balance = credits.balance {
                if balance > 0, balance < Decimal(1) / 100 {
                    return "<\((Decimal(1) / 100).formatted(.number)) credits remaining"
                }
                return "\(balance.formatted(.number.precision(.fractionLength(0...2)))) credits remaining"
            }
            if credits.hasCredits == false { return "No credits available" }
            if credits.hasCredits == true { return "Credits available · balance not reported" }
            return "Credit balance not reported"
        }
        guard let credits = status.credits else { return nil }
        if let limit = credits.limitAmount, let used = credits.usedAmount {
            return "\(max(0, limit - used).formatted(.currency(code: "USD"))) credits"
        }
        if let remaining = credits.remainingPercent {
            return "\(Int(remaining.rounded()))% credits"
        }
        return nil
    }

    static let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!

    private var claudeUsageLink: some View {
        Link(destination: Self.claudeUsageURL) {
            HStack(spacing: 3) {
                Text("View Claude Usage")
                Image(systemName: "arrow.up.right")
            }.font(.caption2)
        }
        .buttonStyle(.plain).foregroundStyle(DaddyTheme.mint)
    }

    static func resetCountText(_ status: ProviderQuotaStatus) -> String {
        guard let count = status.resetCredits else { return "Not reported" }
        return "\(count) \(status.provider == "claude" ? "usage" : "full") \(count == 1 ? "reset" : "resets") available"
    }

    static func claudeGrantCountText(_ count: UInt64, kind: String) -> String {
        "\(kind == "full" ? "Full resets" : "5-hour resets") · \(count == 0 ? "None" : "\(count) left")"
    }

    @ViewBuilder private func claudeGrantRows(_ summary: ClaudeResetGrantSummary) -> some View {
        ForEach(["full", "five-hour"], id: \.self) { kind in
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.claudeGrantCountText(kind == "full" ? summary.fullCount : summary.fiveHourCount, kind: kind))
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(summary.grants.indices.filter { summary.grants[$0].kind == kind }, id: \.self) { index in
                    let grant = summary.grants[index]
                    Text("\(grant.count == 1 ? "Expires" : "\(grant.count) expire") · \(Date(timeIntervalSince1970: TimeInterval(grant.expiresAtUnix)).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if grant.paused || !grant.usableNow {
                        Text(grant.paused ? "Paused" : "Not usable right now")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                }
            }
        }
    }

    static func windowResetText(_ window: ProviderQuotaWindow) -> String? {
        if let description = window.resetDescription { return "Resets \(description)" }
        guard let unix = window.resetsAtUnix else { return nil }
        return "Resets \(Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder private func resetExpiry(_ status: ProviderQuotaStatus) -> some View {
        if let unix = status.earliestReportedResetCreditExpiryUnix {
            Text("First reported expiry · \(Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
        } else if (status.resetCredits ?? 0) > 0 {
            Text(status.resetCreditsWithoutExpiryCount == status.resetCredits
                 ? "Reported reset grants do not expire" : "Reset-grant expiry unavailable")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
        if let details = status.resetCreditDetailsCount, details < (status.resetCredits ?? 0) {
            Text("Only \(details) of \(status.resetCredits ?? 0) grant details reported; an earlier expiry may exist.")
                .font(.caption2).foregroundStyle(DaddyTheme.amber)
        }
    }
}
