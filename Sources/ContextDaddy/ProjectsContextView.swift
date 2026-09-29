import AppKit
import ContextCore
import SwiftUI

private enum ProjectSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case files = "Files"
    case size = "Context size"
    var id: String { rawValue }
}

struct ProjectsContextView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var search = ""
    @State private var provider = "All agents"
    @State private var sort: ProjectSort = .files
    @State private var ascending = false
    @State private var page = 0
    @State private var selectedProjectID: String?
    @State private var previewItem: AIContextItem?
    private let pageSize = 12

    private var rows: [AIContextProject] {
        model.projects.filter { project in
            let providerMatch = provider == "All agents" || project.providers.contains { $0.rawValue == provider }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatch = query.isEmpty || project.path.localizedCaseInsensitiveContains(query)
                || project.providers.contains { $0.rawValue.localizedCaseInsensitiveContains(query) }
                || project.locations.contains { location in
                    location.path.localizedCaseInsensitiveContains(query)
                    || location.items.contains { $0.name.localizedCaseInsensitiveContains(query) }
                }
            return providerMatch && textMatch
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = left.name.localizedStandardCompare(right.name)
            case .files: comparison = compare(Int64(left.projectItemCount), Int64(right.projectItemCount))
            case .size: comparison = compare(left.projectLogicalBytes, right.projectLogicalBytes)
            }
            if comparison == .orderedSame { return left.path < right.path }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private var visibleRows: [AIContextProject] {
        Array(rows.dropFirst(page * pageSize).prefix(pageSize))
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Project context",
                title: "Instructions and skills by project",
                subtitle: "These files were discovered for each project. Availability does not mean they were loaded into a live prompt.",
                art: .projects
            )
            HStack(spacing: 12) {
                Button("Choose folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                    .buttonStyle(ContextDaddyButtonStyle())
                if !search.isEmpty {
                    Button("Clear search") { search = "" }
                        .buttonStyle(ContextDaddyButtonStyle())
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    projectSearch
                    projectFilters
                    Spacer(minLength: 8)
                    projectCount
                }
                VStack(alignment: .leading, spacing: 8) {
                    projectSearch
                    HStack(spacing: 10) {
                        projectFilters
                        Spacer(minLength: 8)
                        projectCount
                    }
                }
            }
            if model.isLoading {
                RefreshContinuityBanner(started: model.loadStarted, hasPreviousResults: model.discoveryReport != nil)
            }
                LazyVStack(spacing: 9) {
                    ForEach(visibleRows) { project in
                        ProjectRow(
                            project: project,
                            loads: AIContextProjectCatalog.agentLoads(in: project.path, rankings: model.folderRankings),
                            expanded: selectedProjectID == project.id,
                            toggle: { selectedProjectID = selectedProjectID == project.id ? nil : project.id },
                            preview: { previewItem = $0 }
                        )
                    }
                    if rows.isEmpty {
                        ContentUnavailableView(
                            model.isLoading ? "Finding project context…" : "No matching project context",
                            systemImage: "folder.badge.questionmark",
                            description: Text(model.isLoading ? "Previous results will stay visible during later refreshes." : "Choose a folder above or change the search and agent filter. Folders without project-owned context files do not appear in this list.")
                        ).padding(.top, 60)
                    }
                }
                .id("project-results")
                ContextPagination(page: $page, total: rows.count, pageSize: pageSize, noun: "projects")
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: page) { _, _ in
            selectedProjectID = nil
            withAnimation(.easeInOut(duration: 0.15)) { scroll.scrollTo("project-results", anchor: .top) }
        }
        }
        .onChange(of: search) { _, _ in resetPage() }
        .onChange(of: provider) { _, _ in resetPage() }
        .onChange(of: sort) { _, _ in resetPage() }
        .onChange(of: ascending) { _, _ in resetPage() }
        .onChange(of: model.projects.count) { _, _ in resetPage() }
        .sheet(item: $previewItem) { ContextDocumentPreviewSheet(item: $0) }
    }

    private func resetPage() { page = 0; selectedProjectID = nil }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect folder"
        panel.message = "Choose a project folder to discover its instructions and skills."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let path = folder.resolvingSymlinksInPath().path
        provider = "All agents"
        search = path
        page = 0
        model.addExtraRoots([folder])
        Task {
            await model.refresh()
            // Do not replace a newer search made while discovery was running.
            if search == path { selectedProjectID = path }
        }
    }
    private func compare(_ a: Int64, _ b: Int64) -> ComparisonResult { a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending) }

    private var projectSearch: some View {
        TextField("Search projects, files, or paths", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240, maxWidth: 380)
    }

    private var projectFilters: some View {
        HStack(spacing: 8) {
            ContextChoiceMenu(
                title: "Agent",
                selection: $provider,
                choices: [ContextChoice("All agents", "All agents")]
                    + AIContextProvider.allCases.filter { $0 != .project }.map { ContextChoice($0.rawValue, $0.rawValue) },
                width: 145
            )
            ContextChoiceMenu(
                title: "Sort",
                selection: $sort,
                choices: ProjectSort.allCases.map { ContextChoice($0, $0.rawValue) },
                width: 145
            )
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(DaddyTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DaddyTheme.line))
            .help(ascending ? "Ascending" : "Descending")
            .accessibilityLabel(ascending ? "Sort ascending" : "Sort descending")
        }
    }

    private var projectCount: some View {
        Text("\(rows.count.formatted()) matching projects")
            .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize()
    }
}

