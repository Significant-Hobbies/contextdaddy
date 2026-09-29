import Foundation

public enum SkillRedundancyKind: String, CaseIterable, Sendable, Identifiable {
    case exactCopy = "Exact copy"
    case versionDrift = "Version drift"
    case semanticOverlap = "Purpose overlap"

    public var id: String { rawValue }
}

public enum SkillRedundancyConfidence: String, CaseIterable, Sendable {
    case high = "High confidence"
    case medium = "Medium confidence"
}

public struct SkillRedundancyMember: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let logicalBytes: Int64
    public let modified: Date
    public let source: String
    public let exposedRuntimes: [AgentRuntime]
    public let isManagedCache: Bool
}

public struct SkillRedundancyFinding: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: SkillRedundancyKind
    public let confidence: SkillRedundancyConfidence
    public let score: Double
    public let members: [SkillRedundancyMember]
    public let keepCandidateID: String
    public let affectedRuntimes: [AgentRuntime]
    public let evidence: [String]
    public let recommendation: String
    public let estimatedDuplicateBytes: Int64
    public let includesManagedCache: Bool

    public var keepCandidate: SkillRedundancyMember? {
        members.first { $0.id == keepCandidateID }
    }

    public var isManagedCacheOnly: Bool { members.allSatisfy(\.isManagedCache) }
}

public struct SkillRedundancySummary: Sendable, Equatable {
    public let findings: [SkillRedundancyFinding]

    public var actionableFindings: [SkillRedundancyFinding] { findings.filter { !$0.isManagedCacheOnly } }
    public var exactCopyCount: Int { actionableFindings.filter { $0.kind == .exactCopy }.count }
    public var versionDriftCount: Int { actionableFindings.filter { $0.kind == .versionDrift }.count }
    public var semanticOverlapCount: Int { actionableFindings.filter { $0.kind == .semanticOverlap }.count }
    public var managedCacheOnlyCount: Int { findings.filter(\.isManagedCacheOnly).count }
    public var estimatedDuplicateBytes: Int64 {
        actionableFindings.filter { $0.kind == .exactCopy }.reduce(0) { $0 + $1.estimatedDuplicateBytes }
    }
    public var managedCacheDuplicateBytes: Int64 {
        findings.filter { $0.kind == .exactCopy && $0.isManagedCacheOnly }.reduce(0) { $0 + $1.estimatedDuplicateBytes }
    }
    public var reviewCount: Int { actionableFindings.count }
}

public enum SkillRedundancyAnalyzer {
    public static func analyze(records: [SkillRecord]) -> SkillRedundancySummary {
        let records = records.sorted { $0.id < $1.id }
        var findings: [SkillRedundancyFinding] = []

        findings.append(contentsOf: exactCopyFindings(records: records))

        let namedGroups = Dictionary(grouping: records, by: { normalizedName($0.name) })
        for (name, group) in namedGroups where !name.isEmpty && group.count > 1 {
            for component in runtimeOverlapComponents(group) where component.count > 1 {
                let fingerprints = component.compactMap(\.contentFingerprint)
                let overlapping = overlappingRuntimes(component)
                guard fingerprints.count == component.count, Set(fingerprints).count > 1, !overlapping.isEmpty else { continue }
                findings.append(makeFinding(
                    kind: .versionDrift,
                    confidence: .high,
                    score: 0.95,
                    records: component,
                    affectedRuntimes: overlapping,
                    evidence: [
                        "Same normalized skill name, but bounded content differs.",
                        "Competes in \(runtimeNames(overlapping)).",
                    ],
                    duplicateBytes: 0
                ))
            }
        }

        findings.append(contentsOf: semanticFindings(records: records))
        findings.sort {
            if $0.isManagedCacheOnly != $1.isManagedCacheOnly { return !$0.isManagedCacheOnly }
            if $0.kind != $1.kind { return kindRank($0.kind) < kindRank($1.kind) }
            if $0.affectedRuntimes.count != $1.affectedRuntimes.count { return $0.affectedRuntimes.count > $1.affectedRuntimes.count }
            if $0.includesManagedCache != $1.includesManagedCache { return !$0.includesManagedCache }
            if $0.estimatedDuplicateBytes != $1.estimatedDuplicateBytes { return $0.estimatedDuplicateBytes > $1.estimatedDuplicateBytes }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id
        }
        return SkillRedundancySummary(findings: findings)
    }

