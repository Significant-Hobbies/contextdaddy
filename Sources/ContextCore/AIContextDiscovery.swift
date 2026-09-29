import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Metadata-only, bounded discovery of well-known agent context locations.
/// It never reads instruction, skill, environment, secret, session, or config bodies.
public enum AIContextDiscovery {
    public struct Limits: Sendable, Equatable {
        public var maximumItems = 5_000
        public var maximumEntries = 100_000
        public var maximumProjectDepth = 4
        public var maximumSkillDepth = 12
        public var maximumPluginEntries = 20_000
        public var maximumPluginItems = 2_000
        public init() {}
    }
    public struct Configuration: Sendable, Equatable {
        public var home: URL
        public var projectRoots: [URL]
        public var additionalRoots: [URL]
        public var additionalSkillRoots: [URL]
        public var limits: Limits
        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    projectRoots: [URL]? = nil, additionalRoots: [URL] = [], additionalSkillRoots: [URL] = [], limits: Limits = .init()) {
            self.home = home.standardizedFileURL
            self.projectRoots = projectRoots ?? ["Desktop", "Documents", "Developer", "Projects", "Code", "src"].map { home.appendingPathComponent($0, isDirectory: true) }
            self.additionalRoots = additionalRoots; self.additionalSkillRoots = additionalSkillRoots; self.limits = limits
        }
    }

    public static func discover(configuration: Configuration = .init()) throws -> AIContextDiscoveryReport {
        let started = Date()
        var state = State(configuration: configuration)
        try state.discoverGlobals()
        try state.discoverProjects()
        try state.discoverPlugins()
        try state.discoverSelectedSkillRoots()
        let items = state.items.values.sorted { ($0.path, $0.id) < ($1.path, $1.id) }
        let rankings = rank(items: items, roots: state.rankingRoots, home: configuration.home)
        var coverage = AIContextCoverage(roots: state.coverageRoots, visitedEntries: state.visited,
                itemLimitReached: state.itemLimitReached, entryLimitReached: state.entryLimitReached,
                unreadableCount: state.unreadable, skippedLinks: state.skippedLinks, notes: state.notes)
        coverage.projectDepthReached = state.projectDepthReached
        coverage.skillDepthReached = state.skillDepthReached
        coverage.pluginEntryLimitReached = state.pluginEntryLimitReached
        coverage.pluginItemLimitReached = state.pluginItemLimitReached
        return AIContextDiscoveryReport(items: items, folderRankings: rankings, coverage: coverage,
            elapsed: Date().timeIntervalSince(started))
    }

    /// Inspect one working directory and its ancestors, never sibling projects or caches.
    public static func discoverFolder(_ directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> AIContextDiscoveryReport {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(root) else { throw SkillManagementError(message: "Choose an existing folder.") }
        let started = Date()
        var state = State(configuration: .init(home: home, projectRoots: []))
        try state.discoverGlobals()
        var ancestor = root
        while ancestor.path != "/" {
            try Task.checkCancellation()
            // Home agent roots were already indexed with global scope.
            if ancestor != home.resolvingSymlinksInPath().standardizedFileURL {
                state.coverageRoots.append(ancestor.path)
                try state.projectMarkers(at: ancestor)
            }
            ancestor.deleteLastPathComponent()
        }
        let items = state.items.values.sorted { $0.path < $1.path }
        var coverage = AIContextCoverage(roots: state.coverageRoots, visitedEntries: state.visited,
            itemLimitReached: state.itemLimitReached, entryLimitReached: state.entryLimitReached,
            unreadableCount: state.unreadable, skippedLinks: state.skippedLinks,
            notes: state.notes + ["Targeted folder scan. Plugin activation and live prompt loading are not verified; plugin caches are excluded."])
        coverage.skillDepthReached = state.skillDepthReached
        return AIContextDiscoveryReport(items: items, folderRankings: rankings(items: items, in: root, home: home),
            coverage: coverage, elapsed: Date().timeIntervalSince(started))
    }

    public static func rankings(items: [AIContextItem], in directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, preserveSkillAliases: Bool = false) -> [AIContextFolderRanking] {
        rank(items: items, roots: [directory.resolvingSymlinksInPath().standardizedFileURL.path], home: home, deduplicateSkills: !preserveSkillAliases)
    }
}