private struct ProjectRow: View {
    let project: AIContextProject
    let loads: [AIContextFolderRanking]
    let expanded: Bool
    let toggle: () -> Void
    let preview: (AIContextItem) -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: toggle) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold)).foregroundStyle(DaddyTheme.muted).frame(width: 12)
                        Image(systemName: "folder.fill").foregroundStyle(DaddyTheme.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name).font(.headline)
                            Text(project.path).font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) {
                                providerNames
                                projectSize
                            }
                            projectSize
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)

                if expanded {
                    Divider().overlay(DaddyTheme.line)
                    ProjectDetail(project: project, loads: loads, preview: preview)
                }
            }
        }
    }

    private var providerNames: some View {
        Text(project.providers.map(\.rawValue).joined(separator: " · "))
            .font(.caption).foregroundStyle(DaddyTheme.blue).fixedSize()
    }

    private var projectSize: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(project.projectItemCount.formatted()) files found").font(.subheadline.weight(.semibold))
            Text(ByteCountFormatter.string(fromByteCount: project.projectLogicalBytes, countStyle: .file))
                .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
        }
        .fixedSize()
    }
}

private struct ProjectDetail: View {
    let project: AIContextProject
    let loads: [AIContextFolderRanking]
    let preview: (AIContextItem) -> Void
    @State private var expandedLocation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent startup estimates").font(.headline)
            if loads.isEmpty {
                Text("No agent-specific instruction estimate is available for this directory.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(loads) { AgentLoadCard(load: $0) }
                }
            }
            Text("Estimates use four bytes per token and exclude skill bodies, which usually load on demand. Rules, tools, memory, and conversation history can add more; this is not a live prompt measurement.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Attributed locations").font(.headline)
            ForEach(project.locations) { location in
                VStack(spacing: 0) {
                    Button {
                        expandedLocation = expandedLocation == location.id ? nil : location.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: expandedLocation == location.id ? "chevron.down" : "chevron.right")
                                .font(.caption).frame(width: 12)
                            Text(location.scope.rawValue).font(.caption2.weight(.bold)).foregroundStyle(DaddyTheme.color(for: location.scope))
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(location.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(location.providers.map(\.rawValue).joined(separator: " · ")).font(.caption2).foregroundStyle(DaddyTheme.muted)
                            }
                            Spacer()
                            Text("\(location.items.count) files").font(.caption)
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expandedLocation == location.id {
                        Divider().overlay(DaddyTheme.line)
                        ForEach(location.items) { item in
                            ContextFileRow(item: item, preview: preview)
                            if item.id != location.items.last?.id { Divider().overlay(DaddyTheme.line) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(DaddyTheme.raised.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct AgentLoadCard: View {
    let load: AIContextFolderRanking

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(load.provider.rawValue).font(.subheadline.weight(.semibold))
                Spacer()
                Text(load.pressure.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(DaddyTheme.color(for: load.pressure))
            }
            Text(load.automaticInstructionSourceCount == 0 ? "Not measured" : tokens(load.estimatedStartupTokens))
                .font(.title3.bold()).monospacedDigit().foregroundStyle(DaddyTheme.color(for: load.pressure))
            contribution("Global", load.globalBytes)
            contribution("Parent folders", load.inheritedBytes)
            contribution("This directory", load.localBytes)
            Divider().overlay(DaddyTheme.line)
            HStack { Text("Available skills"); Spacer(); Text(load.skillCount.formatted()).monospacedDigit() }
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(DaddyTheme.raised).clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func contribution(_ label: String, _ bytes: Int64) -> some View {
        HStack { Text(label); Spacer(); Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).monospacedDigit() }
            .font(.caption2).foregroundStyle(DaddyTheme.muted)
    }

    private func tokens(_ value: Int) -> String {
        value >= 1_000 ? "≈ \(String(format: "%.1fK", Double(value) / 1_000)) tokens" : "≈ \(value.formatted()) tokens"
    }
}

struct RefreshContinuityBanner: View {
    let started: Date
    let hasPreviousResults: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(DaddyTheme.mint)
            Text(hasPreviousResults ? "Refreshing · previous results remain available" : "Discovering local agent context")
                .font(.caption.weight(.semibold))
            Spacer()
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text("\(max(0, Int(context.date.timeIntervalSince(started)))) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
            }
        }
        .padding(10).background(DaddyTheme.mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private extension DaddyTheme {
    static func color(for scope: AIContextProjectLocationScope) -> Color {
        switch scope {
        case .project: mint
        case .inherited: blue
        case .global: amber
        case .installed: muted
        }
    }
}
