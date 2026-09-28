import Foundation

public enum SkillOwnership: String, CaseIterable, Sendable {
    case local = "Local"
    case plugin = "Plugin managed"
    case system = "System managed"

    public static func classify(path: String) -> Self {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.contains("plugins") && parts.contains("cache") { return .plugin }
        if parts.contains(".system") || parts.contains("synced") || parts.contains(".synced") || path.hasPrefix("/Applications/") || path.hasPrefix("/etc/") || path.hasPrefix("/Library/") { return .system }
        return .local
    }
}

public extension SkillRecord {
    var ownership: SkillOwnership { .classify(path: id) }
    var linkedExposureCount: Int { exposures.filter { $0.logicalPath != $0.resolvedPath }.count }
    var locationSummary: String {
        "\(exposures.count) location\(exposures.count == 1 ? "" : "s") · \(linkedExposureCount) linked · \(ownership.rawValue)"
    }
}

/// Search includes physical ownership, logical exposure routes, and policy explanations.
public enum SkillLibraryIndex {
    public static func matching(_ records: [SkillRecord], query: String, ownership: SkillOwnership? = nil,
                                runtime: AgentRuntime? = nil, location: String? = nil) -> [SkillRecord] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return records.filter { record in
            if let ownership, record.ownership != ownership { return false }
            if let runtime, record.policy(for: runtime)?.isExposed != true { return false }
            if let location, !record.exposures.contains(where: { $0.source == location }) { return false }
            if terms.isEmpty { return true }
            let haystack = ([record.name, record.description, record.id, record.ownership.rawValue]
                + record.exposures.flatMap { [$0.logicalPath, $0.source, $0.scope.rawValue] }
                + record.policies.filter(\.isExposed).flatMap { [$0.runtime.rawValue, $0.mode.rawValue, $0.reason] })
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}
