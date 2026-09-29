import AppKit
import ContextCore
import SwiftUI

struct SkillCleanupWorkbench: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var manager = SkillLibraryManager()
    @State private var assessment: SkillCleanupAssessment?
    @State private var context: SkillFolderContext?
    @State private var folder: String?
    @State private var category = SkillCleanupCategory.decision
    @State private var page = 0
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var worker: Task<Void, Never>?
    @State private var scanDeadline: Task<Void, Never>?
    @State private var scanStarted = Date()
    @State private var selected: SkillCleanupRecommendation?
    @State private var batch: CleanupBatch?
    @State private var historyOpen = false
    @State private var kept = Set(UserDefaults.standard.stringArray(forKey: "skillCleanupKeptDecisions") ?? [])
    @State private var showKept = false
    @State private var showContext = false
    @State private var folderSearch = ""
    @AppStorage("skillWorkingFolder") private var savedFolder = ""

    init(initialAssessment: SkillCleanupAssessment? = nil, initialContext: SkillFolderContext? = nil) {
        _assessment = State(initialValue: initialAssessment)
        _context = State(initialValue: initialContext)
        _folder = State(initialValue: initialContext?.path)
    }

    private var recommendations: [SkillCleanupRecommendation] {
        (assessment?.recommendations ?? []).filter {
            $0.category == category && (showKept ? kept.contains($0.decisionKey) : !kept.contains($0.decisionKey))
        }
    }
    private var ready: [SkillChangePlan] {
        (assessment?.recommendations ?? []).filter { $0.category == .ready && !kept.contains($0.decisionKey) }.flatMap(\.plans)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    scope
                    if busy {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking sources and preparing recommendations…")
                                Button("Cancel scan") { stopScan(message: "Scan cancelled. Choose another folder or retry.") }
                            }
                            TimelineView(.periodic(from: scanStarted, by: 1)) { timeline in
                                Text("\(Int(timeline.date.timeIntervalSince(scanStarted))) seconds · Slow or unavailable folders can delay discovery. This scan stops waiting after 30 seconds.")
                                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                            }
                        }
                    } else if assessment == nil && model.isLoading {
                        Text("Discovering projects… You can choose a folder now.").foregroundStyle(DaddyTheme.muted)
                    }
                    if let error {
                        Text(error).foregroundStyle(DaddyTheme.coral).textSelection(.enabled)
                        Button("Retry scan") { assess() }
                    }
                    if let assessment {
                        if (context?.coverage ?? model.catalog?.coverage)?.isPartial == true {
                            Text("Partial discovery · totals may be incomplete. Review coverage before treating this as a full inventory.").font(.caption).foregroundStyle(DaddyTheme.amber)
                        }
                        if let context {
                            DisclosureGroup("Compare agents in this folder", isExpanded: $showContext) { folderSummary(context) }
                        }
                        planHeader
                        if recommendations.isEmpty {
                            Panel {
                                Text(showKept ? "No kept decisions in this section." : category == .ready
                                     ? "No verified consolidations in this scope. Review overlapping workflows and global links under Needs a decision."
                                     : "No recommendations in this section for the current scope.")
                                    .foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(Array(recommendations.dropFirst(page * 6).prefix(6))) { recommendation in
                            recommendationRow(recommendation)
                        }
                        ContextPagination(page: $page, total: recommendations.count, pageSize: 6, noun: "recommendations")
                        DisclosureGroup("Inventory counts and scan coverage") {
                            totals(assessment)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Names group installations with the same declared name; they do not prove equivalent capabilities. Physical sources and agent routes are different counts.")
                                Text("\(assessment.cacheCount) installer-managed definitions and \(assessment.archiveCount) archived definitions are outside the local-library total. They remain on disk. Plugin activation is unverified.")
                                Text("Missing usage telemetry never proves a skill is unused.")
                                if let coverage = context?.coverage ?? model.catalog?.coverage {
                                    Text("\(coverage.unreadableCount) unreadable locations · \(coverage.skippedLinks) skipped links")
                                    ForEach(Array(coverage.notes.enumerated()), id: \.offset) { _, note in
                                        Text(note).textSelection(.enabled)
                                    }
                                }
                                Text("Discovery: \((context?.coverage ?? model.catalog?.coverage)?.isPartial == true ? "partial coverage; some locations may be missing" : "bounded scan"). Folder counts describe discovered access, not a live agent session.")
                            }.font(.callout).foregroundStyle(DaddyTheme.muted)
                        }
                    } else if !busy {
                        Text("Scan the library or choose a folder to prepare a cleanup plan.").foregroundStyle(DaddyTheme.muted)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .onChange(of: model.catalog?.generatedAt, initial: true) { _, _ in if folder == nil && model.catalog != nil { assess() } }
        .onAppear {
            if folder == nil, !savedFolder.isEmpty { selectFolder(savedFolder) }
        }
        .onChange(of: folder) { _, value in savedFolder = value ?? "" }
        .onChange(of: category) { _, _ in page = 0 }
        .onChange(of: showKept) { _, _ in page = 0 }
        .onDisappear { worker?.cancel(); scanDeadline?.cancel() }
        .sheet(item: $selected) { recommendation in
            SkillCleanupDecisionSheet(recommendation: recommendation, manager: manager,
                keep: {
                    kept.insert(recommendation.decisionKey); saveKept(); selected = nil
                }, completed: { await reloadAfterChange() })
        }
        .sheet(item: $batch) { batch in
            SkillCleanupApplySheet(batch: batch, manager: manager, completed: { await reloadAfterChange() })
        }
        .sheet(isPresented: $historyOpen) { SkillCleanupHistorySheet(manager: manager, completed: { await reloadAfterChange() }) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SKILLS").font(.caption.weight(.bold)).tracking(2).foregroundStyle(DaddyTheme.mint)
            Text("Keep the skills you need").font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("Choose where you work. Review what changes. Keep control of every source.").foregroundStyle(DaddyTheme.muted)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Browse all skills") { model.skillsMode = .library }
        Button("History & restore") { historyOpen = true }
        Button("Refresh plan") {
            if folder != nil { assess() }
            else { Task { await model.refreshSkillLibrary() } }
        }.disabled(busy || model.isLoading)
    }

    private var scope: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(folder == nil ? "Where are you working?" : "Working folder").font(.headline)
                if let folder { Text(short(folder)).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                TextField("Search a project or paste a folder path", text: $folderSearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { openTypedFolder() }
                if !folderSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(Array(model.projects.filter { $0.path.localizedCaseInsensitiveContains(folderSearch) }.prefix(5))) { project in
                        Button { selectFolder(project.path) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name).font(.callout.weight(.semibold))
                                Text(short(project.path)).font(.caption).foregroundStyle(DaddyTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if folderSearch.hasPrefix("/") || folderSearch.hasPrefix("~") {
                        Button("Use this folder", action: openTypedFolder)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { folderButtons }
                    VStack(alignment: .leading) { folderButtons }
                }
                Text(folder == nil ? "Showing cleanup across your local library. Select a folder to see what each agent can discover there." : "Includes global and inherited skills. Other projects and plugin caches are excluded.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            }
        }
    }

    @ViewBuilder private var folderButtons: some View {
        Button("Choose folder…") {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.message = "Choose the folder where you run your agent"
            if panel.runModal() == .OK, let url = panel.url { selectFolder(url.path) }
        }
        Menu("Quick targets") {
            ForEach(Array(model.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(12))) { project in
                Button("\(project.name) · \(short(project.path))") { selectFolder(project.path) }
            }
            if model.projects.isEmpty { Text("Choose a folder to get started") }
        }
        if folder != nil { Button("Whole library") { folder = nil; context = nil; model.skillFolderContext = nil; assess() } }
    }

    private func selectFolder(_ path: String) {
        folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        folderSearch = ""
        assess()
    }

    private func openTypedFolder() {
        let path = (folderSearch.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return }
        selectFolder(path)
    }

    private func totals(_ assessment: SkillCleanupAssessment) -> some View {
        Panel(padding: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 32) { totalLabels(assessment) }
                VStack(alignment: .leading, spacing: 12) { totalLabels(assessment) }
            }
        }
    }

    @ViewBuilder private func totalLabels(_ assessment: SkillCleanupAssessment) -> some View {
        VStack(alignment: .leading) {
            Text("\(assessment.localNames)").font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(DaddyTheme.mint)
            Text("local skill names").font(.callout)
        }
        VStack(alignment: .leading) {
            Text("\(assessment.localRecords.count) → \(max(0, assessment.localRecords.count - ready.count))").font(.title2.weight(.semibold))
            Text("physical sources after verified consolidation").font(.caption).foregroundStyle(DaddyTheme.muted)
        }
        VStack(alignment: .leading) {
            Text("\(ready.count) ready").font(.title2.weight(.semibold))
            Text("Names and agent routes stay the same.").font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private func folderSummary(_ context: SkillFolderContext) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("What each agent can discover here").font(.title3.weight(.semibold))
                Text(context.coverage.isPartial ? "Partial discovery · counts may be incomplete" : "Bounded discovery · live activation unverified")
                    .font(.caption).foregroundStyle(DaddyTheme.amber)
                ForEach(context.agents) { agent in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(agent.globalCount) sources with global access · \(agent.projectCount) additional project sources")
                            Text("Automatic means policy permits invocation; it does not mean the skill is loaded on every turn.")
                            if agent.runtime == .devin || agent.runtime == .grok {
                                Text("Local route evidence only. Runtime discovery and activation are not verified.").foregroundStyle(DaddyTheme.amber)
                            }
                            ForEach(agent.records.prefix(12)) { record in
                                Text("\(record.name) · \(record.policy(for: agent.runtime)?.mode.rawValue ?? "Unknown")").font(.caption)
                            }
                            if agent.records.count > 12 { Text("\(agent.records.count - 12) more sources; use the library for full inspection.").font(.caption) }
                        }.foregroundStyle(DaddyTheme.muted)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 20) { agentLabel(agent).frame(minWidth: 230, alignment: .leading); agentCounts(agent) }
                            VStack(alignment: .leading, spacing: 5) { agentLabel(agent); agentCounts(agent) }
                        }
                    }
                }
                Text("Plugin activation is not included. Different definitions with one name remain visible as additional sources.")
                    .font(.caption).foregroundStyle(DaddyTheme.amber)
            }
        }
    }

    private func agentLabel(_ agent: SkillFolderAgent) -> some View {
        Text("\(agent.runtime.rawValue) · \(agent.names) names / \(agent.records.count) sources").font(.callout.weight(.semibold))
    }
    private func agentCounts(_ agent: SkillFolderAgent) -> some View {
        Text("\(agent.summary.automaticCount) auto · \(agent.summary.manualOnlyCount) manual · \(agent.summary.modelOnlyCount) model-only · \(agent.summary.disabledCount) disabled · \(agent.summary.reviewCount) review")
            .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proposed cleanup").font(.title2.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack { planControls }
                VStack(alignment: .leading) { planControls }
            }
        }
    }
    @ViewBuilder private var planControls: some View {
        Picker("Review", selection: $category) {
            ForEach(SkillCleanupCategory.allCases, id: \.self) { category in
                Text("\(category.rawValue) (\((assessment?.recommendations ?? []).filter { $0.category == category && !kept.contains($0.decisionKey) }.count))").tag(category)
            }
        }.fixedSize()
        Toggle("Kept decisions", isOn: $showKept).toggleStyle(.checkbox)
        Button("Preview \(ready.count) verified changes") {
            batch = CleanupBatch(title: "Consolidate verified copies", plans: ready,
                impact: "\(assessment?.localRecords.count ?? 0) → \(max(0, (assessment?.localRecords.count ?? 0) - ready.count)) local physical sources. Skill names and existing agent routes remain unchanged.")
        }.disabled(ready.isEmpty || busy)
    }

    private func recommendationRow(_ recommendation: SkillCleanupRecommendation) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(recommendation.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(recommendation.reason).font(.callout).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                Text("\(recommendation.records.count) sources · \(recommendation.agents.isEmpty ? "Activation unverified" : recommendation.agents)")
                    .font(.caption).foregroundStyle(DaddyTheme.mint)
                if let canonical = recommendation.canonicalID {
                    Text("Keep source: \(short(canonical))").font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text("Invocation: \(invocationSummary(for: recommendation))")
                    .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(recommendation.action == .managed ? "Inspect plugin ownership" : (recommendation.action == .consolidate ? "Preview consolidation" : recommendation.action == .scope ? "Review access change" : "Compare sources")) { selected = recommendation }
                    if showKept { Button("Reopen decision") { kept.remove(recommendation.decisionKey); saveKept() } }
                }
            }
        }
    }

    private func saveKept() { UserDefaults.standard.set(Array(kept).sorted(), forKey: "skillCleanupKeptDecisions"); page = 0 }
    private func short(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }

    private func invocationSummary(for recommendation: SkillCleanupRecommendation) -> String {
        var labels = Set<String>()
        for record in recommendation.records {
            let exposed = Set(record.exposedRuntimes)
            for policy in record.policies where exposed.contains(policy.runtime) {
                labels.insert(policy.runtime.rawValue + " · " + policy.mode.rawValue)
            }
        }
        return labels.sorted().joined(separator: "; ")
    }

    private func stopScan(message: String) {
        generation = UUID()
        worker?.cancel(); scanDeadline?.cancel()
        busy = false; error = message
    }

    private func assess() {
        worker?.cancel(); scanDeadline?.cancel(); let token = UUID(); generation = token
        scanStarted = Date()
        let selectedFolder = folder, catalog = model.catalog, manager = manager
        busy = true; error = nil; page = 0; assessment = nil; context = nil
        scanDeadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard generation == token, busy else { return }
            stopScan(message: "Discovery is taking too long. A local or linked folder may be unavailable or waiting for macOS access. No skills were changed. Retry after checking access, or choose another folder.")
        }
        worker = Task {
            do {
                var scoped: SkillFolderContext?
                if let selectedFolder {
                    let scan = Task.detached(priority: .userInitiated) {
                        let url = URL(fileURLWithPath: selectedFolder)
                        return SkillFolderContext.resolve(report: try AIContextDiscovery.discoverFolder(url), directory: url)
                    }
                    scoped = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                }
                let result = await SkillCleanupPlanner.assess(records: scoped?.records ?? catalog?.records ?? [], manager: manager)
                guard !Task.isCancelled, generation == token else { return }
                context = scoped; model.skillFolderContext = scoped; assessment = result
                category = result.readyPlans.isEmpty ? .decision : .ready
                busy = false; scanDeadline?.cancel()
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription; busy = false; scanDeadline?.cancel()
            }
        }
    }

    private func reloadAfterChange() async {
        if folder != nil { assess() }
        else { assessment = nil }
        // A completed mutation must not trap the user in its sheet while unrelated
        // directories are rescanned. Scoped results refresh independently.
        Task { await model.refreshSkillLibrary() }
    }
}

