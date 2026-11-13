import ContextCore
import SwiftUI
import SaaSMakerUI

struct SourceInventoryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var search = ""
    @State private var provider = "All"
    @State private var kind = "All"
    @State private var scope = "All"
    @State private var sort: AIContextFileSort = .name
    @State private var ascending = true
    @State private var expandedSource: String?
    @State private var page = 0
    @State private var previewItem: AIContextItem?

    private var filteredItems: [AIContextItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.inventory.filter { item in
            (provider == "All" || item.provider.rawValue == provider)
                && (kind == "All" || item.kind.rawValue == kind)
                && (scope == "All" || item.scope.rawValue == scope)
                && (query.isEmpty
                    || item.name.localizedCaseInsensitiveContains(query)
                    || item.path.localizedCaseInsensitiveContains(query)
                    || item.source.localizedCaseInsensitiveContains(query))
        }
    }

    private var groups: [SourceGroup] {
        Dictionary(grouping: filteredItems, by: \.source).map { source, items in
            SourceGroup(source: source, items: AIContextFileSort.sorted(items, by: sort, ascending: ascending))
        }.sorted { $0.source.localizedStandardCompare($1.source) == .orderedAscending }
    }

    private var uniquePhysicalDocuments: Int {
        Set(filteredItems.map { $0.resolvedPath ?? $0.path }).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Raw evidence",
                title: "Where context definitions live",
                subtitle: "These are discovery groups, not separate skill stores. One physical file can have several agent exposures.",
                art: .sources
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    sourceSearch
                    sourceFilters
                }
                VStack(alignment: .leading, spacing: 8) {
                    sourceSearch
                    sourceFilters
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    sortControls
                    Spacer(minLength: 8)
                    inventoryCount
                }
                VStack(alignment: .leading, spacing: 8) {
                    sortControls
                    inventoryCount
                }
            }
            if model.isLoading {
                RefreshContinuityBanner(started: model.loadStarted, hasPreviousResults: model.discoveryReport != nil)
            }
                LazyVStack(spacing: 9) {
                    ForEach(Array(groups.dropFirst(page * 8).prefix(8))) { group in
                        Panel {
                            VStack(spacing: 0) {
                                Button {
                                    expandedSource = expandedSource == group.id ? nil : group.id
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: expandedSource == group.id ? "chevron.down" : "chevron.right")
                                            .font(.caption.weight(.bold)).foregroundStyle(DaddyTheme.muted)
                                        Image(systemName: "shippingbox.fill").foregroundStyle(DaddyTheme.blue)
                                        Text(group.source).font(.headline)
                                        Spacer()
                                        Text("\(group.items.count.formatted()) exposures").font(.caption).foregroundStyle(DaddyTheme.muted)
                                        Text(ByteCountFormatter.string(fromByteCount: group.logicalBytes, countStyle: .file))
                                            .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(group.source), \(group.items.count) exposures")
                                .accessibilityValue(expandedSource == group.id ? "Expanded" : "Collapsed")
                                if expandedSource == group.id {
                                    Divider().overlay(DaddyTheme.line).padding(.top, 12)
                                    PaginatedContextFiles(items: group.items) { previewItem = $0 }
                                }
                            }
                        }
                    }
                    if groups.isEmpty {
                        ContentUnavailableView(
                            model.isLoading ? "Discovering sources…" : "No matching sources",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Change the filters or add a custom discovery root in Diagnostics.")
                        ).padding(.top, 60)
                    }
                }
                ContextPagination(page: $page, total: groups.count, pageSize: 8, noun: "sources")
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: search) { _, _ in resetPage() }
        .onChange(of: provider) { _, _ in resetPage() }
        .onChange(of: kind) { _, _ in resetPage() }
        .onChange(of: scope) { _, _ in resetPage() }
        .onChange(of: sort) { _, _ in resetPage() }
        .onChange(of: ascending) { _, _ in resetPage() }
        .onChange(of: page) { _, _ in expandedSource = nil }
        .onChange(of: groups.count) { _, count in
            page = min(page, max(0, (count - 1) / 8))
        }
        .sheet(item: $previewItem) { ContextDocumentPreviewSheet(item: $0) }
    }

    private func resetPage() { page = 0; expandedSource = nil }

    private var sourceSearch: some View {
        SMSearchField("Search files, paths, or sources", text: $search).frame(minWidth: 240, maxWidth: 360)
    }

    private var sourceFilters: some View {
        HStack(spacing: 8) {
            ContextChoiceMenu(
                title: "Agent",
                selection: $provider,
                choices: [ContextChoice("All", "All")]
                    + AIContextProvider.allCases.map { ContextChoice($0.rawValue, $0.rawValue) },
                width: 140
            )
            ContextChoiceMenu(
                title: "Kind",
                selection: $kind,
                choices: [ContextChoice("All", "All")]
                    + AIContextKind.allCases.map { ContextChoice($0.rawValue, $0.rawValue) },
                width: 135
            )
            ContextChoiceMenu(
                title: "Scope",
                selection: $scope,
                choices: [ContextChoice("All", "All")]
                    + AIContextScope.allCases.map { ContextChoice($0.rawValue, $0.rawValue) },
                width: 135
            )
        }
    }

    private var sortControls: some View {
        HStack(spacing: 8) {
            ContextChoiceMenu(
                title: "Sort",
                selection: $sort,
                choices: AIContextFileSort.allCases.map { ContextChoice($0, $0.rawValue) },
                width: 155
            )
            Button { ascending.toggle() } label: {
                Label(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down")
            }
        }
    }

    private var inventoryCount: some View {
        Text("\(filteredItems.count.formatted()) exposures · \(uniquePhysicalDocuments.formatted()) physical files · \(groups.count.formatted()) source groups")
            .font(.caption).foregroundStyle(DaddyTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .help("Physical-file counts collapse resolved links. Cached versions remain separate.")
    }
}

private struct SourceGroup: Identifiable {
    let source: String
    let items: [AIContextItem]
    var id: String { source }
    var logicalBytes: Int64 { items.reduce(0) { $0 + $1.logicalBytes } }
}
