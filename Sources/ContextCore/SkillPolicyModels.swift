import Foundation

public enum AgentRuntime: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case devin = "Devin"
    case grok = "Grok"

    public var id: String { rawValue }
}

public enum InvocationMode: String, Codable, CaseIterable, Sendable {
    case automatic = "Auto-invocable"
    case manualOnly = "Manual only"
    case modelOnly = "Model only"
    case disabled = "Disabled"
    case unsupported = "Not exposed"
    case unverified = "Needs review"
}

public enum EvidenceQuality: String, Codable, CaseIterable, Sendable {
    case measured = "Measured"
    case derived = "Derived"
    case estimated = "Estimated"
    case partial = "Partial"
    case unavailable = "Unavailable"
}

public struct SkillExposure: Identifiable, Codable, Sendable, Equatable {
    public let logicalPath: String
    public let resolvedPath: String
    public let source: String
    public let scope: AIContextScope
    public let provider: AIContextProvider
    public let applicability: AIContextOrigin

    public var id: String { logicalPath }
}

public struct SkillRuntimePolicy: Identifiable, Codable, Sendable, Equatable {
    public let runtime: AgentRuntime
    public let mode: InvocationMode
    public let explicit: Bool
    public let reason: String
    public let invocation: String
    public let isExposed: Bool
    public let desiredMode: InvocationMode?

    public init(runtime: AgentRuntime, mode: InvocationMode, explicit: Bool, reason: String, invocation: String, isExposed: Bool = true, desiredMode: InvocationMode? = nil) {
        self.runtime = runtime
        self.mode = mode
        self.explicit = explicit
        self.reason = reason
        self.invocation = invocation
        self.isExposed = isExposed
        self.desiredMode = desiredMode
    }

    public var id: String { runtime.rawValue }
    public var evidence: EvidenceQuality { explicit ? .measured : .derived }
}

public struct SkillRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let logicalBytes: Int64
    public let modified: Date
    public let exposures: [SkillExposure]
    public let policies: [SkillRuntimePolicy]
    /// SHA-256 of the complete SKILL.md when it fit inside the bounded reader.
    /// A nil value means exact-copy analysis is unavailable, not that content differs.
    public let contentFingerprint: String?
    public var definitionConflictCount = 1

    public init(
        id: String,
        name: String,
        description: String,
        logicalBytes: Int64,
        modified: Date,
        exposures: [SkillExposure],
        policies: [SkillRuntimePolicy],
        contentFingerprint: String? = nil,
        definitionConflictCount: Int = 1
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.logicalBytes = logicalBytes
        self.modified = modified
        self.exposures = exposures
        self.policies = policies
        self.contentFingerprint = contentFingerprint
        self.definitionConflictCount = definitionConflictCount
    }

    public var needsReview: Bool { policies.contains { $0.mode == .unverified || ($0.desiredMode != nil && $0.desiredMode != $0.mode) } }
    public var manualOnlyCount: Int { policies.filter { $0.mode == .manualOnly }.count }
    public var automaticCount: Int { policies.filter { $0.mode == .automatic }.count }
    public var exposedRuntimes: [AgentRuntime] { policies.filter(\.isExposed).map(\.runtime) }
    public var hasDefinitionConflict: Bool { definitionConflictCount > 1 }

    public func policy(for runtime: AgentRuntime) -> SkillRuntimePolicy? {
        policies.first { $0.runtime == runtime }
    }

    public func needsReview(for runtime: AgentRuntime) -> Bool {
        guard let policy = policy(for: runtime) else { return true }
        return hasDefinitionConflict || policy.mode == .unverified || !policy.explicit
    }
}

public struct SkillGovernanceSummary: Sendable, Equatable {
    public let runtime: AgentRuntime
    public let totalCount: Int
    public let exposedCount: Int
    public let automaticCount: Int
    public let defaultAutomaticCount: Int
    public let manualOnlyCount: Int
    public let modelOnlyCount: Int
    public let disabledCount: Int
    public let notExposedCount: Int
    public let reviewCount: Int

    public init(records: [SkillRecord], runtime: AgentRuntime) {
        self.runtime = runtime
        totalCount = records.count
        let policies = records.compactMap { $0.policy(for: runtime) }
        exposedCount = policies.filter(\.isExposed).count
        automaticCount = policies.filter { $0.mode == .automatic }.count
        defaultAutomaticCount = policies.filter { $0.mode == .automatic && !$0.explicit }.count
        manualOnlyCount = policies.filter { $0.mode == .manualOnly }.count
        modelOnlyCount = policies.filter { $0.mode == .modelOnly }.count
        disabledCount = policies.filter { $0.mode == .disabled }.count
        notExposedCount = records.filter { $0.policy(for: runtime)?.isExposed != true }.count
        reviewCount = records.filter { $0.needsReview(for: runtime) }.count
    }
}

public struct SkillSharingSummary: Sendable, Equatable {
    public let totalCount: Int
    public let everyRuntimeCount: Int
    public let multipleRuntimeCount: Int
    public let singleRuntimeCount: Int
    public let definitionConflictCount: Int

    public init(records: [SkillRecord]) {
        totalCount = records.count
        everyRuntimeCount = records.filter { $0.exposedRuntimes.count == AgentRuntime.allCases.count }.count
        multipleRuntimeCount = records.filter { $0.exposedRuntimes.count > 1 && $0.exposedRuntimes.count < AgentRuntime.allCases.count }.count
        singleRuntimeCount = records.filter { $0.exposedRuntimes.count == 1 }.count
        definitionConflictCount = records.filter(\.hasDefinitionConflict).count
    }
}

public struct SkillCatalogSnapshot: Sendable, Equatable {
    public let records: [SkillRecord]
    public let coverage: AIContextCoverage
    public let generatedAt: Date

    public var physicalSkillCount: Int { records.count }
    public var exposureCount: Int { records.reduce(0) { $0 + $1.exposures.count } }
    public var reviewCount: Int { records.filter(\.needsReview).count }

    public func governance(for runtime: AgentRuntime) -> SkillGovernanceSummary {
        SkillGovernanceSummary(records: records, runtime: runtime)
    }

    public var sharing: SkillSharingSummary { SkillSharingSummary(records: records) }
}