    /// Cleanup only needs exact instruction groups; avoid semantic comparison on sheet renders.
    public static func exactCopyFindings(records: [SkillRecord]) -> [SkillRedundancyFinding] {
        var findings: [SkillRedundancyFinding] = []
        let exactGroups = Dictionary(grouping: records.compactMap { record in
            record.contentFingerprint.map { ($0, record) }
        }, by: { $0.0 })
        for (fingerprint, entries) in exactGroups where entries.count > 1 {
            let group = entries.map(\.1)
            findings.append(makeFinding(
                kind: .exactCopy,
                confidence: .high,
                score: 1,
                records: group,
                affectedRuntimes: runtimeUnion(group),
                evidence: [
                    "Byte-identical bounded SKILL.md content (SHA-256 \(fingerprint.prefix(10))…).",
                    exposureEvidence(group),
                ],
                duplicateBytes: duplicateBytes(group)
            ))
        }

        return findings.sorted {
            if $0.isManagedCacheOnly != $1.isManagedCacheOnly { return !$0.isManagedCacheOnly }
            if $0.members.count != $1.members.count { return $0.members.count > $1.members.count }
            return $0.id < $1.id
        }
    }

    private static func semanticFindings(records: [SkillRecord]) -> [SkillRedundancyFinding] {
        let tokenSets = Dictionary(uniqueKeysWithValues: records.map { ($0.id, meaningfulTokens($0.description)) })
        var index: [String: [Int]] = [:]
        for (position, record) in records.enumerated() {
            for token in tokenSets[record.id, default: []] {
                index[token, default: []].append(position)
            }
        }

        var candidatePairs = Set<Pair>()
        for positions in index.values where positions.count > 1 && positions.count <= 80 {
            for left in positions.indices {
                for right in positions.indices where right > left {
                    candidatePairs.insert(Pair(positions[left], positions[right]))
                }
            }
        }

        return candidatePairs.compactMap { pair in
            let lhs = records[pair.left]
            let rhs = records[pair.right]
            guard normalizedName(lhs.name) != normalizedName(rhs.name) else { return nil }
            guard lhs.contentFingerprint == nil || rhs.contentFingerprint == nil || lhs.contentFingerprint != rhs.contentFingerprint else { return nil }
            let runtimes = Array(Set(lhs.exposedRuntimes).intersection(rhs.exposedRuntimes)).sorted { $0.rawValue < $1.rawValue }
            guard !runtimes.isEmpty else { return nil }
            let leftTokens = tokenSets[lhs.id, default: []]
            let rightTokens = tokenSets[rhs.id, default: []]
            guard leftTokens.count >= 5, rightTokens.count >= 5 else { return nil }
            let shared = leftTokens.intersection(rightTokens)
            guard shared.count >= 4 else { return nil }
            let union = leftTokens.union(rightTokens)
            let jaccard = Double(shared.count) / Double(max(1, union.count))
            let containment = Double(shared.count) / Double(max(1, min(leftTokens.count, rightTokens.count)))
            let score = (jaccard * 0.55) + (containment * 0.45)
            guard jaccard >= 0.42, containment >= 0.68, score >= 0.56 else { return nil }
            let terms = shared.sorted().prefix(6).joined(separator: ", ")
            return makeFinding(
                kind: .semanticOverlap,
                confidence: .medium,
                score: score,
                records: [lhs, rhs],
                affectedRuntimes: runtimes,
                evidence: [
                    "Shares \(shared.count) meaningful purpose terms: \(terms).",
                    "\(Int((containment * 100).rounded()))% containment and \(Int((jaccard * 100).rounded()))% Jaccard similarity.",
                    "Overlaps in \(runtimeNames(runtimes)).",
                ],
                duplicateBytes: 0
            )
        }
    }

    private static func makeFinding(
        kind: SkillRedundancyKind,
        confidence: SkillRedundancyConfidence,
        score: Double,
        records: [SkillRecord],
        affectedRuntimes: [AgentRuntime],
        evidence: [String],
        duplicateBytes: Int64
    ) -> SkillRedundancyFinding {
        let ordered = records.sorted(by: canonicalSort)
        let members = ordered.map(member)
        let includesCache = members.contains(where: \.isManagedCache)
        let recommendation: String
        if members.allSatisfy(\.isManagedCache) {
            recommendation = "Managed cache material only. Review the owning plugin or installer; do not edit cache files directly."
        } else if kind == .semanticOverlap {
            recommendation = "Compare responsibilities and triggers. Keep both when their operational boundaries differ; otherwise consolidate around \(members[0].name)."
        } else if kind == .versionDrift {
            recommendation = "Compare the diverged definitions before consolidating. \(members[0].name) is the leading keep candidate based on active exposure and explicit policy evidence."
        } else {
            recommendation = "Review whether aliases can point to one source. \(members[0].name) is the leading keep candidate; remove nothing automatically."
        }
        let ids = records.map(\.id).sorted().joined(separator: "|")
        return SkillRedundancyFinding(
            id: "\(kind.rawValue):\(ids)",
            kind: kind,
            confidence: confidence,
            score: score,
            members: members,
            keepCandidateID: members[0].id,
            affectedRuntimes: affectedRuntimes,
            evidence: evidence,
            recommendation: recommendation,
            estimatedDuplicateBytes: duplicateBytes,
            includesManagedCache: includesCache
        )
    }

