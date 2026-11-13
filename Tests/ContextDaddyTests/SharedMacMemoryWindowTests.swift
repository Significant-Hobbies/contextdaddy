import AppKit
import ContextCore
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
    defaults.set(project.path, forKey: "skillWorkingFolder")
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
    let view = VStack(spacing: 0) {
        HStack {
            Label("Temporary fixture documents", systemImage: "doc.text")
            Spacer()
            Text("Production Memory view · no live discovery")
        }
        .font(.caption).foregroundStyle(DaddyTheme.muted).padding(.horizontal, 24).frame(height: 36)
        Divider()
        MemoryLibraryView(snapshot: snapshot, manager: manager)
    }
    .environment(model)
    .defaultAppStorage(defaults)
    .contextTheme(DaddyTheme.palette)
    .buttonStyle(SMMacButtonStyle())
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 1180, height: 800),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
    window.title = "ContextDaddy shared UI · temporary fixtures"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 736, height: 500)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    NSApplication.shared.setActivationPolicy(.regular)
    if let screen = NSScreen.screens.last {
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - 24))
    }
    // Surface this test window without activating the app or taking keyboard focus.
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let receipt: [String: Any] = [
        "pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": window.windowNumber,
        "fixtureRoot": temporary.path, "documents": snapshot.entries.count,
        "view": "MemoryLibraryView", "liveDiscovery": false,
        "resizeRequest": ready + ".size", "done": ready + ".done"
    ]
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: ready), options: .atomic)
    var previousSize: Data?
    for _ in 0..<1200 {
        if FileManager.default.fileExists(atPath: ready + ".done") { break }
        if let request = try? Data(contentsOf: URL(fileURLWithPath: ready + ".size")), request != previousSize,
           let size = try? JSONDecoder().decode(MemoryWindowSize.self, from: request) {
            window.setContentSize(NSSize(width: min(1800, max(736, size.width)), height: min(1200, max(500, size.height))))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            previousSize = request
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    for (file, original) in files {
        #expect(try Data(contentsOf: file) == original, "Native UI review must leave fixture documents unchanged")
    }
}

private struct MemoryWindowSize: Decodable {
    let width: Double
    let height: Double
}
