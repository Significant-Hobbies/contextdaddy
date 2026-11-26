import AppKit
import ContextCore
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor
struct ManagedSkillHealthViewTests {
    @Test func writesManagedSkillHealthEvidence() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/design/managed-health")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["healthy", "failed"] {
            let payload = """
            {"schemaVersion":1,"generatedAt":"2026-10-24T00:00:00Z","scope":"all registered targets","repositoryDirty":true,
             "summary":{"entryCount":1,"problemCount":0,"unmanagedCount":0},"skills":[{"name":"example","type":"git-pinned",
             "physicalPath":"/tmp/example","revision":"abc123","status":"ok","targets":[]}],
             "maintenance":{"status":"\(state)","scope":"non-Desktop targets","lastExitCode":\(state == "healthy" ? 0 : 1)}}
            """
            let model = ContextDaddyModel()
            model.managedSkillHealth = try ManagedSkillHealth.decode(Data(payload.utf8))
            for width in [390, 768, 1440] {
                let view = NSHostingView(rootView: ScrollView {
                    ManagedSkillHealthView().padding(24)
                }.contextTheme(DaddyTheme.palette).environment(model).preferredColorScheme(.dark)
                    .frame(width: CGFloat(width), height: 660).background(DaddyTheme.canvas))
                view.frame = NSRect(x: 0, y: 0, width: width, height: 660)
                let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("\(state)-\(width).png"))
                window.orderOut(nil)
            }
        }
    }
}
