import Foundation

/// Persists the last skill-history scan so recorded counts survive relaunch.
/// Stores only skill names, evidence kinds, dates, session file paths and project paths.
public actor SkillActivitySnapshotStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContextDaddy", isDirectory: true)
        fileURL = base.appendingPathComponent("skill-activity.json")
    }

    public func load() -> SkillActivitySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SkillActivitySnapshot.self, from: data)
    }

    public func save(_ snapshot: SkillActivitySnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

/// Review findings for model-invocable skills with no recorded invocation in the scanned
/// Codex and Claude history. Stated as a measurement with its coverage, never as "unused".
public enum SkillActivityFindings {
    static let runtimes: [AgentRuntime] = [.codex, .claude]

    public static func zeroInvocations(records: [SkillRecord], snapshot: SkillActivitySnapshot) -> (issues: [ConfigurationHealthIssue], files: [ConfigurationFileCheck]) {
        let coverage = runtimes.compactMap { runtime in snapshot.coverage.first { $0.runtime == runtime } }
        guard coverage.contains(where: { $0.files > 0 }) else { return ([], []) }
        let sessions = coverage.map { "\($0.files) \($0.runtime.rawValue)" }.joined(separator: " + ")
        let days = coverage.compactMap(\.firstDay).min().flatMap { first in coverage.compactMap(\.lastDay).max().map { first == $0 ? first : "\(first) to \($0)" } }
        let partial = coverage.contains(where: \.partial) ? " Coverage is partial: " + coverage.filter(\.partial).map { "\($0.runtime.rawValue) \($0.note)" }.joined(separator: "; ") + "." : ""
        let scanned = ISO8601DateFormatter.string(from: snapshot.scannedAt, timeZone: .current, formatOptions: [.withFullDate])
        var issues: [ConfigurationHealthIssue] = []
        var files: [ConfigurationFileCheck] = []
        for record in records where record.ownership != .plugin {
            let invocable = runtimes.filter { runtime in
                guard let policy = record.policy(for: runtime) else { return false }
                return policy.isExposed && policy.mode == .automatic
            }
            guard let runtime = invocable.first else { continue }
            let summary = snapshot.summary(for: record)
            let recorded = summary.observations.filter { runtimes.contains($0.runtime) }.count
            files.append(.init(runtime: runtime, path: record.id, status: .checked, detail: "Recorded invocations in scanned history: \(recorded)."))
            guard recorded == 0 else { continue }
            issues.append(.init(
                id: "\(runtime.rawValue)-skill-zero-invocations-\(record.id)", severity: .warning, runtime: runtime,
                title: "No recorded invocations",
                detail: "Measured: 0 invocations of `\(record.name)` in \(sessions) session files\(days.map { ", modified \($0)" } ?? "") (scanned \(scanned)). Counted: Claude Skill tool calls and slash commands, Codex SKILL.md tool reads and `$name` mentions. It is model-invocable for \(invocable.map(\.rawValue).joined(separator: " and ")), so its description is offered in those sessions. Deleted, remote or other agents' sessions are not covered.\(partial)",
                path: record.id, line: 1,
                remediation: "Decide whether `\(record.name)` still needs automatic invocation. Keep it if it covers rare work; otherwise make it manual-only or archive it through the skill library."))
        }
        return (issues, files)
    }
}
