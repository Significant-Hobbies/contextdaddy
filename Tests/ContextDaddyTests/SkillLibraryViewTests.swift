import AppKit
@testable import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
@Suite(.serialized)
struct SkillLibraryViewTests {
    @Test func memoryAndActivityAnswersRenderWithoutHorizontalOverflow() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "AppleShowScrollBars")
        defaults.set("Always", forKey: "AppleShowScrollBars")
        defer { if let previous { defaults.set(previous, forKey: "AppleShowScrollBars") } else { defaults.removeObject(forKey: "AppleShowScrollBars") } }
        let entries = (0..<10).map { index in MemoryEntry(path: "/Users/demo/Desktop/workspace/project-\(index)/AGENTS.md", category: "Instructions", agent: .codex, scope: "Project", access: "Inherited · potential access", bytes: Int64(1000 + index), modified: Date(), editable: true) }
        let snapshot = MemoryInventory(entries: entries, notes: ["Local evidence, not confirmed runtime loading."], checkedAt: Date())
        let model = ContextDaddyModel()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/complete-workflows")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [390, 768, 1440] {
            for (name, view) in [("memory", AnyView(MemoryLibraryView(snapshot: snapshot))), ("activity", AnyView(TelemetryView()))] {
                let host = NSHostingView(rootView: view.environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas).buttonStyle(ContextDaddyButtonStyle()))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let scroll = try #require(scrollViews(host).first)
                #expect(scrollViews(host).count == 1)
                let document = try #require(scroll.documentView)
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(width).png"))
            }
        }
    }
    @Test func pluginLedgerRendersAtSupportedWidthsWithoutHorizontalOverflow() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "AppleShowScrollBars")
        defaults.set(ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_SCROLLBARS"] ?? "Always", forKey: "AppleShowScrollBars")
        defer { if let previous { defaults.set(previous, forKey: "AppleShowScrollBars") } else { defaults.removeObject(forKey: "AppleShowScrollBars") } }
        let versions = (1...12).map { number in
            PluginCacheVersion(path: "/Users/demo/.claude/plugins/cache/official/frontend-design/version-\(number)", version: "version-\(number)", bytes: 12_000,
                               sizeComplete: true, skillNames: ["frontend-design"], fingerprints: [], components: [], modified: nil)
        }
        let entry = PluginInventoryEntry(owner: .claude, marketplace: "claude-plugins-official", name: "frontend-design", summary: "Frontend design skill for UI/UX implementation", versions: versions,
            registrations: [.init(path: versions[0].path, scope: "user", project: nil)], registryVerified: true,
            preferences: [.init(path: "/Users/demo/.claude/settings.json", enabled: true)], localMatches: [])
        let snapshot = PluginInventorySnapshot(entries: [entry], notes: ["Default Codex and Claude cache roots; other agent inventories are not resolved."], checkedSources: [], generatedAt: Date())
        let model = ContextDaddyModel()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/plugin-management")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [390, 768, 1440] {
            let host = NSHostingView(rootView: PluginInventoryView(snapshot: snapshot).environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scroll = try #require(scrollViews(host).first)
            #expect(scrollViews(host).count == 1)
            let document = try #require(scroll.documentView)
            #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("plugins-\(width).png"))
        }
    }

    @Test func cleanupWorkbenchRendersAndScrollsAtSupportedWidths() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "AppleShowScrollBars")
        defaults.set(ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_SCROLLBARS"] ?? "Always", forKey: "AppleShowScrollBars")
        defer { if let previous { defaults.set(previous, forKey: "AppleShowScrollBars") } else { defaults.removeObject(forKey: "AppleShowScrollBars") } }
        let records = [
            record("apple-platform", "Routes native Apple development and distribution work to the focused workflows.", path: "/Users/demo/.agents/skills/apple-platform/SKILL.md", providers: [.codex, .claude]),
            record("apple-native", "Build and review native Apple applications using focused development workflows.", path: "/Users/demo/.agents/skills/apple-native/SKILL.md", providers: [.codex, .claude])
        ]
        let recommendation = SkillCleanupRecommendation(id: "overlap", title: "Review apple-platform + apple-native", reason: "Descriptions overlap; compare responsibilities and invocation before archiving. One source may be a router to the other.", category: .decision, action: .compare, records: records, canonicalID: nil, plans: [], globalLinks: [])
        let assessment = SkillCleanupAssessment(records: records, recommendations: [recommendation], cacheCount: 0, archiveCount: 0)
        let coverage = AIContextCoverage(roots: [], visitedEntries: 0, itemLimitReached: false, entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: [])
        let context = SkillFolderContext(path: "/Users/demo/Desktop/vaultwealth/webapp", agents: AgentRuntime.allCases.map { SkillFolderAgent(runtime: $0, records: [.codex, .claude].contains($0) ? records : [], sources: []) }, records: records, coverage: coverage)
        let model = ContextDaddyModel()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/folder-context")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [390, 768, 1440] {
            let host = NSHostingView(rootView: SkillCleanupWorkbench(initialAssessment: assessment, initialContext: context).environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scroll = try #require(scrollViews(host).first)
            #expect(scrollViews(host).count == 1)
            #expect(scroll.bounds.width <= host.bounds.width + 1)
            let document = try #require(scroll.documentView)
            #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
            if bottom > 0 { #expect(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2) }
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("workbench-\(width).png"))
        }
    }

    @Test func rendersLibraryAtSupportedWidthsWithoutLiveData() throws {
        // AppKit resolves the scroller style once per process, on the first read, so in a full
        // run an earlier suite that created an AppKit view has already fixed it. Lay out against
        // the style AppKit actually resolved. An explicit CONTEXTDADDY_TEST_SCROLLBARS run (use
        // --filter so this test owns the first read) also requires that style to be the one requested.
        let requestedPreference = ProcessInfo.processInfo.environment["CONTEXTDADDY_TEST_SCROLLBARS"]
        let scrollbarPreference = requestedPreference ?? "Always"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "AppleShowScrollBars")
        defaults.set(scrollbarPreference, forKey: "AppleShowScrollBars")
        defer {
            if let previous { defaults.set(previous, forKey: "AppleShowScrollBars") }
            else { defaults.removeObject(forKey: "AppleShowScrollBars") }
        }
        let resolvedStyle = NSScroller.preferredScrollerStyle
        if let requestedPreference {
            #expect(resolvedStyle == (requestedPreference == "Always" ? .legacy : .overlay))
        }
        let model = ContextDaddyModel()
        let records = [
            record("design-workflow", "Design and review Fleet product interfaces.", path: "/Users/demo/skills/design-workflow/SKILL.md", providers: [.codex, .claude]),
            record("xcodebuildmcp", "Build, test, and inspect native Apple applications.", path: "/Users/demo/.codex/plugins/cache/apple/skills/xcodebuildmcp/SKILL.md", providers: []),
            record("skill-creator", "Create focused skills with clear invocation guidance.", path: "/Users/demo/.agents/skills/skill-creator/SKILL.md", providers: [.codex]),
            record("cloudflare", "Choose services and build Cloudflare applications.", path: "/Users/demo/skills/cloudflare/SKILL.md", providers: [.claude]),
        ]
        let coverage = AIContextCoverage(roots: ["/Users/demo/.agents/skills"], visitedEntries: 12, itemLimitReached: false, entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: [])
        model.catalog = SkillCatalogSnapshot(records: records, coverage: coverage, generatedAt: Date())
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/skill-management")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [390, 768, 960, 1440] {
            let height = 900
            let view = SkillLibraryView().environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = hosting
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scrolls = scrollViews(hosting)
            #expect(scrolls.count == 1)
            #expect(scrolls.first?.hasVerticalScroller == true)
            let scroll = try #require(scrolls.first)
            // The view reserves scroller width from the resolved style; the hosted scroll view must use it too.
            #expect(scroll.scrollerStyle == resolvedStyle)
            let reserved = resolvedStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            #expect(scroll.contentView.bounds.width <= scroll.frame.width - reserved + 1)
            #expect(scroll.frame.height <= hosting.bounds.height + 1)
            #expect(scroll.frame.width <= hosting.bounds.width + 1)
            let document = try #require(scroll.documentView)
            if document.bounds.height > scroll.contentView.bounds.height {
                let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(abs(scroll.contentView.bounds.maxY - document.bounds.maxY) < 2)
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("library-\(width).png"))
        }
    }

    @Test func rootKeepsSkillsInsideTheActualWindow() throws {
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        model.show(.skills)
        for width in [960, 1180, 1440] {
            let host = NSHostingView(rootView: RootView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let scroll = try #require(scrollViews(host).first)
            let viewport = scroll.convert(scroll.bounds, to: host)
            #expect(viewport.minX >= -1)
            #expect(viewport.minY >= -1)
            #expect(viewport.maxX <= host.bounds.maxX + 1)
            #expect(viewport.maxY <= host.bounds.maxY + 1)
            #expect(viewport.height > 400)
        }
    }

    @Test func rendersOrganizationSheetsWithVisibleControls() throws {
        let records = [
            SkillRecord(id: "/Users/demo/.agents/skills/example/SKILL.md", name: "example", description: "Example", logicalBytes: 200, modified: Date(), exposures: [], policies: [], contentFingerprint: "same"),
            SkillRecord(id: "/Users/demo/.claude/skills/example/SKILL.md", name: "example", description: "Example", logicalBytes: 200, modified: Date(), exposures: [], policies: [], contentFingerprint: "same")
        ]
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/skill-organization")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for action in [SkillOrganizationAction.move, .share, .invocation, .cleanup] {
            let hosting = NSHostingView(rootView: SkillOrganizationSheet(action: action, records: records, manager: SkillLibraryManager(), refreshed: {}).preferredColorScheme(.dark))
            hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
            window.contentView = hosting
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            #expect(scrollViews(hosting).count == 1)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("sheet-\(action.id).png"))
        }
    }

    @Test func activityAndDiagnosticsKeepOneReachableScrollSurface() throws {
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/design/location-map")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.configurationHealth = ConfigurationHealthReport(issues: [ConfigurationHealthIssue(id: "fixture-ignored", severity: .warning, runtime: .codex, title: "Ignored setting", detail: "This setting is under the wrong table and has no effect.", path: "/Users/demo/.codex/config.toml", line: 12, remediation: "Review the supported table before moving the setting.")], scannedFiles: ["/Users/demo/.codex/config.toml"])
        for width in [390, 768, 1440] {
            for (name, view) in [("activity", AnyView(TelemetryView())), ("diagnostics", AnyView(CoverageView()))] {
                let host = NSHostingView(rootView: view.environment(model).preferredColorScheme(.dark).background(DaddyTheme.canvas))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = host
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let scroll = try #require(scrollViews(host).first)
                #expect(scrollViews(host).count == 1)
                let document = try #require(scroll.documentView)
                #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name)-\(width).png"))
            }
        }
    }

    @Test func individualDiagnosticHandoffTracksOnlyTheCopiedIssue() throws {
        let model = ContextDaddyModel(discover: { _ in throw CancellationError() })
        let issue = ConfigurationHealthIssue(id: "fixture-one", severity: .warning, runtime: .codex, title: "Ignored setting", detail: "Setting is in an unsupported table", path: "/fixture/config.toml", line: 4, remediation: "Review the table placement")
        model.captureConfigurationIssues([issue])
        #expect(model.configurationIssueBaseline?.issues.map(\.id) == [issue.id])
        #expect(model.configurationIssueVerification == nil)
        let missing = model.configurationIssueBaseline?.verify(against: .empty)
        #expect(missing?.unverified.map(\.id) == [issue.id])
        let cleared = model.configurationIssueBaseline?.verify(against: ConfigurationHealthReport(issues: [], scannedFiles: [issue.path]))
        #expect(cleared?.cleared.map(\.id) == [issue.id])
    }

    private func record(_ name: String, _ description: String, path: String, providers: [AgentRuntime]) -> SkillRecord {
        SkillRecord(id: path, name: name, description: description, logicalBytes: 800, modified: Date(),
            exposures: providers.map { runtime in
                SkillExposure(logicalPath: "/Users/demo/.\(runtime.rawValue.lowercased())/skills/\(name)/SKILL.md", resolvedPath: path, source: "\(runtime.rawValue) · Personal skills", scope: .global, provider: AIContextProvider(rawValue: runtime.rawValue)!, applicability: .conditional)
            },
            policies: AgentRuntime.allCases.map { runtime in
                SkillRuntimePolicy(runtime: runtime, mode: providers.contains(runtime) ? .automatic : .unsupported, explicit: false,
                    reason: providers.contains(runtime) ? "Derived from the discovered skill route." : "No active route found.", invocation: "$\(name)", isExposed: providers.contains(runtime))
            })
    }
    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