struct CleanupBatch: Identifiable {
    let id = UUID()
    let title: String
    let plans: [SkillChangePlan]
    let impact: String
}

struct SkillCleanupApplySheet: View {
    @Environment(\.dismiss) private var dismiss
    let batch: CleanupBatch
    let manager: SkillLibraryManager
    let completed: () async -> Void
    @State private var selected = Set<UUID>()
    @State private var working = false
    @State private var result: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(batch.title).font(.title2.weight(.semibold))
            Text(batch.impact).foregroundStyle(DaddyTheme.mint)
            Text("Projection assumes every listed change is selected. Apply stops on the first failure. Every completed change can be reviewed in History.")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(batch.plans) { plan in
                        Panel(padding: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(plan.title, isOn: Binding(get: { selected.contains(plan.id) }, set: { if $0 { selected.insert(plan.id) } else { selected.remove(plan.id) } }))
                                Text(plan.detail).font(.callout).foregroundStyle(DaddyTheme.muted)
                                ForEach(plan.fileChanges, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                DisclosureGroup("Before and after") { Text("BEFORE\n\(plan.before)\n\nAFTER\n\(plan.after)").font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                    }
                }.disabled(working || result != nil)
            }
            if let result { Text(result).textSelection(.enabled) }
            HStack {
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                else if result == nil {
                    Button("Apply \(selected.count) changes") {
                        working = true
                        Task {
                            var count = 0
                            do {
                                for plan in batch.plans where selected.contains(plan.id) { _ = try await manager.apply(plan.id); count += 1 }
                                result = "Applied \(count) changes. Recovery is available in History."
                            } catch { result = "Applied \(count) changes, then stopped: \(error.localizedDescription) Check History before trying again." }
                            await completed(); working = false
                        }
                    }.disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 760, height: 660).background(DaddyTheme.canvas)
            .interactiveDismissDisabled(working).onAppear { selected = Set(batch.plans.map(\.id)) }
    }
}

struct SkillCleanupDecisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recommendation: SkillCleanupRecommendation
    let manager: SkillLibraryManager
    let keep: () -> Void
    let completed: () async -> Void
    @State private var chosen = ""
    @State private var document: String?
    @State private var batch: CleanupBatch?
    @State private var error: String?
    @State private var working = false
    @State private var refreshedAfterApply = false
    private var selectedRecord: SkillRecord? { recommendation.records.first { $0.id == chosen } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(recommendation.title).font(.title2.weight(.semibold))
            Text(recommendation.reason).foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(recommendation.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.name).font(.headline)
                            Text(record.description).font(.callout)
                            Text(record.id).font(.caption.monospaced()).textSelection(.enabled)
                            DisclosureGroup("\(record.exposures.count) agent routes") {
                                ForEach(record.exposures) { exposure in
                                    Text("\(exposure.provider.rawValue) · \(exposure.scope.rawValue) · \(exposure.logicalPath)")
                                        .font(.caption.monospaced()).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if recommendation.action == .managed {
                        Text("No cache files are modified here. These paths identify the plugin and version; open the owning agent’s plugin manager to verify activation and uninstall an obsolete installation.")
                            .foregroundStyle(DaddyTheme.amber)
                    }
                    Picker("Inspect source", selection: $chosen) {
                        Text("Choose a source…").tag("")
                        ForEach(recommendation.records) { Text($0.id).tag($0.id) }
                    }
                    Button("Read selected instructions") {
                        guard let selectedRecord else { return }
                        do {
                            let preview = try SkillDocumentReader.read(url: URL(fileURLWithPath: selectedRecord.id))
                            document = preview.text
                            if preview.truncated { self.error = "Preview truncated to 256 KiB. Read the complete source before archiving." }
                        }
                        catch { self.error = error.localizedDescription }
                    }.disabled(selectedRecord == nil)
                    if let document { Text(document).font(.caption.monospaced()).textSelection(.enabled) }
                    if recommendation.action == .compare, let selectedRecord, selectedRecord.ownership == .local {
                        Text("Selected source affects: \(selectedRecord.exposedRuntimes.map(\.rawValue).joined(separator: ", ")). \(selectedRecord.exposures.count) discovered routes.")
                            .font(.callout.weight(.semibold))
                        Text("Archiving removes this source from every agent route pointing to it. Other versions remain. Only proceed after deciding this workflow is redundant.")
                            .font(.callout).foregroundStyle(DaddyTheme.amber)
                        Button("Preview archive of selected source") {
                            prepare {
                                let plan = try await manager.prepareArchive(skill: URL(fileURLWithPath: selectedRecord.id))
                                return CleanupBatch(title: "Archive \(selectedRecord.name)", plans: [plan],
                                    impact: "Physical sources: \(recommendation.records.count) → \(recommendation.records.count - 1) in this group. \(selectedRecord.exposures.count) discovered routes lose this source. This may affect other folders too.")
                            }
                        }
                    }
                    if recommendation.action == .scope {
                        Text("Global links to remove:\n" + recommendation.globalLinks.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Preview project-only access") {
                            prepare {
                                var plans: [SkillChangePlan] = []
                                for path in recommendation.globalLinks { plans.append(try await manager.prepareUnlink(path: URL(fileURLWithPath: path))) }
                                return CleanupBatch(title: "Narrow global access", plans: plans,
                                    impact: "Selected global links: \(plans.count) → 0. Physical sources unchanged. Existing project routes remain; other folders lose these global routes.")
                            }
                        }
                    }
                    if !recommendation.plans.isEmpty {
                        Button("Preview verified consolidation") {
                            batch = CleanupBatch(title: "Share one source", plans: recommendation.plans,
                                impact: "Physical copies in this group: \(recommendation.records.count) → \(recommendation.records.count - recommendation.plans.count). Existing agent routes remain.")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).disabled(working || refreshedAfterApply)
            }
            if let error { Text(error).foregroundStyle(DaddyTheme.coral) }
            if refreshedAfterApply { Text("The plan has been refreshed. Close this review to see the current recommendations.").foregroundStyle(DaddyTheme.mint) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Keep as-is") { keep() }.disabled(working || refreshedAfterApply)
            }
            Text("Keep as-is records a review decision; it does not remove or disable skills. Reopen it under Kept decisions.").font(.caption).foregroundStyle(DaddyTheme.muted)
        }.padding(24).frame(width: 760, height: 660).background(DaddyTheme.canvas)
            .interactiveDismissDisabled(working)
            .sheet(item: $batch) { value in SkillCleanupApplySheet(batch: value, manager: manager, completed: { await completed(); refreshedAfterApply = true }) }
            .onChange(of: chosen) { _, _ in document = nil }
    }
    private func prepare(_ operation: @escaping () async throws -> CleanupBatch) {
        working = true; error = nil
        Task { defer { working = false }; do { batch = try await operation() } catch { self.error = error.localizedDescription } }
    }
}

struct SkillCleanupHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let manager: SkillLibraryManager
    let completed: () async -> Void
    @State private var receipts: [SkillChangeReceipt] = []
    @State private var error: String?
    @State private var busy = false
    private func short(_ path: String) -> String { path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanup history").font(.title2.weight(.semibold))
            Text("Restore protects newer work. Changes are recorded individually, including partial failures.").foregroundStyle(DaddyTheme.muted)
            if let error { Text(error).foregroundStyle(DaddyTheme.coral) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if receipts.isEmpty { Text("No changes recorded yet.") }
                    ForEach(receipts, id: \.id) { receipt in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(receipt.title).font(.headline)
                            Text(short(receipt.destination)).font(.caption.monospaced()).textSelection(.enabled)
                            Text(receipt.restored ? "Restored" : receipt.completed ? "Applied" : "Incomplete · inspect recovery location").font(.caption)
                            if receipt.completed && !receipt.restored {
                                Button("Restore this change") {
                                    busy = true
                                    Task {
                                        defer { busy = false }
                                        do { try await manager.restore(receipt.id); receipts = try await manager.history(); await completed() }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }.disabled(busy)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
        }.padding(24).frame(width: 700, height: 580).background(DaddyTheme.canvas)
        .task { do { receipts = try await manager.history() } catch { self.error = error.localizedDescription } }
        .interactiveDismissDisabled(busy)
    }

}
