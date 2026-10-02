import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
struct UsageAllowanceViewTests {
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

    /// Focused native evidence; no local-history scan or provider call is needed.
    @Test func rendersCreditEvidence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design/codex-credits/current", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = ContextDaddyModel()
        let originalAutoCheck = model.autoCheckAllowance
        defer { model.autoCheckAllowance = originalAutoCheck }
        model.autoCheckAllowance = false
        let fixture = #"{"schema_version":"contextdaddy.provider-quota/v1","generated_at":"2026-10-03T12:00:00Z","providers":[{"provider":"codex","status":"ready","source":"Codex fixture","checked_at":"2026-10-03T12:00:00Z","plan":"pro","windows":[{"id":"codex.primary","label":"5-hour window","remaining_percent":70}],"credits":{"balance":12345.6789,"has_credits":true,"unlimited":false},"reset_credits":2,"message":null},{"provider":"claude","status":"ready","source":"Claude fixture","checked_at":"2026-10-03T12:00:00Z","windows":[{"id":"current","label":"Current window","remaining_percent":80},{"id":"weekly","label":"Weekly window","remaining_percent":60}],"credits":{"used_amount":25,"limit_amount":150},"reset_credits":1,"message":null}]}"#
        let receipt = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(fixture.utf8))
        model.quotaReceipts["codex"] = receipt
        model.quotaReceipts["claude"] = receipt
        for width in [960, 1180, 1440] {
            let view = FocusDeskView().environment(model)
                .frame(width: CGFloat(width), height: 740, alignment: .topLeading)
                .background(DaddyTheme.canvas).preferredColorScheme(.dark)
                .tint(DaddyTheme.mint).buttonStyle(ContextDaddyButtonStyle())
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 740)
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
            try png.write(to: directory.appendingPathComponent("allowance-\(width).png"), options: .atomic)
        }
    }
}
