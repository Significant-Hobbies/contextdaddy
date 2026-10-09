import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
struct UsageAllowanceViewTests {
    @Test func rendersThreeProviderComparisonAndGrokFailureStates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design/provider-comparison/after")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        let originalAutoCheck = model.autoCheckAllowance
        defer { model.autoCheckAllowance = originalAutoCheck }
        model.autoCheckAllowance = false
        model.show(.overview)
        let fixture = #"""
        {"schema_version":"contextdaddy.provider-quota/v1","generated_at":"2026-10-09T12:00:00Z","providers":[
          {"provider":"codex","status":"ready","source":"Fixture · Codex app-server","checked_at":"2026-10-09T12:00:00Z","plan":"pro","windows":[{"id":"codex.primary","label":"5-hour window","window_duration_minutes":300,"remaining_percent":70,"reset_description":"Today at 5:30pm"},{"id":"codex.secondary","label":"Weekly window","window_duration_minutes":10080,"remaining_percent":60,"reset_description":"Oct 15 at 2:43am"}],"credits":{"balance":12345.67},"reset_credits":2,"earliest_reported_reset_credit_expiry_unix":1793386560,"latest_reported_reset_credit_expiry_unix":1795978560,"reset_credit_details_count":2},
          {"provider":"claude","status":"ready","source":"Fixture · Claude usage","checked_at":"2026-10-09T12:00:00Z","windows":[{"id":"current","label":"Current window","remaining_percent":80,"reset_description":"Today at 8:30pm"},{"id":"weekly","label":"Weekly window","remaining_percent":60,"reset_description":"Oct 16 at 5:30pm"}],"credits":{"used_amount":25,"limit_amount":150},"claude_reset_grants":{"fullCount":1,"fiveHourCount":2,"checkedAt":"2026-10-09T12:00:00Z","grants":[{"kind":"full","count":1,"expiresAtUnix":1793386560,"paused":false,"usableNow":true},{"kind":"five-hour","count":2,"expiresAtUnix":1795978560,"paused":true,"usableNow":false}]}},
          {"provider":"grok","status":"ready","source":"Fixture · Grok CLI ACP x.ai/billing","checked_at":"2026-10-09T12:00:00Z","plan":"SuperGrok","windows":[{"id":"grok.allowance","label":"Weekly window","remaining_percent":74.5,"resets_at_unix":1792022400}],"grok_billing":{"prepaidUSD":12.5,"onDemandEnabled":true,"onDemandUsedUSD":5,"onDemandCapUSD":20,"unifiedBilling":true,"periodStart":"2026-10-08T00:00:00Z"}}
        ]}
        """#
        let receipt = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(fixture.utf8))
        for provider in ["codex", "claude", "grok"] { model.quotaReceipts[provider] = receipt }
        #expect(UsageAllowanceView.creditText(receipt.providers[2]) == 12.5.formatted(.currency(code: "USD")))
        #expect(UsageAllowanceView.windowKind(receipt.providers[0].windows[1]) == "weekly")
        for width in [960, 1180, 1440] {
            try render(model, width: width, height: 900, to: directory.appendingPathComponent("comparison-\(width).png"))
        }
        model.quotaErrors["grok"] = "Fixture: Grok billing could not be read."
        try render(model, width: 960, height: 900, to: directory.appendingPathComponent("stale-grok-960.png"))
        model.quotaReceipts.removeValue(forKey: "grok")
        try render(model, width: 960, height: 900, to: directory.appendingPathComponent("unavailable-grok-960.png"))
    }

    @Test func creditLabelsDistinguishUnitsAndMissingStates() throws {
        func status(_ credits: String, provider: String = "codex") throws -> ProviderQuotaStatus {
            let json = "{\"provider\":\"\(provider)\",\"status\":\"ready\",\"source\":\"fixture\",\"checked_at\":\"2026-10-03T12:00:00Z\",\"windows\":[],\"credits\":\(credits)}"
            return try JSONDecoder().decode(ProviderQuotaStatus.self, from: Data(json.utf8))
        }
        let balance = Decimal(string: "12345.6789")!
        let formatted = balance.formatted(.number.precision(.fractionLength(0...2)))
        #expect(try UsageAllowanceView.creditText(status(#"{"balance":12345.6789}"#)) == "\(formatted) credits remaining")
        #expect(try UsageAllowanceView.creditText(status(#"{"unlimited":true,"balance":0}"#)) == "Unlimited credits")
        #expect(try UsageAllowanceView.creditText(status(#"{"balance":0,"has_credits":false}"#)) == "0 credits remaining")
        #expect(try UsageAllowanceView.creditText(status(#"{"has_credits":false}"#)) == "No credits available")
        #expect(try UsageAllowanceView.creditText(status(#"{"has_credits":true}"#)) == "Credits available · balance not reported")
        #expect(try UsageAllowanceView.creditText(status("null")) == "Credit balance not reported")
        let tiny = (Decimal(1) / 100).formatted(.number)
        #expect(try UsageAllowanceView.creditText(status(#"{"balance":0.001}"#)) == "<\(tiny) credits remaining")
        let dollars = 125.formatted(.currency(code: "USD"))
        #expect(try UsageAllowanceView.creditText(status(#"{"used_amount":25,"limit_amount":150}"#, provider: "claude")) == "\(dollars) credits")
    }

    @Test func resetGrantLabelsKeepUnknownDistinctFromZero() throws {
        func status(_ count: String, provider: String = "claude") throws -> ProviderQuotaStatus {
            let json = "{\"provider\":\"\(provider)\",\"status\":\"ready\",\"source\":\"fixture\",\"checked_at\":\"2026-10-03T12:00:00Z\",\"windows\":[],\"reset_credits\":\(count)}"
            return try JSONDecoder().decode(ProviderQuotaStatus.self, from: Data(json.utf8))
        }
        #expect(try UsageAllowanceView.resetCountText(status("null")) == "Not reported")
        #expect(try UsageAllowanceView.resetCountText(status("0")) == "0 usage resets available")
        #expect(try UsageAllowanceView.resetCountText(status("1")) == "1 usage reset available")
        #expect(try UsageAllowanceView.resetCountText(status("2")) == "2 usage resets available")
        #expect(try UsageAllowanceView.resetCountText(status("2", provider: "codex")) == "2 full resets available")
        let window = try JSONDecoder().decode(ProviderQuotaWindow.self, from:
            Data(#"{"id":"current","label":"Current window","remaining_percent":80,"reset_description":"8:30pm (Asia/Calcutta)"}"#.utf8))
        #expect(UsageAllowanceView.windowResetText(window) == "Resets 8:30pm (Asia/Calcutta)")
        #expect(UsageAllowanceView.claudeGrantCountText(1, kind: "full") == "Full resets · 1 left")
        #expect(UsageAllowanceView.claudeGrantCountText(0, kind: "five-hour") == "5-hour resets · None")
        #expect(UsageAllowanceView.claudeGrantCountText(2, kind: "five-hour") == "5-hour resets · 2 left")
    }

    @Test func rendersScopedClaudeResetGrantsAndUnavailableDetails() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design/claude-grants/after", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        let originalAutoCheck = model.autoCheckAllowance
        defer { model.autoCheckAllowance = originalAutoCheck }
        model.autoCheckAllowance = false
        model.show(.overview)
        let fixture = #"{"schema_version":"contextdaddy.provider-quota/v1","generated_at":"2026-10-03T12:00:00Z","providers":[{"provider":"codex","status":"ready","source":"codex app-server account/rateLimits/read","checked_at":"2026-10-03T12:00:00Z","plan":"pro","windows":[{"id":"weekly","label":"Weekly window","remaining_percent":70,"reset_description":"Oct 10 at 2:43am"}],"credits":{"balance":12345.67},"reset_credits":2},{"provider":"claude","status":"ready","source":"Claude Code /usage","checked_at":"2026-10-03T12:00:00Z","plan":"Claude Team","windows":[{"id":"current","label":"Current window","remaining_percent":80,"reset_description":"8:30pm (Asia/Calcutta)"},{"id":"weekly","label":"Weekly window","remaining_percent":60,"reset_description":"Oct 4 at 5:30pm (Asia/Calcutta)"}],"credits":{"used_amount":25,"limit_amount":150},"claude_reset_grants":{"fullCount":1,"fiveHourCount":0,"checkedAt":"2026-10-03T12:00:01Z","grants":[{"kind":"full","count":1,"expiresAtUnix":1918915200,"paused":false,"usableNow":true}]}}]}"#
        let receipt = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(fixture.utf8))
        model.quotaReceipts["codex"] = receipt
        model.quotaReceipts["claude"] = receipt
        for width in [960, 1180, 1440] {
            try render(model, width: width, height: 740, to: directory.appendingPathComponent("grants-\(width).png"))
        }
        var unavailable = try #require(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        var providers = try #require(unavailable["providers"] as? [[String: Any]])
        providers[1].removeValue(forKey: "claude_reset_grants")
        providers[1]["reset_grant_error"] = "Claude reset-grant check failed. Try checking again."
        unavailable["providers"] = providers
        model.quotaReceipts["claude"] = try JSONDecoder().decode(ProviderQuotaReceipt.self,
                                                               from: JSONSerialization.data(withJSONObject: unavailable))
        try render(model, width: 960, height: 740, to: directory.appendingPathComponent("unavailable-960.png"))
        let pausedJSON = fixture.replacingOccurrences(of: "\"fiveHourCount\":0", with: "\"fiveHourCount\":2")
            .replacingOccurrences(of: "\"grants\":[", with: "\"grants\":[{\"kind\":\"five-hour\",\"count\":2,\"expiresAtUnix\":1928915200,\"paused\":true,\"usableNow\":false},")
        model.quotaReceipts["claude"] = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(pausedJSON.utf8))
        try render(model, width: 960, height: 740, to: directory.appendingPathComponent("paused-960.png"))
    }

    /// Focused native evidence; no local-history scan or provider call is needed.
    @Test func rendersAllowanceGrouping() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design/allowance-layout/after", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        let originalAutoCheck = model.autoCheckAllowance
        defer { model.autoCheckAllowance = originalAutoCheck }
        model.autoCheckAllowance = false
        model.show(.overview)
        let fixture = #"{"schema_version":"contextdaddy.provider-quota/v1","generated_at":"2026-10-03T12:00:00Z","providers":[{"provider":"codex","status":"ready","source":"codex app-server account/rateLimits/read","checked_at":"2026-10-03T12:00:00Z","plan":"pro","windows":[{"id":"codex.primary","label":"5-hour window","remaining_percent":70,"reset_description":"4 Oct at 5:30pm (Asia/Calcutta)"}],"credits":{"balance":12345.6789,"has_credits":true,"unlimited":false},"reset_credits":2,"earliest_reported_reset_credit_expiry_unix":1793386560,"latest_reported_reset_credit_expiry_unix":1793386560,"reset_credit_details_count":1,"message":null},{"provider":"claude","status":"ready","source":"Claude Code /usage","checked_at":"2026-10-03T12:00:00Z","plan":"Claude Team","windows":[{"id":"current","label":"Current window","remaining_percent":80,"reset_description":"8:30pm (Asia/Calcutta)"},{"id":"weekly","label":"Weekly window","remaining_percent":60,"reset_description":"Oct 4 at 5:29pm (Asia/Calcutta)"}],"credits":{"used_amount":25,"limit_amount":150},"reset_credits":1,"message":null}]}"#
        let receipt = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(fixture.utf8))
        model.quotaReceipts["codex"] = receipt
        model.quotaReceipts["claude"] = receipt
        for width in [960, 1180, 1440] {
            try render(model, width: width, height: 740, to: directory.appendingPathComponent("allowance-\(width).png"))
        }
        let unreported = try JSONDecoder().decode(ProviderQuotaReceipt.self, from:
            Data(fixture.replacingOccurrences(of: "\"reset_credits\":1", with: "\"reset_credits\":null").utf8))
        model.quotaReceipts["claude"] = unreported
        try render(model, width: 960, height: 640, to: directory.appendingPathComponent("unreported-960.png"))
        let depleted = try JSONDecoder().decode(ProviderQuotaReceipt.self, from:
            Data(fixture.replacingOccurrences(of: "\"reset_credits\":1", with: "\"reset_credits\":0").utf8))
        model.quotaReceipts["claude"] = depleted
        model.quotaErrors["claude"] = "Fixture: allowance unavailable."
        try render(model, width: 960, height: 640, to: directory.appendingPathComponent("depleted-stale-960.png"))
        model.quotaReceipts.removeValue(forKey: "claude")
        try render(model, width: 960, height: 640, to: directory.appendingPathComponent("unavailable-960.png"))
    }

    private func render(_ model: ContextDaddyModel, width: Int, height: Int, to destination: URL) throws {
        let view = RootView().environment(model)
            .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
            .background(DaddyTheme.canvas).preferredColorScheme(.dark)
            .tint(DaddyTheme.mint).buttonStyle(ContextDaddyButtonStyle())
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)
    }
}
