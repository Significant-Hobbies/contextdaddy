import SwiftUI

/// Persistent context inventory shared by the host's routes and quit review.
@MainActor public final class ContextWorkspaceSession: ObservableObject {
    let model: ContextDaddyModel
    private let refresh: @MainActor (ContextDaddyModel) async -> Void
    private var initialRefresh: Task<Void, Never>?

    public convenience init() {
        Self.importPresentationPreferences(from: UserDefaults(suiteName: "com.significanthobbies.contextdaddy"), to: .standard)
        self.init(model: ContextDaddyModel()) { await $0.refresh() }
    }

    init(model: ContextDaddyModel, refresh: @escaping @MainActor (ContextDaddyModel) async -> Void) {
        self.model = model
        self.refresh = refresh
    }

    // Paths and provider checks require new choices in this host. Only
    // presentation settings and prior keep decisions cross the app boundary.
    static func importPresentationPreferences(from source: UserDefaults?, to destination: UserDefaults) {
        let marker = "contextDaddyImportedStandalonePreferencesV1"
        guard !destination.bool(forKey: marker), let source else { return }
        let keys = ["skillLibraryFavorites", "skillLibraryTags", "skillCleanupKeptDecisions",
                    "contextDaddySessionTimeZone", "contextDaddySessionTimeRead", "skillLibraryGuideCompleted"]
        for key in keys where destination.object(forKey: key) == nil {
            if let value = source.object(forKey: key) { destination.set(value, forKey: key) }
        }
        destination.set(true, forKey: marker)
    }

    @discardableResult func startIfNeeded() -> Task<Void, Never> {
        if let initialRefresh { return initialRefresh }
        let task = Task { [model, refresh] in await refresh(model) }
        initialRefresh = task
        return task
    }

    public var activeWorkDescription: String? { model.activeWorkDescription }
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
            .onChange(of: route, initial: true) { _, destination in destination.select(in: session.model) }
            .onChange(of: ContextRoute.visible(in: session.model)) { _, updated in
                if updated != route { onNavigate(updated) }
            }
            .onAppear { session.startIfNeeded() }
    }
}

extension ContextRoute {
    @MainActor static func visible(in model: ContextDaddyModel) -> ContextRoute {
        if model.evidenceOpen { return model.sourcesMode == .inventory ? .files : .diagnostics }
        switch model.section ?? .overview {
        case .overview: return .usage
        case .telemetry: return .telemetry
        case .memory: return .memory
        case .projects: return .projects
        case .skills: return model.skillsMode == .plugins ? .plugins : model.skillsMode == .cleanup ? .cleanup : .skills
        }
    }

    @MainActor func select(in model: ContextDaddyModel) {
        switch self {
        case .usage: model.show(.overview)
        case .memory: model.show(.memory)
        case .projects: model.show(.projects)
        case .telemetry: model.show(.telemetry)
        case .files: model.showEvidence(.inventory)
        case .diagnostics: model.showEvidence(.diagnostics)
        case .skills, .cleanup, .plugins:
            model.show(.skills)
            model.skillsMode = self == .cleanup ? .cleanup : self == .plugins ? .plugins : .library
        }
    }
}
