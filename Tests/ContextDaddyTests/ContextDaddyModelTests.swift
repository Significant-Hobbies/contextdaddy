import Foundation
import Testing
@testable import ContextCore
@testable import ContextDaddy

@MainActor
struct ContextDaddyModelTests {
    @Test func decisionDeskNavigationKeepsEvidenceSecondary() {
        let model = ContextDaddyModel()
        #expect(model.section == .overview)
        #expect(model.visibleSkills.isEmpty)
        #expect(AppSection.allCases == [.overview, .skills, .memory, .projects, .telemetry])
        #expect(AppSection.overview.label == "Usage")
        #expect(AppSection.telemetry.label == "Run telemetry")
        #expect(SkillsMode.ledger.rawValue == "Agent policies")
        #expect(!model.evidenceOpen)
        #expect(model.skillsMode == .library)

        model.showEvidence(.diagnostics)
        #expect(model.evidenceOpen)
        #expect(model.sourcesMode == .diagnostics)
        model.skillsMode = .plugins
        model.pendingSkillRuntime = .claude
        model.show(.skills)
        #expect(model.skillsMode == .library)
        #expect(model.pendingSkillRuntime == .claude)
        model.show(.telemetry)
        #expect(model.section == .telemetry)
        #expect(!model.evidenceOpen)
        #expect(model.sourcesMode == .diagnostics)
    }

    @Test func failedLibraryRefreshPreservesPreviousDiscovery() async {
        let source = LockedDiscoveryResults([.success(report(elapsed: 0.25)), .failure(.expected)])
        let model = ContextDaddyModel { _ in try source.next() }
        await model.refreshSkillLibrary()
        let previous = model.catalog
        await model.refreshSkillLibrary()
        #expect(model.catalog == previous)
        #expect(model.lastError != nil)
        #expect(!model.isLoading)
    }

    @Test func failedRefreshPreservesPreviousDiscovery() async {
        let source = LockedDiscoveryResults([
            .success(report(elapsed: 0.25)),
            .failure(.expected),
        ])
        let model = ContextDaddyModel { _ in try source.next() }

        await model.refresh()
        let firstReport = model.discoveryReport
        #expect(firstReport?.elapsed == 0.25)

        await model.refresh()
        #expect(model.discoveryReport == firstReport)
        #expect(model.discoveryStatus.contains("showing previous results"))
        #expect(model.lastError != nil)
    }

    @Test func ledgerFiltersUseTheSelectedRuntimeOnly() {
        let model = ContextDaddyModel()
        model.catalog = SkillCatalogSnapshot(
            records: [
                skill("auto", codex: .automatic, claude: .manualOnly),
                skill("manual", codex: .manualOnly, claude: .automatic),
                skill("hidden", codex: .unsupported, claude: .automatic),
                skill("default", codex: .automatic, claude: .unsupported, codexExplicit: false),
            ],
            coverage: emptyCoverage,
            generatedAt: .distantPast
        )

        model.selectedRuntime = .codex
        model.filter = .manual
        #expect(model.visibleSkills.map(\.name) == ["manual"])
        model.filter = .notExposed
        #expect(model.visibleSkills.map(\.name) == ["hidden"])
        model.filter = .review
        #expect(model.visibleSkills.map(\.name) == ["default"])

        model.selectedRuntime = .claude
        model.filter = .manual
        #expect(model.visibleSkills.map(\.name) == ["auto"])
        model.filter = .notExposed
        #expect(model.visibleSkills.map(\.name) == ["default"])
    }

    @Test func redundancyReviewFiltersByKindAgentAndSearch() {
        let model = ContextDaddyModel()
        model.catalog = SkillCatalogSnapshot(
            records: [
                skill("copy-a", codex: .automatic, claude: .unsupported, fingerprint: "same", description: "Identical alpha content"),
                skill("copy-b", codex: .automatic, claude: .unsupported, fingerprint: "same", description: "Identical alpha content"),
                skill("drift", codex: .unsupported, claude: .automatic, fingerprint: "old", description: "Old Claude definition"),
                skill("Drift", codex: .unsupported, claude: .automatic, fingerprint: "new", description: "New Claude definition"),
            ],
            coverage: emptyCoverage,
            generatedAt: .distantPast
        )

        model.redundancyKindFilter = .exact
        #expect(model.visibleRedundancyFindings.count == 1)
        model.redundancyAgentFilter = .claude
        #expect(model.visibleRedundancyFindings.isEmpty)
        model.redundancyKindFilter = .drift
        #expect(model.visibleRedundancyFindings.count == 1)
        model.search = "new claude"
        #expect(model.visibleRedundancyFindings.count == 1)
    }