private struct State {
    let configuration: AIContextDiscovery.Configuration
    var items: [String: AIContextItem] = [:]
    var pluginItems = 0; var pluginEntries = 0
    var visited = 0; var unreadable = 0; var skippedLinks = 0
    var itemLimitReached = false; var entryLimitReached = false
    var projectDepthReached = false; var skillDepthReached = false
    var pluginEntryLimitReached = false; var pluginItemLimitReached = false
    var coverageRoots: [String] = []; var rankingRoots: Set<String> = []
    var notes = ["Discovery indexes file metadata only. Policy resolution may separately read up to 64 KiB from skill metadata files; instruction bodies are not read."]
    init(configuration: AIContextDiscovery.Configuration) { self.configuration = configuration }

    mutating func discoverGlobals() throws {
        let home = configuration.home
        for (provider, directory, instruction) in [(.codex, ".codex", "AGENTS.md"), (.claude, ".claude", "CLAUDE.md")] as [(AIContextProvider, String, String)] {
            let root = home.appendingPathComponent(directory, isDirectory: true)
            coverageRoots.append(root.path)
            try addNamed(root.appendingPathComponent(instruction), provider: provider, scope: .global, kind: .instruction, origin: .global, source: "\(provider.rawValue) · Global instructions")
            // Codex gives AGENTS.override.md precedence. Both are inventory evidence; ranking applies override semantics.
            if provider == .codex { try addNamed(root.appendingPathComponent("AGENTS.override.md"), provider: provider, scope: .global, kind: .instruction, origin: .global, source: "Codex · Global instructions") }
            try skills(root.appendingPathComponent("skills", isDirectory: true), provider: provider, source: "\(provider.rawValue) · Personal skills", origin: .conditional)
            let agentExtension = provider == .codex ? "toml" : "md"
            try namedChildren(root.appendingPathComponent("agents", isDirectory: true), extension: agentExtension,
                              provider: provider, kind: .agentDefinition, source: "\(provider.rawValue) · Personal agents",
                              origin: .conditional, scope: .global, recursive: true)
            if provider == .claude {
                try namedChildren(root.appendingPathComponent("rules", isDirectory: true), extension: "md", provider: .claude, kind: .rule, source: "Claude · Global rules", origin: .conditional, scope: .global, recursive: true)
            }
        }
        let agents = home.appendingPathComponent(".agents", isDirectory: true)
        coverageRoots.append(agents.path)
        try skills(agents.appendingPathComponent("skills", isDirectory: true), provider: .agents, source: "Agents · Personal skills", origin: .conditional)
        let codexAdmin = URL(fileURLWithPath: "/etc/codex/skills", isDirectory: true)
        coverageRoots.append(codexAdmin.path)
        try skills(codexAdmin, provider: .codex, source: "Codex · Admin skills", origin: .conditional)
        let cursor = home.appendingPathComponent(".cursor", isDirectory: true)
        coverageRoots.append(cursor.path)
        try addNamed(home.appendingPathComponent(".cursorrules"), provider: .cursor, scope: .global, kind: .rule, origin: .conditional, source: "Cursor · Global rules")
        try namedChildren(cursor.appendingPathComponent("rules", isDirectory: true), extension: "mdc", provider: .cursor, kind: .rule, source: "Cursor · Rules", origin: .conditional, scope: .global, recursive: true)
        try skills(cursor.appendingPathComponent("skills", isDirectory: true), provider: .cursor, source: "Cursor · Personal skills", origin: .conditional)
        let grok = home.appendingPathComponent(".grok", isDirectory: true)
        coverageRoots.append(grok.path)
        try skills(grok.appendingPathComponent("skills", isDirectory: true), provider: .grok, source: "Grok · Personal skills", origin: .conditional)
        try namedChildren(grok.appendingPathComponent("agents", isDirectory: true), extension: "md", provider: .grok, kind: .agentDefinition, source: "Grok · Personal agents", origin: .conditional, scope: .global, recursive: true)
        for root in [home.appendingPathComponent(".config/devin/skills", isDirectory: true), home.appendingPathComponent(".config/cognition/skills", isDirectory: true)] {
            coverageRoots.append(root.path)
            try skills(root, provider: .devin, source: "Devin · Personal skills", origin: .conditional)
        }
        notes.append("Codex project ranking uses nearest git root through the selected folder; its default per-project instruction cap is 32 KiB, so bytes are potential evidence rather than measured loaded bytes.")
        notes.append("Claude skills and Cursor rules are conditional. Plugin caches and MCP configuration are not counted as inherited instructions.")
    }

