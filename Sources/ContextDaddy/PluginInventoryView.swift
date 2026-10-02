import AppKit
import ContextCore
import SwiftUI

struct PluginInventoryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("skillWorkingFolder") private var folder = ""
    @State private var snapshot: PluginInventorySnapshot?
    @State private var query = ""
    @State private var owner: AgentRuntime?
    @State private var reviewOnly = false
    @State private var selected: String?
    @State private var page = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var historyOpen = false
    @State private var actionManager = PluginActionManager()
    @State private var manage: PluginInventoryEntry?
    @State private var revision = 0
    private let fixture: PluginInventorySnapshot?

    init(snapshot: PluginInventorySnapshot? = nil, defaults: UserDefaults? = nil) {
        fixture = snapshot
        _snapshot = State(initialValue: snapshot)
        _folder = AppStorage(wrappedValue: "", "skillWorkingFolder", store: defaults)
    }
    private var matches: [PluginInventoryEntry] {
        (snapshot?.entries ?? []).filter {
            (owner == nil || $0.owner == owner) &&
            (!reviewOnly || $0.versions.count > 1 || !$0.localMatches.isEmpty || $0.versions.isEmpty) &&
            (query.isEmpty || ($0.name + " " + $0.marketplace + " " + $0.summary + " " + $0.owner.rawValue).localizedCaseInsensitiveContains(query))
        }
    }
    private var pageCount: Int { max(1, (matches.count + 7) / 8) }
    private var visible: [PluginInventoryEntry] { Array(matches.dropFirst(min(page, pageCount - 1) * 8).prefix(8)) }
    private var selection: PluginInventoryEntry? { matches.first { $0.id == selected } ?? visible.first }

    var body: some View {
        GeometryReader { geometry in
            let bar = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            let width = max(0, geometry.size.width - bar - 44)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        scope
                        if let snapshot { summary(snapshot) }
                        if loading { ProgressView("Reading plugin owners, versions and settings…") }
                        if let failure { Text(failure).foregroundStyle(DaddyTheme.coral) }
                        if let notice { Text(notice).foregroundStyle(DaddyTheme.mint).font(.callout) }
                        filters
                        if matches.isEmpty && !loading {
                            ContentUnavailableView(owner == .cursor || owner == .devin || owner == .grok ? "Plugin inventory unavailable" : "No plugins found for this view", systemImage: "puzzlepiece.extension",
                                description: Text(owner == .cursor || owner == .devin || owner == .grok ? "This agent’s plugin inventory is not supported yet. This is not evidence that it has no plugins." : "Try another search or inspect scan coverage below."))
                        } else if width >= 1050 {
                            HStack(alignment: .top, spacing: 20) {
                                ledger.frame(width: width - 390)
                                if let selection { inspector(selection).frame(width: 370).id("plugin-details") }
                            }
                        } else {
                            ledger
                            if let selection { inspector(selection).id("plugin-details") }
                        }
                        if let snapshot {
                            DisclosureGroup("Scan coverage & evidence") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Checked \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                    ForEach(snapshot.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(DaddyTheme.amber) }
                                    ForEach(snapshot.checkedSources, id: \.self) { path($0) }
                                }.padding(.top, 10)
                            }
                        }
                    }.padding(22).frame(width: width + 44, alignment: .leading)
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .onChange(of: selected) { _, value in if value != nil && width < 1050 { proxy.scrollTo("plugin-details", anchor: .top) } }
            }
        }
        .task(id: folder + "#" + String(revision)) { await refresh() }
        .onChange(of: query) { _, _ in page = 0; selected = nil }
        .onChange(of: owner) { _, _ in page = 0; selected = nil }
        .onChange(of: reviewOnly) { _, _ in page = 0; selected = nil }
        .sheet(item: $manage) { entry in PluginActionSheet(entry: entry, manager: actionManager) { revision += 1 } }
        .sheet(isPresented: $historyOpen) { PluginHistorySheet(manager: actionManager) }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack { titles; Spacer(); headerActions }
            VStack(alignment: .leading, spacing: 12) { titles; headerActions }
        }
    }
    private var titles: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Plugins").font(.title2.bold())
            Text("Understand what each plugin adds. Review what you can remove.").font(.callout).foregroundStyle(DaddyTheme.muted)
        }
    }
    private var headerActions: some View {
        HStack {
            Button("History") { historyOpen = true }
            Button("Local skills") { model.skillsMode = .library }
            Button("Recheck") { revision += 1 }.disabled(loading)
        }
    }
    private var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { folderMenu; Text(folder.isEmpty ? "User settings" : folder).font(.caption.monospaced()) }
                VStack(alignment: .leading) { folderMenu; Text(folder.isEmpty ? "User settings" : folder).font(.caption.monospaced()) }
            }
            Text("Default Codex and Claude caches. Folder selection adds ancestor and local settings; explicit settings do not prove live loading.")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }
    private var folderMenu: some View {
        Menu("Folder") {
            Button("User settings only") { folder = "" }
            Button("Choose folder…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = false; panel.message = "Inspect plugin settings for this folder"
                if panel.runModal() == .OK, let url = panel.url { folder = url.path }
            }
            ForEach(Array(model.projects.prefix(20))) { project in Button(project.name) { folder = project.path } }
        }
    }
    private func summary(_ snapshot: PluginInventorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PluginCountCopy.summary(snapshot))
                .font(.headline)
            Text(PluginCountCopy.references(snapshot))
                .font(.callout).foregroundStyle(DaddyTheme.muted)
            Text("Unreferenced does not mean safe to delete. Plugin managers own installation and removal.")
                .font(.caption).foregroundStyle(DaddyTheme.amber)
            if snapshot.isPartial { Text("Partial scan · inspect coverage below before relying on these counts.").font(.caption).foregroundStyle(DaddyTheme.amber) }
        }
    }
    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search plugins, marketplaces or capabilities", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search plugins")
            ViewThatFits(in: .horizontal) {
                HStack { ownerPicker; Toggle("Repeated versions or local overlap", isOn: $reviewOnly).toggleStyle(.checkbox) }
                VStack(alignment: .leading) { ownerPicker; Toggle("Repeated versions or local overlap", isOn: $reviewOnly).toggleStyle(.checkbox) }
            }
        }
    }
    private var ownerPicker: some View {
        Picker("Agent", selection: $owner) {
            Text("All agents").tag(AgentRuntime?.none)
            ForEach(AgentRuntime.allCases) { Text($0.rawValue).tag(Optional($0)) }
        }.frame(maxWidth: 250)
    }
    private var ledger: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(PluginCountCopy.ledger(matches.count)).font(.caption).foregroundStyle(DaddyTheme.muted).padding(.bottom, 12)
                ForEach(visible) { entry in
                    Button {
                        selected = entry.id
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top) {
                                Text(entry.name).font(.headline).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(PluginCountCopy.count(entry.versions.count, "version")).font(.caption).foregroundStyle(DaddyTheme.mint)
                            }
                            Text("\(entry.owner.rawValue) · \(entry.marketplace)").font(.caption).foregroundStyle(DaddyTheme.muted)
                            Text("\(PluginCountCopy.count(entry.skillNames.count, "skill name")) · \(size(entry.bytes, complete: entry.sizeComplete))")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                            Text(entry.settingLabel).font(.caption).foregroundStyle(entry.preferences.isEmpty ? DaddyTheme.amber : DaddyTheme.muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selection?.id == entry.id ? DaddyTheme.mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Inspect \(entry.name) for \(entry.owner.rawValue)")
                    Divider().padding(.vertical, 3)
                }
                HStack {
                    Button("Previous") { page -= 1; selected = nil }.disabled(page == 0)
                    Spacer()
                    Text("\(min(page + 1, pageCount)) / \(pageCount)").font(.caption)
                    Spacer()
                    Button("Next") { page += 1; selected = nil }.disabled(page + 1 >= pageCount)
                }.padding(.top, 12)
            }
        }
    }
    private func inspector(_ entry: PluginInventoryEntry) -> some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.name).font(.title2.bold())
                Text("\(entry.owner.rawValue) · \(entry.marketplace)").font(.caption).foregroundStyle(DaddyTheme.mint)
                if !entry.summary.isEmpty { Text(entry.summary).font(.callout).foregroundStyle(DaddyTheme.muted) }
                Divider()
                Text(entry.reviewReason).font(.headline)
                Text(entry.registryVerified ? "Installation references checked against Claude’s local registry." : "Current installation is not verified. Cached versions alone cannot establish it.")
                    .font(.callout).foregroundStyle(DaddyTheme.muted)
                Button("Manage plugin…") { manage = entry }
                DisclosureGroup("Agent access & settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if entry.registrations.isEmpty { Text("No verified installation scope.") }
                        ForEach(entry.registrations) { registration in
                            Text("Registered · \(registration.scope.capitalized)").font(.headline)
                            if let project = registration.project { path(project) }
                            path(registration.path)
                        }
                        if entry.preferences.isEmpty { Text("No supported explicit enablement setting found in the checked files.").foregroundStyle(DaddyTheme.amber) }
                        ForEach(entry.preferences) { preference in
                            Text(preference.enabled ? "Explicitly enabled" : "Explicitly disabled").font(.headline)
                            path(preference.path)
                        }
                        Text("These are individual declarations. Managed policy, trust, profiles and launch overrides can change the effective result. Observed invocation is unavailable.").foregroundStyle(DaddyTheme.muted)
                    }.font(.callout).padding(.top, 10)
                }
                DisclosureGroup("Versions (\(entry.versions.count))") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(entry.versions) { version in
                            Text(version.version).font(.headline.monospaced())
                            Text(versionState(version, entry: entry)).font(.caption).foregroundStyle(DaddyTheme.amber)
                            Text("\(size(version.bytes, complete: version.sizeComplete)) · \(PluginCountCopy.count(version.skillNames.count, "skill file"))").font(.caption)
                            if let date = version.modified { Text("Folder modified \(date.formatted(date: .abbreviated, time: .omitted)) · not last use").font(.caption).foregroundStyle(DaddyTheme.muted) }
                            path(version.path)
                            Divider()
                        }
                    }.padding(.top, 10)
                }
                DisclosureGroup("Included capabilities") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(PluginCountCopy.capabilities(entry.skillNames.count)).font(.caption).foregroundStyle(DaddyTheme.muted)
                        ForEach(entry.skillNames, id: \.self) { Text($0).font(.callout) }
                        let components = Array(Set(entry.versions.flatMap(\.components))).sorted()
                        if !components.isEmpty { Text("Also found: " + components.joined(separator: ", ")).font(.callout) }
                        if entry.skillNames.isEmpty { Text("No skill files discovered. This plugin may provide tools or other capabilities.").font(.callout) }
                    }.padding(.top, 10)
                }
                if !entry.localMatches.isEmpty {
                    DisclosureGroup("Matching local instructions (\(entry.localMatches.count))") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SKILL.md bytes match. Support files and invocation rules can still differ; this is not a safe-merge decision.").font(.caption).foregroundStyle(DaddyTheme.amber)
                            ForEach(entry.localMatches, id: \.self) { path($0) }
                        }.padding(.top, 10)
                    }
                }
            }.textSelection(.enabled)
        }
    }
    private func versionState(_ version: PluginCacheVersion, entry: PluginInventoryEntry) -> String {
        guard entry.registryVerified else { return "Installation reference unverified" }
        return entry.isReferenced(version) ? "Referenced by installation registry" : "Not referenced by checked registry · review with owner"
    }
    private func path(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/"))
                .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)]) } label: { Image(systemName: "folder") }
                .help("Reveal in Finder").accessibilityLabel("Reveal \(URL(fileURLWithPath: value).lastPathComponent) in Finder")
        }
    }
    private func size(_ bytes: Int64, complete: Bool) -> String {
        (complete ? "" : "At least ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func refresh() async {
        guard fixture == nil else { return }
        loading = true; failure = nil
        let previous = snapshot
        let local = model.catalog?.records ?? []
        let target = folder.isEmpty ? nil : URL(fileURLWithPath: folder)
        let job = Task.detached(priority: .userInitiated) { try PluginInventory.scan(folder: target, localSkills: local) }
        do {
            let value = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            try Task.checkCancellation()
            snapshot = value
            if let previous {
                notice = previous.entries == value.entries ? "Rechecked. No changes detected in the inspected plugin evidence."
                    : "Rechecked. Plugin evidence changed; the list now shows the current snapshot."
            }
        } catch is CancellationError { return }
        catch { failure = "Plugin scan could not finish. Recheck when directory access is available." }
        loading = false
    }
}

// Shared by the actual view and fixture assertions; no layout or state behavior.
enum PluginCountCopy {
    static func count(_ value: Int, _ singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
    static func summary(_ snapshot: PluginInventorySnapshot) -> String {
        "\(count(snapshot.entries.count, "plugin")) found · \(snapshot.versionCount) cached \(snapshot.versionCount == 1 ? "version" : "versions")"
    }
    static func references(_ snapshot: PluginInventorySnapshot) -> String {
        "\(snapshot.repeatedPluginCount) \(snapshot.repeatedPluginCount == 1 ? "plugin has" : "plugins have") multiple versions · \(snapshot.unreferencedVersionCount) \(snapshot.unreferencedVersionCount == 1 ? "version is" : "versions are") not referenced by the checked Claude registry"
    }
    static func ledger(_ count: Int) -> String {
        "\(self.count(count, "plugin")) · grouped by owner and marketplace"
    }
    static func capabilities(_ count: Int) -> String {
        "\(count) unique skill directory \(count == 1 ? "name" : "names") across cached versions. Files and declared components do not prove runtime activation."
    }
}
