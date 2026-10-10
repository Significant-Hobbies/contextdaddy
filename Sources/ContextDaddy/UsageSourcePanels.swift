import ContextCore
import SwiftUI
import SaaSMakerUI

/// Account allowance, one provider at a time. A provider with a reading gets
/// one focal number; providers without one collapse to a single quiet line.
struct UsageAllowanceView: View {
    @Environment(ContextDaddyModel.self) private var model
    let stacked: Bool
    /// Focal number beside its detail list; below it when the page is narrow.
    var sideBySide = true
    static let providers = ["codex", "claude", "grok"]

    var body: some View {
        @Bindable var model = model
        let read = Self.providers.filter { model.quotaStatus(for: $0) != nil }
        let unread = Self.providers.filter { model.quotaStatus(for: $0) == nil }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                UsageSectionTitle(title: "allowance", detail: "What each provider says is left on your account.")
                Spacer(minLength: 12)
                checkAllControl
            }
            Panel(padding: stacked ? 16 : 22) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(read.enumerated()), id: \.element) { index, provider in
                        if index > 0 { separator }
                        providerReading(provider)
                            .padding(.top, index == 0 ? 0 : 18)
                            .padding(.bottom, 18)
                    }
                    if !unread.isEmpty {
                        if !read.isEmpty { separator }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(unread, id: \.self) { unreadRow($0) }
                        }
                        .padding(.top, read.isEmpty ? 0 : 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("check allowances when opening usage", isOn: $model.autoCheckAllowance)
                    .font(.caption).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: model.autoCheckAllowance) { _, enabled in
                        if enabled { Task { await model.autoRefreshQuotasIfNeeded() } }
                    }
                Text("Separate from local token history. Checks use each provider's existing sign-in; automatic checks are opt-in and run at most every 15 minutes.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.autoRefreshQuotasIfNeeded() }
    }

    @ViewBuilder private var checkAllControl: some View {
        if model.isQuotaLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("checking…").font(.caption).foregroundStyle(DaddyTheme.muted)
            }
        } else {
            Button("check all") { Task { await model.refreshAllQuotas() } }
        }
    }

    private var separator: some View {
        Rectangle().fill(DaddyTheme.line).frame(height: 1)
    }

    // MARK: Provider with a reading

    private func providerReading(_ provider: String) -> some View {
        let status = model.quotaStatus(for: provider)
        let ready = readyStatus(provider)
        let error = model.quotaErrors[provider]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider).font(.system(size: 17, weight: .bold, design: .rounded))
                if let plan = status?.plan {
                    Text(plan).font(.caption).foregroundStyle(DaddyTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(stateText(provider)).font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor(provider))
            }
            if let ready {
                if sideBySide {
                    HStack(alignment: .top, spacing: 32) {
                        focal(ready).frame(width: 210, alignment: .leading)
                        details(ready).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        focal(ready)
                        details(ready)
                    }
                }
            } else {
                Text(status?.message ?? "The provider did not return an allowance reading.")
                    .font(.callout).foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text("Latest check failed; showing the saved reading. \(error)")
                    .font(.caption).foregroundStyle(DaddyTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            readingDetails(provider)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.capitalized) allowance")
    }

    /// The single number this provider is judged by: the weekly window when
    /// reported, otherwise the tightest window.
    static func focalWindow(_ status: ProviderQuotaStatus) -> ProviderQuotaWindow? {
        status.windows.first { windowKind($0) == "weekly" }
            ?? status.windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    @ViewBuilder private func focal(_ status: ProviderQuotaStatus) -> some View {
        if let window = Self.focalWindow(status) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: stacked ? 40 : 48, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(health(window.remainingPercent).1)
                Text("\(Self.windowName(window)) left")
                    .font(.callout.weight(.semibold))
                if let pace = paceLabel(window) {
                    Text(pace).font(.caption).foregroundStyle(DaddyTheme.muted)
                }
                Text(Self.windowResetText(window) ?? "Reset time not reported")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("No usage windows reported")
                .font(.callout).foregroundStyle(DaddyTheme.muted)
        }
    }

    private func details(_ status: ProviderQuotaStatus) -> some View {
        let focalID = Self.focalWindow(status)?.id
        return VStack(alignment: .leading, spacing: 11) {
            ForEach(status.windows.filter { $0.id != focalID }, id: \.id) { window in
                detailRow(Self.windowName(window)) {
                    Text("\(Int(window.remainingPercent.rounded()))% left")
                        .foregroundStyle(health(window.remainingPercent).1).monospacedDigit()
                    Text([paceLabel(window), Self.windowResetText(window) ?? "Reset time not reported"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                }
            }
            if status.windows.isEmpty, let end = status.grokBilling?.periodEnd {
                detailRow("period") { Text("Resets · \(end)") }
            }
            detailRow("credits") {
                Text(Self.creditText(status) ?? "Not reported")
                Text(status.provider == "claude" ? "Paid usage credits" : status.provider == "grok" ? "Prepaid balance · USD" : "Codex credit units")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            }
            detailRow("reset grants") {
                if let grants = status.claudeResetGrants, status.provider == "claude" {
                    claudeGrantRows(grants)
                } else {
                    Text(Self.resetCountText(status))
                }
                if status.provider == "codex", status.resetCredits != nil { resetExpiry(status) }
                if let error = status.resetGrantError {
                    Text(error).font(.caption).foregroundStyle(DaddyTheme.amber)
                }
                if status.provider == "claude", status.claudeResetGrants == nil, status.resetCredits == nil {
                    claudeUsageLink
                }
            }
            if let billing = status.grokBilling {
                detailRow("pay as you go") {
                    Text(billing.onDemandEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not reported")
                    let spend = [billing.onDemandUsedUSD.map { "Used \($0.formatted(.currency(code: "USD")))" },
                                 billing.onDemandCapUSD.map { "cap \($0.formatted(.currency(code: "USD")))" }]
                        .compactMap { $0 }
                    if !spend.isEmpty {
                        Text(spend.joined(separator: " · ")).font(.caption).foregroundStyle(DaddyTheme.muted)
                    }
                }
            }
        }
    }

    private func detailRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.callout).foregroundStyle(DaddyTheme.muted)
                .frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) { value() }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Provider without a reading

    private func unreadRow(_ provider: String) -> some View {
        let error = model.quotaErrors[provider]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(provider).font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(width: 64, alignment: .leading)
            Text(error.map { "Check failed. \($0)" } ?? "Not checked yet")
                .font(.caption).foregroundStyle(error == nil ? DaddyTheme.muted : DaddyTheme.amber)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if !model.isQuotaLoading, let service = UsageService.allCases.first(where: { $0.quotaKey == provider }) {
                Button("check") { Task { await model.refreshQuotas(for: [service]) } }
                    .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
                    .accessibilityLabel("Check \(provider.capitalized) allowance")
            }
        }
    }

    // MARK: Shared pieces

    private func readyStatus(_ provider: String) -> ProviderQuotaStatus? {
        guard let status = model.quotaStatus(for: provider), status.status == "ready" else { return nil }
        return status
    }

    private func stateText(_ provider: String) -> String {
        let remaining = readyStatus(provider).flatMap { Self.focalWindow($0)?.remainingPercent }
        if model.quotaErrors[provider] != nil { return readyStatus(provider) == nil ? "unavailable" : "stale" }
        if readyStatus(provider) == nil { return "no reading" }
        return remaining.map { health($0).0 } ?? "ready"
    }

    private func stateColor(_ provider: String) -> Color {
        if model.quotaErrors[provider] != nil { return DaddyTheme.amber }
        let remaining = readyStatus(provider).flatMap { Self.focalWindow($0)?.remainingPercent }
        return remaining.map { health($0).1 } ?? DaddyTheme.muted
    }

    static func windowKind(_ window: ProviderQuotaWindow) -> String {
        if window.windowDurationMinutes == 300 || window.id == "current" || window.label == "5-hour window" { return "short" }
        if window.windowDurationMinutes == 10_080 || window.id == "weekly" || window.label == "Weekly window" { return "weekly" }
        return "other"
    }

    static func windowName(_ window: ProviderQuotaWindow) -> String {
        switch windowKind(window) {
        case "short": "5-hour"
        case "weekly": "weekly"
        default: window.label.lowercased()
        }
    }

    @ViewBuilder private func readingDetails(_ provider: String) -> some View {
        if let status = model.quotaStatus(for: provider) {
            DisclosureGroup("source & details") {
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
                }
                .font(.caption).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private func health(_ remaining: Double) -> (String, Color) {
        if remaining <= 20 { return ("low", DaddyTheme.coral) }
        if remaining <= 40 { return ("watch", DaddyTheme.amber) }
        return ("healthy", DaddyTheme.mint)
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
                    .font(.callout).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(summary.grants.indices.filter { summary.grants[$0].kind == kind }, id: \.self) { index in
                    let grant = summary.grants[index]
                    Text("\(grant.count == 1 ? "Expires" : "\(grant.count) expire") · \(Date(timeIntervalSince1970: TimeInterval(grant.expiresAtUnix)).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if grant.paused || !grant.usableNow {
                        Text(grant.paused ? "Paused" : "Not usable right now")
                            .font(.caption).foregroundStyle(DaddyTheme.amber)
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
                .font(.caption).foregroundStyle(DaddyTheme.muted)
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

/// Quiet lowercase section heading shared by the Usage page sections.
struct UsageSectionTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SMDisplay(title, size: 20).accessibilityLabel(title)
            Text(detail).font(.caption).foregroundStyle(DaddyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
