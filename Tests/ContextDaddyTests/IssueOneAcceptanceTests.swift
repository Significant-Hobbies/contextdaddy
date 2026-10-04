import AppKit
import SwiftUI
import Testing
@testable import ContextCore
@testable import ContextDaddy

/// Portable native acceptance for issue #1. Uses synthetic records only;
/// never refreshes machine inventory, provider allowances, or configuration.
@MainActor
@Suite(.serialized)
struct IssueOneAcceptanceTests {
    @Test func policyAndRedundancyWindowsRemainReachable() throws {
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        model.show(.skills)
        let records = [
            record("build-native", path: "/demo/global/build-native", fingerprint: "copy", mode: .manualOnly),
            record("build-native", path: "/demo/project/build-native", fingerprint: "copy", mode: .unverified),
            record("release-review", path: "/demo/global/release-review", fingerprint: "old"),
            record("release-review", path: "/demo/project/release-review", fingerprint: "new"),
            record("cached-one", path: "/demo/cache/one", fingerprint: "cache", cache: true),
            record("cached-two", path: "/demo/cache/two", fingerprint: "cache", cache: true),
        ]
        model.catalog = SkillCatalogSnapshot(records: records,
            coverage: AIContextCoverage(roots: ["/demo"], visitedEntries: 6, itemLimitReached: false,
                entryLimitReached: false, unreadableCount: 0, skippedLinks: 1,
                notes: ["Synthetic acceptance inventory. One broken link remains unavailable."]),
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(model.redundancySummary?.reviewCount == 2)
        #expect(model.redundancySummary?.managedCacheOnlyCount == 1)
        model.selectedRuntime = .claude
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/design/issue-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (width, height) in [(960, 640), (1180, 740), (1440, 900)] {
            for mode in [SkillsMode.ledger, .redundancy] {
                model.skillsMode = mode
                try render(model, width: width, height: height,
                    to: directory.appendingPathComponent("\(mode == .ledger ? "policies" : "redundancy")-\(width).png"))
            }
        }
        model.redundancyKindFilter = .managed
        #expect(model.visibleRedundancyFindings.count == 1)
        #expect(model.visibleRedundancyFindings.allSatisfy { $0.isManagedCacheOnly })
        try render(model, width: 960, height: 640, to: directory.appendingPathComponent("managed-960.png"))
        model.redundancyKindFilter = .review
        model.captureSkillIssues()
        let baseline = try #require(model.skillIssueBaseline)
        #expect(baseline.findings.count == 2)
        model.skillIssueVerification = baseline.verify(against: model.redundancySummary,
            scannedRecordIDs: Set(records.map(\.id)))
        #expect(model.skillIssueVerification?.stillDetected.count == 2)
        #expect(model.skillIssueVerification?.cleared.isEmpty == true)
        try render(model, width: 960, height: 640, to: directory.appendingPathComponent("handoff-960.png"))
        model.skillIssueBaseline = nil
        model.search = "no matching fixture"
        #expect(model.visibleRedundancyFindings.isEmpty)
        try render(model, width: 960, height: 640, to: directory.appendingPathComponent("empty-960.png"))
    }

    private func record(_ name: String, path: String, fingerprint: String,
                        mode: InvocationMode = .automatic, cache: Bool = false) -> SkillRecord {
        SkillRecord(id: path, name: name,
            description: name == "build-native"
                ? "Compile Swift applications using Apple SDKs and package targets."
                : "Review distribution notarization codesigning releases with receipt checks.",
            logicalBytes: 1024, modified: .distantPast,
            exposures: [SkillExposure(logicalPath: path, resolvedPath: path, source: cache ? "Plugin cache" : "Fixture",
                scope: .global, provider: .claude, applicability: cache ? .installedOnly : .global)],
            policies: AgentRuntime.allCases.map { runtime in
                SkillRuntimePolicy(runtime: runtime, mode: runtime == .claude && !cache ? mode : .unsupported,
                    explicit: mode != .unverified, reason: "Synthetic fixture; live runtime activation is unverified.",
                    invocation: runtime == .codex ? "$\(name)" : "/\(name)", isExposed: runtime == .claude && !cache)
            }, contentFingerprint: fingerprint)
    }

    private func render(_ model: ContextDaddyModel, width: Int, height: Int, to destination: URL) throws {
        let hosting = NSHostingView(rootView: RootView(refreshOnAppear: false).environment(model)
            .preferredColorScheme(.dark).background(DaddyTheme.canvas)
            .tint(DaddyTheme.mint).buttonStyle(ContextDaddyButtonStyle()))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ContextDaddy — issue 1 acceptance fixture"
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let scroll = try #require(scrollViews(hosting).first)
        #expect(scrollViews(hosting).count == 1)
        let document = try #require(scroll.documentView)
        // Legacy scrollers reserve part of the scroll view's frame. SwiftUI's
        // document can include that trailing inset without clipping its content.
        #expect(document.bounds.width <= scroll.bounds.width + 1)
        #expect(!scroll.hasHorizontalScroller)
        let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        if bottom > 0 { #expect(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2) }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
