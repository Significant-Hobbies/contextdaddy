import Foundation

/// Repository copies must remain portable when their checkout moves or is cloned.
public enum SkillConsolidationBoundary {
    public static func repositoryRoot(for skill: URL) -> URL? {
        var folder = skill.resolvingSymlinksInPath().deletingLastPathComponent()
        while folder.path != "/" {
            // A worktree has a .git file; a regular checkout has a directory.
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                return folder
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    public static func reason(duplicate: URL, canonical: URL) -> String? {
        guard let owner = repositoryRoot(for: duplicate), owner != repositoryRoot(for: canonical) else { return nil }
        return "Independent repository or worktree copy. Replacing it with an external link would make this checkout depend on another location. Keep it independent; migrate shared ownership separately."
    }
}

public enum SkillSortField: String, CaseIterable, Sendable {
    case name = "Skill", location = "Location", agents = "Agent access", invocation = "Invocation", copies = "Copies"
}

public enum SkillOrganizationIndex {
    public static func invocation(_ record: SkillRecord, runtime: AgentRuntime?) -> String {
        if let runtime { return record.policy(for: runtime)?.mode.rawValue ?? "Needs review" }
        let modes = Set(record.policies.filter(\.isExposed).map(\.mode))
        if modes.isEmpty { return "Not exposed" }
        return modes.count == 1 ? modes.first!.rawValue : "Mixed · per agent"
    }

    public static func location(_ record: SkillRecord) -> String {
        if record.ownership != .local { return record.ownership.rawValue }
        let scopes = Set(record.exposures.map(\.scope.rawValue)).sorted()
        return scopes.isEmpty ? "Library only" : scopes.joined(separator: " + ")
    }

    public static func matching(_ records: [SkillRecord], runtime: AgentRuntime?, invocation: InvocationMode?,
                                scope: AIContextScope?, sort: SkillSortField, ascending: Bool,
                                duplicateCounts: [String: Int]) -> [SkillRecord] {
        records.filter { record in
            if let scope, !record.exposures.contains(where: { $0.scope == scope }) { return false }
            if let invocation {
                if invocation == .unverified {
                    return record.policies.contains { (runtime == nil || $0.runtime == runtime) && ($0.mode == .unverified || ($0.desiredMode != nil && $0.desiredMode != $0.mode)) }
                }
                if let runtime { return record.policy(for: runtime)?.mode == invocation }
                if invocation == .unsupported { return record.exposedRuntimes.isEmpty }
                return record.policies.contains { $0.mode == invocation && ($0.isExposed || invocation == .unsupported || invocation == .unverified) }
            }
            return true
        }.sorted { lhs, rhs in
            func key(_ record: SkillRecord) -> String {
                switch sort {
                case .name: record.name.lowercased()
                case .location: location(record) + record.id
                case .agents: record.exposedRuntimes.map(\.rawValue).sorted().joined(separator: ",")
                case .invocation: self.invocation(record, runtime: runtime)
                case .copies: String(format: "%08d", duplicateCounts[record.id, default: 1])
                }
            }
            let left = key(lhs), right = key(rhs)
            if left == right { return lhs.id < rhs.id }
            return ascending ? left < right : left > right
        }
    }
}
