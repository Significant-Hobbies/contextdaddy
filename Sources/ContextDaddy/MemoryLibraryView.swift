import AppKit
import ContextCore
import SwiftUI
import SaaSMakerUI

struct MemoryLibraryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("skillWorkingFolder") private var folder = ""
    @State private var folderInput = ""
    @State private var scopeExpanded = false
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
    @State private var manager: MemoryDocumentManager
    private let fixture: MemoryInventory?
    init(snapshot: MemoryInventory? = nil, manager: MemoryDocumentManager = MemoryDocumentManager(), initialSelection: MemoryEntry? = nil) {
        fixture = snapshot
        _snapshot = State(initialValue: snapshot)
        _manager = State(initialValue: manager)
        _selected = State(initialValue: initialSelection)
    }
    private var matches: [MemoryEntry] {
        (snapshot?.entries ?? []).filter {
            (agent == nil || $0.agent == agent) && (kind == "All types" || $0.category == kind) &&
            (!duplicatesOnly || duplicatePaths?.contains($0.path) == true) &&
            (query.isEmpty || [$0.path, $0.category, $0.scope, $0.agent?.rawValue ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }
    var body: some View {
        GeometryReader { geometry in
            let gutter: CGFloat = geometry.size.width < 740 ? 24 : 32
            let width = max(250, geometry.size.width - gutter * 2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ScreenHeader(eyebrow: "Your agents’ context", title: "Memory",
                            subtitle: "Keep the useful context. Review what your agents can remember.", art: .sources,
                            compact: width < 760)
                        folderControls
                        if loading { ProgressView("Finding instructions and saved memory…") }
                        if let failure { Text(failure).foregroundStyle(DaddyTheme.amber).textSelection(.enabled) }
                        if let snapshot {
                            summary(snapshot)
                            filters(width: width)
                            if let agent, [.cursor, .devin, .grok].contains(agent) {
                                Text("\(agent.rawValue): local formats only. Managed memory and shared AGENTS.md loading are not fully resolved; an empty list does not mean this agent has no memory.")
                                    .font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.amber)
                            }
                            if matches.isEmpty {
                                ContentUnavailableView("No matching documents", systemImage: "doc.text.magnifyingglass",
                                    description: Text("Try another search or scope. Managed or cloud memory may still exist."))
                            } else if width >= 870 && selected != nil {
                                HStack(alignment: .top, spacing: 28) {
                                    ledger.frame(width: width - 340)
                                    if let selected { inspector(selected).frame(width: 312).id("memory-detail") }
                                }
                            } else {
                                ledger
                                if let selected { inspector(selected).id("memory-detail") }
                            }
                            comparisonTools
                            DisclosureGroup("Coverage & agent differences") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(snapshot.notes, id: \.self) { Text($0).font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.muted) }
                                    Text("Checked \(snapshot.checkedAt.formatted())").font(.caption)
                                    Text("Claude: use /memory to verify its active memory directory. Cursor: use its Rules settings. Devin: review Knowledge in Devin. Grok: memory activation is not verified here.").font(DaddyTheme.type(12))
                                }.padding(.top, 12)
                            }
                            .font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.muted)
                        }
                    }
                    .padding(gutter).frame(width: width + gutter * 2, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .onChange(of: selected?.id) { _, id in if id != nil && width < 870 { proxy.scrollTo("memory-detail", anchor: .top) } }
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
    private var actions: some View {
        HStack(spacing: 8) {
            Button("History", systemImage: "clock.arrow.circlepath") { historyOpen = true }
            Button("Recheck", systemImage: "arrow.clockwise", action: recheck).disabled(loading || model.isLoading)
        }
    }
    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                DisclosureGroup(isExpanded: $scopeExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        folderField
                        folderActions
                        Text(folder.isEmpty ? "Discovered instruction locations and default saved-memory stores." : "Folder instructions and saved stores. Saved-store folder mapping is unverified.")
                            .font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted)
                    }.padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FOLDER SCOPE").font(DaddyTheme.type(10, .medium)).tracking(1.2).foregroundStyle(DaddyTheme.muted)
                        Text(folder.isEmpty ? "All discovered projects" : (folder as NSString).lastPathComponent)
                            .font(DaddyTheme.type(12, .medium)).foregroundStyle(DaddyTheme.ink)
                            .lineLimit(1).truncationMode(.middle).help(folder.isEmpty ? "All discovered projects" : shortPath(folder))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize()
            }
        }
    }
    private var folderField: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(DaddyTheme.mint)
            TextField("Folder path · empty for discovered projects", text: $folderInput)
                .textFieldStyle(.plain).font(DaddyTheme.type(12))
                .onSubmit { folder = (folderInput as NSString).expandingTildeInPath }
        }
        .padding(.horizontal, 12).frame(minWidth: 230, minHeight: 38)
        .background(DaddyTheme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DaddyTheme.line))
        .accessibilityLabel("Folder path")
    }
    private var folderActions: some View {
        HStack(spacing: 8) {
            Button("Inspect") { folder = (folderInput as NSString).expandingTildeInPath }.accessibilityLabel("Inspect folder")
            Menu("Choose folder") {
                Button("Browse…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                }
                Button("All discovered projects") { folder = "" }
                ForEach(Array(model.projects.prefix(20))) { project in Button(project.name) { folder = project.path } }
            }.fixedSize()
        }
    }
    private func summary(_ snapshot: MemoryInventory) -> some View {
        let saved = snapshot.entries.filter { $0.category == "Saved memory" }.count
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                memoryCount(snapshot.entries.count - saved, title: "instructions & rules")
                memoryCount(saved, title: "saved-memory files")
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                memoryCount(snapshot.entries.count - saved, title: "instructions & rules")
                memoryCount(saved, title: "saved-memory files")
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(DaddyTheme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DaddyTheme.line).frame(height: 1) }
    }
    private func memoryCount(_ count: Int, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(count.formatted()).font(DaddyTheme.type(14, .semibold)).monospacedDigit().foregroundStyle(DaddyTheme.ink)
            Text(title).font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.muted)
        }
    }
    private var comparisonTools: some View {
        DisclosureGroup("Compare document contents") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Find identical contents before deciding what to keep. Separate projects may intentionally use the same guidance.")
                    .font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.muted)
                Button(comparing ? "Comparing…" : "Find exact copies", systemImage: "doc.on.doc") { Task { await compare() } }
                    .disabled(comparing || loading)
                Text("Reads up to 256 KiB per document locally. Contents never leave this Mac.")
                    .font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted)
                if let compareNote { Text(compareNote).font(.caption).foregroundStyle(DaddyTheme.amber) }
            }.padding(.top, 12)
        }
        .font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.muted)
    }
    private func filters(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if width >= 850 {
                HStack(spacing: 12) {
                    SMSearchField("Find a document, folder or agent", text: $query)
                    agentPicker
                    typePicker
                }
            } else {
                SMSearchField("Find a document, folder or agent", text: $query)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { agentPicker; typePicker; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 10) { agentPicker; typePicker }
                }
            }
            if duplicatePaths != nil { Toggle("Exact copies only", isOn: $duplicatesOnly).toggleStyle(.checkbox) }
        }
    }
    private var agentPicker: some View { ContextChoiceMenu(title: "Agent", selection: $agent, choices: [ContextChoice<AgentRuntime?>(nil, "All agents")] + AgentRuntime.allCases.map { ContextChoice<AgentRuntime?>($0, $0.rawValue) }, width: 176) }
    private var typePicker: some View { ContextChoiceMenu(title: "Type", selection: $kind, choices: ["All types", "Instructions", "Rule", "Saved memory"].map { ContextChoice($0, $0) }, width: 176) }
    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DOCUMENT / LOCATION").tracking(1.1)
                Spacer()
                Text("LARGEST FIRST").tracking(1.1)
            }
            .font(DaddyTheme.type(10, .medium)).foregroundStyle(DaddyTheme.muted)
            .padding(.bottom, 14)
            Rectangle().fill(DaddyTheme.line).frame(height: 1)
            ForEach(Array(matches.dropFirst(page * 8).prefix(8))) { entry in
                Button { selected = entry } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 19, weight: .regular)).foregroundStyle(DaddyTheme.mint)
                            .frame(width: 36, height: 42)
                            .background(DaddyTheme.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(DaddyTheme.type(15, .semibold)).foregroundStyle(DaddyTheme.ink)
                            Text(shortPath(entry.path)).font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted)
                                .lineLimit(1).truncationMode(.middle)
                            if duplicatePaths?.contains(entry.path) == true {
                                Text("Exact content copy · review scope").font(DaddyTheme.type(10)).foregroundStyle(DaddyTheme.amber)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                                .font(DaddyTheme.type(13, .medium)).monospacedDigit().foregroundStyle(DaddyTheme.ink)
                            Text("\(entry.agent?.rawValue ?? "Other") · \(entry.category)").font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(DaddyTheme.muted)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected?.id == entry.id ? DaddyTheme.mint.opacity(0.08) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.name), \(entry.agent?.rawValue ?? "Other"), \(entry.category), \(entry.bytes) bytes")
                .accessibilityAddTraits(selected?.id == entry.id ? .isSelected : [])
                Rectangle().fill(DaddyTheme.line).frame(height: 1)
            }
            HStack(spacing: 12) {
                Text("\(matches.count.formatted()) documents").font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted)
                Spacer()
                Button("Previous", systemImage: "chevron.left") { page -= 1; selected = nil }.disabled(page == 0)
                Text("\(page + 1) / \(max(1, (matches.count + 7) / 8))").font(DaddyTheme.type(11)).monospacedDigit().foregroundStyle(DaddyTheme.muted)
                Button("Next", systemImage: "chevron.right") { page += 1; selected = nil }.disabled((page + 1) * 8 >= matches.count)
            }.padding(.top, 18)
        }
    }
    private func inspector(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DOCUMENT DETAILS").font(DaddyTheme.type(10, .medium)).tracking(1.3).foregroundStyle(DaddyTheme.muted)
            Text(entry.name).font(DaddyTheme.heading(23)).foregroundStyle(DaddyTheme.ink)
            Text(entry.category).font(DaddyTheme.type(12, .medium)).foregroundStyle(DaddyTheme.mint)
            Text(shortPath(entry.path)).font(.caption.monospaced()).foregroundStyle(DaddyTheme.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(DaddyTheme.line).frame(height: 1)
            Text("\(entry.agent?.rawValue ?? "Unverified agent") · \(entry.scope)").font(DaddyTheme.type(13, .medium)).fixedSize(horizontal: false, vertical: true)
            Text(entry.access).font(DaddyTheme.type(12)).foregroundStyle(DaddyTheme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if entry.name.hasPrefix("AGENTS") { Text("Shown under the Codex instruction adapter. Other agents may support this format; their loading policy is not established here.").font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.amber) }
            Text("Updated \(entry.modified.formatted(date: .abbreviated, time: .shortened)) · not last use")
                .font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
            Button("Open document…", systemImage: "doc.text") { editing = entry }
                .buttonStyle(SMMacButtonStyle(.primary))
            Button("Reveal in Finder", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
            if let group = duplicateGroups.first(where: { $0.contains(where: { $0.id == entry.id }) }) {
                Text("IDENTICAL CONTENTS ALSO AT").font(DaddyTheme.type(10, .medium)).tracking(1).foregroundStyle(DaddyTheme.muted)
                ForEach(group.filter { $0.id != entry.id }) { copy in
                    Button(shortPath(copy.path)) { selected = copy }.font(.caption).multilineTextAlignment(.leading)
                }
            }
            ContextDoodleArt(topic: .sources).frame(width: 116, height: 116).frame(maxWidth: .infinity)
            Text("Shared sources affect every reader. Changes require your review; History keeps recovery copies.")
                .font(DaddyTheme.type(11)).foregroundStyle(DaddyTheme.muted).lineSpacing(3)
        }
        .padding(22)
        .background(DaddyTheme.canvas)
        .overlay(alignment: .leading) { Rectangle().fill(DaddyTheme.line).frame(width: 1) }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(plan == nil ? entry.name : "Review document changes").font(DaddyTheme.heading(24))
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
                Button("Close") { dismiss() }.accessibilityLabel("Close").keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if plan != nil {
                    Button("Back to editing") { plan = nil }.accessibilityLabel("Back to editing").disabled(busy)
                    Button(plan?.archive == true ? "Apply archive" : "Apply edit") { Task { busy = true; defer { busy = false }; do { _ = try await ContextUpdateActivity.perform { try await manager.apply(plan!.id) }; changed(); dismiss() } catch { failure = error.localizedDescription; plan = nil } } }.disabled(busy)
                } else {
                    Button("Preview archive") { Task { do { plan = try await manager.prepareArchive(entry: entry); failure = nil } catch { failure = error.localizedDescription } } }.accessibilityLabel("Preview archive").disabled(!loaded || !entry.editable || truncated || text != original)
                    Button("Preview changes") { Task { do { plan = try await manager.prepare(entry: entry, text: text); failure = nil } catch { failure = error.localizedDescription } } }.accessibilityLabel("Preview changes").disabled(!loaded || !entry.editable || truncated || text == original)
                }
            }
        }.padding(28).frame(width: 680, height: 640)
        .contextTheme(DaddyTheme.palette)
        .buttonStyle(SMMacButtonStyle())
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
            Text("Memory edit history").font(DaddyTheme.heading(24))
            Text("Restore only succeeds while the saved result is unchanged. Newer work is preserved.").foregroundStyle(DaddyTheme.muted)
            if let failure { Text(failure).foregroundStyle(DaddyTheme.amber) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if receipts.isEmpty { Text("No document edits yet.") }
                    ForEach(receipts) { receipt in
                        Text(receipt.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text("\(receipt.date.formatted()) · \(receipt.restored ? "Restored" : receipt.completed ? (receipt.archived == true ? "Archived" : "Applied") : "Interrupted · inspect recovery")").font(.caption)
                        if !receipt.restored { Button("Restore previous document") { restoring = receipt.id }.accessibilityLabel("Restore previous document").disabled(restoring != nil) }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }.accessibilityLabel("Done").keyboardShortcut(.cancelAction)
        }.padding(28).frame(width: 620, height: 520)
        .contextTheme(DaddyTheme.palette)
        .buttonStyle(SMMacButtonStyle())
        .task { await reload() }
        .confirmationDialog("Restore the previous document?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            if let id = restoring {
                Button("Restore") { restoring = nil; Task { do { try await ContextUpdateActivity.perform { try await manager.restore(id) }; changed(); await reload() } catch { failure = error.localizedDescription } } }.accessibilityLabel("Restore")
            }
            Button("Cancel", role: .cancel) { restoring = nil }.accessibilityLabel("Cancel")
        }
    }
    private func reload() async { do { receipts = try await manager.history() } catch { failure = error.localizedDescription } }
}
