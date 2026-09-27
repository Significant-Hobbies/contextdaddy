import CryptoKit
import Foundation

public enum CCUsageError: Error, LocalizedError, Sendable, Equatable {
    case missingBinary
    case unsupportedVersion
    case launchFailed
    case timedOut
    case oversizedOutput
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .missingBinary: "ccusage is not bundled or installed in a supported local location."
        case .unsupportedVersion: "ContextDaddy requires the pinned ccusage 20.0.24 JSON contract."
        case .launchFailed: "ccusage could not be started."
        case .timedOut: "ccusage did not finish within 45 seconds."
        case .oversizedOutput: "ccusage returned more than 40 MiB of local usage data."
        case .invalidOutput: "ccusage did not return the expected local usage JSON."
        }
    }
}

/// Runs the upstream ccusage binary directly. It never launches CodeVetter,
/// reads provider credentials, or sends usage data to a network endpoint.
public struct CCUsageClient: Sendable {
    public static let pinnedVersion = "20.0.24"
    private let executableURL: URL?
    private let timeout: TimeInterval = 45
    private let outputLimit = 40 * 1024 * 1024

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    public func loadUsage(refresh: Bool = false) async throws -> LocalUsageReport {
        try await Task.detached(priority: refresh ? .userInitiated : .utility) {
            guard let executable = resolvedExecutable() else { throw CCUsageError.missingBinary }
            let versionData = try run(executable: executable, arguments: ["--version"])
            guard String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                == "ccusage \(Self.pinnedVersion)" else { throw CCUsageError.unsupportedVersion }
            let timezone = TimeZone.current.identifier
            let primary = try runReport(executable: executable, arguments: [
                "daily", "--sections", "daily,session", "--by-agent", "--json", "--offline",
                "--timezone", timezone, "--no-color",
            ])
            // Claude project attribution is optional enrichment, not a second
            // accounting source. A failed or mismatched scan leaves it absent.
            let projects = try? runReport(executable: executable, arguments: [
                "claude", "daily", "--instances", "--json", "--offline",
                "--timezone", timezone, "--no-color",
            ])
            var sessionProjects: [String: Data] = [:]
            for agent in ["claude", "grok"] {
                sessionProjects[agent] = try? runReport(executable: executable, arguments: [
                    agent, "session", "--json", "--offline", "--timezone", timezone, "--no-color",
                ])
            }
            let codexProjects = (try? CodexSessionProjectIndex().load()) ?? [:]
            return try CCUsageNormalizer.normalize(primary, projects: projects,
                                                   version: Self.pinnedVersion,
                                                   sessionProjects: sessionProjects,
                                                   codexProjectPaths: codexProjects, timezone: timezone)
        }.value
    }

    private func runReport(executable: URL, arguments: [String]) throws -> Data {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextdaddy-ccusage-config-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: configURL.path, contents: Data("{}".utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CCUsageError.launchFailed
        }
        defer { try? FileManager.default.removeItem(at: configURL) }
        return try run(executable: executable, arguments: arguments + ["--config", configURL.path])
    }

