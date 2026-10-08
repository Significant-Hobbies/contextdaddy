import ContextCore
import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case skills = "Skills"
    case memory = "Memory"
    case projects = "Projects"
    case telemetry = "Telemetry"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: "Usage"
        case .telemetry: "Run telemetry"
        case .skills, .memory, .projects: rawValue
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .skills: "square.stack.3d.up"
        case .memory: "brain.head.profile"
        case .projects: "folder.badge.gearshape"
        case .telemetry: "waveform.path.ecg"
        }
    }
}

enum SourcesMode: String, CaseIterable, Identifiable {
    case inventory = "Inventory"
    case diagnostics = "Diagnostics"
    var id: String { rawValue }
}

enum SkillFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case automatic = "Automatic"
    case manual = "Manual only"
    case model = "Model only"
    case disabled = "Disabled"
    case notExposed = "Cannot discover"
    case review = "Needs review"

    var id: String { rawValue }
}

enum SkillsMode: String, CaseIterable, Identifiable {
    case plugins = "Plugins"
    case cleanup = "Cleanup plan"
    case library = "Library"
    case ledger = "Agent policies"
    case redundancy = "Redundancy review"
    var id: String { rawValue }
}

enum RedundancyKindFilter: String, CaseIterable, Identifiable {
    case review = "Review candidates"
    case exact = "Exact copies"
    case drift = "Version drift"
    case overlap = "Purpose overlap"
    case managed = "Managed cache"
    case all = "All evidence"
    var id: String { rawValue }
}

enum RedundancyAgentFilter: String, CaseIterable, Identifiable {
    case all = "All agents"
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case devin = "Devin"
    case grok = "Grok"
    var id: String { rawValue }
    var runtime: AgentRuntime? { self == .all ? nil : AgentRuntime(rawValue: rawValue) }
}

@MainActor @Observable
final class ContextDaddyModel {
    var section: AppSection? = .overview
    var evidenceOpen = false
    var sourcesMode: SourcesMode = .inventory
    var catalog: SkillCatalogSnapshot? {
        didSet { redundancySummary = catalog.map { SkillRedundancyAnalyzer.analyze(records: $0.records) } }
    }
    var redundancySummary: SkillRedundancySummary?
    var skillIssueBaseline: SkillIssueBaseline?
    var skillIssueVerification: SkillIssueVerification?
    var isVerifyingSkillIssues = false
    var discoveryReport: AIContextDiscoveryReport?
    var projects: [AIContextProject] = []
    var telemetry: ObservabilitySnapshot = .unavailable
    var telemetryHistory: [ObservabilitySnapshot] = []
    var selectedTelemetryRuntime: AgentRuntime = .codex
    var isTelemetryLoading = false
    var usageReport: LocalUsageReport?
    var skillActivity: SkillActivitySnapshot?
    var isSkillActivityLoading = false
    var usageError: String?
    var isUsageLoading = false
    var isDevinLoading = false
    var quotaReceipt: ProviderQuotaReceipt?
    var quotaError: String?
    var quotaReceipts: [String: ProviderQuotaReceipt] = [:]
    var quotaErrors: [String: String] = [:]
    var isQuotaLoading = false
    var autoCheckAllowance = UserDefaults.standard.bool(forKey: "contextDaddyAutoCheckAllowance") {
        didSet { UserDefaults.standard.set(autoCheckAllowance, forKey: "contextDaddyAutoCheckAllowance") }
    }
    var lastAllowanceCheckAttempt = UserDefaults.standard.object(forKey: "contextDaddyLastAllowanceCheckAttempt") as? Date
    var usageService: UsageService = .codex {
        didSet { usageModel = nil; quotaError = nil }
    }
    var usageRange: UsageRange = .month {
        didSet { usageModel = nil }
    }
    var usageModel: String?
    var usageScale: UsageChartScale = .day
    var usageMetric: UsageChartMetric = .generated
    var usageHistoryGrouping: UsageHistoryGrouping = .model
    var usageHistoryAgents: Set<String> = []
    var configurationHealth: ConfigurationHealthReport = .empty
    var configurationIssueBaseline: ConfigurationIssueBaseline?
    var configurationIssueVerification: ConfigurationIssueVerification?
    var isVerifyingConfigurationIssues = false
    var search = ""
    var filter: SkillFilter = .all
    var skillsMode: SkillsMode = .library
    var skillFolderContext: SkillFolderContext?
    var redundancyKindFilter: RedundancyKindFilter = .review
    var redundancyAgentFilter: RedundancyAgentFilter = .all
    var selectedRuntime: AgentRuntime = .codex
    var pendingSkillRuntime: AgentRuntime?
    var pendingSkillInvocation: InvocationMode?
    var pendingSkillAllFolders = false
    var isLoading = false
    var isContextRefreshRunning = false
    var lastSuccessfulRefreshAt: Date?
    var loadStarted = Date()
    var discoveryStatus = "Not scanned yet"
    var lastError: String?
    var extraRoots: [String] = UserDefaults.standard.stringArray(forKey: "contextDaddySearchRoots") ?? [] {
        didSet { UserDefaults.standard.set(extraRoots, forKey: "contextDaddySearchRoots") }
    }
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var usageGeneration = UUID()
    @ObservationIgnored private let discover: @Sendable ([URL]) throws -> AIContextDiscoveryReport
    private let snapshotStore = TelemetrySnapshotStore()
    private let skillActivityStore = SkillActivitySnapshotStore()

