import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
struct DesignSnapshotTests {
    @Test func listDestinationsHaveReachableScrollRangeAtMinimumHeight() async throws {
        let model = ContextDaddyModel()
        await model.refresh()
        let destinations: [(String, AnyView)] = [
            ("Focus Desk", AnyView(LiveRunsView().environment(model))),
            ("Skills", AnyView(SkillsLedgerView().environment(model))),
            ("Projects", AnyView(ProjectsContextView().environment(model))),
            ("Telemetry", AnyView(TelemetryView().environment(model))),
            ("Sources", AnyView(SourcesHubView().environment(model))),
        ]

        for (name, view) in destinations {
            let ranges = scrollRanges(for: view)
            #expect(ranges.count == 1, "\(name) should have one vertical scroll surface; found \(ranges)")
            if name != "Telemetry" || model.telemetry.collectorReachable {
                #expect(ranges.contains { $0 > 100 }, "\(name) needs a real scroll range at 640-point window height; found \(ranges)")
            }
        }
        model.skillsMode = .redundancy
        let redundancyRanges = scrollRanges(for: AnyView(SkillsLedgerView().environment(model)))
        #expect(redundancyRanges.count == 1, "Redundancy review should have one vertical scroll surface; found \(redundancyRanges)")
        #expect(redundancyRanges.contains { $0 > 100 }, "Redundancy review needs a real scroll range; found \(redundancyRanges)")
        model.sourcesMode = .diagnostics
        let diagnosticsRanges = scrollRanges(for: AnyView(SourcesHubView().environment(model)))
        #expect(diagnosticsRanges.count == 1, "Sources diagnostics should have one vertical scroll surface; found \(diagnosticsRanges)")
        #expect(diagnosticsRanges.contains { $0 > 100 }, "Sources diagnostics needs a real scroll range; found \(diagnosticsRanges)")
    }