    mutating func discoverSelectedSkillRoots() throws {
        for root in configuration.additionalSkillRoots {
            coverageRoots.append(root.standardizedFileURL.path)
            let path = root.standardizedFileURL.path + "/"
            let known: [(String, AIContextProvider)] = [("/.agents/skills/", .agents), ("/.codex/skills/", .codex),
                ("/.claude/skills/", .claude), ("/.cursor/skills/", .cursor), ("/.grok/skills/", .grok),
                ("/.config/devin/skills/", .devin), ("/.config/cognition/skills/", .devin)]
            let provider = known.first { path.contains($0.0) }?.1 ?? .project
            let global = known.contains { path.hasPrefix(configuration.home.path + $0.0) }
            try skills(root, provider: provider, source: "Added library · \(root.lastPathComponent)",
                       origin: provider == .project ? .installedOnly : .conditional, scope: global ? .global : .project)
        }
    }

    mutating func discoverPlugins() throws {
        let home = configuration.home
        for (provider, root) in [
            (AIContextProvider.codex, home.appendingPathComponent(".codex/plugins/cache", isDirectory: true)),
            (.claude, home.appendingPathComponent(".claude/plugins/cache", isDirectory: true)),
        ] {
            coverageRoots.append(root.path)
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard pluginRootIsSafe(resolvedRoot) else { skippedLinks += 1; continue }
            try skills(root, provider: provider, source: "\(provider.rawValue) · Installed plugins",
                       origin: .installedOnly, pluginRoot: resolvedRoot)
        }
    }

    mutating func discoverProjects() throws {
        let additionalPaths = Set(configuration.additionalRoots.map(\.standardizedFileURL.path))
        for root in configuration.projectRoots + configuration.additionalRoots {
            let standardized = root.standardizedFileURL
            coverageRoots.append(standardized.path)
            if additionalPaths.contains(standardized.path) {
                rankingRoots.insert(standardized.path)
                try discoverAncestorMarkers(for: standardized)
            }
            try projectWalk(standardized, depth: 0)
        }
    }

    /// A manually selected folder can inherit exact instruction markers above it even though
    /// project discovery otherwise walks downward. Inspect ancestor directories only; never
    /// enumerate their children or infer that this is the agent's actual loaded prompt.
    mutating func discoverAncestorMarkers(for selectedRoot: URL) throws {
        guard isDirectory(selectedRoot), !isSymlink(selectedRoot), let rootInfo = fileInfo(selectedRoot) else { return }
        let device = rootInfo.st_dev
        var directory = selectedRoot
        while true {
            try Task.checkCancellation()
            guard !isSymlink(directory) else { return }
            try instructionMarkers(at: directory)

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path,
                  let parentInfo = fileInfo(parent),
                  parentInfo.st_mode & S_IFMT == S_IFDIR,
                  parentInfo.st_dev == device else { return }
            directory = parent
        }
    }

