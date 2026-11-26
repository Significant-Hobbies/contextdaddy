import AppKit
import SwiftUI
import Testing
@testable import ContextDaddy

@MainActor @Suite(.serialized)
struct ContextWorkspaceTests {
    @Test func routesRoundTripAndInPageNavigationRemainsVisible() {
        let model = ContextDaddyModel()
        for route in ContextRoute.allCases {
            route.select(in: model)
            #expect(ContextRoute.visible(in: model) == route)
        }
        ContextRoute.memory.select(in: model)
        model.showEvidence(.inventory)
        #expect(ContextRoute.visible(in: model) == .files)
        model.sourcesMode = .diagnostics
        #expect(ContextRoute.visible(in: model) == .diagnostics)
        model.evidenceOpen = false
        #expect(ContextRoute.visible(in: model) == .memory)
        model.show(.skills)
        for mode in [SkillsMode.ledger, .redundancy] {
            model.skillsMode = mode
            #expect(ContextRoute.visible(in: model) == .skills)
            ContextRoute.skills.select(in: model)
            #expect(model.skillsMode == mode)
        }
        model.skillsMode = .plugins
        #expect(ContextRoute.visible(in: model) == .plugins)
    }

    @Test func initialRefreshSurvivesViewCancellationAndRunsOnce() async {
        var calls = 0
        var cancelled = false
        let session = ContextWorkspaceSession(model: ContextDaddyModel()) { _ in
            calls += 1
            await Task.yield()
            cancelled = Task.isCancelled
        }
        let viewLifetime = Task { await session.startIfNeeded().value }
        viewLifetime.cancel()
        await viewLifetime.value
        await session.startIfNeeded().value
        #expect(calls == 1)
        #expect(!cancelled)
    }

    @Test func managedOperationsSurfaceAsActiveWork() async {
        let model = ContextDaddyModel()
        let session = ContextWorkspaceSession(model: model) { _ in }
        await ContextUpdateActivity.perform {
            #expect(model.activeWorkDescription?.contains("restored") == true)
            #expect(session.activeWorkDescription == model.activeWorkDescription)
        }
        #expect(session.activeWorkDescription == nil)
    }

    @Test func preferencesMigrateOnceWithoutExtendingConsentOrOverwritingHostChoices() throws {
        let old = UUID().uuidString, new = UUID().uuidString
        let source = try #require(UserDefaults(suiteName: old))
        let destination = try #require(UserDefaults(suiteName: new))
        defer {
            source.removePersistentDomain(forName: old)
            destination.removePersistentDomain(forName: new)
        }
        source.set(["favorite"], forKey: "skillLibraryFavorites")
        source.set(["keep"], forKey: "skillCleanupKeptDecisions")
        destination.set(["existing"], forKey: "skillCleanupKeptDecisions")
        for key in ["contextDaddySearchRoots", "contextDaddySkillRoots", "contextDaddyAutoCheckAllowance", "contextDaddySessionTimeRead", "skillWorkingFolder"] {
            source.set("private choice", forKey: key)
        }
        ContextWorkspaceSession.importPresentationPreferences(from: source, to: destination)
        #expect(destination.stringArray(forKey: "skillLibraryFavorites") == ["favorite"])
        #expect(destination.stringArray(forKey: "skillCleanupKeptDecisions") == ["existing"])
        for key in ["contextDaddySearchRoots", "contextDaddySkillRoots", "contextDaddyAutoCheckAllowance", "contextDaddySessionTimeRead", "skillWorkingFolder"] {
            #expect(destination.object(forKey: key) == nil)
        }
        destination.removeObject(forKey: "skillLibraryFavorites")
        ContextWorkspaceSession.importPresentationPreferences(from: source, to: destination)
        #expect(destination.object(forKey: "skillLibraryFavorites") == nil)
    }

    @Test func anEarlierImportRequiresFreshTranscriptConsent() throws {
        let name = UUID().uuidString
        let destination = try #require(UserDefaults(suiteName: name))
        defer { destination.removePersistentDomain(forName: name) }
        destination.set(true, forKey: "contextDaddyImportedStandalonePreferencesV1")
        destination.set(true, forKey: "contextDaddySessionTimeRead")
        ContextWorkspaceSession.importPresentationPreferences(from: destination, to: destination)
        #expect(!destination.bool(forKey: "contextDaddySessionTimeRead"))
        destination.set(true, forKey: "contextDaddySessionTimeRead")
        ContextWorkspaceSession.importPresentationPreferences(from: destination, to: destination)
        #expect(destination.bool(forKey: "contextDaddySessionTimeRead"))
    }

    @Test func hostedNavigationSelectsRoutesAndDoesNotEchoTheCallback() throws {
        let model = ContextDaddyModel()
        let session = ContextWorkspaceSession(model: model) { _ in }
        var changes: [ContextRoute] = []
        func content(_ route: ContextRoute) -> ContextWorkspaceView {
            ContextWorkspaceView(session: session, route: route) { changes.append($0) }
        }
        let host = NSHostingView(rootView: content(.projects))
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        settle()
        #expect(ContextRoute.visible(in: model) == .projects)
        host.rootView = content(.telemetry)
        settle()
        #expect(ContextRoute.visible(in: model) == .telemetry)
        model.showEvidence(.diagnostics)
        settle()
        #expect(changes == [.diagnostics])
        host.rootView = content(.diagnostics)
        settle()
        #expect(changes == [.diagnostics])
    }

}
