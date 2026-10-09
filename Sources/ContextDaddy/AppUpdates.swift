import AppKit
import Combine

@MainActor final class AppUpdates: DaddyAppUpdates {
    init() {
        super.init(appName: "ContextDaddy", busyMessage: "Finish the current context check or management review before checking for updates.")
    }

    func start(model: ContextDaddyModel) {
        // The model uses Observation; a lightweight timer also notices native
        // sheets closing and management tasks completing outside a model refresh.
        let activity = Timer.publish(every: 1, on: .main, in: .common).autoconnect().map { _ in () }.eraseToAnyPublisher()
        start(observing: activity) { [weak model] in
            guard let model else { return false }
            return model.activeWorkDescription == nil && ContextUpdateActivity.operations == 0
                && NSApplication.shared.modalWindow == nil
                && !NSApplication.shared.windows.contains { $0.attachedSheet != nil }
        }
    }
}

/// Holds relaunch across awaited owner-approved writes, even if a sheet closes.
@MainActor enum ContextUpdateActivity {
    private(set) static var operations = 0

    static func perform<T>(_ operation: () async throws -> T) async rethrows -> T {
        operations += 1
        defer { operations -= 1 }
        return try await operation()
    }
}