    mutating func instructionMarkers(at root: URL) throws {
        let markers: [(String, AIContextProvider, AIContextKind, AIContextOrigin)] = [
            ("AGENTS.md", .codex, .instruction, .inherited), ("AGENTS.override.md", .codex, .instruction, .inherited),
            ("CLAUDE.md", .claude, .instruction, .inherited), (".claude/CLAUDE.md", .claude, .instruction, .inherited),
            ("CLAUDE.local.md", .claude, .instruction, .conditional), ("GEMINI.md", .gemini, .instruction, .conditional),
            (".cursorrules", .cursor, .rule, .conditional),
        ]
        for marker in markers {
            let url = root.appendingPathComponent(marker.0)
            if marker.0.hasPrefix(".claude/"), isSymlink(root.appendingPathComponent(".claude")) { continue }
            try addNamed(url, provider: marker.1, scope: .project,
                         kind: marker.2, origin: marker.3, source: "Project · \(root.lastPathComponent)")
        }
    }

    mutating func projectWalk(_ root: URL, depth: Int) throws {
        try Task.checkCancellation()
        guard depth <= configuration.limits.maximumProjectDepth, canVisit() else { return }
        guard isDirectory(root) else { return }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) { rankingRoots.insert(root.path) }
        try projectMarkers(at: root)
        let descendants = children(root)
        guard depth < configuration.limits.maximumProjectDepth else {
            if descendants.contains(where: { shouldWalkProjectChild($0) }) { projectDepthReached = true }
            return
        }
        for child in descendants {
            try Task.checkCancellation()
            guard canVisit() else { return }
            let lower = child.lastPathComponent.lowercased()
            if blocked.contains(lower) || generatedProjectDirectories.contains(lower) || agentProjectDirectories.contains(lower) || child.pathExtension.lowercased() == "app" { continue }
            if isSymlink(child) { skippedLinks += 1; continue }
            guard isDirectory(child) else { continue }
            try projectWalk(child, depth: depth + 1)
        }
    }

    mutating func projectMarkers(at root: URL) throws {
        let countBefore = items.count
        try instructionMarkers(at: root)
        try namedChildren(root.appendingPathComponent(".cursor/rules", isDirectory: true), extension: "mdc", provider: .cursor, kind: .rule, source: "Cursor · Project rules", origin: .conditional)
        try skills(root.appendingPathComponent(".agents/skills", isDirectory: true), provider: .agents, source: "Agents · Project skills", origin: .conditional, scope: .project)
        try skills(root.appendingPathComponent(".codex/skills", isDirectory: true), provider: .codex, source: "Codex · Project skills", origin: .conditional, scope: .project)
        try skills(root.appendingPathComponent(".claude/skills", isDirectory: true), provider: .claude, source: "Claude · Project skills", origin: .conditional, scope: .project)
        try skills(root.appendingPathComponent(".cursor/skills", isDirectory: true), provider: .cursor, source: "Cursor · Project skills", origin: .conditional, scope: .project)
        try skills(root.appendingPathComponent(".grok/skills", isDirectory: true), provider: .grok, source: "Grok · Project skills", origin: .conditional, scope: .project)
        try namedChildren(root.appendingPathComponent(".codex/agents", isDirectory: true), extension: "toml", provider: .codex, kind: .agentDefinition, source: "Codex · Project agents", origin: .conditional, recursive: true)
        try namedChildren(root.appendingPathComponent(".claude/agents", isDirectory: true), extension: "md", provider: .claude, kind: .agentDefinition, source: "Claude · Project agents", origin: .conditional, recursive: true)
        try namedChildren(root.appendingPathComponent(".claude/rules", isDirectory: true), extension: "md", provider: .claude, kind: .rule, source: "Claude · Project rules", origin: .conditional, recursive: true)
        if items.count > countBefore { rankingRoots.insert(root.path) }
    }

    mutating func skills(_ root: URL, provider: AIContextProvider, source: String, origin: AIContextOrigin, scope: AIContextScope = .global, depth: Int = 0, seen: Set<String> = [], pluginRoot: URL? = nil) throws {
        guard depth <= configuration.limits.maximumSkillDepth, visit(plugin: pluginRoot != nil) else { return }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(resolved), !isBlockedForTraversal(resolved, explicitRoot: pluginRoot), !seen.contains(resolved.path) else {
            if isSymlink(root) {
                skippedLinks += 1
                if notes.filter({ $0.hasPrefix("Broken or unreadable skill link:") }).count < 20 {
                    notes.append("Broken or unreadable skill link: \(root.path)")
                }
            }
            return
        }
        var seen = seen; seen.insert(resolved.path)
        let descendants = children(resolved)
        if depth == configuration.limits.maximumSkillDepth,
           descendants.contains(where: { isDirectory($0) || isSymlink($0) }) { skillDepthReached = true }
        for child in descendants {
            try Task.checkCancellation(); guard visit(plugin: pluginRoot != nil) else { return }
            if isBlockedForTraversal(child.resolvingSymlinksInPath().standardizedFileURL, explicitRoot: pluginRoot) { continue }
            let logicalChild = root.appendingPathComponent(child.lastPathComponent)
            if child.lastPathComponent.lowercased() == "skill.md" {
                try addSkill(logical: logicalChild, resolved: child, provider: provider, scope: scope, source: source, origin: origin, plugin: pluginRoot != nil)
            } else if pluginRoot != nil, isAgentDefinition(child) {
                try addNamed(logicalChild, resolved: child, provider: provider, scope: scope, kind: .agentDefinition, origin: origin, source: source, plugin: true)
            } else if depth < configuration.limits.maximumSkillDepth, isDirectory(child) || isSymlink(child) {
                try skills(logicalChild, provider: provider, source: source, origin: origin, scope: scope, depth: depth + 1, seen: seen, pluginRoot: pluginRoot)
            }
        }
    }

    mutating func namedChildren(_ root: URL, extension ext: String, provider: AIContextProvider, kind: AIContextKind, source: String, origin: AIContextOrigin, scope: AIContextScope = .project, recursive: Bool = false, depth: Int = 0) throws {
        guard isDirectory(root) else { return }
        for child in children(root) {
            try Task.checkCancellation(); guard canVisit() else { return }
            if child.pathExtension.lowercased() == ext { try addNamed(child, provider: provider, scope: scope, kind: kind, origin: origin, source: source) }
            else if recursive, isDirectory(child), !isSymlink(child), !isBlocked(child) {
                if depth < configuration.limits.maximumSkillDepth {
                    try namedChildren(child, extension: ext, provider: provider, kind: kind, source: source, origin: origin, scope: scope, recursive: true, depth: depth + 1)
                } else {
                    skillDepthReached = true
                }
            }
        }
    }

    mutating func addNamed(_ url: URL, provider: AIContextProvider, scope: AIContextScope, kind: AIContextKind, origin: AIContextOrigin, source: String) throws {
        try Task.checkCancellation(); guard canVisit(), !isBlocked(url), !isSymlink(url), let info = fileInfo(url) else { return }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return }
        add(item(url: url, resolved: nil, info: info, provider: provider, scope: scope, kind: kind, origin: origin, source: source))
    }
    mutating func addNamed(_ logical: URL, resolved: URL, provider: AIContextProvider, scope: AIContextScope, kind: AIContextKind, origin: AIContextOrigin, source: String, plugin: Bool) throws {
        try Task.checkCancellation(); guard !isSymlink(resolved), let info = fileInfo(resolved), (info.st_mode & S_IFMT) == S_IFREG else { return }
        add(item(url: logical, resolved: resolved.standardizedFileURL.path, info: info, provider: provider, scope: scope, kind: kind, origin: origin, source: source), plugin: plugin)
    }
    mutating func addSkill(logical: URL, resolved: URL, provider: AIContextProvider, scope: AIContextScope, source: String, origin: AIContextOrigin, plugin: Bool = false) throws {
        let physicalURL = resolved.resolvingSymlinksInPath().standardizedFileURL
        guard let info = fileInfo(physicalURL), (info.st_mode & S_IFMT) == S_IFREG else {
            if isSymlink(resolved) {
                skippedLinks += 1
                if notes.filter({ $0.hasPrefix("Broken or unreadable skill link:") }).count < 20 {
                    notes.append("Broken or unreadable skill link: \(logical.path)")
                }
            }
            return
        }
        add(item(url: logical, resolved: physicalURL.path, info: info, provider: provider, scope: scope, kind: .skill, origin: origin, source: source), plugin: plugin)
    }
    mutating func add(_ item: AIContextItem, plugin: Bool = false) {
        guard items[item.id] == nil else { return }
        if plugin {
            guard pluginItems < configuration.limits.maximumPluginItems else { pluginItemLimitReached = true; return }
            pluginItems += 1
        }
        guard items.count < configuration.limits.maximumItems else { itemLimitReached = true; return }
        items[item.id] = item
    }
    mutating func canVisit() -> Bool { guard visited < configuration.limits.maximumEntries else { entryLimitReached = true; return false }; visited += 1; return true }
    mutating func visit(plugin: Bool) -> Bool {
        guard plugin else { return canVisit() }
        guard pluginEntries < configuration.limits.maximumPluginEntries else { pluginEntryLimitReached = true; return false }
        pluginEntries += 1; visited += 1; return true
    }
    mutating func children(_ root: URL) -> [URL] {
        do { return try BoundedDirectoryReader.children(root).sorted { $0.path < $1.path } }
        catch {
            unreadable += 1
            if notes.count < 40 { notes.append("Could not read directory: \(root.path). \(error.localizedDescription)") }
            return []
        }
    }
}

