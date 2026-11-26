import Foundation
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

    @Test func managedOperationsProtectBothQuitPaths() async {
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
        for key in ["contextDaddySearchRoots", "contextDaddySkillRoots", "contextDaddyAutoCheckAllowance", "skillWorkingFolder"] {
            source.set("private choice", forKey: key)
        }
        ContextWorkspaceSession.importPresentationPreferences(from: source, to: destination)
        #expect(destination.stringArray(forKey: "skillLibraryFavorites") == ["favorite"])
        #expect(destination.stringArray(forKey: "skillCleanupKeptDecisions") == ["existing"])
        for key in ["contextDaddySearchRoots", "contextDaddySkillRoots", "contextDaddyAutoCheckAllowance", "skillWorkingFolder"] {
            #expect(destination.object(forKey: key) == nil)
        }
        destination.removeObject(forKey: "skillLibraryFavorites")
        ContextWorkspaceSession.importPresentationPreferences(from: source, to: destination)
        #expect(destination.object(forKey: "skillLibraryFavorites") == nil)
    }
}