    init(discover: @escaping @Sendable ([URL]) throws -> AIContextDiscoveryReport = { roots in
        try AIContextDiscovery.discover(configuration: .init(additionalRoots: roots, additionalSkillRoots:
            (UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []).map { URL(fileURLWithPath: $0) }))
    }) {
        self.discover = discover
    }

    var contextMenuStatus: String {
        if isLoading { return "Refreshing local context…" }
        if lastError != nil { return "Last refresh needs attention" }
        return lastSuccessfulRefreshAt == nil ? "Local context not scanned yet" : "Ready for local review"
    }

    var activeWorkDescription: String? {
        if isLoading || isContextRefreshRunning || isSkillFolderLoading || isVerifyingSkillIssues || isVerifyingConfigurationIssues {
            return "A local context review is still running."
        }
        if isUsageLoading || isDevinLoading { return "Local usage history is still being read." }
        if isTelemetryLoading { return "Local telemetry is still being read." }
        if isSkillActivityLoading { return "Skill activity history is still being read." }
        if isQuotaLoading { return "A provider allowance check is still running." }
        return nil
    }

    func show(_ destination: AppSection) {
        if destination == .skills, pendingSkillRuntime != nil { skillsMode = .library }
        section = destination
        evidenceOpen = false
    }

    func showEvidence(_ mode: SourcesMode = .inventory) {
        sourcesMode = mode
        evidenceOpen = true
    }

    var inventory: [AIContextItem] { discoveryReport?.items ?? [] }
    var folderRankings: [AIContextFolderRanking] { discoveryReport?.folderRankings ?? [] }
    var governanceSummary: SkillGovernanceSummary? { skillFolderContext.map { SkillGovernanceSummary(records: $0.records, runtime: selectedRuntime) } ?? catalog?.governance(for: selectedRuntime) }
    var sharingSummary: SkillSharingSummary? { skillFolderContext.map { SkillSharingSummary(records: $0.records) } ?? catalog?.sharing }
    var usageModels: [String] { usageReport?.models(for: usageService, range: usageRange) ?? [] }
    var usageSlice: UsageSlice? { usageReport?.slice(service: usageService, model: usageModel, range: usageRange) }
    var usageDashboard: UsageDashboardProjection? {
        usageReport.map { UsageDashboardProjection(report: $0, service: usageService, model: usageModel,
                                                   range: usageRange, scale: usageScale, metric: usageMetric) }
    }
    var quotaStatus: ProviderQuotaStatus? {
        guard let key = usageService.quotaKey else { return nil }
        return quotaStatus(for: key)
    }
    func quotaStatus(for key: String) -> ProviderQuotaStatus? {
        quotaReceipts[key]?.providers.first { $0.provider == key }
            ?? quotaReceipt?.providers.first { $0.provider == key }
    }
    var availableHistoryAgents: [String] {
        guard let usageReport else { return ["devin"] }
        return Set((usageReport.provenance.detectedAgents ?? [])
                   + usageReport.daily.flatMap { $0.agents.map(\.agent) }
                   + ["devin"]).sorted()
    }

