import AppKit
import Combine
import XCTest
@testable import ContextDaddy

final class BackgroundActivityTests: XCTestCase {
    @MainActor func testUpdaterPublishesOnlyCombinedIdleTransitions() async {
        let model = ContextDaddyModel()
        let updates = AppUpdates()
        let activity = PassthroughSubject<Void, Never>()
        updates.start(model: model, activity: activity.eraseToAnyPublisher())
        var publications = 0
        let subscription = updates.$waitingForIdle.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        await pulse(activity)
        await pulse(activity)
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(updates.isIdle)

        model.isSessionTimeLoading = true
        await pulse(activity)
        XCTAssertEqual(publications, 2)
        XCTAssertFalse(updates.isIdle)
        await ContextUpdateActivity.perform {
            model.isSessionTimeLoading = false
            await pulse(activity)
            XCTAssertEqual(publications, 2)
            XCTAssertFalse(updates.isIdle)
        }
        await pulse(activity)
        await pulse(activity)
        XCTAssertEqual(publications, 3)
        XCTAssertTrue(updates.isIdle)
    }

    @MainActor func testSessionTimeAutomaticReadFollowsNativeWindowVisibility() async throws {
        _ = NSApplication.shared
        let visibility = SessionTimeVisibility()
        XCTAssertFalse(visibility.allowsAutomaticRead)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 200, height: 120),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = visibility
        defer { window.close() }
        XCTAssertFalse(visibility.allowsAutomaticRead)

        window.orderFrontRegardless()
        guard await waitFor({ window.occlusionState.contains(.visible) }) else {
            throw XCTSkip("WindowServer did not expose the shown fixture window as visible in this test host.")
        }
        XCTAssertTrue(visibility.allowsAutomaticRead)

        window.miniaturize(nil)
        _ = await waitFor { window.isMiniaturized }
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(visibility.allowsAutomaticRead)

        window.deminiaturize(nil)
        window.orderFrontRegardless()
        _ = await waitFor { visibility.allowsAutomaticRead }
        XCTAssertTrue(visibility.allowsAutomaticRead)

        window.orderOut(nil)
        _ = await waitFor { !visibility.allowsAutomaticRead }
        XCTAssertFalse(visibility.allowsAutomaticRead)
        window.contentView = nil
        XCTAssertFalse(visibility.allowsAutomaticRead)
    }

    @MainActor func testUpdaterRetainsBusyIntervalBetweenTimerPulses() async {
        let model = ContextDaddyModel()
        let updates = AppUpdates()
        let activity = PassthroughSubject<Void, Never>()
        updates.start(model: model, activity: activity.eraseToAnyPublisher())
        var publications = 0
        let subscription = updates.$waitingForIdle.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        await pulse(activity)
        XCTAssertEqual(publications, 1)

        model.isSessionTimeLoading = true
        XCTAssertFalse(updates.isIdle)
        model.isSessionTimeLoading = false
        await pulse(activity)
        XCTAssertEqual(publications, 3)
        XCTAssertTrue(updates.isIdle)
    }

    @MainActor private func pulse(_ activity: PassthroughSubject<Void, Never>) async {
        activity.send(())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