private let blocked: Set<String> = [".aws", ".cache", ".docker", ".git", ".gnupg", ".kube", ".ssh", "node_modules", "build", ".build", "deriveddata", "cache", "caches", "credentials", "env", "environment", "environments", "secret", "secrets", "session", "sessions", "tmp", "temp", "artifacts", "archives", "releases"]
private let generatedProjectDirectories: Set<String> = ["dist", "out", ".next", ".nuxt", ".turbo", ".svelte-kit", "coverage"]
private let agentProjectDirectories: Set<String> = [".agents", ".claude", ".codex", ".cursor", ".grok"]
private func isBlocked(_ url: URL) -> Bool { url.pathComponents.contains { blocked.contains($0.lowercased()) } }
private func isBlockedForTraversal(_ url: URL, explicitRoot: URL?) -> Bool {
    guard let explicitRoot else { return isBlocked(url) }
    let path = canonicalPath(url.path), root = canonicalPath(explicitRoot.path)
    if path == root { return false }
    if path.hasPrefix(root + "/") {
        let relative = String(path.dropFirst(root.count)).split(separator: "/")
        return relative.contains { blocked.contains($0.lowercased()) }
    }
    return isBlocked(url)
}
private func pluginRootIsSafe(_ url: URL) -> Bool {
    let allowed: Set<String> = ["cache", "caches"]
    return !url.pathComponents.contains { blocked.contains($0.lowercased()) && !allowed.contains($0.lowercased()) }
}
private func shouldWalkProjectChild(_ url: URL) -> Bool {
    let lower = url.lastPathComponent.lowercased()
    return !blocked.contains(lower) && !generatedProjectDirectories.contains(lower) &&
        !agentProjectDirectories.contains(lower) && url.pathExtension.lowercased() != "app" &&
        !isSymlink(url) && isDirectory(url)
}
private func isAgentDefinition(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return (ext == "md" || ext == "toml") && url.pathComponents.dropLast().contains { $0.lowercased() == "agents" }
}
private func isDirectory(_ url: URL) -> Bool { var v: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &v) && v.boolValue }
private func isSymlink(_ url: URL) -> Bool { guard let v = fileInfo(url) else { return false }; return (v.st_mode & S_IFMT) == S_IFLNK }
private func fileInfo(_ url: URL) -> stat? { var info = stat(); return lstat(url.path, &info) == 0 ? info : nil }
private func contextDate(_ info: stat) -> Date {
    #if canImport(Darwin)
    Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    #else
    Date(timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec) + TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000)
    #endif
}
private func item(url: URL, resolved: String?, info: stat, provider: AIContextProvider, scope: AIContextScope, kind: AIContextKind, origin: AIContextOrigin, source: String) -> AIContextItem {
    let path = url.standardizedFileURL.path; let allocated = Int64(info.st_blocks) * 512
    return AIContextItem(id: path, path: path, resolvedPath: resolved, name: kind == .skill ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent, scope: scope, kind: kind, provider: provider, source: source, logicalBytes: Int64(info.st_size), allocatedBytes: allocated, modified: contextDate(info), applicability: origin)
}

