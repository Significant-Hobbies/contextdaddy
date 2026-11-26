import AppKit
import SwiftUI
import Testing
@testable import ContextCore
@testable import ContextDaddy

@MainActor
@Suite(.serialized)
struct PluginCountQualificationTests {
    @Test(arguments: [0, 1, 2]) func actualViewCopyUsesZeroOneMultipleSemantics(_ count: Int) {
        let snapshot = fixture(count)
        let expected = [
            "0 plugins found · 0 cached versions",
            "1 plugin found · 1 cached version",
            "2 plugins found · 4 cached versions"
        ]
        #expect(PluginCountCopy.summary(snapshot) == expected[count])
        #expect(PluginCountCopy.ledger(count) == "\(count) \(count == 1 ? "plugin" : "plugins") · grouped by owner and marketplace")
        #expect(PluginCountCopy.count(count, "skill name") == ["0 skill names", "1 skill name", "2 skill names"][count])
        #expect(PluginCountCopy.count(count, "skill file") == ["0 skill files", "1 skill file", "2 skill files"][count])
        #expect(PluginCountCopy.capabilities(count).hasPrefix(["0 unique skill directory names", "1 unique skill directory name", "2 unique skill directory names"][count]))
        #expect(PluginCountCopy.references(snapshot) == [
            "0 plugins have multiple versions · 0 versions are not referenced by the checked Claude registry",
            "0 plugins have multiple versions · 1 version is not referenced by the checked Claude registry",
            "2 plugins have multiple versions · 4 versions are not referenced by the checked Claude registry"
        ][count])
        if count == 1 { #expect(snapshot.entries[0].reviewReason == "1 version not referenced by the checked registry") }
    }

    @Test func oneRepeatedPluginAndZeroUnreferencedUseCorrectVerbs() {
        let versions = fixture(2).entries[0].versions
        let entry = PluginInventoryEntry(owner: .claude, marketplace: "fixture", name: "sample", summary: "Synthetic",
            versions: versions, registrations: versions.map { .init(path: $0.path, scope: "user", project: nil) },
            registryVerified: true, preferences: [], localMatches: [])
        let snapshot = PluginInventorySnapshot(entries: [entry], notes: [], checkedSources: [], generatedAt: .distantPast)
        #expect(PluginCountCopy.references(snapshot) == "1 plugin has multiple versions · 0 versions are not referenced by the checked Claude registry")
    }

    // Opt-in, offscreen only. No NSApplication activation, orderFront, standard
    // preference writes, real discovery, plugin commands, or network access.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_PLUGIN_RENDER"] == "1"))
    func rendersSyntheticCountsWithoutGlobalPreferenceWrites() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/queue-review/native-counts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "ContextDaddy-fixture-" + UUID().uuidString))
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        for count in [0, 1, 2] {
            for width in [390, 768, 1440] {
                let view = PluginInventoryView(snapshot: fixture(count), defaults: defaults)
                    .environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let scrolls = scrollViews(host)
                #expect(scrolls.count == 1)
                let scroll = try #require(scrolls.first)
                let document = try #require(scroll.documentView)
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                if bottom > 0 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    #expect(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2)
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("plugins-count-\(count)-\(width).png"))
                window.contentView = nil
            }
        }
    }

    private func fixture(_ count: Int) -> PluginInventorySnapshot {
        let entries = (0..<count).map { index in
            let versions = (0..<count).map { version in
                PluginCacheVersion(path: "/fixture/.claude/plugins/cache/fixture/plugin-\(index)/v\(version)", version: "v\(version)",
                    bytes: 12000, sizeComplete: false, skillNames: (0..<count).map { "skill-\($0)" }, fingerprints: [], components: [], modified: nil)
            }
            return PluginInventoryEntry(owner: .claude, marketplace: "fixture", name: "plugin-\(index)", summary: "Synthetic qualification fixture",
                versions: versions, registrations: [], registryVerified: true, preferences: [], localMatches: [])
        }
        return PluginInventorySnapshot(entries: entries, notes: ["Synthetic snapshot only; observed invocation is unavailable."], checkedSources: [], generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
