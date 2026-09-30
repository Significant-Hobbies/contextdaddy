import ContextCore
import SwiftUI

/// Both provider cards remain visible as in CodeVetter. Automatic checks are
/// opt-in and throttled; the manual button always remains available.
struct UsageAllowanceView: View {
    @Environment(ContextDaddyModel.self) private var model
    let stacked: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            if stacked {
                VStack(alignment: .leading, spacing: 8) { allowanceHeading; checkButton }
            } else {
                HStack { allowanceHeading; Spacer(); checkButton }
            }
            if stacked {
                VStack(spacing: 12) {
                    card("codex", title: "Codex")
                    card("claude", title: "Claude")
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    card("codex", title: "Codex").frame(maxWidth: .infinity)
                    card("claude", title: "Claude").frame(maxWidth: .infinity)
                }
            }
            Toggle("Check allowances when opening Usage", isOn: $model.autoCheckAllowance)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: model.autoCheckAllowance) { _, enabled in
                    if enabled { Task { await model.autoRefreshQuotasIfNeeded() } }
                }
            Text("Account-level allowance is separate from local tokens. Checks may contact Codex and Claude; automatic checks are opt-in and run at most once every 15 minutes.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task { await model.autoRefreshQuotasIfNeeded() }
    }

    private var allowanceHeading: some View {
        Text("PROVIDER ALLOWANCE").font(.caption.weight(.bold)).tracking(1)
            .foregroundStyle(DaddyTheme.mint)
    }

    private var checkButton: some View {
        Button(model.isQuotaLoading ? "Checking…" : "Check both allowances") {
            Task { await model.refreshAllQuotas() }
        }.disabled(model.isQuotaLoading)
    }

    private func card(_ provider: String, title: String) -> some View {
        let status = model.quotaStatus(for: provider)
        let windows = visibleWindows(status)
        let worst = windows.map(\.remainingPercent).min() ?? 100
        let error = model.quotaErrors[provider]
        return Panel(padding: status == nil ? 14 : 18) {
            VStack(alignment: .leading, spacing: status == nil ? 6 : 10) {
                HStack {
                    Text(title).font(.title3.weight(.semibold))
                    if let plan = status?.plan {
                        Text(plan.uppercased()).font(.caption2.weight(.bold).monospaced())
                            .foregroundStyle(DaddyTheme.muted)
                    }
                    Spacer()
                    Text(status == nil ? "NOT CHECKED" : status?.status == "ready" && !windows.isEmpty
                         ? health(worst).0.uppercased() : "UNAVAILABLE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(status?.status == "ready" && error == nil ? health(worst).1 : DaddyTheme.muted)
                }
                if status?.status == "ready", !windows.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(windows, id: \.id) { window in
                                windowValue(window).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(windows, id: \.id) { window in windowValue(window) }
                        }
                    }
                    if let status, let creditText = creditText(status) {
                        Text(creditText).font(.caption2.weight(.semibold))
                            .foregroundStyle(DaddyTheme.muted)
                        if let resets = status.resetCredits {
                            Text(resetCountText(resets, provider: provider))
                                .font(.caption2).foregroundStyle(DaddyTheme.muted)
                        }
                    } else if let resets = status?.resetCredits {
                        Text(resetCountText(resets, provider: provider))
                            .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    }
                    if provider == "claude", status?.resetCredits == nil {
                        Text("Usage reset count not reported")
                            .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    }
                    if let status, provider == "codex", status.resetCredits != nil {
                        resetExpiry(status)
                    }
                } else {
                    Text(status?.message ?? "Check both allowances for an account reading.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text("Latest check failed; any saved reading may be stale. \(error)")
                        .font(.caption2).foregroundStyle(DaddyTheme.amber)
                }
                if let status {
                    Text("\(status.source) · \(status.checkedAt)")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func visibleWindows(_ status: ProviderQuotaStatus?) -> [ProviderQuotaWindow] {
        guard let status else { return [] }
        if status.provider == "claude" {
            return Array(status.windows.filter {
                !$0.id.localizedCaseInsensitiveContains("model") && !$0.id.localizedCaseInsensitiveContains("fable")
            }.prefix(2))
        }
        return Array(status.windows.prefix(1))
    }

    private func windowValue(_ window: ProviderQuotaWindow) -> some View {
        let state = health(window.remainingPercent)
        return VStack(alignment: .leading, spacing: 5) {
            Text(window.label.replacingOccurrences(of: " window", with: "").uppercased())
                .font(.caption2.weight(.bold).monospaced()).foregroundStyle(DaddyTheme.muted)
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 31, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(state.1)
            Text("remaining · \(state.0)").font(.caption2.weight(.semibold)).foregroundStyle(state.1)
            GeometryReader { proxy in
                Capsule().fill(DaddyTheme.raised)
                    .overlay(alignment: .leading) {
                        Capsule().fill(state.1)
                            .frame(width: proxy.size.width * min(1, max(0, window.remainingPercent / 100)))
                    }
            }.frame(height: 5)
            if let pace = paceLabel(window) {
                Text(pace).font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
            }
            if let reset = window.resetDescription {
                Text("Resets \(reset)").font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
            }
        }
        .frame(minWidth: 0, maxWidth: 190, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label), \(Int(window.remainingPercent.rounded())) percent remaining")
    }

    private func health(_ remaining: Double) -> (String, Color) {
        if remaining <= 20 { return ("Low", DaddyTheme.coral) }
        if remaining <= 40 { return ("Watch", DaddyTheme.amber) }
        return ("Healthy", DaddyTheme.mint)
    }

    private func paceLabel(_ window: ProviderQuotaWindow) -> String? {
        guard let minutes = window.windowDurationMinutes, minutes > 0,
              let reset = window.resetsAtUnix else { return nil }
        let remaining = (Double(reset) - Date().timeIntervalSince1970) / (Double(minutes) * 60)
        guard remaining > 0, remaining <= 1 else { return nil }
        let delta = window.remainingPercent - remaining * 100
        if abs(delta) < 1 { return "On even-use pace" }
        return "\(delta > 0 ? "+" : "")\(Int(delta.rounded())) pts \(delta > 0 ? "ahead of" : "behind") even pace"
    }

    private func creditText(_ status: ProviderQuotaStatus) -> String? {
        guard let credits = status.credits else { return nil }
        if let limit = credits.limitAmount, let used = credits.usedAmount {
            return "\(max(0, limit - used).formatted(.currency(code: "USD"))) credits"
        }
        if let remaining = credits.remainingPercent {
            return "\(Int(remaining.rounded()))% credits"
        }
        return nil
    }

    private func resetCountText(_ count: UInt64, provider: String) -> String {
        "\(count) \(provider == "claude" ? "usage" : "full") \(count == 1 ? "reset" : "resets") available"
    }

    @ViewBuilder private func resetExpiry(_ status: ProviderQuotaStatus) -> some View {
        if let unix = status.latestReportedResetCreditExpiryUnix {
            Text("Latest reported expiry · \(Date(timeIntervalSince1970: TimeInterval(unix)).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
        } else if (status.resetCredits ?? 0) > 0 {
            Text(status.resetCreditsWithoutExpiryCount == status.resetCredits
                 ? "Reported credits do not expire" : "Reset-credit expiry unavailable")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
        if let nonExpiring = status.resetCreditsWithoutExpiryCount, nonExpiring > 0,
           status.latestReportedResetCreditExpiryUnix != nil {
            Text("\(nonExpiring) reported \(nonExpiring == 1 ? "credit has" : "credits have") no expiry.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
        if let details = status.resetCreditDetailsCount, details < (status.resetCredits ?? 0) {
            Text("Only \(details) of \(status.resetCredits ?? 0) credit details reported; a later expiry may exist.")
                .font(.caption2).foregroundStyle(DaddyTheme.amber)
        }
    }
}
