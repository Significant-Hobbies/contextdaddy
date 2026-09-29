import Foundation

public struct SkillFolderAgent: Identifiable, Sendable {
    public let runtime: AgentRuntime
    public let records: [SkillRecord]
    public let sources: [AIContextContribution]
    public var id: String { runtime.rawValue }
    public var summary: SkillGovernanceSummary { .init(records: records, runtime: runtime) }
    public var names: Int { Set(records.map { $0.name.lowercased() }).count }
    public var globalCount: Int { records.filter { $0.exposures.contains { $0.scope == .global } }.count }
    public var projectCount: Int { records.count - globalCount }
}

public struct SkillFolderContext: Sendable {
    public let path: String
    public let agents: [SkillFolderAgent]
    public let records: [SkillRecord]
    public let coverage: AIContextCoverage

    public static func resolve(report: AIContextDiscoveryReport, directory: URL) -> Self {
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let rankings = AIContextDiscovery.rankings(items: report.items, in: directory, preserveSkillAliases: true)
        let agents = AgentRuntime.allCases.map { runtime in
            let sources = rankings.first { $0.provider.rawValue == runtime.rawValue }?.sources.filter { $0.origin != .installedOnly } ?? []
            let scoped = AIContextDiscoveryReport(items: sources.map(\.item), folderRankings: [], coverage: report.coverage, elapsed: report.elapsed)
            let records = SkillPolicyResolver.resolve(report: scoped).records.filter { $0.policy(for: runtime)?.isExposed == true }
            return SkillFolderAgent(runtime: runtime, records: records, sources: sources)
        }
        let grouped = Dictionary(grouping: agents.flatMap(\.records), by: \.id)
        let records = grouped.values.compactMap { copies -> SkillRecord? in
            guard let first = copies.first else { return nil }
            let exposures = Dictionary(grouping: copies.flatMap(\.exposures), by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
            let policies = agents.map { agent in
                agent.records.first { $0.id == first.id }?.policy(for: agent.runtime)
                    ?? SkillRuntimePolicy(runtime: agent.runtime, mode: .unsupported, explicit: true,
                                          reason: "No applicable exposure in this folder.", invocation: "", isExposed: false)
            }
            return SkillRecord(id: first.id, name: first.name, description: first.description, logicalBytes: first.logicalBytes,
                               modified: first.modified, exposures: exposures, policies: policies, contentFingerprint: first.contentFingerprint)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Self(path: path, agents: agents, records: records, coverage: report.coverage)
    }
}
