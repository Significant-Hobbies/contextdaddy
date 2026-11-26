import SwiftUI

/// Persistent context inventory shared by the host's routes and quit review.
@MainActor public final class ContextWorkspaceSession: ObservableObject {
    fileprivate let model: ContextDaddyModel
    fileprivate var loaded = false
    public init() {
        // Read the standalone app's established preferences when the host has no override.
        UserDefaults.standard.addSuite(named: "com.significanthobbies.contextdaddy")
        model = ContextDaddyModel()
    }
    public var activeWorkDescription: String? { model.activeWorkDescription }
}

public enum ContextRoute: String, CaseIterable {
    case usage, skills, cleanup, memory, projects, telemetry, diagnostics, plugins, files
}

public struct ContextWorkspaceView: View {
    private let session: ContextWorkspaceSession
    private let route: ContextRoute

    public init(session: ContextWorkspaceSession, route: ContextRoute) {
        self.session = session
        self.route = route
    }

    public var body: some View {
        RootView(refreshOnAppear: false, embedded: true)
            .environment(session.model)
            .onChange(of: route, initial: true) { _, destination in select(destination) }
            .task {
                guard !session.loaded else { return }
                await session.model.refresh()
                if !Task.isCancelled { session.loaded = true }
            }
    }

    private func select(_ route: ContextRoute) {
        let model = session.model
        switch route {
        case .usage: model.show(.overview)
        case .memory: model.show(.memory)
        case .projects: model.show(.projects)
        case .telemetry: model.show(.telemetry)
        case .files: model.showEvidence(.inventory)
        case .diagnostics: model.showEvidence(.diagnostics)
        case .skills, .cleanup, .plugins:
            model.show(.skills)
            model.skillsMode = route == .cleanup ? .cleanup : route == .plugins ? .plugins : .library
        }
    }
}