    private static func member(_ record: SkillRecord) -> SkillRedundancyMember {
        SkillRedundancyMember(
            id: record.id,
            name: record.name,
            description: record.description,
            logicalBytes: record.logicalBytes,
            modified: record.modified,
            source: record.exposures.first?.source ?? "Unknown source",
            exposedRuntimes: record.exposedRuntimes.sorted { $0.rawValue < $1.rawValue },
            isManagedCache: isManagedCache(record)
        )
    }

    private static func canonicalSort(_ lhs: SkillRecord, _ rhs: SkillRecord) -> Bool {
        let leftCache = isManagedCache(lhs)
        let rightCache = isManagedCache(rhs)
        if leftCache != rightCache { return !leftCache }
        if lhs.exposedRuntimes.count != rhs.exposedRuntimes.count { return lhs.exposedRuntimes.count > rhs.exposedRuntimes.count }
        let leftExplicit = lhs.policies.filter { $0.isExposed && $0.explicit }.count
        let rightExplicit = rhs.policies.filter { $0.isExposed && $0.explicit }.count
        if leftExplicit != rightExplicit { return leftExplicit > rightExplicit }
        if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
        return lhs.id < rhs.id
    }

    private static func isManagedCache(_ record: SkillRecord) -> Bool {
        !record.exposures.isEmpty && record.exposures.allSatisfy { $0.applicability == .installedOnly }
    }

    private static func duplicateBytes(_ records: [SkillRecord]) -> Int64 {
        let sizes = records.map(\.logicalBytes).sorted(by: >)
        return sizes.dropFirst().reduce(0, +)
    }

    private static func overlappingRuntimes(_ records: [SkillRecord]) -> [AgentRuntime] {
        AgentRuntime.allCases.filter { runtime in
            records.filter { $0.policy(for: runtime)?.isExposed == true }.count > 1
        }
    }

    private static func runtimeOverlapComponents(_ records: [SkillRecord]) -> [[SkillRecord]] {
        var remaining = records.sorted { $0.id < $1.id }
        var components: [[SkillRecord]] = []
        while let seed = remaining.first {
            remaining.removeFirst()
            var component = [seed]
            var changed = true
            while changed {
                changed = false
                let active = Set(component.flatMap(\.exposedRuntimes))
                var retained: [SkillRecord] = []
                for candidate in remaining {
                    if !active.isDisjoint(with: candidate.exposedRuntimes) {
                        component.append(candidate)
                        changed = true
                    } else {
                        retained.append(candidate)
                    }
                }
                remaining = retained
            }
            components.append(component)
        }
        return components
    }

    private static func runtimeUnion(_ records: [SkillRecord]) -> [AgentRuntime] {
        Array(Set(records.flatMap(\.exposedRuntimes))).sorted { $0.rawValue < $1.rawValue }
    }

    private static func exposureEvidence(_ records: [SkillRecord]) -> String {
        let runtimes = runtimeUnion(records)
        return runtimes.isEmpty ? "No active runtime exposure was proven." : "Visible to \(runtimeNames(runtimes))."
    }

    private static func runtimeNames(_ runtimes: [AgentRuntime]) -> String {
        runtimes.map(\.rawValue).joined(separator: ", ")
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func meaningfulTokens(_ value: String) -> Set<String> {
        let words = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private static func kindRank(_ kind: SkillRedundancyKind) -> Int {
        switch kind {
        case .exactCopy: 0
        case .versionDrift: 1
        case .semanticOverlap: 2
        }
    }

    private static let stopwords: Set<String> = [
        "about", "agent", "agents", "also", "and", "any", "are", "asks", "build", "can", "create", "does", "for", "from", "has", "have", "into", "its", "local", "not", "only", "other", "project", "projects", "request", "requests", "skill", "skills", "that", "the", "their", "them", "this", "through", "tool", "tools", "use", "used", "user", "users", "using", "when", "where", "with", "work"
    ]

    private struct Pair: Hashable {
        let left: Int
        let right: Int
        init(_ lhs: Int, _ rhs: Int) {
            left = min(lhs, rhs)
            right = max(lhs, rhs)
        }
    }
}