    @Test func redundancyReviewDefaultsToActionableFindingsNotManagedCaches() {
        let model = ContextDaddyModel()
        let active = skill("active-a", codex: .automatic, claude: .unsupported, fingerprint: "active")
        var cachedA = skill("cached-a", codex: .unsupported, claude: .unsupported, fingerprint: "cache")
        var cachedB = skill("cached-b", codex: .unsupported, claude: .unsupported, fingerprint: "cache")
        cachedA = managedCache(cachedA)
        cachedB = managedCache(cachedB)
        model.catalog = SkillCatalogSnapshot(
            records: [active, skill("active-b", codex: .automatic, claude: .unsupported, fingerprint: "active"), cachedA, cachedB],
            coverage: emptyCoverage,
            generatedAt: .distantPast
        )

        #expect(model.redundancyKindFilter == .review)
        #expect(model.visibleRedundancyFindings.count == 1)
        model.redundancyKindFilter = .exact
        #expect(model.visibleRedundancyFindings.count == 1)
        #expect(model.visibleRedundancyFindings.allSatisfy { !$0.isManagedCacheOnly })
        model.redundancyKindFilter = .managed
        #expect(model.visibleRedundancyFindings.count == 1)
        #expect(model.visibleRedundancyFindings.allSatisfy { $0.isManagedCacheOnly })
    }

    private func report(elapsed: TimeInterval) -> AIContextDiscoveryReport {
        AIContextDiscoveryReport(
            items: [], folderRankings: [],
            coverage: AIContextCoverage(roots: [], visitedEntries: 0, itemLimitReached: false,
                                       entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: []),
            elapsed: elapsed
        )
    }

    private var emptyCoverage: AIContextCoverage {
        AIContextCoverage(roots: [], visitedEntries: 0, itemLimitReached: false,
                          entryLimitReached: false, unreadableCount: 0, skippedLinks: 0, notes: [])
    }

    private func skill(
        _ name: String,
        codex: InvocationMode,
        claude: InvocationMode,
        codexExplicit: Bool = true,
        fingerprint: String? = nil,
        description: String = "Fixture"
    ) -> SkillRecord {
        let policies = AgentRuntime.allCases.map { runtime -> SkillRuntimePolicy in
            let mode: InvocationMode = runtime == .codex ? codex : runtime == .claude ? claude : .unsupported
            return SkillRuntimePolicy(
                runtime: runtime,
                mode: mode,
                explicit: runtime == .codex ? codexExplicit : true,
                reason: "Fixture",
                invocation: runtime == .codex ? "$\(name)" : "/\(name)",
                isExposed: mode != .unsupported
            )
        }
        return SkillRecord(
            id: "/skills/\(name)/SKILL.md",
            name: name,
            description: description,
            logicalBytes: 1,
            modified: .distantPast,
            exposures: [
                SkillExposure(
                    logicalPath: "/skills/\(name)/SKILL.md",
                    resolvedPath: "/skills/\(name)/SKILL.md",
                    source: "Fixture",
                    scope: .global,
                    provider: codex != .unsupported ? .codex : .claude,
                    applicability: .global
                ),
            ],
            policies: policies,
            contentFingerprint: fingerprint
        )
    }

    private func managedCache(_ record: SkillRecord) -> SkillRecord {
        SkillRecord(
            id: record.id,
            name: record.name,
            description: record.description,
            logicalBytes: record.logicalBytes,
            modified: record.modified,
            exposures: record.exposures.map {
                SkillExposure(
                    logicalPath: $0.logicalPath,
                    resolvedPath: $0.resolvedPath,
                    source: "Plugin cache",
                    scope: $0.scope,
                    provider: $0.provider,
                    applicability: .installedOnly
                )
            },
            policies: record.policies,
            contentFingerprint: record.contentFingerprint
        )
    }
}

private enum DiscoveryTestError: Error { case expected }

private final class LockedDiscoveryResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<AIContextDiscoveryReport, DiscoveryTestError>]

    init(_ results: [Result<AIContextDiscoveryReport, DiscoveryTestError>]) { self.results = results }

    func next() throws -> AIContextDiscoveryReport {
        lock.lock()
        defer { lock.unlock() }
        return try results.removeFirst().get()
    }
}
