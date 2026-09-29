import Foundation
import CryptoKit

public enum SkillCleanupCategory: String, CaseIterable, Sendable {
    case ready = "Ready to preview", decision = "Needs a decision", managed = "Plugin ownership", independent = "Keep independent"
}

public enum SkillCleanupAction: String, Sendable {
    case consolidate, compare, scope, managed, independent
}

public struct SkillCleanupRecommendation: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let reason: String
    public let category: SkillCleanupCategory
    public let action: SkillCleanupAction
    public let records: [SkillRecord]
    public let canonicalID: String?
    public let plans: [SkillChangePlan]
    public let globalLinks: [String]
    public var agents: String { Set(records.flatMap(\.exposedRuntimes).map(\.rawValue)).sorted().joined(separator: ", ") }
    /// A kept decision expires when instruction content, exposures or policies change.
    public var decisionKey: String {
        let evidence = records.sorted { $0.id < $1.id }.map {
            $0.id + ($0.contentFingerprint ?? "unknown-\($0.modified.timeIntervalSince1970)")
                + $0.exposures.map(\.id).sorted().joined()
                + $0.policies.map { $0.runtime.rawValue + $0.mode.rawValue }.sorted().joined()
        }.joined()
        return SHA256.hash(data: Data((id + evidence).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SkillCleanupAssessment: Sendable {
    public let records: [SkillRecord]
    public let recommendations: [SkillCleanupRecommendation]
    public let cacheCount: Int
    public let archiveCount: Int
    public var localRecords: [SkillRecord] { records.filter { $0.ownership == .local && !SkillCleanupPlanner.isArchived($0) } }
    public var localNames: Int { Set(localRecords.map { $0.name.lowercased() }).count }
    public var readyPlans: [SkillChangePlan] { recommendations.filter { $0.category == .ready }.flatMap(\.plans) }
}

public enum SkillCleanupPlanner {
    public static func isArchived(_ record: SkillRecord) -> Bool {
        func archived(_ path: String) -> Bool {
            let components = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().pathComponents
            return components.contains { ["fleet-archive", "worktree-archive", "archives", "SkillHistory"].contains($0) }
        }
        return archived(record.id) && record.exposures.allSatisfy { archived($0.logicalPath) }
    }

    public static func assess(records: [SkillRecord], manager: SkillLibraryManager) async -> SkillCleanupAssessment {
        let current = records.filter { !isArchived($0) }
        let findings = SkillRedundancyAnalyzer.analyze(records: current).findings
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var recommendations: [SkillCleanupRecommendation] = []
        for finding in findings {
            if Task.isCancelled { break }
            let members = finding.members.compactMap { byID[$0.id] }
            let local = members.filter { $0.ownership == .local }
            if local.isEmpty {
                // One owner/version review, never a promise that cache files can be deleted.
                guard finding.kind == .exactCopy else { continue }
                recommendations.append(.init(id: finding.id, title: "Review \(members.first?.name ?? "plugin") installations",
                    reason: "\(members.count) matching cached instructions. Activation and obsolete versions are unverified. Manage these through the owning plugin installer.",
                    category: .managed, action: .managed, records: members, canonicalID: nil, plans: [], globalLinks: []))
                continue
            }
            if finding.kind != .exactCopy {
                let separateProjects = finding.kind == .versionDrift && members.allSatisfy {
                    !$0.exposures.isEmpty && $0.exposures.allSatisfy { $0.scope == .project }
                } && !hasOverlappingProjects(members)
                recommendations.append(.init(id: finding.id,
                    title: separateProjects ? "Keep project versions of \(local[0].name) independent" : finding.kind == .versionDrift ? "Choose a version of \(local[0].name)" : "Review \(local.map(\.name).joined(separator: " + "))",
                    reason: separateProjects ? "These versions belong to separate project scopes. No overlapping folder exposure was found; a matching name does not make them competing installations." : finding.kind == .versionDrift ? "Same name, different instructions. Compare content and affected agents before retiring a source." : "Descriptions overlap; this is a review lead, not proof of redundancy. Compare responsibilities before combining or archiving.",
                    category: separateProjects ? .independent : .decision, action: separateProjects ? .independent : .compare,
                    records: members, canonicalID: nil, plans: [], globalLinks: []))
                continue
            }
            guard local.count > 1 else { continue }
            // Partition by checkout: no auto-selected shared source across independent projects.
            let ordered = local.sorted { lhs, rhs in
                let l = lhs.id.contains("/.agents/skills/"), r = rhs.id.contains("/.agents/skills/")
                if l != r { return l }
                if lhs.exposures.count != rhs.exposures.count { return lhs.exposures.count > rhs.exposures.count }
                return lhs.id < rhs.id
            }
            let keep = ordered[0]
            var plans: [SkillChangePlan] = [], reasons: [String] = []
            for duplicate in ordered.dropFirst() {
                do {
                    let plan = try await manager.prepareConsolidation(duplicate: URL(fileURLWithPath: duplicate.id), canonical: URL(fileURLWithPath: keep.id))
                    // External relative references make changing a folder's location significant.
                    let text = try BoundedTextReader.read(url: URL(fileURLWithPath: keep.id), maximumBytes: 64 * 1024)
                    if text.contains("../") { reasons.append("External relative references require review."); continue }
                    plans.append(plan)
                } catch { reasons.append(error.localizedDescription) }
            }
            let independent = !reasons.isEmpty && reasons.allSatisfy { $0.hasPrefix("Independent repository") }
            recommendations.append(.init(id: finding.id, title: "Keep one source for \(keep.name)",
                reason: plans.isEmpty ? Array(Set(reasons)).sorted().joined(separator: " ") : "\(plans.count) complete folders match, including support files and permissions. Existing agent routes remain as links.\(reasons.isEmpty ? "" : " Other copies need separate review.")",
                category: plans.isEmpty ? (independent ? .independent : .decision) : .ready,
                action: plans.isEmpty ? (independent ? .independent : .compare) : .consolidate,
                records: members, canonicalID: keep.id, plans: plans, globalLinks: []))
        }
        // Narrow only a global alias when a project route for the same provider already exists.
        for record in current where record.ownership == .local {
            let globals = record.exposures.filter { exposure in
                guard exposure.scope == .global, exposure.logicalPath != exposure.resolvedPath else { return false }
                let folder = URL(fileURLWithPath: exposure.logicalPath).deletingLastPathComponent()
                guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return false }
                return record.exposures.contains { $0.scope == .project && $0.provider == exposure.provider }
            }
            guard !globals.isEmpty else { continue }
            recommendations.append(.init(id: "scope:" + record.id, title: "Keep \(record.name) project-scoped?",
                reason: "The same source already has project routes and global links. Removing only the selected global links narrows availability outside those projects; the source and project access remain. Decide whether this workflow is truly project-specific.",
                category: .decision, action: .scope, records: [record], canonicalID: record.id, plans: [],
                globalLinks: Array(Set(globals.map { URL(fileURLWithPath: $0.logicalPath).deletingLastPathComponent().path })).sorted()))
        }
        let order: [SkillCleanupCategory: Int] = [.ready: 0, .decision: 1, .independent: 2, .managed: 3]
        recommendations.sort {
            if $0.category != $1.category { return order[$0.category]! < order[$1.category]! }
            if $0.plans.count != $1.plans.count { return $0.plans.count > $1.plans.count }
            return $0.id < $1.id
        }
        return SkillCleanupAssessment(records: records, recommendations: recommendations,
            cacheCount: records.filter { $0.ownership != .local }.count,
            archiveCount: records.filter { isArchived($0) }.count)
    }

    private static func hasOverlappingProjects(_ records: [SkillRecord]) -> Bool {
        func owner(_ exposure: SkillExposure) -> String? {
            for marker in ["/.agents/skills/", "/.codex/skills/", "/.claude/skills/", "/.cursor/skills/", "/.grok/skills/"] {
                if let range = exposure.logicalPath.range(of: marker) { return String(exposure.logicalPath[..<range.lowerBound]) }
            }
            return nil
        }
        for i in records.indices {
            for j in records.indices where j > i {
                for left in records[i].exposures {
                    for right in records[j].exposures {
                        // Unknown ownership must remain reviewable, not be declared independent.
                        guard let a = owner(left), let b = owner(right) else { return true }
                        if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") { return true }
                    }
                }
            }
        }
        return false
    }
}
