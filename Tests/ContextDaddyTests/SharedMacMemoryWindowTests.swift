import AppKit
@testable import ContextCore
import SwiftUI
import Testing
import SaaSMakerUI
@testable import ContextDaddy

/// Opt-in real-window evidence for the production Memory view. The ready file
/// identifies the window; create `<ready>.done` to finish before the 120s bound.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTEXTDADDY_MAC_UI_EVIDENCE"] == "1"))
func sharedMacMemoryWindowEvidence() async throws {
    let ready = try #require(ProcessInfo.processInfo.environment["CONTEXTDADDY_MAC_UI_READY"])
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ContextDaddy-Memory-UI-Fixture-\(UUID().uuidString)")
    let home = temporary.appendingPathComponent("home")
    let project = home.appendingPathComponent("workspace")
    let suite = "ContextDaddy.NativeUIFixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    // Empty Skills scope is essential: its production loader returns immediately.
    // Memory still receives only the supplied temporary inventory.
    defaults.set("", forKey: "skillWorkingFolder")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
    }

    var files: [URL: Data] = [:]
    func document(_ relative: String, _ text: String, repetitions: Int = 1) throws -> URL {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(String(repeating: text, count: repetitions).utf8)
        try bytes.write(to: file)
        files[file] = bytes
        return file
    }
    let shared = "# Temporary fixture guidance\nKeep changes scoped and preserve recovery.\n"
    let instructions = [
        try document("workspace/AGENTS.md", shared, repetitions: 120),
        try document("workspace/CLAUDE.md", shared, repetitions: 120),
        try document("workspace/components/AGENTS.md", "# Temporary component guidance\nUse the shared native controls.\n", repetitions: 45)
    ]
    var items = instructions.enumerated().map { index, file in
        AIContextItem(id: file.path, path: file.path, name: file.lastPathComponent, scope: .project,
                      kind: .instruction, provider: index == 1 ? .claude : .codex,
                      logicalBytes: Int64(files[file]?.count ?? 0), allocatedBytes: Int64(files[file]?.count ?? 0), modified: Date())
    }
    for index in 1...5 {
        let file = try document("workspace/rules/interface-\(index).md", "Temporary UI rule \(index).\n", repetitions: index * 20)
        items.append(AIContextItem(id: file.path, path: file.path, name: file.lastPathComponent,
                                   scope: .project, kind: .rule, provider: .cursor,
                                   logicalBytes: Int64(files[file]?.count ?? 0), allocatedBytes: Int64(files[file]?.count ?? 0), modified: Date()))
    }
    _ = try document(".codex/memories/raw_memories.md", "Temporary agent-owned saved-memory fixture.\n", repetitions: 8000)
    _ = try document(".codex/memories/memory_summary.md", "Temporary saved-memory summary.\n", repetitions: 60)
    _ = try document(".claude/projects/fixture-workspace/memory/MEMORY.md", "Temporary project-store fixture.\n", repetitions: 240)
    let scanned = try MemoryInventory.scan(items: items, home: home, folder: project)
    let snapshot = MemoryInventory(entries: scanned.entries,
        notes: ["Temporary fixture documents and stores only; no real memory locations are read."] + scanned.notes,
        checkedAt: scanned.checkedAt)
    #expect(snapshot.entries.count == 11)
    let manager = MemoryDocumentManager(storage: temporary.appendingPathComponent("recovery"), home: home)
    let model = ContextDaddyModel(discover: { _ in throw CancellationError() },
                                  loadQuota: { _ in throw CancellationError() })
    let coverage = AIContextCoverage(roots: [home.path], visitedEntries: files.count,
        itemLimitReached: false, entryLimitReached: false, unreadableCount: 0, skippedLinks: 0,
        notes: ["Temporary fixture sources only."])
    let skillNames = ["native-components", "design-review", "focused-tests", "context-hygiene", "release-checks"]
    let records = try skillNames.enumerated().map { index, name in
        let file = try document("workspace/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: Temporary native UI review fixture.\n---\nUse this temporary fixture for \(name).\n")
        return SkillRecord(id: file.path, name: name, description: "Temporary fixture · \(name.replacingOccurrences(of: "-", with: " "))",
            logicalBytes: Int64(files[file]?.count ?? 0), modified: Date(),
            exposures: [SkillExposure(logicalPath: file.path, resolvedPath: file.path, source: "Temporary workspace", scope: .project, provider: .codex, applicability: .conditional)],
            policies: [SkillRuntimePolicy(runtime: .codex, mode: .automatic, explicit: false, reason: "Temporary fixture route.", invocation: "$" + name, isExposed: true)],
            contentFingerprint: "temporary-fixture-\(index)")
    }
    model.catalog = SkillCatalogSnapshot(records: records, coverage: coverage, generatedAt: Date())
    model.skillActivity = SkillActivitySnapshot(observations: [], coverage: [], scannedAt: Date())
    let usageFixture = UsageLayoutTests.fixtureModel()
    model.usageReport = usageFixture.usageReport
    model.quotaReceipts = usageFixture.quotaReceipts
    model.projects = [AIContextProject(id: project.path, path: project.path, name: "Temporary workspace",
        locations: [AIContextProjectLocation(id: project.path, path: project.path, name: "Project instructions", scope: .project,
            items: items, providers: [.codex, .claude, .cursor], logicalBytes: items.reduce(0) { $0 + $1.logicalBytes })],
        projectItemCount: items.count, projectLogicalBytes: items.reduce(0) { $0 + $1.logicalBytes }, providers: [.codex, .claude, .cursor])]
    model.show(.memory)
    let initialSelection = ProcessInfo.processInfo.environment["CONTEXTDADDY_MAC_UI_SELECTED"] == "1" ? snapshot.entries.first : nil
    let view = VStack(spacing: 0) {
        HStack {
            Label("Temporary fixture documents", systemImage: "doc.text")
            Spacer()
            Text("Production workspace · no live discovery")
        }
        .font(.caption).foregroundStyle(DaddyTheme.muted).padding(.horizontal, 24).frame(height: 36)
        Divider()
        RootView(refreshOnAppear: false, memorySnapshot: snapshot, memoryManager: manager, memorySelection: initialSelection)
    }
    .environment(model)
    .defaultAppStorage(defaults)
    .contextTheme(DaddyTheme.palette)
    .buttonStyle(SMMacButtonStyle())
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 1240, height: 800),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.title = "ContextDaddy review desk · temporary fixtures"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 880, height: 640)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    NSApplication.shared.setActivationPolicy(.regular)
    if let screen = NSScreen.screens.last {
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - 24))
    }
    // Default: surface without taking focus. ACTIVATE=1 opts into a key window and activation.
    if ProcessInfo.processInfo.environment["CONTEXTDADDY_MAC_UI_ACTIVATE"] == "1" {
        window.makeKeyAndOrderFront(nil)
    } else {
        window.orderFront(nil)
    }
    defer { window.orderOut(nil); window.contentView = nil }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let receipt: [String: Any] = [
        "pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": window.windowNumber,
        "fixtureRoot": temporary.path, "documents": snapshot.entries.count,
        "view": "RootView + MemoryLibraryView", "liveDiscovery": false,
        "resizeRequest": ready + ".size", "done": ready + ".done",
        "windowFrame": ["x": Double(window.frame.minX), "y": Double(window.frame.minY), "width": Double(window.frame.width), "height": Double(window.frame.height)],
        "contentBounds": ["width": Double(host.bounds.width), "height": Double(host.bounds.height)],
        "backingScaleFactor": Double(window.backingScaleFactor)
    ]
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: ready), options: .atomic)
    var previousSize: Data?
    var previousSection: String?
    holdNativeEventLoop {
        if FileManager.default.fileExists(atPath: ready + ".done") { return true }
        if let request = try? Data(contentsOf: URL(fileURLWithPath: ready + ".size")), request != previousSize,
           let size = try? JSONDecoder().decode(MemoryWindowSize.self, from: request) {
            window.setContentSize(NSSize(width: min(1800, max(880, size.width)), height: min(1200, max(640, size.height))))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            previousSize = request
        }
        if let section = try? String(contentsOfFile: ready + ".section", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           section != previousSection, let destination = AppSection(rawValue: section),
           [.overview, .skills, .memory, .projects].contains(destination) {
            // These destinations do not start collectors. Skills' empty scope prevents live discovery.
            defaults.set("", forKey: "skillWorkingFolder")
            model.show(destination)
            previousSection = section
        }
        return false
    }
    for (file, original) in files {
        #expect(try Data(contentsOf: file) == original, "Native UI review must leave fixture documents unchanged")
    }
}

/// Test-only AppKit event loop: AX must be able to service real native actions.
@MainActor private func holdNativeEventLoop(poll: @escaping @MainActor () -> Bool) {
    let deadline = Date().addingTimeInterval(120)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            guard poll() || Date() >= deadline else { return }
            NSApplication.shared.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApplication.shared.postEvent(event, atStart: false)
            }
        }
    }
    if ProcessInfo.processInfo.environment["CONTEXTDADDY_MAC_UI_ACTIVATE"] == "1" {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    NSApplication.shared.run()
    timer.invalidate()
}

private struct MemoryWindowSize: Decodable {
    let width: Double
    let height: Double
}
