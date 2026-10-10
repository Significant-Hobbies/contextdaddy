import AppKit
import ContextCore
import SwiftUI
import SaaSMakerUI

struct MemoryLibraryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("skillWorkingFolder") private var folder = ""
    @State private var folderInput = ""
    @State private var snapshot: MemoryInventory?
    @State private var query = ""
    @State private var agent: AgentRuntime?
    @State private var kind = "All types"
    @State private var selected: MemoryEntry?
    @State private var editing: MemoryEntry?
    @State private var historyOpen = false
    @State private var loading = false
    @State private var revision = 0
    @State private var failure: String?
    @State private var duplicatePaths: Set<String>?
    @State private var duplicateGroups: [[MemoryEntry]] = []
    @State private var compareNote: String?
    @State private var comparing = false
    @State private var comparisonID = UUID()
    @State private var duplicatesOnly = false
    @State private var page = 0
    @State private var manager = MemoryDocumentManager()
    private let fixture: MemoryInventory?
    init(snapshot: MemoryInventory? = nil) { fixture = snapshot; _snapshot = State(initialValue: snapshot) }
    private var matches: [MemoryEntry] {
        (snapshot?.entries ?? []).filter {
            (agent == nil || $0.agent == agent) && (kind == "All types" || $0.category == kind) &&
            (!duplicatesOnly || duplicatePaths?.contains($0.path) == true) &&
            (query.isEmpty || [$0.path, $0.category, $0.scope, $0.agent?.rawValue ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(250, geometry.size.width - 44)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ViewThatFits(in: .horizontal) {
                            HStack { titles; Spacer(); actions }
                            VStack(alignment: .leading, spacing: 12) { titles; actions }
                        }
                        folderControls
                        if loading { ProgressView("Finding instructions and saved memory…") }
                        if let failure { Text(failure).foregroundStyle(DaddyTheme.amber).textSelection(.enabled) }
                        if let snapshot {
                            summary(snapshot)
                            filters
                            if let agent, [.cursor, .devin, .grok].contains(agent) {
                                Text("\(agent.rawValue): local formats only. Managed memory and shared AGENTS.md loading are not fully resolved; an empty list does not mean this agent has no memory.").font(.callout).foregroundStyle(DaddyTheme.amber)
                            }
                            if matches.isEmpty {
                                Text("No matching local documents in the checked sources. Managed or cloud memory may still exist.").foregroundStyle(DaddyTheme.muted)
                            } else if width >= 1050 && selected != nil {
                                HStack(alignment: .top, spacing: 20) { ledger.frame(width: width - 390); if let selected { inspector(selected).frame(width: 370).id("memory-detail") } }
                            } else {
                                ledger
                                if let selected { inspector(selected).id("memory-detail") }
                            }
                            DisclosureGroup("Coverage and agent differences") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(snapshot.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(DaddyTheme.muted) }
                                    Text("Checked \(snapshot.checkedAt.formatted())").font(.caption)
                                    Text("Claude: use /memory to verify its active memory directory. Cursor: use its Rules settings. Devin: review Knowledge in Devin. Grok: memory activation is not verified here.").font(.callout)
                                }.padding(.top, 10)
                            }
                        }
                    }.padding(22).frame(width: width + 44, alignment: .leading)
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .onChange(of: selected?.id) { _, id in if id != nil && width < 1050 { proxy.scrollTo("memory-detail", anchor: .top) } }
            }
        }
        .task(id: folder + "#" + String(revision)) { folderInput = folder; await refresh() }
        .onChange(of: model.inventory) { _, _ in if folder.isEmpty { revision += 1 } }
        .onChange(of: query) { _, _ in reset() }
        .onChange(of: agent) { _, _ in reset() }
        .onChange(of: kind) { _, _ in reset() }
        .onChange(of: duplicatesOnly) { _, _ in reset() }
        .sheet(item: $editing) { entry in MemoryEditorSheet(entry: entry, manager: manager, changed: recheck) }
        .sheet(isPresented: $historyOpen) { MemoryHistorySheet(manager: manager, changed: recheck) }
    }
    private var titles: some View {
        VStack(alignment: .leading, spacing: 5) {
            SMSectionHeader("memory", size: 22).accessibilityLabel("Memory")
            Text("See what agents can remember. Keep the useful context.").font(.callout).foregroundStyle(DaddyTheme.muted)
        }
    }
    private var actions: some View {
        HStack { Button("history") { historyOpen = true }.accessibilityLabel("History"); Button("recheck", action: recheck).accessibilityLabel("Recheck").disabled(loading || model.isLoading) }
    }
    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Folder path · leave empty for discovered projects", text: $folderInput).textFieldStyle(.roundedBorder)
                .onSubmit { folder = (folderInput as NSString).expandingTildeInPath }
            HStack {
                Button("inspect folder") { folder = (folderInput as NSString).expandingTildeInPath }.accessibilityLabel("Inspect folder")
                Menu("Choose folder") {
                    Button("browse…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }.accessibilityLabel("Browse…")
                    Button("all discovered projects") { folder = "" }.accessibilityLabel("All discovered projects")
                    ForEach(Array(model.projects.prefix(20))) { project in Button(project.name) { folder = project.path } }
                }
            }
            Text(folder.isEmpty ? "All discovered instruction locations + default saved-memory stores" : "Instructions for this folder + saved stores with unverified folder mapping")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }
    private func summary(_ snapshot: MemoryInventory) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                let saved = snapshot.entries.filter { $0.category == "Saved memory" }.count
                Text("\(snapshot.entries.count - saved) instruction & rule files · \(saved) saved-memory files").font(.headline)
                Text("Start with the largest files below. Open a document to remove stale guidance, or compare exact copies before deciding what to keep.").font(.callout).foregroundStyle(DaddyTheme.muted)
                Button(comparing ? "Comparing…" : "Compare document contents for duplicates") { Task { await compare() } }.disabled(comparing || loading)
                Text("Comparison reads up to 256 KiB per document locally. Contents are never sent to a service.").font(.caption).foregroundStyle(DaddyTheme.muted)
                if let compareNote { Text(compareNote).font(.caption).foregroundStyle(DaddyTheme.amber) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search filenames, folders or agents", text: $query).textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) {
                HStack { agentPicker; typePicker }
                VStack(alignment: .leading) { agentPicker; typePicker }
            }
            if duplicatePaths != nil { Toggle("Exact copies only", isOn: $duplicatesOnly).toggleStyle(.checkbox) }
        }
    }
    private var agentPicker: some View { Picker("Agent", selection: $agent) { Text("All agents").tag(AgentRuntime?.none); ForEach(AgentRuntime.allCases) { Text($0.rawValue).tag(Optional($0)) } }.frame(maxWidth: 240) }
    private var typePicker: some View { Picker("Type", selection: $kind) { ForEach(["All types", "Instructions", "Rule", "Saved memory"], id: \.self) { Text($0) } }.frame(maxWidth: 240) }
    private var ledger: some View {
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(matches.count) documents · largest first").font(.caption).foregroundStyle(DaddyTheme.muted)
                ForEach(Array(matches.dropFirst(page * 8).prefix(8))) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(.headline)
                            Text("\(entry.agent?.rawValue ?? "Other") · \(entry.category) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))").font(.caption).foregroundStyle(DaddyTheme.mint)
                            Text(shortPath(entry.path)).font(.caption).foregroundStyle(DaddyTheme.muted).lineLimit(2).truncationMode(.middle)
                            if duplicatePaths?.contains(entry.path) == true { Text("Exact content copy found · review scope before changing").font(.caption).foregroundStyle(DaddyTheme.amber) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected?.id == entry.id ? DaddyTheme.mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
                HStack { Button("previous") { page -= 1; selected = nil }.accessibilityLabel("Previous").disabled(page == 0); Spacer(); Text("\(page + 1) / \(max(1, (matches.count + 7) / 8))").font(.caption); Spacer(); Button("next") { page += 1; selected = nil }.accessibilityLabel("Next").disabled((page + 1) * 8 >= matches.count) }
            }
        }
    }
    private func inspector(_ entry: MemoryEntry) -> some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.name).font(.title2.bold())
                Text(entry.category).foregroundStyle(DaddyTheme.mint)
                Text(shortPath(entry.path)).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("\(entry.agent?.rawValue ?? "Unverified agent") · \(entry.scope)").font(.headline)
                Text(entry.access).font(.callout).foregroundStyle(DaddyTheme.muted)
                if entry.name.hasPrefix("AGENTS") { Text("Shown under the Codex instruction adapter. Other agents may also support this format; their loading policy is not established by this file alone.").font(.caption).foregroundStyle(DaddyTheme.amber) }
                Text("Updated \(entry.modified.formatted(date: .abbreviated, time: .shortened)) · not last use").font(.caption).foregroundStyle(DaddyTheme.muted)
                Button("open document…") { editing = entry }.accessibilityLabel("Open document…")
                Button("reveal in finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }.accessibilityLabel("Reveal in Finder")
                if let group = duplicateGroups.first(where: { $0.contains(where: { $0.id == entry.id }) }) {
                    SMDisplay("identical contents also at", size: 13).accessibilityLabel("Identical contents also at")
                    ForEach(group.filter { $0.id != entry.id }) { copy in
                        Button(shortPath(copy.path)) { selected = copy }.font(.caption).multilineTextAlignment(.leading)
                    }
                }
                Text("Editing a shared source changes it for every reader. Identical files can intentionally serve separate projects. No automatic merging or access changes.").font(.caption).foregroundStyle(DaddyTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func reset() { page = 0; selected = nil }
    private func recheck() { Task { if folder.isEmpty { await model.refreshSkillLibrary() }; revision += 1 } }
    private func shortPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    private func refresh() async {
        guard fixture == nil else { return }
        loading = true; failure = nil; comparisonID = UUID(); comparing = false; duplicatePaths = nil; duplicateGroups = []; compareNote = nil; duplicatesOnly = false; reset()
        let selectedFolder = folder, allItems = model.inventory
        let job = Task.detached(priority: .utility) {
            var items = allItems
            var coverage: [String] = []
            if !selectedFolder.isEmpty {
                let url = URL(fileURLWithPath: selectedFolder)
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw SkillManagementError(message: "Choose an existing folder.") }
                let report = try AIContextDiscovery.discoverFolder(url)
                items = AIContextDiscovery.rankings(items: report.items, in: url).flatMap(\.sources).filter { $0.origin != .installedOnly }.map(\.item)
                coverage = report.coverage.limitReasons + report.coverage.notes
            }
            let value = try MemoryInventory.scan(items: items, folder: selectedFolder.isEmpty ? nil : URL(fileURLWithPath: selectedFolder))
            return (value, coverage)
        }
        do {
            let (value, coverage) = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation(); snapshot = MemoryInventory(entries: value.entries, notes: value.notes + coverage, checkedAt: value.checkedAt)
        } catch is CancellationError { return }
        catch { snapshot = nil; failure = error.localizedDescription }
        loading = false
    }
    private func compare() async {
        comparing = true
        let request = UUID(); comparisonID = request
        let entries = snapshot?.entries ?? []
        do {
            let result = try await Task.detached(priority: .utility) { try MemoryInventory.compare(entries) }.value
            guard comparisonID == request else { return }
            duplicateGroups = result.groups
            duplicatePaths = Set(result.groups.flatMap { $0.map(\.path) })
            compareNote = "\(result.groups.count) groups with identical contents · \(result.skipped) unreadable or oversized documents excluded. Separate scopes may need their own copies."
            duplicatesOnly = !result.groups.isEmpty
        } catch { failure = error.localizedDescription }
        comparing = false
    }
}

private struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: MemoryEntry
    let manager: MemoryDocumentManager
    let changed: () -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var truncated = false
    @State private var plan: MemoryEditPlan?
    @State private var failure: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan == nil ? entry.name : "Review document changes").font(.title2.bold())
            Text(entry.path).font(.caption.monospaced()).textSelection(.enabled)
            if let failure { Text(failure).foregroundStyle(DaddyTheme.amber) }
            if let plan {
                Text(plan.archive ? "Archive moves this document out of its current location. Every agent reading this path loses this guidance, and imports may stop resolving. A recovery copy is retained in History." : "This changes the existing file for every agent that reads it. A private recovery copy is retained. Runtime loading is not verified.").font(.callout)
                ScrollView { VStack(alignment: .leading, spacing: 16) { Text("BEFORE").font(.caption.bold()); Text(plan.before).font(.body.monospaced()); Divider(); Text("AFTER").font(.caption.bold()); Text(plan.after).font(.body.monospaced()) }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            } else if loaded {
                TextEditor(text: $text).font(.body.monospaced()).disabled(!entry.editable || truncated)
                Text(entry.editable && !truncated ? "Remove stale or repeated guidance. Save requires a preview; History can restore the previous document." : "Read-only source. Manage this file through its owning agent.").font(.caption).foregroundStyle(DaddyTheme.muted)
            } else { ProgressView("Opening document…").frame(maxHeight: .infinity) }
            HStack {
                Button("close") { dismiss() }.accessibilityLabel("Close").keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if plan != nil {
                    Button("back to editing") { plan = nil }.accessibilityLabel("Back to editing").disabled(busy)
                    Button(plan?.archive == true ? "Apply archive" : "Apply edit") { Task { busy = true; defer { busy = false }; do { _ = try await ContextUpdateActivity.perform { try await manager.apply(plan!.id) }; changed(); dismiss() } catch { failure = error.localizedDescription; plan = nil } } }.disabled(busy)
                } else {
                    Button("preview archive") { Task { do { plan = try await manager.prepareArchive(entry: entry); failure = nil } catch { failure = error.localizedDescription } } }.accessibilityLabel("Preview archive").disabled(!loaded || !entry.editable || truncated || text != original)
                    Button("preview changes") { Task { do { plan = try await manager.prepare(entry: entry, text: text); failure = nil } catch { failure = error.localizedDescription } } }.accessibilityLabel("Preview changes").disabled(!loaded || !entry.editable || truncated || text == original)
                }
            }
        }.padding(24).frame(width: 680, height: 640)
        .task {
            do { let document = try await Task.detached { try MemoryInventory.read(entry) }.value; text = document.text; original = text; truncated = document.truncated; loaded = true }
            catch { failure = error.localizedDescription }
        }
    }
}

