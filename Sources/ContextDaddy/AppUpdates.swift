import AppKit
import Combine

@MainActor final class AppUpdates: DaddyAppUpdates {
    init() {
        super.init(appName: "ContextDaddy", busyMessage: "Finish the current context check or management review before checking for updates.")
    }

    func start(model: ContextDaddyModel, activity: AnyPublisher<Void, Never> = Timer.publish(every: 1, on: .main, in: .common).autoconnect().map { _ in () }.eraseToAnyPublisher()) {
        // The model uses Observation; a lightweight timer also notices native
        // sheets closing and management tasks completing outside a model refresh.
        let isIdle = { [weak model] in
            guard let model else { return false }
            return model.activeWorkDescription == nil && ContextUpdateActivity.operations == 0
                && NSApplication.shared.modalWindow == nil
                && !NSApplication.shared.windows.contains { $0.attachedSheet != nil }
        }
        let busyChecks = PassthroughSubject<Bool, Never>()
        let changes = activity.map { isIdle() }.merge(with: busyChecks)
            .removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        start(observing: changes) {
            let idle = isIdle()
            if !idle { busyChecks.send(false) }
            return idle
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
