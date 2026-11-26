import SwiftUI

/// Persistent context inventory shared by the host's routes and quit review.
@MainActor public final class ContextWorkspaceSession: ObservableObject {
    fileprivate let model: ContextDaddyModel
    fileprivate var loaded = false
    public init() {
        model = ContextDaddyModel()
    }
    public var activeWorkDescription: String? { ContextUpdateActivity.operations > 0 ? "An approved context change is being applied or restored." : model.activeWorkDescription }
}

public enum ContextRoute: String, CaseIterable {
    case usage, skills, cleanup, memory, projects, telemetry, diagnostics, plugins, files
}

public struct ContextWorkspaceView: View {
    private let session: ContextWorkspaceSession
    private let route: ContextRoute

    private let onNavigate: (ContextRoute) -> Void

    public init(session: ContextWorkspaceSession, route: ContextRoute, onNavigate: @escaping (ContextRoute) -> Void = { _ in }) {
        self.onNavigate = onNavigate
        self.session = session
        self.route = route
    }

    public var body: some View {
        RootView(refreshOnAppear: false, embedded: true)
            .environment(session.model)
            .onChange(of: route, initial: true) { _, destination in select(destination) }
            .onChange(of: visibleRoute) { _, updated in
                if updated != route { onNavigate(updated) }
            }
            .task {
                guard !session.loaded else { return }
                await session.model.refresh()
                if !Task.isCancelled { session.loaded = true }
            }
    }

    private var visibleRoute: ContextRoute {
        let model = session.model
        if model.evidenceOpen { return model.sourcesMode == .inventory ? .files : .diagnostics }
        switch model.section ?? .overview {
        case .overview: return .usage
        case .telemetry: return .telemetry
        case .memory: return .memory
        case .projects: return .projects
        case .skills: return model.skillsMode == .plugins ? .plugins : model.skillsMode == .cleanup ? .cleanup : .skills
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