private struct MemoryHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let manager: MemoryDocumentManager
    let changed: () -> Void
    @State private var receipts: [MemoryEditReceipt] = []
    @State private var failure: String?
    @State private var restoring: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Memory edit history").font(.title2.bold())
            Text("Restore only succeeds while the saved result is unchanged. Newer work is preserved.").foregroundStyle(DaddyTheme.muted)
            if let failure { Text(failure).foregroundStyle(DaddyTheme.amber) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if receipts.isEmpty { Text("No document edits yet.") }
                    ForEach(receipts) { receipt in
                        Text(receipt.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(receipt.date.formatted()) · \(receipt.restored ? "Restored" : receipt.completed ? (receipt.archived == true ? "Archived" : "Applied") : "Interrupted · inspect recovery")").font(.caption)
                        if !receipt.restored { Button("restore previous document") { restoring = receipt.id }.accessibilityLabel("Restore previous document").disabled(restoring != nil) }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("done") { dismiss() }.accessibilityLabel("Done").keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 620, height: 520)
        .task { await reload() }
        .confirmationDialog("Restore the previous document?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            if let id = restoring {
                Button("restore") { restoring = nil; Task { do { try await ContextUpdateActivity.perform { try await manager.restore(id) }; changed(); await reload() } catch { failure = error.localizedDescription } } }.accessibilityLabel("Restore")
            }
            Button("cancel", role: .cancel) { restoring = nil }.accessibilityLabel("Cancel")
        }
    }
    private func reload() async { do { receipts = try await manager.history() } catch { failure = error.localizedDescription } }
}