private func rank(items: [AIContextItem], roots: Set<String>, home: URL, deduplicateSkills: Bool = true) -> [AIContextFolderRanking] {
    let candidateRoots = roots.isEmpty ? Set(items.filter { $0.scope == .project }.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }) : roots
    return candidateRoots.flatMap { path -> [AIContextFolderRanking] in
        let effectivePath = canonicalPath(path)
        return AIContextProvider.allCases.filter { $0 != .project }.map { provider in
            var relevant = items.compactMap { item -> AIContextContribution? in
                guard item.provider == provider || (item.kind == .skill && item.provider == .agents && (provider == .agents || provider == .codex)) else { return nil }
                if item.scope == .global { return AIContextContribution(item: item, origin: item.applicability) }
                let owner = contextOwner(for: item)
                guard effectivePath == owner || effectivePath.hasPrefix(owner + "/") else { return nil }
                // Without a repository, only the selected folder's own files apply.
                if provider == .codex {
                    if let boundary = nearestGitRoot(containing: effectivePath) {
                        guard owner == boundary || owner.hasPrefix(boundary + "/") else { return nil }
                    } else if owner != effectivePath { return nil }
                }
                let origin: AIContextOrigin = effectivePath == owner ? (item.applicability == .inherited ? .local : item.applicability) : item.applicability == .conditional ? .conditional : .inherited
                return AIContextContribution(item: item, origin: origin)
            }
            // Multiple aliases can expose one physical skill. Preserve aliases in inventory,
            // but do not count that document more than once in a folder/provider ranking.
            relevant.sort {
                let leftInstalled = $0.origin == .installedOnly
                let rightInstalled = $1.origin == .installedOnly
                return leftInstalled == rightInstalled ? $0.item.path < $1.item.path : !leftInstalled
            }
            var physicalSkills = Set<String>()
            relevant.removeAll { contribution in
                guard deduplicateSkills, contribution.item.kind == .skill else { return false }
                return !physicalSkills.insert(contribution.item.resolvedPath ?? contribution.item.path).inserted
            }
            // A Codex override in one directory replaces that directory's AGENTS.md.
            if provider == .codex {
                let overrideParents = Set(relevant.filter { $0.item.path.lowercased().hasSuffix("/agents.override.md") }.map { URL(fileURLWithPath: $0.item.path).deletingLastPathComponent().path })
                relevant.removeAll { contribution in
                    contribution.item.path.lowercased().hasSuffix("/agents.md") && overrideParents.contains(URL(fileURLWithPath: contribution.item.path).deletingLastPathComponent().path)
                }
            }
            let instructions = relevant.filter {
                $0.item.kind == .instruction && [.global, .inherited, .local].contains($0.origin)
            }
            let sum = { (origin: AIContextOrigin) in instructions.filter { $0.origin == origin }.reduce(Int64(0)) { $0 + $1.item.logicalBytes } }
            let availableSkills = relevant.filter { $0.item.kind == .skill && $0.origin != .installedOnly }
            return AIContextFolderRanking(id: provider.rawValue + ":" + path, path: path, provider: provider,
                instructionBytes: instructions.reduce(0) { $0 + $1.item.logicalBytes }, globalBytes: sum(.global), inheritedBytes: sum(.inherited), localBytes: sum(.local), skillCount: availableSkills.count, skillBytes: availableSkills.reduce(0) { $0 + $1.item.logicalBytes }, conditionalCount: relevant.filter { $0.origin == .conditional }.count, installedOnlyCount: relevant.filter { $0.origin == .installedOnly }.count, sources: relevant, notes: provider == .codex ? ["Potential ancestor scope; 32 KiB default project cap is not an exact loaded-byte measurement."] : provider == .claude ? ["CLAUDE.local.md and skill activation are conditional."] : ["Availability and activation are conditional or unknown."])
        }
    }.sorted { ($0.instructionBytes, $0.path, $0.provider.rawValue) > ($1.instructionBytes, $1.path, $1.provider.rawValue) }
}

