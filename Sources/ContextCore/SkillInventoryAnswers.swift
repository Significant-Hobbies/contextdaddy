import Foundation

/// Summarizes physical definitions, never counting an exposure link as another skill.
public struct SkillInventoryAnswers: Sendable {
    public let local: [SkillRecord]
    public let pluginCount: Int
    public let archivedCount: Int
    public let systemCount: Int
    public let uniqueNames: Int
    public let uniqueInstructions: Int
    public let unverifiedInstructions: Int
    public let extraInstructionCopies: Int
    public let globalCount: Int
    public let projectOnlyCount: Int
    public let noAccessCount: Int

    public init(records: [SkillRecord]) {
        let physical = Dictionary(grouping: records, by: \.id).values.compactMap(\.first)
        archivedCount = physical.filter { SkillCleanupPlanner.isArchived($0) }.count
        let current = physical.filter { !SkillCleanupPlanner.isArchived($0) }
        pluginCount = current.filter { $0.ownership == .plugin }.count
        local = current.filter { $0.ownership == .local }
        systemCount = current.count - pluginCount - local.count
        uniqueNames = Set(local.map { $0.name.lowercased() }).count
        let fingerprints = local.compactMap(\.contentFingerprint)
        uniqueInstructions = Set(fingerprints).count
        unverifiedInstructions = local.count - fingerprints.count
        extraInstructionCopies = fingerprints.count - uniqueInstructions
        globalCount = local.filter { $0.exposures.contains { $0.scope == .global } }.count
        projectOnlyCount = local.filter { !$0.exposures.contains { $0.scope == .global } && $0.exposures.contains { $0.scope == .project } }.count
        noAccessCount = local.filter { $0.exposedRuntimes.isEmpty }.count
    }

    public func count(for runtime: AgentRuntime) -> Int {
        local.filter { $0.policy(for: runtime)?.isExposed == true }.count
    }

    /// Includes counterpart sources outside the selected location, within the scanned scope.
    /// This is an instruction match only; mutation still requires whole-folder verification.
    public static func matchingCopyIDs(near selectedIDs: Set<String>, records: [SkillRecord]) -> Set<String> {
        let groups = Dictionary(grouping: records.filter { $0.contentFingerprint != nil }, by: { $0.contentFingerprint! })
        return Set(groups.values.flatMap { group -> [String] in
            let ids = Set(group.map(\.id))
            return ids.count > 1 && !ids.isDisjoint(with: selectedIDs) ? Array(ids) : []
        })
    }
}
