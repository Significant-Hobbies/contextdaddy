import AppKit
import ContextCore
import SwiftUI

struct SkillLibraryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("skillLibrarySearch") private var query = ""
    @State private var checked = Set<String>()
    @State private var mapSkillIDs: Set<String>?
    @State private var mapLocation: String?
    @State private var locationsExpanded = false
    @State private var invocationFilter: InvocationMode?
    @State private var scopeFilter: AIContextScope?
    @State private var sortField: SkillSortField = .name
    @State private var ascending = true
    @State private var organizationAction: SkillOrganizationAction?
    @State private var organizationRecords: [SkillRecord] = []
    @State private var duplicateCounts: [String: Int] = [:]
    @State private var indexedRecords: [SkillRecord] = []
    private var selectedRecords: [SkillRecord] { records.filter { checked.contains($0.id) } }

    @AppStorage("skillLibraryGuideCompleted") private var guideCompleted = false
    @State private var guideOpen = false
    @State private var guideStep = 0
    @FocusState private var searchFocused: Bool
    private var showsGuide: Bool { guideOpen }
    @State private var ownership: SkillOwnership? = .local
    @State private var agent: AgentRuntime?
    @State private var location: String?
    @State private var selectedID: String?
    @State private var page = 0
    @State private var tab = "Overview"
    @State private var favorites = Set(UserDefaults.standard.stringArray(forKey: "skillLibraryFavorites") ?? [])
    @State private var favoriteOnly = false
    @State private var tags = UserDefaults.standard.dictionary(forKey: "skillLibraryTags") as? [String: String] ?? [:]
    @State private var document: String?
    @State private var plan: SkillChangePlan?
    @State private var error: String?
    @State private var notice: String?
    @State private var working = false
    @State private var filtersOpen = false
    @State private var folderLoading = false
    @State private var folderRevision = 0
    @AppStorage("skillWorkingFolder") private var workingFolder = ""
    @State private var editor = false
    @State private var draft = ""
    @State private var showCreate = false
    @State private var sharingSkill: SkillRecord?
    @State private var showLocations = false
    @State private var showHistory = false
    @State private var receipts: [SkillChangeReceipt] = []
    @State private var restoreReceipt: SkillChangeReceipt?
    @State private var manager = SkillLibraryManager()
    @State private var externalSources: [String: ExternalSkillSourceEvidence] = [:]
    @State private var checkingSourceID: String?
    @State private var sourceAudit: ExternalSkillSourceAudit?
    @State private var sourceAuditLoading = false
    @State private var unresolvedSourcesOnly = false

    private var records: [SkillRecord] { workingFolder.isEmpty ? model.catalog?.records ?? [] : model.skillFolderContext?.records ?? [] }
    private var results: [SkillRecord] { indexedRecords }
    private var ownedRecords: [SkillRecord] {
        records.filter { (ownership == nil || $0.ownership == ownership) && (ownership != .local || !SkillCleanupPlanner.isArchived($0)) }
    }

    private func rebuildIndex() {
        let base = SkillLibraryIndex.matching(ownedRecords, query: "", ownership: ownership, runtime: invocationFilter == .unsupported || invocationFilter == .unverified ? nil : agent, location: location)
            .filter { !favoriteOnly || favorites.contains($0.id) }
            .filter { !unresolvedSourcesOnly || externalSources[$0.id]?.kind == .unresolved }
            .filter { mapSkillIDs?.contains($0.id) ?? true }
        let matchingIDs = Set(SkillLibraryIndex.matching(base, query: query).map(\.id))
        let matching = query.isEmpty ? base : base.filter { matchingIDs.contains($0.id) || tags[$0.id, default: ""].localizedCaseInsensitiveContains(query) }
        indexedRecords = SkillOrganizationIndex.matching(matching, runtime: agent, invocation: invocationFilter, scope: scopeFilter,
                                              sort: sortField, ascending: ascending, duplicateCounts: duplicateCounts)
    }
    private var selection: SkillRecord? { results.first { $0.id == selectedID } ?? visible.first }
    private var pageCount: Int { max(1, (results.count + 7) / 8) }
    private var visible: [SkillRecord] { Array(results.dropFirst(min(page, pageCount - 1) * 8).prefix(8)) }

    var body: some View { libraryDialogs }

    private var libraryLayout: some View {
        GeometryReader { geometry in
            // Legacy scrollers reserve layout space; overlay scrollers do not.
            let scrollbarWidth = NSScroller.preferredScrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            let contentWidth = max(0, geometry.size.width - scrollbarWidth)
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    folderControl
                    if folderLoading { ProgressView("Reading this folder…") }
                    else {
                        inventoryAnswers
                        sourceAuditSummary
                        DisclosureGroup("Where these skills come from", isExpanded: $locationsExpanded) {
                        SkillLocationMapView(records: ownedRecords) { path, ids in
                            query = ""; agent = nil; location = nil
                            scopeFilter = nil; invocationFilter = nil; favoriteOnly = false
                            mapSkillIDs = ids; mapLocation = path
                            resetPage()
                            scroll.scrollTo("skill-search", anchor: .top)
                        } onReviewCopies: { ids in
                            checked = ids
                            openOrganization(.cleanup)
                        }
                        }.font(.callout)
                    }
                    if showsGuide && contentWidth >= 1180 {
                        HStack(alignment: .top, spacing: 20) {
                            workspace(width: contentWidth - 344, scroll: scroll)
                            guide(scroll: scroll).frame(width: 280)
                        }
                    } else {
                        if showsGuide { guide(scroll: scroll) }
                        workspace(width: contentWidth - 44, scroll: scroll)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onChange(of: selectedID) { _, value in
                if value != nil && contentWidth < 1000 {
                    if showsGuide && guideStep == 0 { guideStep = 1 }
                    scroll.scrollTo("skill-inspector", anchor: .top)
                }
            }
            }
        }
    }

    private var libraryLifecycle: some View {
        libraryLayout
        .onAppear {
            if let requested = model.pendingSkillRuntime {
                if model.pendingSkillAllFolders { workingFolder = ""; model.skillFolderContext = nil }
                model.pendingSkillAllFolders = false
                query = ""; ownership = .local; location = nil; scopeFilter = nil; invocationFilter = model.pendingSkillInvocation
                model.pendingSkillInvocation = nil
                favoriteOnly = false; mapSkillIDs = nil; mapLocation = nil; agent = requested; filtersOpen = true
                model.pendingSkillRuntime = nil
                resetPage()
            }
        }
        .task(id: workingFolder + "#" + String(folderRevision)) {
            folderLoading = true
            await model.loadSkillFolder(workingFolder)
            folderLoading = false
            if let failure = model.skillFolderError { error = failure }
        }

        .sheet(item: $organizationAction) { action in
            SkillOrganizationSheet(action: action, records: organizationRecords, manager: manager) {
                checked.removeAll()
                await refreshLibrary()
            }
        }
    }

    private var libraryIndexUpdates: some View {
        libraryLifecycle
        .onChange(of: agent) { _, value in if let value { model.selectedTelemetryRuntime = value } }
        .onChange(of: records, initial: true) { _, _ in
            sourceAudit = nil
            externalSources.removeAll()
            unresolvedSourcesOnly = false
            var counts: [String: Int] = [:]
            for group in Dictionary(grouping: records.filter { $0.contentFingerprint != nil }, by: { $0.contentFingerprint! }).values {
                for record in group { counts[record.id] = group.count }
            }
            duplicateCounts = counts
            checked.formIntersection(Set(records.map(\.id)))
            mapSkillIDs = nil; mapLocation = nil
            resetPage()
        }
        .onChange(of: favorites) { _, _ in rebuildIndex() }
        .onChange(of: tags) { _, _ in rebuildIndex() }
        .onChange(of: invocationFilter) { _, _ in resetPage() }
        .onChange(of: scopeFilter) { _, _ in resetPage() }
        .onChange(of: sortField) { _, _ in resetPage() }
        .onChange(of: ascending) { _, _ in resetPage() }
        .onChange(of: query) { _, _ in resetPage() }
        .onChange(of: ownership) { _, _ in resetPage() }
        .onChange(of: agent) { _, _ in resetPage() }
        .onChange(of: location) { _, _ in resetPage() }
        .onChange(of: favoriteOnly) { _, _ in resetPage() }
        .onChange(of: unresolvedSourcesOnly) { _, _ in resetPage() }
        .onChange(of: selection?.id) { _, _ in document = nil; tab = "Overview" }
    }

    private var libraryDialogs: some View {
        libraryIndexUpdates
        .sheet(item: $plan) { pending in changePreview(pending) }
        .sheet(isPresented: $editor) { contentEditor }
        .sheet(item: $sharingSkill) { skill in
            SkillShareSheet(skill: skill) { parent, project in
                sharingSkill = nil
                if let project, !model.extraRoots.contains(project.path) { model.extraRoots.append(project.path) }
                rememberLocation(parent)
                perform { try await manager.prepareLink(skill: URL(fileURLWithPath: skill.id), parent: parent) }
            }
        }
        .sheet(isPresented: $showCreate) {
            SkillCreateSheet { parent, name, text in
                showCreate = false
                rememberLocation(parent)
                perform { try await manager.prepareCreate(parent: parent, name: name, text: text) }
            }
        }
        .sheet(isPresented: $showLocations) { locationsSheet }
        .sheet(isPresented: $showHistory) { SkillCleanupHistorySheet(manager: manager, completed: { await refreshLibrary() }) }
        .confirmationDialog("Restore this change? Newer edits are protected; the current version is retained in recovery storage.", isPresented: Binding(get: { restoreReceipt != nil }, set: { if !$0 { restoreReceipt = nil } })) {
            Button("Restore change") {
                guard let receipt = restoreReceipt else { return }
                restoreReceipt = nil
                Task {
                    do { try await manager.restore(receipt.id); receipts = try await manager.history(); await refreshLibrary(); notice = "Change restored." }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func workspace(width availableWidth: CGFloat, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
                    filters
                    if let notice { Text(notice).font(.callout).foregroundStyle(DaddyTheme.mint).textSelection(.enabled) }
                    if let error { Text(error).font(.callout).foregroundStyle(DaddyTheme.coral).textSelection(.enabled) }
                    if model.lastError != nil { Text("Scan needs attention. Showing the last available library.").foregroundStyle(DaddyTheme.amber) }
                    if results.isEmpty {
                        ContentUnavailableView(model.isLoading ? "Scanning skill locations…" : "No matching skills", systemImage: "books.vertical",
                            description: Text(records.isEmpty ? "Add a skill folder or search location to begin." : "Try another search, agent, or ownership filter."))
                    } else {
                        if availableWidth >= 1000 {
                            HStack(alignment: .top, spacing: 18) {
                                organizationLedger(width: availableWidth - 378).id("skill-columns")
                                if let selection { inspector(selection, scroll: scroll).frame(width: 360).id("skill-inspector") }
                            }
                        } else {
                            organizationLedger(width: availableWidth).id("skill-columns")
                            if let selection { inspector(selection, scroll: scroll).id("skill-inspector") }
                        }
                        if !checked.isEmpty { changeTray }
                    }
                    if results.isEmpty && !checked.isEmpty { changeTray }
        }.frame(width: max(0, availableWidth), alignment: .leading)
    }

    private func guide(scroll: ScrollViewProxy) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("YOUR FIRST SKILL · \(guideStep + 1) OF 3")
                        .font(.caption2.weight(.bold)).foregroundStyle(DaddyTheme.mint)
                    Spacer()
                    Button("Skip") { guideCompleted = true; guideOpen = false }
                        .font(.caption).accessibilityLabel("Dismiss skill guide")
                }
                Text(["Find something you use", "See who can use it", "Know what you can change"][guideStep])
                    .font(.title3.weight(.semibold))
                Text([
                    "Search a name or topic, then select a skill. One definition can appear in several locations through links. Browsing changes nothing.",
                    "Open Access on the selected skill. It explains each agent’s discovery and invocation policy. An installed plugin is not necessarily enabled.",
                    "Local skills can be edited or shared after a preview. Linked locations use the same definition. Plugin-managed skills are changed through their installer. History keeps recovery records for changes made here."
                ][guideStep]).font(.callout).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                if guideStep == 0 {
                    Button("Find a skill") {
                        searchFocused = true
                        scroll.scrollTo("skill-search", anchor: .top)
                    }
                } else if guideStep == 1 {
                    Button("Show agent access") {
                        tab = "Access"
                        scroll.scrollTo(selection?.id, anchor: .top)
                    }.disabled(selection == nil)
                } else {
                    Button("Explore this skill") {
                        tab = "Overview"
                        guideCompleted = true; guideOpen = false
                        scroll.scrollTo(selection?.id, anchor: .top)
                    }.disabled(selection == nil)
                }
                HStack {
                    if guideStep > 0 { Button("Back") { guideStep -= 1 } }
                    Spacer()
                    Button(guideStep == 2 ? "Finish guide" : "Next") {
                        if guideStep == 2 { guideCompleted = true; guideOpen = false }
                        else { guideStep += 1 }
                    }
                }.font(.caption)
                Text("Reopen anytime with Guide.").font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
        }
        .id("skill-guide")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skill library guide")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("Skills").font(.title2.bold())
                Spacer()
                simpleActions
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Skills").font(.title2.bold())
                simpleActions
            }
        }
    }

    private var simpleActions: some View {
        HStack {
            Button("Clean up duplicates") { openOrganization(.cleanup) }
            Menu("More") {
                Button("Manage plugins…") { model.skillsMode = .plugins }
                Button("Create skill…") { showCreate = true }
                Button("Import skill…") { importFolder() }
                Button("Search locations…") { showLocations = true }
                Button("Review overlap and scope…") { model.skillsMode = .cleanup }
                Button("History & undo…") { Task { do { receipts = try await manager.history(); showHistory = true } catch { self.error = error.localizedDescription } } }
                Button("Refresh") { Task { await refreshLibrary() } }
                Button("Help") { guideOpen = true; guideStep = 0 }
            }
        }.disabled(working || folderLoading)
    }

    private var folderControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack { folderMenu; Text(workingFolder.isEmpty ? "All folders" : workingFolder).font(.caption.monospaced()).lineLimit(2) }
            VStack(alignment: .leading) { folderMenu; Text(workingFolder.isEmpty ? "All folders" : workingFolder).font(.caption.monospaced()).lineLimit(2) }
        }
    }

    private var folderMenu: some View {
        Menu("Folder") {
            Button("All folders") { workingFolder = "" }
            Button("Choose folder…") {
                if let folder = chooseFolder("Choose where you work") { workingFolder = folder.path }
            }
            ForEach(Array(model.projects.prefix(20))) { project in
                Button(project.name + " · " + project.path) { workingFolder = project.path }
            }
        }.fixedSize()
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { addSkillMenu; libraryActions }
            VStack(alignment: .leading, spacing: 8) { addSkillMenu; HStack { libraryActions } }
        }.buttonStyle(ContextDaddyButtonStyle()).disabled(working)
    }
    private var addSkillMenu: some View {
            Menu {
                Button("Create skill…") { showCreate = true }
                Button("Import local skill folder…") { importFolder() }
                Button("Add search location…") { addLocation() }
            } label: { Label("Add skill", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize().padding(9).background(DaddyTheme.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var libraryActions: some View {
            Button("Guide") { guideOpen = true; guideStep = 0 }.fixedSize()
            Button("Locations") { showLocations = true }.fixedSize()
            Button("History") { Task { do { receipts = try await manager.history(); showHistory = true } catch { self.error = error.localizedDescription } } }
    }
    private var navigation: some View {
        HStack {
                        Button(checked.isEmpty ? "Clean up duplicates" : "Clean up \(checked.count) selected") { openOrganization(.cleanup) }
        }.buttonStyle(ContextDaddyButtonStyle())
    }
    private var inventoryAnswers: some View {
        let answers = SkillInventoryAnswers(records: records)
        let coverage = model.skillFolderContext?.coverage ?? model.catalog?.coverage
        return VStack(alignment: .leading, spacing: 10) {
            if model.catalog == nil && model.skillFolderContext == nil {
                Text("Counting skills…").foregroundStyle(DaddyTheme.muted)
            } else {
                Text("\(answers.local.count) local definitions · \(answers.uniqueNames) unique names · \(answers.extraInstructionCopies) matching instruction \(answers.extraInstructionCopies == 1 ? "copy" : "copies")")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("\(answers.globalCount) available globally · \(answers.projectOnlyCount) project-only · \(answers.noAccessCount) with no known agent route")
                    .font(.callout).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(AgentRuntime.allCases) { runtime in
                        Button("\(runtime.rawValue): \(answers.count(for: runtime))") {
                            query = ""; location = nil; scopeFilter = nil; favoriteOnly = false
                            mapSkillIDs = nil; mapLocation = nil
                            ownership = .local
                            agent = runtime
                            invocationFilter = nil
                            filtersOpen = true
                        }.help("Show local definitions available to \(runtime.rawValue)")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { ownershipSummary(answers) }
                    VStack(alignment: .leading) { ownershipSummary(answers) }
                }
                if coverage?.isPartial == true {
                    Text("Partial scan · these are discovered counts, not a complete inventory.").font(.caption).foregroundStyle(DaddyTheme.amber)
                }
                DisclosureGroup("What these numbers mean") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Counts cover the selected folder, before search or filters. Agent counts overlap: one skill can be available to several agents.")
                        Text("\(answers.uniqueInstructions) distinct instruction contents verified; \(answers.unverifiedInstructions) definitions could not be compared. Matching instructions do not prove matching support files or interchangeable workflows.")
                        Text("\(answers.pluginCount) plugin definitions, \(answers.systemCount) system definitions and \(answers.archivedCount) archived definitions are excluded from local counts. They remain visible in the full list when in scope.")
                        Text("Unique names are case-insensitive names, not a semantic count of capabilities. Agent access is discovered evidence, not proof of loading in a live session.")
                    }.font(.caption).foregroundStyle(DaddyTheme.muted)
                }.font(.caption)
            }
        }
    }

    private var sourceAuditSummary: some View {
        let local = records.filter { $0.ownership == .local && !SkillCleanupPlanner.isArchived($0) }
        return Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Skill sources").font(.headline)
                    Spacer()
                    Button(sourceAuditLoading ? "Checking…" : "Audit sources") { auditSources() }
                        .disabled(sourceAuditLoading || local.isEmpty)
                }
                if sourceAuditLoading { ProgressView().controlSize(.small) }
                if let sourceAudit {
                    let values = local.compactMap { sourceAudit.byPath[$0.id] }
                    let tracked = values.filter { $0.kind == .github }.count
                    let repository = values.filter { $0.kind == .repository }.count
                    let unresolved = values.filter { $0.kind == .unresolved }.count
                    Text("\(tracked) tracked by Vercel skills · \(repository) in Git repositories · \(unresolved) source unresolved")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("Unresolved includes locally authored skills. It is a review queue, not a removal recommendation.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                    if !sourceAudit.unavailableTools.isEmpty {
                        Text("Inventory unavailable: \(sourceAudit.unavailableTools.joined(separator: ", ")). Counts are partial.")
                            .font(.caption).foregroundStyle(DaddyTheme.amber)
                    }
                    if unresolved > 0 {
                        Button(unresolvedSourcesOnly ? "Show all skills" : "Review unresolved sources") {
                            ownership = .local
                            unresolvedSourcesOnly.toggle()
                        }.font(.caption)
                    }
                    let pluginFiles = records.filter { $0.ownership == .plugin }.count
                    Text(pluginFiles > 0
                        ? "\(pluginFiles) plugin files have separate owners. This audit reads inventories; it does not update or remove skills."
                        : "Plugin files are outside this folder view. Manage their lifecycle in the owning agent. This audit does not update or remove skills.")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                } else {
                    Text("Use ASM and Vercel skills to identify where these skills came from. Local repositories are checked through Git.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                }
                HStack(spacing: 12) {
                    Link("ASM", destination: URL(string: "https://github.com/luongnv89/agent-skill-manager")!)
                    Link("Vercel skills", destination: URL(string: "https://github.com/vercel-labs/skills")!)
                }.font(.caption2)
            }
        }
    }

    private func auditSources() {
        let paths = records.filter { $0.ownership == .local && !SkillCleanupPlanner.isArchived($0) }.map(\.id)
        let selectedFolder = workingFolder
        let folder = URL(fileURLWithPath: selectedFolder.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path : workingFolder)
        sourceAuditLoading = true
        Task {
            let result = await ExternalSkillSources().audit(skillPaths: paths, folder: folder)
            guard workingFolder == selectedFolder,
                  Set(paths) == Set(records.filter { $0.ownership == .local && !SkillCleanupPlanner.isArchived($0) }.map(\.id)) else {
                sourceAuditLoading = false
                return
            }
            sourceAudit = result
            externalSources.merge(result.byPath) { _, new in new }
            sourceAuditLoading = false
            rebuildIndex()
        }
    }

    @ViewBuilder private func ownershipSummary(_ answers: SkillInventoryAnswers) -> some View {
        if ownership == .local {
            Text("Showing your local skills.").font(.caption).foregroundStyle(DaddyTheme.muted)
            if answers.pluginCount > 0 {
                Button("Manage plugins · \(answers.pluginCount) skill files") {
                    model.skillsMode = .plugins
                }.font(.caption)
            }
        } else {
            Button("Back to local skills") {
                ownership = .local; mapSkillIDs = nil; mapLocation = nil; query = ""; resetPage()
            }.font(.caption)
            Text("Installer-owned files are inspected here; their installer controls changes.").font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var summary: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { summaryFacts }
                    VStack(alignment: .leading, spacing: 6) { summaryFacts }
                }
                HStack {
                    Text(model.catalog?.coverage.isPartial == true ? "Some folders could not be fully scanned. Open Locations to see what is missing." : "Locations include links to the same skill. Installed plugins may not be enabled.")
                        .font(.caption).foregroundStyle(model.catalog?.coverage.isPartial == true ? DaddyTheme.amber : DaddyTheme.muted)
                    Spacer()
                    Button(model.isLoading ? "Scanning…" : "Rescan") { Task { await refreshLibrary() } }.disabled(model.isLoading)
                }
            }
        }
    }
    @ViewBuilder private var summaryFacts: some View {
        Text("\(records.count) skill definitions").fontWeight(.semibold)
        Text("\(records.reduce(0) { $0 + $1.exposures.count }) agent locations").foregroundStyle(DaddyTheme.muted)
        Text("\(records.filter { $0.ownership == .plugin }.count) installed by plugins").foregroundStyle(DaddyTheme.muted)
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mapLocation {
                Text("Sources from: " + (mapLocation as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced())
                Button("Show all locations") { mapSkillIDs = nil; self.mapLocation = nil; resetPage() }
            }
            HStack {
                TextField("Search skills", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search skill library").focused($searchFocused).id("skill-search")
                if !query.isEmpty { Button("Clear") { query = "" } }
            }
            DisclosureGroup("Filters", isExpanded: $filtersOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    filterMenus
                    organizationFilters
                    favoritesButton
                    Button("Reset filters") { mapSkillIDs = nil; mapLocation = nil; ownership = nil; agent = nil; location = nil; scopeFilter = nil; invocationFilter = nil; favoriteOnly = false; unresolvedSourcesOnly = false }
                }.font(.caption)
            }
        }
    }
    private var filterMenus: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ownerPicker; agentPicker; locationPicker }
            VStack(alignment: .leading, spacing: 8) { ownerPicker; agentPicker; locationPicker }
        }.font(.caption)
    }
    private var ownerPicker: some View {
            Picker("Owner", selection: $ownership) {
                Text("All owners").tag(nil as SkillOwnership?)
                ForEach(SkillOwnership.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
    }
    private var agentPicker: some View {
            Picker("Agent", selection: $agent) {
                Text("All agents").tag(nil as AgentRuntime?)
                ForEach(AgentRuntime.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
    }
    private var locationPicker: some View {
            Menu {
                Button("All locations") { location = nil }
                ForEach(Array(Set(records.flatMap { $0.exposures.map(\.source) })).sorted(), id: \.self) { source in
                    Button(source) { location = source }
                }
            } label: { Label(location ?? "All locations", systemImage: "folder") }
            .fixedSize(horizontal: true, vertical: false)
    }
    private var favoritesButton: some View {
        Button { favoriteOnly.toggle() } label: { Label("Favorites", systemImage: favoriteOnly ? "star.fill" : "star") }
            .buttonStyle(ContextDaddyButtonStyle()).accessibilityValue(favoriteOnly ? "On" : "Off")
    }
    @ViewBuilder private var organizationFilters: some View {
        Picker("Scope", selection: $scopeFilter) {
            Text("All scopes").tag(nil as AIContextScope?)
            ForEach(AIContextScope.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }
        Picker("Invocation", selection: $invocationFilter) {
            Text("All modes").tag(nil as InvocationMode?)
            ForEach(InvocationMode.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }
        Picker("Sort", selection: $sortField) {
            ForEach(SkillSortField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Button(ascending ? "Ascending ↑" : "Descending ↓") { ascending.toggle() }
    }
    private func organizationLedger(width: CGFloat) -> some View {
        let wide = width >= 820
        let counts = duplicateCounts
        return Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(results.count) matching definitions").font(.caption).foregroundStyle(DaddyTheme.muted)
                    Spacer()
                    Button("Select page") { checked.formUnion(visible.map(\.id)) }
                    Button("Clear") { checked.removeAll() }.disabled(checked.isEmpty)
                }.padding(.bottom, 12)
                if wide {
                    HStack {
                        Spacer().frame(width: 24)
                        columnHeading(.name, width: width * 0.22)
                        columnHeading(.location, width: width * 0.23)
                        columnHeading(.agents, width: width * 0.18)
                        columnHeading(.invocation, width: width * 0.16)
                        columnHeading(.copies, width: 60)
                    }.font(.caption2).padding(.bottom, 8)
                }
                ForEach(visible) { skill in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("Select \(skill.name)", isOn: Binding(get: { checked.contains(skill.id) }, set: {
                            if $0 { checked.insert(skill.id) } else { checked.remove(skill.id) }
                        })).labelsHidden().toggleStyle(.checkbox).frame(width: 24)
                        if wide {
                            Button { selectedID = skill.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(skill.name).fontWeight(.semibold).lineLimit(2)
                                    Text(skill.ownership.rawValue).font(.caption2).foregroundStyle(DaddyTheme.muted)
                                    if let evidence = externalSources[skill.id] {
                                        Text(evidence.kind.rawValue).font(.caption2).foregroundStyle(evidence.kind == .unresolved ? DaddyTheme.amber : DaddyTheme.muted)
                                    }
                                }.frame(width: width * 0.22, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Inspect \(skill.name)")
                            locationCell(skill).frame(width: width * 0.23, alignment: .leading)
                            Text(agentLabel(skill)).frame(width: width * 0.18, alignment: .leading)
                            Text(SkillOrganizationIndex.invocation(skill, runtime: agent)).frame(width: width * 0.16, alignment: .leading)
                            Text("\(counts[skill.id, default: 1])").frame(width: 60, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 7) {
                                Button(skill.name) { selectedID = skill.id }.font(.headline).buttonStyle(.plain)
                                if let evidence = externalSources[skill.id] {
                                    Text(evidence.kind.rawValue).font(.caption2).foregroundStyle(evidence.kind == .unresolved ? DaddyTheme.amber : DaddyTheme.muted)
                                }
                                locationCell(skill)
                                Text("Agents: \(agentLabel(skill))")
                                Text("Invocation: \(SkillOrganizationIndex.invocation(skill, runtime: agent))")
                                Text("\(counts[skill.id, default: 1]) matching instruction copies · \(skill.ownership.rawValue)").foregroundStyle(DaddyTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.caption).padding(.vertical, 12)
                        .background(checked.contains(skill.id) ? DaddyTheme.mint.opacity(0.10) : Color.clear)
                        .overlay(alignment: .leading) {
                            if selectedID == skill.id { Rectangle().fill(DaddyTheme.mint).frame(width: 2).accessibilityHidden(true) }
                        }
                    Divider()
                }
                HStack {
                    Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
                    Spacer()
                    Text("\(min(page, pageCount - 1) + 1) / \(pageCount)").font(.caption.monospacedDigit())
                    Spacer()
                    Button("Next") { page += 1 }.disabled(page >= pageCount - 1)
                }.buttonStyle(ContextDaddyButtonStyle()).padding(.top, 12)
                Text("Copies compare instructions only. Cleanup checks the complete folder. Agent access is discovered evidence, not proof of live use.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted).padding(.top, 10)
            }
        }
    }
    private func columnHeading(_ field: SkillSortField, width: CGFloat) -> some View {
        Button(field.rawValue + (sortField == field ? (ascending ? " ↑" : " ↓") : " ↕")) {
            if sortField == field { ascending.toggle() } else { sortField = field; ascending = true }
        }.buttonStyle(.plain).foregroundStyle(DaddyTheme.mint).frame(width: width, alignment: .leading)
    }
    private func locationCell(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SkillOrganizationIndex.location(skill))
            Text(skill.id.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted).lineLimit(2).help(skill.id)
        }
    }
    private func agentLabel(_ skill: SkillRecord) -> String {
        skill.exposedRuntimes.isEmpty ? (skill.ownership == .plugin ? "Cached · activation unverified" : "No known agent route")
            : skill.exposedRuntimes.map(\.rawValue).joined(separator: ", ")
    }
    private var changeTray: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(checked.count) selected").font(.headline)
                    Spacer()
                    if !checked.isEmpty { Button("Clear selection") { checked.removeAll() } }
                }
                Text("Selection includes rows on other pages or hidden by filters. Every change is previewed and recorded in History.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
                ViewThatFits(in: .horizontal) {
                    HStack { bulkButtons }
                    VStack(alignment: .leading, spacing: 8) { bulkButtons }
                }
            }
        }
    }
    @ViewBuilder private var bulkButtons: some View {
        Button("Move to folder…") { openOrganization(.move) }.disabled(checked.isEmpty)
        Button("Share with agents…") { openOrganization(.share) }.disabled(checked.isEmpty)
        Button("Set invocation…") { openOrganization(.invocation) }.disabled(checked.isEmpty)
        Button(checked.isEmpty ? "Review all duplicates…" : "Compare selected copies…") { openOrganization(.cleanup) }
    }
    private func inspector(_ skill: SkillRecord, scroll: ScrollViewProxy) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                if showsGuide {
                    Button("Back to guide") { scroll.scrollTo("skill-guide", anchor: .top) }
                        .font(.caption)
                }
                HStack(alignment: .top) {
                    Text(skill.name).font(.system(size: 24, weight: .semibold, design: .rounded)).textSelection(.enabled)
                    Spacer()
                    Button {
                        if favorites.contains(skill.id) { favorites.remove(skill.id) } else { favorites.insert(skill.id) }
                        UserDefaults.standard.set(Array(favorites), forKey: "skillLibraryFavorites")
                    } label: { Image(systemName: favorites.contains(skill.id) ? "star.fill" : "star") }.help("Favorite this skill")
                        .accessibilityLabel(favorites.contains(skill.id) ? "Remove \(skill.name) from favorites" : "Add \(skill.name) to favorites")
                        .accessibilityValue(favorites.contains(skill.id) ? "Favorite" : "Not a favorite")
                }
                Text(skill.description).font(.callout).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                Picker("Skill details", selection: $tab) {
                    ForEach(["Overview", "Content", "Access"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if tab == "Overview" { overview(skill) }
                else if tab == "Content" { content(skill) }
                else { access(skill) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.id(skill.id)
    }
    private func overview(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(skill.ownership.rawValue, systemImage: skill.ownership == .local ? "doc.text" : "shippingbox").foregroundStyle(DaddyTheme.mint)
            VStack(alignment: .leading, spacing: 5) {
                if let evidence = externalSources[skill.id] {
                    Text(evidence.kind.rawValue).font(.caption.weight(.semibold))
                    if let sourceURL = evidence.sourceURL, let url = URL(string: sourceURL) {
                        Link(sourceURL, destination: url).font(.caption)
                    }
                    if let owner = evidence.owner { Text("Managed by \(owner)").font(.caption) }
                    Text(evidence.note).font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
                Button(checkingSourceID == skill.id ? "Checking source…" : "Check source with ASM + skills") {
                    checkingSourceID = skill.id
                    Task {
                        let folder = URL(fileURLWithPath: workingFolder.isEmpty
                            ? FileManager.default.homeDirectoryForCurrentUser.path : workingFolder)
                        let evidence = await ExternalSkillSources().lookup(skillPath: skill.id, folder: folder)
                        externalSources[skill.id] = evidence
                        checkingSourceID = nil
                    }
                }
                .disabled(checkingSourceID != nil)
                .font(.caption)
            }
            if skill.exposedRuntimes.isEmpty {
                Text(skill.ownership == .plugin
                     ? "Installed by a plugin. We found its files, but have not verified whether the plugin is enabled. This is not evidence that it enters your context."
                     : "We found this file, but no supported agent route to it. It may be a stored source, an old copy, or a location discovery does not understand. This does not prove it is unused.")
                    .font(.callout).foregroundStyle(DaddyTheme.amber)
                if skill.ownership == .local {
                    Button("Make available to an agent…") { share(skill) }
                }
            }
            Text("Physical definition").font(.caption).foregroundStyle(DaddyTheme.muted)
            path(skill.id)
            TextField("Tags, separated by commas", text: Binding(get: { tags[skill.id, default: ""] }, set: {
                tags[skill.id] = $0; UserDefaults.standard.set(tags, forKey: "skillLibraryTags")
            })).textFieldStyle(.roundedBorder)
            Text("Tags and favorites stay in ContextDaddy.").font(.caption2).foregroundStyle(DaddyTheme.muted)
            Divider()
            Text("Where this skill appears").font(.headline)
            ForEach(skill.exposures) { exposure in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(exposure.provider.rawValue) · \(exposure.scope.rawValue) · \(exposure.applicability.rawValue)").font(.caption.weight(.semibold))
                    path(exposure.logicalPath)
                    Text(exposure.logicalPath == exposure.resolvedPath ? "Physical source" : "Linked to the physical source above").font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
            }
            if skill.hasDefinitionConflict {
                Button("Compare copies") { checked = Set(records.filter { $0.name == skill.name || (skill.contentFingerprint != nil && $0.contentFingerprint == skill.contentFingerprint) }.map(\.id)); openOrganization(.cleanup) }
                    .buttonStyle(ContextDaddyButtonStyle())
            }
            if skill.ownership == .local {
                ViewThatFits(in: .horizontal) {
                    HStack { managementActions(skill) }
                    VStack(alignment: .leading) { managementActions(skill) }
                }
            } else {
                Text("Managed by \(skill.ownership == .plugin ? "the plugin installer" : "the system skill owner"). Update or remove it through that owner. Cached installation alone does not prove agent access.")
                    .font(.callout).foregroundStyle(DaddyTheme.amber)
            }
        }
    }
    @ViewBuilder private func managementActions(_ skill: SkillRecord) -> some View {
        Button("Edit content") { loadEditor(skill) }
        Button("Update from folder…") {
            guard let source = chooseFolder("Choose the replacement skill folder") else { return }
            perform { try await manager.prepareUpdate(skill: URL(fileURLWithPath: skill.id), source: source) }
        }
        Menu("More") {
            Button("Share to agent or project…") { share(skill) }
            Button("Archive skill…") { perform { try await manager.prepareArchive(skill: URL(fileURLWithPath: skill.id)) } }
        }
    }
    private func content(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let document {
                Text(document).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if skill.ownership == .local { Button("Edit content") { draft = document; editor = true }.buttonStyle(ContextDaddyButtonStyle()) }
            } else {
                Text("Open SKILL.md explicitly to inspect its instructions. Supporting scripts are never executed.").foregroundStyle(DaddyTheme.muted)
                Button("Read SKILL.md") {
                    do {
                        let result = try SkillDocumentReader.read(url: URL(fileURLWithPath: skill.id))
                        document = result.text
                        if result.truncated { notice = "Preview is truncated to 256 KiB. Editing is unavailable for larger documents." }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(ContextDaddyButtonStyle())
            }
        }
    }
    private func access(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discovery, invocation, and installation are separate controls. These policies describe local evidence, not a live session.").font(.caption).foregroundStyle(DaddyTheme.muted)
            ForEach(skill.policies) { policy in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(policy.runtime.rawValue).font(.headline); Spacer(); Text(policy.mode.rawValue).font(.caption).foregroundStyle(DaddyTheme.color(for: policy.mode)) }
                    Text(policy.reason).font(.caption).textSelection(.enabled)
                    Text(policy.explicit ? "Explicit control" : "Derived default · no explicit override found").font(.caption2).foregroundStyle(DaddyTheme.muted)
                    if policy.isExposed {
                        Button("Copy \(policy.invocation)") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(policy.invocation, forType: .string) }
                    }
                }
                Divider()
            }
            Text("Edit SKILL.md to change its declared controls. Codex may also use agents/openai.yaml; global settings and plugin enablement remain with their owning agent.").font(.caption).foregroundStyle(DaddyTheme.muted)
            if skill.ownership == .local {
                Button("Share to agent or project…") { share(skill) }.buttonStyle(ContextDaddyButtonStyle())
                ForEach(skill.exposures.filter { $0.logicalPath != $0.resolvedPath }) { exposure in
                    Button("Remove link: \(exposure.logicalPath)") {
                        perform { try await manager.prepareUnlink(path: URL(fileURLWithPath: exposure.logicalPath).deletingLastPathComponent()) }
                    }.font(.caption).lineLimit(2)
                }
            }
        }
    }
    private func path(_ value: String) -> some View {
        HStack(alignment: .top) {
            Text(value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)]) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
        }
    }
    private var contentEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit skill content").font(.title2.bold())
            Text("Changes affect every link to this physical definition. Review before saving.").foregroundStyle(DaddyTheme.muted)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(minHeight: 340)
            HStack {
                Button("Cancel") { editor = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review changes") {
                    guard let selection else { return }
                    let text = draft
                    editor = false
                    perform { try await manager.prepareEdit(skill: URL(fileURLWithPath: selection.id), text: text) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 560)
    }
    private func changePreview(_ pending: SkillChangePlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.title).font(.title2.bold())
            Text(pending.destination).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(pending.detail).foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pending.fileChanges, id: \.self) { Text($0).font(.caption.monospaced()) }
                    Divider()
                HStack(alignment: .top, spacing: 16) {
                    previewText("Current", pending.before)
                    previewText("Proposed", pending.after)
                }
                }
            }
            HStack {
                Button("Cancel") { plan = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply change") {
                    plan = nil; working = true
                    Task {
                        defer { working = false }
                        do {
                            let receipt = try await manager.apply(pending.id)
                            document = nil
                            notice = "\(receipt.title) completed. Recovery is available in History."
                            await refreshLibrary()
                        } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(working || model.isLoading)
            }
        }.padding(24).frame(width: 760, height: 570)
    }
    private func previewText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Text(text.isEmpty ? "No content" : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var locationsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Skill locations").font(.title2.bold())
            Text("Known agent roots and plugin caches are scanned automatically. Add a folder for skills stored elsewhere; adding it to this library does not enable it for any agent.").foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.catalog?.coverage.limitReasons ?? [], id: \.self) { Text($0).foregroundStyle(DaddyTheme.amber) }
                    if let coverage = model.catalog?.coverage {
                        Text("\(coverage.unreadableCount) unreadable locations · \(coverage.skippedLinks) skipped links").font(.caption)
                    }
                    ForEach(Array(Set(model.catalog?.coverage.roots ?? [])).sorted(), id: \.self) { path($0) }
                    Divider()
                    Text("Added skill folders").font(.headline)
                    ForEach(UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? [], id: \.self) { root in
                        HStack {
                            path(root)
                            Button("Stop scanning") {
                                let roots = (UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []).filter { $0 != root }
                                UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots")
                                Task { await refreshLibrary() }
                            }
                        }
                    }
                }
            }
            HStack { Button("Add skill location…") { addLocation() }; Spacer(); Button("Done") { showLocations = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 720, height: 580)
    }
    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change history & recovery").font(.title2.bold())
            Text("Only changes made through ContextDaddy appear here. Restoring never overwrites newer edits.").foregroundStyle(DaddyTheme.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if receipts.isEmpty { Text("No changes yet.") }
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(receipt.title).font(.headline)
                            Text(receipt.date, style: .date).font(.caption)
                            path(receipt.destination)
                            if !receipt.completed {
                                Text("Incomplete action · inspect recovery files before retrying").foregroundStyle(DaddyTheme.amber)
                                if let backup = receipt.backupPath { path(backup) }
                            }
                            else if receipt.restored { Text("Restored").foregroundStyle(DaddyTheme.mint) }
                            else { Button("Restore…") { restoreReceipt = receipt } }
                        }
                        Divider()
                    }
                }
            }
            if let error { Text(error).foregroundStyle(DaddyTheme.coral) }
            Button("Done") { showHistory = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 720, height: 560)
    }
    private func refreshLibrary() async {
        folderRevision += 1
        await model.refreshSkillLibrary()
    }

    private func openOrganization(_ action: SkillOrganizationAction) {
        organizationRecords = action == .cleanup && checked.isEmpty
            ? ownedRecords.filter { mapSkillIDs?.contains($0.id) ?? true } : selectedRecords
        organizationAction = action
    }

    private func resetPage() { rebuildIndex(); page = 0; selectedID = nil; document = nil }
    private func perform(_ operation: @escaping () async throws -> SkillChangePlan) {
        working = true; error = nil; notice = nil
        Task { defer { working = false }; do { plan = try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func loadEditor(_ skill: SkillRecord) {
        do {
            let result = try SkillDocumentReader.read(url: URL(fileURLWithPath: skill.id))
            guard !result.truncated else { throw SkillManagementError(message: "This document is too large to edit safely.") }
            draft = result.text; editor = true
        } catch { self.error = error.localizedDescription }
    }
    private func chooseFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func addLocation() {
        guard let root = chooseFolder("Choose a skill folder or a directory containing skills") else { return }
        var roots = UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []
        if !roots.contains(root.path) { roots.append(root.path); UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots") }
        Task { await refreshLibrary() }
    }
    private func importFolder() {
        guard let source = chooseFolder("Choose one skill folder containing SKILL.md"),
              let parent = chooseFolder("Choose the destination skills directory (for example ~/.agents/skills)") else { return }
        rememberLocation(parent)
        perform { try await manager.prepareImport(source: source, parent: parent) }
    }
    private func share(_ skill: SkillRecord) { sharingSkill = skill }
    private func rememberLocation(_ root: URL) {
        var roots = UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []
        if !roots.contains(root.path) { roots.append(root.path); UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots") }
    }
}

private struct SkillCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let create: (URL, String, String) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var bodyText = "# Instructions\n\n"
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills")
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a skill").font(.title2.bold())
            TextField("skill-name", text: $name).textFieldStyle(.roundedBorder)
            TextField("When should an agent use this skill?", text: $description).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
            Text(parent.path).font(.caption.monospaced()).textSelection(.enabled)
            Button("Choose destination…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { parent = url }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review new skill") {
                    let encoded = String(data: try! JSONEncoder().encode(description), encoding: .utf8)!
                    create(parent, name, "---\nname: \(name)\ndescription: \(encoded)\n---\n\n\(bodyText)")
                }.disabled(name.isEmpty || description.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 520)
    }
}

private struct SkillShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skill: SkillRecord
    let share: (URL, URL?) -> Void
    @State private var runtime: AgentRuntime = .codex
    @State private var project: URL?
    @State private var projectOnly = false
    private var destination: URL {
        let root = projectOnly ? (project ?? FileManager.default.homeDirectoryForCurrentUser) : FileManager.default.homeDirectoryForCurrentUser
        let directory: String = switch runtime {
        case .codex: ".agents/skills"
        case .claude: ".claude/skills"
        case .cursor: ".cursor/skills"
        case .grok: ".grok/skills"
        case .devin: projectOnly ? ".agents/skills" : ".config/devin/skills"
        }
        return root.appendingPathComponent(directory)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share \(skill.name)").font(.title2.bold())
            Text("Choose an agent and scope. ContextDaddy creates a link to the existing definition.").foregroundStyle(DaddyTheme.muted)
            Picker("Agent", selection: $runtime) { ForEach(AgentRuntime.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Only inside a project", isOn: $projectOnly)
            if projectOnly {
                Button(project?.path ?? "Choose project folder…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK { project = panel.url }
                }
            }
            Text("Destination").font(.headline)
            Text(destination.appendingPathComponent(URL(fileURLWithPath: skill.id).deletingLastPathComponent().lastPathComponent).path)
                .font(.caption.monospaced()).textSelection(.enabled)
            if runtime == .devin {
                Text("Devin local routes are inventory evidence. Runtime discovery and activation must be verified in Devin.").foregroundStyle(DaddyTheme.amber)
            }
            Text("This shares access; it does not force automatic invocation or change agent settings. An existing destination will never be overwritten.").font(.callout).foregroundStyle(DaddyTheme.muted)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review link") { share(destination, projectOnly ? project : nil) }
                    .disabled(projectOnly && project == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }
}
