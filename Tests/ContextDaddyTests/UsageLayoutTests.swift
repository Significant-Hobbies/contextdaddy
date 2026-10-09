import AppKit
@testable import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

/// Usage page layout: the page never lays out wider than (or offset from) its visible
/// area, and the rendered page is written as native evidence at realistic window sizes.
@MainActor
struct UsageLayoutTests {
    static let sizes = [(960, 640), (1100, 800), (1440, 900)]

    @Test func usageSectionsFitThePageWidthAndRenderEvidence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let phase = ProcessInfo.processInfo.environment["USAGE_SNAPSHOT_PHASE"] ?? "after"
        let directory = root.appendingPathComponent("artifacts/design/usage-calm/\(phase)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = Self.fixtureModel()
        let originalAutoCheck = model.autoCheckAllowance
        defer { model.autoCheckAllowance = originalAutoCheck }
        model.autoCheckAllowance = false
        model.show(.overview)

        for (width, height) in Self.sizes {
            try Self.render(model, width: width, height: height,
                            to: directory.appendingPathComponent("usage-\(width)x\(height).png"))
        }
        // A connected mouse or "Always show scroll bars" takes a scroller lane from the page.
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        defer { UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars") }
        try Self.render(model, width: 960, height: 640,
                        to: directory.appendingPathComponent("usage-scrollbar-960x640.png"))
        UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars")
        model.isQuotaLoading = true
        try Self.render(model, width: 1180, height: 740,
                        to: directory.appendingPathComponent("usage-checking-1180x740.png"))
        model.isQuotaLoading = false

        // Every provider read, plus one stale reading.
        let all = try Self.receipt(includeAll: true)
        for provider in UsageAllowanceView.providers { model.quotaReceipts[provider] = all }
        model.quotaErrors["grok"] = "Fixture: Grok billing could not be read."
        for (width, height) in [(960, 900), (1440, 900)] {
            try Self.render(model, width: width, height: height,
                            to: directory.appendingPathComponent("usage-all-\(width)x\(height).png"))
        }
    }

    static func fixtureModel() -> ContextDaddyModel {
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        model.quotaReceipts["codex"] = try? receipt(includeAll: false)
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        let days = (0..<24).map { (offset: Int) -> DevinUsageDay in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date())!
            let tokens = Int64(40_000 + (offset * 7_919) % 90_000)
            return DevinUsageDay(period: formatter.string(from: date), sessions: 2, generatedTokens: tokens,
                                 cacheReadTokens: tokens / 3,
                                 models: [DevinUsageModel(model: "swe-2-high", sessions: 2,
                                                          generatedTokens: tokens, cacheReadTokens: tokens / 3, costUSD: 0)])
        }
        model.usageReport = LocalUsageReport.unavailable(message: "Fixture: agent logs not read.").withDevin(
            DevinUsage(status: "ready", source: "fixture", windows: [], daily: days, limitations: [], costAvailable: false))
        return model
    }

    /// Codex as in the owner's screenshot: weekly 69% remaining, a few points ahead of even pace.
    static func receipt(includeAll: Bool) throws -> ProviderQuotaReceipt {
        let now = Int(Date().timeIntervalSince1970)
        let weeklyReset = now + Int(0.65 * 10_080 * 60)
        let fiveHourReset = now + 3 * 3_600
        let codex = #"{"provider":"codex","status":"ready","source":"Fixture · Codex app-server","checked_at":"2026-10-09T12:00:00Z","plan":"pro","windows":[{"id":"codex.primary","label":"5-hour window","window_duration_minutes":300,"remaining_percent":82,"resets_at_unix":\#(fiveHourReset)},{"id":"codex.secondary","label":"Weekly window","window_duration_minutes":10080,"remaining_percent":69,"resets_at_unix":\#(weeklyReset)}],"credits":{"balance":12345.67},"reset_credits":2,"earliest_reported_reset_credit_expiry_unix":1793386560,"latest_reported_reset_credit_expiry_unix":1795978560,"reset_credit_details_count":2}"#
        let others = #",{"provider":"claude","status":"ready","source":"Fixture · Claude usage","checked_at":"2026-10-09T12:00:00Z","plan":"Claude Max","windows":[{"id":"current","label":"Current window","remaining_percent":34,"reset_description":"Today at 8:30pm"},{"id":"weekly","label":"Weekly window","remaining_percent":58,"reset_description":"Oct 16 at 5:30pm"}],"credits":{"used_amount":25,"limit_amount":150},"claude_reset_grants":{"fullCount":1,"fiveHourCount":2,"checkedAt":"2026-10-09T12:00:00Z","grants":[{"kind":"full","count":1,"expiresAtUnix":1793386560,"paused":false,"usableNow":true},{"kind":"five-hour","count":2,"expiresAtUnix":1795978560,"paused":true,"usableNow":false}]}},{"provider":"grok","status":"ready","source":"Fixture · Grok CLI ACP x.ai/billing","checked_at":"2026-10-09T12:00:00Z","plan":"SuperGrok","windows":[{"id":"grok.allowance","label":"Weekly window","remaining_percent":74.5,"resets_at_unix":1792022400}],"grok_billing":{"prepaidUSD":12.5,"onDemandEnabled":true,"onDemandUsedUSD":5,"onDemandCapUSD":20,"unifiedBilling":true,"periodStart":"2026-10-08T00:00:00Z"}}"#
        let json = #"{"schema_version":"contextdaddy.provider-quota/v1","generated_at":"2026-10-09T12:00:00Z","providers":["# + codex + (includeAll ? others : "") + "]}"
        return try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(json.utf8))
    }

    static func render(_ model: ContextDaddyModel, width: Int, height: Int, to destination: URL) throws {
        let view = RootView(refreshOnAppear: false).environment(model)
            .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
            .background(DaddyTheme.canvas).preferredColorScheme(.dark)
            .tint(DaddyTheme.mint).buttonStyle(ContextDaddyButtonStyle())
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The page must never be wider than, or offset from, the area that shows it.
        for scrollView in scrollViews(in: hosting) {
            let clip = scrollView.contentView.bounds
            let document = scrollView.documentView?.frame ?? .zero
            #expect(clip.origin.x == 0 && document.minX >= 0 && document.width <= clip.width + 0.5,
                    "\(destination.lastPathComponent): page \(document) overflows visible \(clip)")
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)
    }
}

@MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
}