    var historySourceNotice: String {
        var messages: [String] = []
        if let usageError { messages.append("Agent logs: \(usageError)") }
        if usageHistoryAgents.isEmpty || usageHistoryAgents.contains("devin") {
            if isDevinLoading {
                messages.append("Reading Devin history…")
            } else if let devin = usageReport?.devin, ["ready", "empty"].contains(devin.status) {
                if usageHistoryGrouping == .project {
                    messages.append("Devin project attribution unavailable; Devin is excluded from this session-project view.")
                } else if usageMetric == .estimatedCost {
                    messages.append("Devin cost unavailable; estimated costs exclude Devin.")
                } else if devin.daily == nil {
                    messages.append("Devin daily history unavailable; indexed window totals cannot be allocated to chart dates.")
                } else {
                    messages.append("Includes Devin’s deduplicated local session index alongside agent logs.")
                }
            } else {
                messages.append("Devin history unavailable. " + (usageReport?.devin?.limitations.joined(separator: " · ") ?? "No verified index was returned."))
            }
        }
        return messages.joined(separator: " · ")
    }

    var usageHistory: UsageHistoryProjection? {
        guard let usageReport else { return nil }
        return UsageHistoryProjection(report: usageReport, agents: usageHistoryAgents,
                                      range: usageRange, scale: usageScale,
                                      grouping: usageHistoryGrouping, metric: usageMetric)
    }

    var visibleSkills: [SkillRecord] {
        guard let records = skillFolderContext?.records ?? catalog?.records else { return [] }
        return records.filter { record in
            let matchesSearch = search.isEmpty || record.name.localizedCaseInsensitiveContains(search)
                || record.description.localizedCaseInsensitiveContains(search)
                || record.exposures.contains { $0.logicalPath.localizedCaseInsensitiveContains(search) }
            let matchesFilter = switch filter {
            case .all: true
            case .automatic: record.policy(for: selectedRuntime)?.mode == .automatic
            case .manual: record.policy(for: selectedRuntime)?.mode == .manualOnly
            case .model: record.policy(for: selectedRuntime)?.mode == .modelOnly
            case .disabled: record.policy(for: selectedRuntime)?.mode == .disabled
            case .notExposed: record.policy(for: selectedRuntime)?.isExposed != true
            case .review: record.needsReview(for: selectedRuntime)
            }
            return matchesSearch && matchesFilter
        }
    }

    var visibleRedundancyFindings: [SkillRedundancyFinding] {
        guard let findings = redundancySummary?.findings else { return [] }
        return findings.filter { finding in
            let matchesKind = switch redundancyKindFilter {
            case .review: !finding.isManagedCacheOnly
            case .exact: finding.kind == .exactCopy && !finding.isManagedCacheOnly
            case .drift: finding.kind == .versionDrift
            case .overlap: finding.kind == .semanticOverlap
            case .managed: finding.isManagedCacheOnly
            case .all: true
            }
            let matchesAgent = redundancyAgentFilter.runtime.map { finding.affectedRuntimes.contains($0) } ?? true
            let matchesSearch = search.isEmpty
                || finding.members.contains {
                    $0.name.localizedCaseInsensitiveContains(search)
                        || $0.description.localizedCaseInsensitiveContains(search)
                        || $0.id.localizedCaseInsensitiveContains(search)
                }
                || finding.evidence.contains { $0.localizedCaseInsensitiveContains(search) }
            return matchesKind && matchesAgent && matchesSearch
        }
    }

    func captureSkillIssues() {
        skillIssueBaseline = SkillIssueBaseline(findings: redundancySummary?.actionableFindings ?? [])
        skillIssueVerification = nil
    }

    func verifySkillIssues() async {
        guard let baseline = skillIssueBaseline, !isVerifyingSkillIssues else { return }
        isVerifyingSkillIssues = true
        defer { isVerifyingSkillIssues = false }
        await refresh()
        skillIssueVerification = baseline.verify(
            against: lastError == nil ? redundancySummary : nil,
            scannedRecordIDs: lastError == nil ? catalog.map { Set($0.records.map(\.id)) } : nil)
    }

    func captureConfigurationIssues(_ issues: [ConfigurationHealthIssue]? = nil) {
        configurationIssueBaseline = ConfigurationIssueBaseline(issues: issues ?? configurationHealth.issues)
        configurationIssueVerification = nil
    }