private func contextOwner(for item: AIContextItem) -> String {
    let url = URL(fileURLWithPath: item.path)
    if item.kind == .skill || item.kind == .rule || item.kind == .agentDefinition {
        for component in ["/.agents/skills/", "/.codex/skills/", "/.claude/skills/", "/.cursor/skills/", "/.grok/skills/", "/.grok/agents/", "/.claude/rules/", "/.codex/agents/", "/.claude/agents/", "/.cursor/rules/"] {
            if let marker = url.path.range(of: component) { return canonicalPath(String(url.path[..<marker.lowerBound])) }
        }
    }
    if item.path.hasSuffix("/.claude/CLAUDE.md"), let marker = item.path.range(of: "/.claude/") { return canonicalPath(String(item.path[..<marker.lowerBound])) }
    return canonicalPath(url.deletingLastPathComponent().path)
}

private func nearestGitRoot(containing path: String) -> String? {
    var url = URL(fileURLWithPath: canonicalPath(path), isDirectory: true)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
        url.deleteLastPathComponent()
    }
    return nil
}

private func canonicalPath(_ path: String) -> String {
    let value = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    return value == "/private/var" ? "/var" : value.hasPrefix("/private/var/") ? "/var/" + value.dropFirst("/private/var/".count) : value
}

/// Filesystem access may wait for a disconnected volume or an OS permission prompt.
/// Bound both the caller's wait and outstanding reads; never create unlimited stuck workers.
enum BoundedDirectoryReader {
    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<[URL], Error>?
    }
    private static let permits = DispatchSemaphore(value: 8)
    static func children(_ root: URL, timeout: TimeInterval = 2,
                         read: @escaping @Sendable (URL) throws -> [URL] = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }) throws -> [URL] {
        let deadline = DispatchTime.now() + max(0, timeout)
        guard permits.wait(timeout: deadline) == .success else {
            throw SkillManagementError(message: "Directory access is still pending. Retry when unavailable locations recover.")
        }
        let box = ResultBox(), signal = DispatchSemaphore(value: 0)
        // A dedicated thread avoids starving behind callers blocking a shared
        // executor. The permits above cap outstanding filesystem reads at eight.
        Thread.detachNewThread {
            let result = Result { try read(root) }
            box.lock.lock(); box.result = result; box.lock.unlock()
            permits.signal()
            signal.signal()
        }
        guard signal.wait(timeout: deadline) == .success else {
            throw SkillManagementError(message: "Directory access timed out; check macOS access or volume availability.")
        }
        box.lock.lock(); let result = box.result; box.lock.unlock()
        return try result!.get()
    }
}
