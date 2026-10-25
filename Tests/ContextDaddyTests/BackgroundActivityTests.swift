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

    @MainActor func testSessionTimeAutomaticReadFollowsNativeWindowVisibility() async {
        _ = NSApplication.shared
        let visibility = SessionTimeVisibility()
        XCTAssertFalse(visibility.allowsAutomaticRead)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 200, height: 120),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = visibility
        defer { window.close() }
        XCTAssertFalse(visibility.allowsAutomaticRead)

        window.orderFrontRegardless()
        await settleWindow()
        XCTAssertTrue(window.occlusionState.contains(.visible))
        XCTAssertTrue(visibility.allowsAutomaticRead)

        window.miniaturize(nil)
        await settleWindow()
        XCTAssertTrue(window.isMiniaturized)
        XCTAssertFalse(visibility.allowsAutomaticRead)

        window.deminiaturize(nil)
        window.orderFrontRegardless()
        await settleWindow()
        XCTAssertTrue(visibility.allowsAutomaticRead)

        window.orderOut(nil)
        await settleWindow()
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

    @MainActor private func settleWindow() async {
        try? await Task.sleep(for: .milliseconds(150))
    }
}