    @Test func writesResponsiveDesignEvidence() async throws {
        let model = ContextDaddyModel()
        await model.refresh()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = root.appendingPathComponent("artifacts/ContextDaddy.app/Contents/Helpers/ccusage")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            model.usageReport = try await CCUsageClient(executableURL: helper).loadUsage()
        } else {
            await model.refreshUsage()
        }
        if let report = model.usageReport, let devin = try? await DevinUsageClient().load() {
            model.usageReport = report.withDevin(devin)
        }
        let directory = root.appendingPathComponent("artifacts/design", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for width in [390, 768, 1440] {
            let height = width == 390 ? 844 : 900
            try render(
                AnyView(LiveRunsView().environment(model)),
                width: width,
                height: height,
                to: directory.appendingPathComponent("after-\(width).png")
            )
        }

        let quotaFixture = #"{"schema_version":"contextdaddy.provider-quota/v1","generated_at":"2026-09-23T12:00:00Z","providers":[{"provider":"codex","status":"ready","source":"Codex fixture","checked_at":"2026-09-23T12:00:00Z","plan":"pro","windows":[{"id":"codex.primary","label":"5-hour window","remaining_percent":70}],"reset_credits":2,"latest_reported_reset_credit_expiry_unix":1800000000,"reset_credit_details_count":1,"message":null}]}"#
        model.quotaReceipts["codex"] = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: Data(quotaFixture.utf8))
        try render(AnyView(LiveRunsView().environment(model)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-allowance-expiry-1440.png"))
        model.quotaReceipts.removeValue(forKey: "codex")
        let devinModel = ContextDaddyModel()
        devinModel.usageReport = model.usageReport
        devinModel.usageHistoryAgents = ["devin"]
        try render(AnyView(LiveRunsView().environment(devinModel)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-devin-history-1440.png"))
        devinModel.usageHistoryGrouping = .provider
        try render(AnyView(LiveRunsView().environment(devinModel)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-devin-provider-1440.png"))
        model.usageHistoryGrouping = .project
        try render(AnyView(LiveRunsView().environment(model)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-session-projects-1440.png"))
        model.usageHistoryGrouping = .provider
        try render(AnyView(LiveRunsView().environment(model)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-agent-providers-1440.png"))
        model.usageHistoryGrouping = .model

        let destinations: [(String, AnyView)] = [
            ("skills", AnyView(SkillsLedgerView().environment(model))),
            ("projects", AnyView(ProjectsContextView().environment(model))),
            ("telemetry", AnyView(TelemetryView().environment(model))),
            ("sources", AnyView(SourcesHubView().environment(model))),
        ]

        for (name, view) in destinations {
            for width in [720, 1040, 1440] {
                try render(
                    view,
                    width: width,
                    height: width == 720 ? 680 : 900,
                    to: directory.appendingPathComponent("after-\(name)-\(width).png")
                )
            }
        }
        try render(AnyView(ProjectsContextView().environment(model)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-projects-pagination-1440.png"), scrollToBottom: true)

        model.skillsMode = .redundancy
        for width in [720, 1040, 1440] {
            try render(
                AnyView(SkillsLedgerView().environment(model)),
                width: width,
                height: width == 720 ? 680 : 900,
                to: directory.appendingPathComponent("after-redundancy-\(width).png")
            )
        }
        model.captureSkillIssues()
        try render(AnyView(SkillsLedgerView().environment(model)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-skill-handoff-1440.png"))
        model.skillIssueVerification = model.skillIssueBaseline?.verify(
            against: model.redundancySummary,
            scannedRecordIDs: Set(model.catalog?.records.map(\.id) ?? []))
        try render(AnyView(SkillsLedgerView().environment(model)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-skill-verification-1440.png"))
        model.skillIssueBaseline = nil
        model.skillIssueVerification = nil
        try render(AnyView(OTelDashboardView(snapshot: model.telemetry, runtime: .codex)), width: 1440, height: 900,
                   to: directory.appendingPathComponent("after-otel-opportunities-1440.png"))
        let disconnectedModel = ContextDaddyModel()
        try render(AnyView(TelemetryView().environment(disconnectedModel)), width: 960, height: 640,
                   to: directory.appendingPathComponent("after-telemetry-disconnected-960x640.png"))
        disconnectedModel.selectedTelemetryRuntime = .claude
        try render(AnyView(TelemetryView().environment(disconnectedModel)), width: 960, height: 640,
                   to: directory.appendingPathComponent("after-telemetry-claude-disconnected-960x640.png"))

        model.section = .skills
        for (width, height) in [(960, 640), (1180, 740), (1440, 900)] {
            try render(
                AnyView(RootView().environment(model)),
                width: width,
                height: height,
                to: directory.appendingPathComponent("after-full-window-redundancy-\(width)x\(height).png")
            )
        }

        model.skillsMode = .ledger
        model.sourcesMode = .inventory
        for section in AppSection.allCases {
            model.section = section
            try render(
                AnyView(RootView().environment(model)),
                width: 960,
                height: 640,
                to: directory.appendingPathComponent("after-full-window-\(section.id.replacingOccurrences(of: " ", with: "-").lowercased())-960x640.png")
            )
        }
        model.selectedTelemetryRuntime = .claude
        model.section = .telemetry
        try render(
            AnyView(RootView().environment(model)), width: 960, height: 640,
            to: directory.appendingPathComponent("after-full-window-telemetry-claude-960x640.png")
        )
        model.selectedTelemetryRuntime = .codex

        model.showEvidence(.diagnostics)
        try render(
            AnyView(RootView().environment(model)), width: 960, height: 640,
            to: directory.appendingPathComponent("after-full-window-evidence-diagnostics-960x640.png")
        )
        model.showEvidence(.inventory)
        try render(
            AnyView(RootView().environment(model)), width: 960, height: 640,
            to: directory.appendingPathComponent("after-full-window-evidence-inventory-960x640.png")
        )
        let issueModel = ContextDaddyModel()
        issueModel.configurationHealth = ConfigurationHealthReport(
            issues: [ConfigurationHealthIssue(
                id: "fixture-codex-config", severity: .warning, runtime: .codex,
                title: "Ignored setting", detail: "Fixture issue for sidebar layout.",
                path: "/tmp/contextdaddy-audit.toml", line: 1,
                remediation: "Review this setting."
            )],
            scannedFiles: ["/tmp/contextdaddy-audit.toml"]
        )
        issueModel.showEvidence(.diagnostics)
        try render(
            AnyView(RootView().environment(issueModel)), width: 960, height: 640,
            to: directory.appendingPathComponent("after-full-window-files-diagnostics-issue-fixture-960x640.png")
        )
        model.show(.skills)

        model.section = .skills
        try render(
            AnyView(RootView().environment(model)),
            width: 1800,
            height: 800,
            to: directory.appendingPathComponent("after-full-window-skills-1800x800.png")
        )

        model.section = .overview
        for (width, height) in [(1180, 740), (1800, 800)] {
            try render(
                AnyView(RootView().environment(model)),
                width: width,
                height: height,
                to: directory.appendingPathComponent("after-full-window-live-runs-\(width)x\(height).png")
            )
        }
    }

    @Test func writesSessionTimeEvidence() throws {
        let model = ContextDaddyModel()
        let snapshot = SessionTimeScanner().scan()
        model.sessionTimeSnapshot = snapshot
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, range, scale) in [("all-weeks", SessionTimeRange.all, SessionTimeScale.week), ("month-days", .month, .day)] {
            model.sessionTimeRange = range
            model.sessionTimeScale = scale
            model.sessionTimeReport = SessionTimeReport.build(snapshot: snapshot, filter: model.sessionTimeFilter)
            for width in [720, 1440] {
                try render(AnyView(ScrollView { SessionTimeView().padding(24) }.contextTheme(DaddyTheme.palette).font(.custom(DaddyTheme.palette.sansFont, size: 13)).environment(model)), width: width, height: 3200,
                           to: directory.appendingPathComponent("after-session-time-\(name)-\(width).png"))
            }
        }
    }

    private func render(_ view: AnyView, width: Int, height: Int, to url: URL, scrollToBottom: Bool = false) throws {
        let hosting = NSHostingView(rootView: view.preferredColorScheme(.dark)
            .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
            .background(DaddyTheme.canvas))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if scrollToBottom, let scroll = scrollViews(in: hosting).first,
           let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        // Give NavigationSplitView's asynchronous first paint time to settle;
        // otherwise evidence images can omit the sidebar brand and rows.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func scrollRanges(for view: AnyView) -> [CGFloat] {
        let hosting = NSHostingView(rootView: view.frame(width: 700, height: 544))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 544)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return scrollViews(in: hosting).compactMap { scroll -> CGFloat? in
            guard let document = scroll.documentView else { return nil }
            let range = document.bounds.height - scroll.contentView.bounds.height
            if range > 100 {
                scroll.contentView.scroll(to: .zero)
                let start = scroll.contentView.bounds.origin.y
                scroll.contentView.scroll(to: NSPoint(x: 0, y: range))
                #expect(abs(scroll.contentView.bounds.origin.y - start) > 100, "The scroll surface should move through its content")
            }
            return range
        }
    }
}
