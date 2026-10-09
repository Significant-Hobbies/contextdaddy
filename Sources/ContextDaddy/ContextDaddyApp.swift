import AppKit
import SwiftUI

@main
struct ContextDaddyApp: App {
    @NSApplicationDelegateAdaptor(ContextDaddyAppDelegate.self) private var appDelegate
    @State private var model = ContextDaddyModel()
    @StateObject private var updates = AppUpdates()

    var body: some Scene {
        Window("ContextDaddy", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { appDelegate.activeWork = { model.activeWorkDescription } }
                .task { updates.start(model: model) }
        }
        .defaultSize(width: 1180, height: 740)
        .defaultPosition(.center)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                DaddyUpdateMenu(updates: updates)
            }
        }
        MenuBarExtra {
            ContextMenu(model: model)
        } label: {
            Label("ContextDaddy", systemImage: "square.stack.3d.up")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class ContextDaddyAppDelegate: NSObject, NSApplicationDelegate {
    var activeWork: (() -> String?)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = ContextDoodleArt.appIcon()
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first,
                  let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame.insetBy(dx: 18, dy: 18)
            guard !visible.contains(window.frame) else { return }

            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = ContextDoodleArt.appIcon()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DaddyQuitReview.shouldQuit(appName: "ContextDaddy", activeWork: activeWork?()) ? .terminateNow : .terminateCancel
    }

}

struct ContextMenu: View {
    let model: ContextDaddyModel

    var body: some View {
        DaddyMenuStatus(message: model.contextMenuStatus)
        if let lastRefresh = model.lastSuccessfulRefreshAt {
            Text("Last refresh: \(lastRefresh.formatted(date: .abbreviated, time: .shortened))")
        }
        Divider()
        DaddyMenuOpenButton(appName: "ContextDaddy")
        Button("Refresh Local Context") { Task { await model.refreshSkillLibrary() } }
            .disabled(model.isLoading)
        Divider()
        DaddyMenuQuitButton(appName: "ContextDaddy")
    }
}
