import Foundation

public enum AIContextProjectLocationScope: String, Sendable, CaseIterable {
    case project = "Project"
    case inherited = "Inherited"
    case global = "Global"
    case installed = "Installed"
}

public struct AIContextProjectLocation: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let name: String
    public let scope: AIContextProjectLocationScope
    public let items: [AIContextItem]
    public let providers: [AIContextProvider]
    public let logicalBytes: Int64
}

public struct AIContextProject: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let name: String
    public let locations: [AIContextProjectLocation]
    public let projectItemCount: Int
    public let projectLogicalBytes: Int64
    public let providers: [AIContextProvider]
}

public enum AIContextProjectCatalog {
    /// Scoped estimates for real agents, excluding installed-only cache evidence.
    public static func agentLoads(in directory: String, rankings: [AIContextFolderRanking]) -> [AIContextFolderRanking] {
        let agents: Set<AIContextProvider> = [.codex, .claude, .cursor, .gemini]
        return rankings.filter {
            $0.path == directory && agents.contains($0.provider)
                && $0.sources.contains { $0.origin != .installedOnly }
        }.sorted {
            $0.instructionBytes == $1.instructionBytes
                ? $0.provider.rawValue < $1.provider.rawValue
                : $0.instructionBytes > $1.instructionBytes
        }
    }

    public static func projects(from report: AIContextDiscoveryReport) -> [AIContextProject] {
        let paths = Set(report.folderRankings.map(\.path))
        let ownedInventory = Dictionary(grouping: report.items.filter { $0.scope == .project && $0.applicability != .installedOnly }) {
            projectOwner(for: $0, locationPath: storageLocation(for: $0))
        }
        // A file reached through a Claude @import is also visible to Claude, even when
        // inventory attributes the file itself to another agent (for example AGENTS.md).
        var importingProviders: [String: Set<AIContextProvider>] = [:]
        for ranking in report.folderRankings {
            for contribution in ranking.sources where contribution.item.source.hasPrefix(InstructionImports.sourcePrefix) {
                importingProviders[contribution.item.path, default: []].insert(ranking.provider)
            }
        }
        return paths.map { projectPath in
            let rankings = report.folderRankings.filter { $0.path == projectPath }
            var contributionsByPath: [String: AIContextContribution] = [:]
            for contribution in rankings.flatMap(\.sources) where contribution.item.scope != .global && contribution.origin != .installedOnly {
                let key = contribution.item.path
                if let existing = contributionsByPath[key] {
                    contributionsByPath[key] = preferred(existing, contribution)
                } else {
                    contributionsByPath[key] = contribution
                }
            }

            // Rankings deduplicate physical skills for prompt estimates. The location
            // browser must retain every local alias from the original inventory.
            for item in ownedInventory[projectPath] ?? [] {
                contributionsByPath[item.path] = AIContextContribution(item: item, origin: item.applicability == .inherited ? .local : item.applicability)
            }
            let projectContributions = contributionsByPath.values.filter {
                $0.origin != .installedOnly && $0.item.scope != .global
            }
            let grouped = Dictionary(grouping: projectContributions) { contribution in
                let locationPath = storageLocation(for: contribution.item)
                let scope = locationScope(for: contribution, projectPath: projectPath, locationPath: locationPath)
                return LocationKey(path: locationPath, scope: scope)
            }
            let locations = grouped.map { key, values in
                let items = values.map(\.item).sorted(by: itemOrder)
                let providers = sortedProviders(Set(items.map(\.provider)).union(items.flatMap { importingProviders[$0.path] ?? [] }))
                return AIContextProjectLocation(
                    id: key.scope.rawValue + ":" + key.path,
                    path: key.path,
                    name: URL(fileURLWithPath: key.path).lastPathComponent,
                    scope: key.scope,
                    items: items,
                    providers: providers,
                    logicalBytes: items.reduce(0) { $0 + $1.logicalBytes }
                )
            }.sorted(by: locationOrder)
            let owned = locations.filter { $0.scope == .project }
            var providers = Set(owned.flatMap(\.providers))
            if providers.contains(.agents) { providers.insert(.codex) }
            return AIContextProject(
                id: projectPath,
                path: projectPath,
                name: URL(fileURLWithPath: projectPath).lastPathComponent,
                locations: locations,
                projectItemCount: owned.reduce(0) { $0 + $1.items.count },
                projectLogicalBytes: owned.reduce(0) { $0 + $1.logicalBytes },
                providers: sortedProviders(providers)
            )
        }.filter { $0.projectItemCount > 0 }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
    }

    private struct LocationKey: Hashable {
        let path: String
        let scope: AIContextProjectLocationScope
    }

    private static func preferred(_ left: AIContextContribution, _ right: AIContextContribution) -> AIContextContribution {
        let order: [AIContextOrigin: Int] = [.local: 0, .inherited: 1, .conditional: 2, .global: 3, .installedOnly: 4]
        return (order[left.origin] ?? 9) <= (order[right.origin] ?? 9) ? left : right
    }

    private static func storageLocation(for item: AIContextItem) -> String {
        let markers = [
            "/.codex/plugins/cache/", "/.claude/plugins/cache/",
            "/.agents/skills/", "/.codex/skills/", "/.claude/skills/",
            "/.claude/rules/", "/.codex/agents/", "/.claude/agents/", "/.cursor/rules/",
        ]
        for marker in markers {
            if let range = item.path.range(of: marker) {
                return String(item.path[..<range.upperBound]).dropLast().description
            }
        }
        return URL(fileURLWithPath: item.path).deletingLastPathComponent().path
    }

    private static func locationScope(
        for contribution: AIContextContribution,
        projectPath: String,
        locationPath: String
    ) -> AIContextProjectLocationScope {
        if contribution.origin == .installedOnly { return .installed }
        if contribution.item.scope == .global { return .global }
        let owner = projectOwner(for: contribution.item, locationPath: locationPath)
        return owner == projectPath ? .project : .inherited
    }

    private static func projectOwner(for item: AIContextItem, locationPath: String) -> String {
        if item.kind == .skill || item.kind == .rule || item.kind == .agentDefinition {
            for marker in ["/.agents/skills/", "/.codex/skills/", "/.claude/skills/", "/.claude/rules/", "/.codex/agents/", "/.claude/agents/", "/.cursor/rules/"] {
                if let range = item.path.range(of: marker) { return String(item.path[..<range.lowerBound]) }
            }
            return locationPath
        }
        if item.path.hasSuffix("/.claude/CLAUDE.md") {
            return URL(fileURLWithPath: item.path).deletingLastPathComponent().deletingLastPathComponent().path
        }
        return URL(fileURLWithPath: item.path).deletingLastPathComponent().path
    }

    private static func sortedProviders(_ providers: Set<AIContextProvider>) -> [AIContextProvider] {
        providers.sorted { $0.rawValue < $1.rawValue }
    }

    private static func itemOrder(_ left: AIContextItem, _ right: AIContextItem) -> Bool {
        let comparison = left.name.localizedStandardCompare(right.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        if left.path != right.path { return left.path < right.path }
        return left.provider.rawValue < right.provider.rawValue
    }

    private static func locationOrder(_ left: AIContextProjectLocation, _ right: AIContextProjectLocation) -> Bool {
        let scopeOrder: [AIContextProjectLocationScope: Int] = [.project: 0, .inherited: 1, .global: 2, .installed: 3]
        let leftScope = scopeOrder[left.scope] ?? 9, rightScope = scopeOrder[right.scope] ?? 9
        return leftScope == rightScope ? left.path < right.path : leftScope < rightScope
    }
}