    func verifyConfigurationIssues() async {
        guard let baseline = configurationIssueBaseline, !isVerifyingConfigurationIssues else { return }
        isVerifyingConfigurationIssues = true
        defer { isVerifyingConfigurationIssues = false }
        await refreshConfigurationHealth()
        configurationIssueVerification = baseline.verify(against: configurationHealth)
    }

    private var folderGeneration = UUID()
    var skillFolderError: String?
    var isSkillFolderLoading = false
    func loadSkillFolder(_ path: String) async {
        let request = UUID()
        folderGeneration = request
        skillFolderError = nil
        guard !path.isEmpty else { skillFolderContext = nil; isSkillFolderLoading = false; return }
        isSkillFolderLoading = true
        defer { if folderGeneration == request { isSkillFolderLoading = false } }
        do {
            let task = Task.detached(priority: .userInitiated) {
                let directory = URL(fileURLWithPath: path)
                return SkillFolderContext.resolve(report: try AIContextDiscovery.discoverFolder(directory), directory: directory)
            }
            let context = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, folderGeneration == request else { return }
            skillFolderContext = context
        } catch {
            guard !Task.isCancelled, folderGeneration == request else { return }
            skillFolderContext = nil
            skillFolderError = "Could not inspect the selected folder. " + error.localizedDescription
        }
    }

    private var configurationGeneration = UUID()
    func refreshConfigurationHealth() async {
        let request = UUID()
        configurationGeneration = request
        let project = skillFolderContext.map { URL(fileURLWithPath: $0.path) }
        // Discovered project folders get instruction-import, skill and AGENTS.md visibility checks.
        let discovered = projects.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let records = catalog?.records ?? []
        let activity = skillActivity
        let report = await Task.detached(priority: .utility) {
            let setup = AgentSetupAudit.audit(project: project, instructionProjects: discovered)
            // Measured zero-invocation findings join setup issues so Copy all and Verify include them.
            guard let activity else { return setup }
            let usage = SkillActivityFindings.zeroInvocations(records: records, snapshot: activity)
            return ConfigurationHealthReport(issues: setup.issues + usage.issues, scannedFiles: setup.scannedFiles + usage.files.map(\.path),
                                             generatedAt: setup.generatedAt, files: setup.files + usage.files)
        }.value
        guard configurationGeneration == request else { return }
        configurationHealth = report
    }

