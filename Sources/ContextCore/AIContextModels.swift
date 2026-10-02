import Foundation

public enum AIContextScope: String, Codable, Sendable, CaseIterable {
    case global = "Global"
    case project = "Project"
}

public enum AIContextKind: String, Codable, Sendable, CaseIterable {
    case instruction = "Instruction"
    case skill = "Skill"
    case rule = "Rule"
    case mcpConfig = "MCP config"
    case agentDefinition = "Agent definition"
}

public enum AIContextProvider: String, Codable, Sendable, CaseIterable {
    case codex = "Codex"
    case claude = "Claude"
    case agents = "Agents"
    case cursor = "Cursor"
    case devin = "Devin"
    case grok = "Grok"
    case gemini = "Gemini"
    case project = "Project"
}

/// How a source can apply to a selected folder. This is potential scope, not
/// evidence that a running agent has loaded the source.
public enum AIContextOrigin: String, Codable, Sendable, CaseIterable {
    case global = "Global"
    case inherited = "Inherited"
    case local = "Local"
    case conditional = "Conditional"
    case installedOnly = "Installed only"
}

public enum AIContextPressure: String, Codable, Sendable, CaseIterable {
    case light = "Light"
    case elevated = "Elevated"
    case heavy = "Heavy"

    public static let elevatedTokenThreshold = 8_000
    public static let heavyTokenThreshold = 20_000

    public static func classify(estimatedTokens: Int) -> Self {
        if estimatedTokens >= heavyTokenThreshold { return .heavy }
        if estimatedTokens >= elevatedTokenThreshold { return .elevated }
        return .light
    }
}

public struct AIContextItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let resolvedPath: String?
    public let name: String
    public let scope: AIContextScope
    public let kind: AIContextKind
    public let provider: AIContextProvider
    public let source: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modified: Date
    public let applicability: AIContextOrigin

    public init(id: String, path: String, resolvedPath: String? = nil, name: String,
                scope: AIContextScope, kind: AIContextKind,
                provider: AIContextProvider = .project, source: String = "Local",
                logicalBytes: Int64, allocatedBytes: Int64, modified: Date,
                applicability: AIContextOrigin = .local) {
        self.id = id; self.path = path; self.resolvedPath = resolvedPath; self.name = name
        self.scope = scope; self.kind = kind; self.provider = provider; self.source = source
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.modified = modified
        self.applicability = applicability
    }
}

public struct AIContextContribution: Sendable, Identifiable, Equatable {
    public let item: AIContextItem
    public let origin: AIContextOrigin
    public var id: String { item.id + ":" + origin.rawValue }
    public init(item: AIContextItem, origin: AIContextOrigin) { self.item = item; self.origin = origin }
}

public struct AIContextFolderRanking: Sendable, Identifiable, Equatable {
    public let id: String
    public let path: String
    public let provider: AIContextProvider
    public let instructionBytes: Int64
    public let globalBytes: Int64
    public let inheritedBytes: Int64
    public let localBytes: Int64
    public let skillCount: Int
    /// Storage bytes of available skill documents. These are not prompt-token or inherited-instruction bytes.
    public let skillBytes: Int64
    public let conditionalCount: Int
    public let installedOnlyCount: Int
    public let sources: [AIContextContribution]
    public let notes: [String]

    public func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if path.localizedCaseInsensitiveContains(query) || provider.rawValue.localizedCaseInsensitiveContains(query) { return true }
        return sources.contains { source in
            [source.item.name, source.item.path, source.item.source, source.item.provider.rawValue, source.item.kind.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Approximate tokens from instruction files that may apply automatically
    /// when this agent starts in the folder. Skill bodies remain separate.
    public var estimatedStartupTokens: Int {
        let bytes = max(0, instructionBytes)
        let roundedUp = bytes / 4 + (bytes % 4 == 0 ? 0 : 1)
        return Int(clamping: roundedUp)
    }

    public var pressure: AIContextPressure {
        AIContextPressure.classify(estimatedTokens: estimatedStartupTokens)
    }

    public var automaticInstructionSourceCount: Int {
        sources.filter {
            $0.item.kind == .instruction && [.global, .inherited, .local].contains($0.origin)
        }.count
    }
}

public struct AIContextCoverage: Sendable, Equatable {
    public let roots: [String]
    public let visitedEntries: Int
    public let itemLimitReached: Bool
    public let entryLimitReached: Bool
    public let unreadableCount: Int
    public let skippedLinks: Int
    public let notes: [String]
    public var projectDepthReached = false
    public var skillDepthReached = false
    public var pluginEntryLimitReached = false
    public var pluginItemLimitReached = false

    public var isPartial: Bool {
        itemLimitReached || entryLimitReached || unreadableCount > 0 || skippedLinks > 0 ||
        projectDepthReached || skillDepthReached || pluginEntryLimitReached || pluginItemLimitReached
    }

    public var limitReasons: [String] {
        var reasons: [String] = []
        if itemLimitReached { reasons.append("File limit reached") }
        if entryLimitReached { reasons.append("Directory-entry limit reached") }
        if projectDepthReached { reasons.append("Some project folders are deeper than the search limit. Add a specific folder to include it.") }
        if skillDepthReached { reasons.append("Some skill folders are deeper than the search limit.") }
        if pluginEntryLimitReached { reasons.append("Plugin directory-entry limit reached") }
        if pluginItemLimitReached { reasons.append("Plugin file limit reached") }
        return reasons
    }
}

public struct AIContextDiscoveryReport: Sendable, Equatable {
    public let items: [AIContextItem]
    public let folderRankings: [AIContextFolderRanking]
    public let coverage: AIContextCoverage
    public let elapsed: TimeInterval

    /// Allows external read-only adapters to restrict inventory before policy
    /// resolution reads bounded skill metadata. Coverage remains the original
    /// discovery evidence, not a claim that excluded exposures were inspected.
    public init(items: [AIContextItem], folderRankings: [AIContextFolderRanking], coverage: AIContextCoverage, elapsed: TimeInterval) {
        self.items = items
        self.folderRankings = folderRankings
        self.coverage = coverage
        self.elapsed = elapsed
    }
}