    private func run(executable: URL, arguments: [String]) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextdaddy-ccusage-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CCUsageError.launchFailed
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never surface paths or provider diagnostics.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CCUSAGE_TIMEZONE")
        environment.removeValue(forKey: "LOG_LEVEL")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        do { try process.run() } catch { throw CCUsageError.launchFailed }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw CCUsageError.timedOut
        }
        process.waitUntilExit()
        try output.synchronize()
        let bytes = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= outputLimit else { throw CCUsageError.oversizedOutput }
        guard process.terminationStatus == 0, bytes > 0 else { throw CCUsageError.invalidOutput }
        return try Data(contentsOf: outputURL)
    }

    private func resolvedExecutable() -> URL? {
        if let executableURL {
            return FileManager.default.isExecutableFile(atPath: executableURL.path) ? executableURL : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ccusage"),
            home.appendingPathComponent(".local/bin/ccusage"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ccusage"),
            URL(fileURLWithPath: "/usr/local/bin/ccusage"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum CCUsageNormalizer {
    static func normalize(_ data: Data, projects: Data?, version: String,
                          sessionProjects: [String: Data] = [:],
                          codexProjectPaths: [String: String] = [:],
                          timezone: String, now: Date = Date()) throws -> LocalUsageReport {
        guard let raw = try? JSONDecoder().decode(CCRawReport.self, from: data) else {
            throw CCUsageError.invalidOutput
        }
        let accounted: Set<String> = ["claude", "codex", "grok"]
        var detected = Set<String>()
        var fallback = Set<String>()
        var unpriced = Set<String>()
        let days = try raw.daily.map { day -> UsageDay in
            guard Self.validDay(day.period) else { throw CCUsageError.invalidOutput }
            let agents = try day.agents.filter { accounted.contains($0.agent) }.map { agent -> UsageAgent in
                detected.insert(agent.agent)
                let models = try agent.modelBreakdowns.map { model -> UsageModel in
                    let normalized = try model.normalized()
                    if normalized.fallback { fallback.insert(normalized.model) }
                    if !normalized.priced { unpriced.insert(normalized.model) }
                    return normalized
                }
                return UsageAgent(agent: agent.agent, totals: try agent.totals.normalized(), models: models)
            }
            return UsageDay(period: day.period, agents: agents, projects: nil)
        }.sorted { $0.period < $1.period }
        var directoryByAgent: [String: [String: String]] = [:]
        for (agent, projectData) in sessionProjects {
            directoryByAgent[agent] = (try? Self.sessionDirectories(projectData, agent: agent)) ?? [:]
        }
        let sessions = try raw.session.filter { accounted.contains($0.agent) }.map { session -> UsageSession in
            detected.insert(session.agent)
            return UsageSession(sessionID: session.period, agent: session.agent,
                                lastActivity: session.metadata?.lastActivity,
                                project: session.agent == "codex" ? codexProjectPaths[session.period]
                                    : directoryByAgent[session.agent]?[session.period],
                                reasoningOutputTokens: session.metadata?.reasoningOutputTokens ?? 0,
                                totals: try session.totals.normalized(),
                                models: try session.modelBreakdowns.map { try $0.normalized() })
        }
        let enriched = (try? attachProjects(projects, to: days)) ?? days
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let generatedAt = ISO8601DateFormatter().string(from: now)
        let provenance = UsageProvenance(engine: "ccusage", version: version,
                                         generatedAt: generatedAt, timezone: timezone,
                                         pricingComplete: unpriced.isEmpty,
                                         fallbackModels: fallback.sorted(), unpricedModels: unpriced.sorted(),
                                         detectedAgents: detected.sorted(), sourceFingerprint: "sha256:\(digest)",
                                         window: "all")
        return LocalUsageReport(status: "ready", stale: false, error: nil,
                                     provenance: provenance, daily: enriched, sessions: sessions, devin: nil)
    }

    private static func sessionDirectories(_ data: Data, agent: String) throws -> [String: String] {
        let report = try JSONDecoder().decode(CCSessionProjectReport.self, from: data)
        var results: [String: String] = [:]
        for session in report.sessions {
            guard let directory = session.directory ?? session.projectPath,
                  directory.utf8.count <= 4096,
                  !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !session.sessionId.isEmpty else { continue }
            let absolutePath = directory.hasPrefix("/") && directory != "/"
            let claudeSlug = agent == "claude" && directory.count > 1 && directory.hasPrefix("-")
                && directory.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._")).contains($0)
                }
            guard absolutePath || claudeSlug else { continue }
            if let existing = results[session.sessionId], existing != directory {
                throw CCUsageError.invalidOutput
            }
            results[session.sessionId] = directory
        }
        return results
    }

    private static func attachProjects(_ data: Data?, to days: [UsageDay]) throws -> [UsageDay] {
        guard let data else { return days }
        let raw = try JSONDecoder().decode(CCProjectReport.self, from: data)
        var rowsByDay: [String: [UsageDayProject]] = [:]
        for (project, rows) in raw.projects {
            guard !project.trimmingCharacters(in: .whitespaces).isEmpty,
                  project.utf8.count <= 4096,
                  !project.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CCUsageError.invalidOutput
            }
            var seen = Set<String>()
            for row in rows {
                guard validDay(row.date), seen.insert(row.date).inserted else { throw CCUsageError.invalidOutput }
                rowsByDay[row.date, default: []].append(
                    UsageDayProject(project: project, agent: "claude", totals: try row.totals.normalized()))
            }
        }
        return days.map { day in
            guard let rows = rowsByDay[day.period],
                  let canonical = day.agents.first(where: { $0.agent == "claude" })?.totals,
                  let sum = sum(rows.map(\.totals)), within(sum, canonical) else { return day }
            return UsageDay(period: day.period, agents: day.agents, projects: rows)
        }
    }

    private static func validDay(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil
    }

    private static func sum(_ values: [UsageTotals]) -> UsageTotals? {
        func added(_ values: [UInt64]) -> UInt64? {
            var total: UInt64 = 0
            for value in values {
                let (next, overflow) = total.addingReportingOverflow(value)
                if overflow { return nil }
                total = next
            }
            return total
        }
        let cost = values.reduce(0) { $0 + $1.costUSD }
        guard cost.isFinite,
              let input = added(values.map(\.inputTokens)),
              let cacheCreation = added(values.map(\.cacheCreationTokens)),
              let cacheRead = added(values.map(\.cacheReadTokens)),
              let output = added(values.map(\.outputTokens)),
              let total = added(values.map(\.totalTokens)) else { return nil }
        return UsageTotals(inputTokens: input, cacheCreationTokens: cacheCreation,
                           cacheReadTokens: cacheRead, outputTokens: output,
                           totalTokens: total, costUSD: cost)
    }

    private static func within(_ value: UsageTotals, _ limit: UsageTotals) -> Bool {
        value.inputTokens <= limit.inputTokens && value.outputTokens <= limit.outputTokens &&
        value.cacheCreationTokens <= limit.cacheCreationTokens && value.cacheReadTokens <= limit.cacheReadTokens &&
        value.totalTokens <= limit.totalTokens && value.costUSD <= limit.costUSD + 0.000_001
    }
}

private struct CCRawReport: Decodable {
    let daily: [CCRawDay]
    let session: [CCRawSession]
}

private struct CCRawDay: Decodable {
    let period: String
    let agents: [CCRawAgent]
}

private struct CCRawAgent: Decodable {
    let agent: String
    let totals: CCRawTotals
    let modelBreakdowns: [CCRawModel]

    private enum CodingKeys: String, CodingKey { case agent, modelBreakdowns }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        modelBreakdowns = try container.decodeIfPresent([CCRawModel].self, forKey: .modelBreakdowns) ?? []
        totals = try CCRawTotals(from: decoder)
    }
}

private struct CCRawSession: Decodable {
    let agent: String
    let period: String
    let metadata: CCRawMetadata?
    let modelBreakdowns: [CCRawModel]
    let totals: CCRawTotals

    private enum CodingKeys: String, CodingKey { case agent, period, metadata, modelBreakdowns }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(String.self, forKey: .agent)
        period = try container.decode(String.self, forKey: .period)
        metadata = try container.decodeIfPresent(CCRawMetadata.self, forKey: .metadata)
        modelBreakdowns = try container.decodeIfPresent([CCRawModel].self, forKey: .modelBreakdowns) ?? []
        totals = try CCRawTotals(from: decoder)
    }
}