    func refreshSkillLibrary() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        let roots = extraRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let discover = self.discover
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let report = try discover(roots)
                return (report, SkillPolicyResolver.resolve(report: report), AIContextProjectCatalog.projects(from: report))
            }.value
            discoveryReport = loaded.0
            catalog = loaded.1
            projects = loaded.2
            lastSuccessfulRefreshAt = Date()
            discoveryStatus = "\(loaded.1.physicalSkillCount) physical skills · \(loaded.1.exposureCount) locations"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        Task { await refreshUsage() }
        let request = UUID()
        refreshGeneration = request
        isContextRefreshRunning = true
        isLoading = true
        loadStarted = Date()
        discoveryStatus = discoveryReport == nil ? "Reading local context metadata…" : "Refreshing while previous results remain available…"
        lastError = nil
        defer {
            if refreshGeneration == request { isLoading = false; isContextRefreshRunning = false }
        }
        if skillActivity == nil, let saved = await skillActivityStore.load() { skillActivity = saved }
        let roots = extraRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let discover = self.discover
        async let loadedContext = Task.detached(priority: .userInitiated) {
            let report = try discover(roots)
            return (report, SkillPolicyResolver.resolve(report: report), AIContextProjectCatalog.projects(from: report))
        }.value
        async let loadedTelemetry = LocalObservabilityClient().load()

        do {
            let loaded = try await loadedContext
            guard refreshGeneration == request else { return }
            discoveryReport = loaded.0
            catalog = loaded.1
            projects = loaded.2
            lastSuccessfulRefreshAt = Date()
            discoveryStatus = "\(loaded.2.count.formatted()) projects · \(loaded.0.items.count.formatted()) file locations · \(String(format: "%.1f", loaded.0.elapsed)) s"
        } catch {
            guard refreshGeneration == request else { return }
            lastError = error.localizedDescription
            discoveryStatus = discoveryReport == nil ? "Discovery needs attention" : "Refresh failed · showing previous results"
        }
        // Publish local discovery before waiting for unrelated collector or config reads.
        isLoading = false
        let nextTelemetry = await loadedTelemetry
        if let path = skillFolderContext?.path { await loadSkillFolder(path) }
        await refreshConfigurationHealth()
        var nextHistory = await snapshotStore.load()
        guard refreshGeneration == request else { return }
        telemetry = nextTelemetry
        telemetryHistory = nextHistory
        if nextTelemetry.collectorReachable {
            do {
                nextHistory = try await snapshotStore.append(nextTelemetry)
                guard refreshGeneration == request else { return }
                telemetryHistory = nextHistory
            } catch {
                lastError = "Telemetry was measured but could not be retained: \(error.localizedDescription)"
            }
        }

    }

    func refreshTelemetry() async {
        guard !isTelemetryLoading else { return }
        isTelemetryLoading = true
        defer { isTelemetryLoading = false }
        let next = await LocalObservabilityClient().load()
        telemetry = next
        guard next.collectorReachable else { return }
        do {
            telemetryHistory = try await snapshotStore.append(next)
        } catch {
            lastError = "Telemetry was measured but could not be retained: \(error.localizedDescription)"
        }
    }

    func refreshUsage(force: Bool = false) async {
        let request = UUID()
        usageGeneration = request
        isUsageLoading = true
        isDevinLoading = true
        let devinTask = Task {
            do { return try await DevinUsageClient().load() }
            catch { return DevinUsage.unavailable(message: error.localizedDescription) }
        }
        do {
            let report = try await CCUsageClient().loadUsage(refresh: force)
            guard usageGeneration == request else { return }
            usageReport = usageReport?.devin.map { report.withDevin($0) } ?? report
            usageError = report.error?.message
            if let usageModel, !report.models(for: usageService, range: usageRange).contains(usageModel) {
                self.usageModel = nil
            }
        } catch {
            guard usageGeneration == request else { return }
            usageError = error.localizedDescription
            // A transport failure must not discard the last valid local view.
            if usageReport == nil { usageReport = .unavailable(message: error.localizedDescription) }
        }
        isUsageLoading = false
        let devin = await devinTask.value
        guard usageGeneration == request else { return }
        if let usageReport { self.usageReport = usageReport.withDevin(devin) }
        isDevinLoading = false
    }

    func refreshSkillActivity() async {
        guard !isSkillActivityLoading else { return }
        isSkillActivityLoading = true
        let snapshot = await Task.detached(priority: .utility) { SkillActivityHistory().scan() }.value
        skillActivity = snapshot
        isSkillActivityLoading = false
        try? await skillActivityStore.save(snapshot)
        await refreshConfigurationHealth()
    }

    func refreshQuota() async {
        let service = usageService
        guard service.quotaKey != nil else { return }
        isQuotaLoading = true
        quotaError = nil
        defer { isQuotaLoading = false }
        do {
            let receipt = try await ProviderQuotaClient().loadQuota(for: service)
            quotaReceipt = receipt
            if let key = service.quotaKey { quotaReceipts[key] = receipt; quotaErrors[key] = nil }
        } catch {
            quotaError = error.localizedDescription
            if let key = service.quotaKey { quotaErrors[key] = error.localizedDescription }
        }
    }

    /// Only called by the explicit Usage-page button; this may contact both providers.
    func refreshAllQuotas() async {
        guard !isQuotaLoading else { return }
        lastAllowanceCheckAttempt = Date()
        UserDefaults.standard.set(lastAllowanceCheckAttempt, forKey: "contextDaddyLastAllowanceCheckAttempt")
        isQuotaLoading = true
        defer { isQuotaLoading = false }
        for service in [UsageService.codex, .claude] {
            guard let key = service.quotaKey else { continue }
            do {
                quotaReceipts[key] = try await ProviderQuotaClient().loadQuota(for: service)
                quotaErrors[key] = nil
            } catch {
                quotaErrors[key] = error.localizedDescription
            }
        }
    }

    func autoRefreshQuotasIfNeeded(now: Date = Date()) async {
        guard AllowanceAutoCheckPolicy.shouldCheck(enabled: autoCheckAllowance,
                                                  lastAttempt: lastAllowanceCheckAttempt, now: now),
              !isQuotaLoading else { return }
        await refreshAllQuotas()
    }

    func addExtraRoots(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            if !extraRoots.contains(path) { extraRoots.append(path) }
        }
    }

    func removeExtraRoot(_ path: String) {
        extraRoots.removeAll { $0 == path }
    }
}