private struct CCRawMetadata: Decodable {
    let lastActivity: String?
    let reasoningOutputTokens: UInt64?
}

private struct CCRawTotals: Decodable {
    let inputTokens: UInt64
    let cacheCreationTokens: UInt64
    let cacheReadTokens: UInt64
    let outputTokens: UInt64
    let totalTokens: UInt64
    let totalCost: Double

    func normalized() throws -> UsageTotals {
        guard totalCost.isFinite, totalCost >= 0 else { throw CCUsageError.invalidOutput }
        return UsageTotals(inputTokens: inputTokens, cacheCreationTokens: cacheCreationTokens,
                           cacheReadTokens: cacheReadTokens, outputTokens: outputTokens,
                           totalTokens: totalTokens, costUSD: totalCost)
    }
}

private struct CCRawModel: Decodable {
    let cacheCreationTokens: UInt64
    let cacheReadTokens: UInt64
    let cost: Double
    let inputTokens: UInt64
    let isFallback: Bool?
    let modelName: String
    let outputTokens: UInt64

    func normalized() throws -> UsageModel {
        guard cost.isFinite, cost >= 0, !modelName.isEmpty else { throw CCUsageError.invalidOutput }
        let components = [inputTokens, cacheCreationTokens, cacheReadTokens, outputTokens]
        var total: UInt64 = 0
        for component in components {
            let (next, overflow) = total.addingReportingOverflow(component)
            guard !overflow else { throw CCUsageError.invalidOutput }
            total = next
        }
        let totals = UsageTotals(inputTokens: inputTokens, cacheCreationTokens: cacheCreationTokens,
                                 cacheReadTokens: cacheReadTokens, outputTokens: outputTokens,
                                 totalTokens: total, costUSD: cost)
        return UsageModel(model: modelName, totals: totals, fallback: isFallback ?? false,
                          priced: total == 0 || cost > 0)
    }
}

private struct CCProjectReport: Decodable {
    let projects: [String: [CCProjectDay]]
}

private struct CCProjectDay: Decodable {
    let date: String
    let totals: CCRawTotals
    private enum CodingKeys: String, CodingKey { case date }
    init(from decoder: Decoder) throws {
        date = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .date)
        totals = try CCRawTotals(from: decoder)
    }
}

private struct CCSessionProjectReport: Decodable {
    let sessions: [CCSessionProject]
}

private struct CCSessionProject: Decodable {
    let sessionId: String
    let directory: String?
    let projectPath: String?
}
