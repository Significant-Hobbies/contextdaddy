import Foundation
import Testing
@testable import ContextCore

struct CCUsageClientTests {
    private let unified = Data(#"""
    {
      "daily": [{
        "period":"2026-09-23", "agents":[
          {"agent":"claude","inputTokens":4,"cacheCreationTokens":2,"cacheReadTokens":5,"outputTokens":1,"totalTokens":12,"totalCost":0,
           "modelBreakdowns":[{"modelName":"claude-opus-5","inputTokens":4,"cacheCreationTokens":2,"cacheReadTokens":5,"outputTokens":1,"cost":0}]},
          {"agent":"codex","inputTokens":6,"cacheCreationTokens":0,"cacheReadTokens":15,"outputTokens":4,"totalTokens":25,"totalCost":0.3,
           "modelBreakdowns":[{"modelName":"gpt-5.6-sol","inputTokens":6,"cacheCreationTokens":0,"cacheReadTokens":15,"outputTokens":4,"cost":0.3,"isFallback":true}]},
          {"agent":"grok","inputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":0,"outputTokens":2,"totalTokens":4,"totalCost":0.02},
          {"agent":"goose","inputTokens":99,"cacheCreationTokens":0,"cacheReadTokens":0,"outputTokens":1,"totalTokens":100,"totalCost":2}
        ]
      }],
      "session":[
        {"agent":"codex","period":"codex-session","inputTokens":6,"cacheCreationTokens":0,"cacheReadTokens":15,"outputTokens":4,"totalTokens":25,"totalCost":0.3,"metadata":{"lastActivity":"2026-09-23T10:00:00Z","reasoningOutputTokens":2}},
        {"agent":"claude","period":"claude-session","inputTokens":4,"cacheCreationTokens":2,"cacheReadTokens":5,"outputTokens":1,"totalTokens":12,"totalCost":0,"metadata":{"lastActivity":"2026-09-23T11:00:00Z"}}
      ],
      "totals":{"inputTokens":111,"cacheCreationTokens":2,"cacheReadTokens":20,"outputTokens":8,"totalTokens":141,"totalCost":2.32}
    }
    """#.utf8)

    @Test func mapsDirectCcusageWithoutOtherAgentsOrDevin() throws {
        let report = try CCUsageNormalizer.normalize(unified, projects: nil, version: "20.0.24", timezone: "UTC")
        #expect(report.provenance.engine == "ccusage")
        #expect(report.provenance.detectedAgents == ["claude", "codex", "grok"])
        #expect(report.daily[0].agents.count == 3)
        #expect(report.daily[0].agents.first { $0.agent == "claude" }?.totals.generatedTokens == 7)
        #expect(report.daily[0].agents.first { $0.agent == "codex" }?.models.first?.fallback == true)
        #expect(report.provenance.unpricedModels == ["claude-opus-5"])
        #expect(report.sessions?.first?.reasoningOutputTokens == 2)
        #expect(report.devin == nil)
    }

    @Test func projectAttributionCannotInflateCanonicalClaudeDay() throws {
        let accepted = Data(#"{"projects":{"alpha":[{"date":"2026-09-23","inputTokens":4,"cacheCreationTokens":2,"cacheReadTokens":5,"outputTokens":1,"totalTokens":12,"totalCost":0}]}}"#.utf8)
        let acceptedReport = try CCUsageNormalizer.normalize(unified, projects: accepted, version: "20.0.24", timezone: "UTC")
        #expect(acceptedReport.daily[0].projects?.first?.project == "alpha")

        let excess = Data(#"{"projects":{"alpha":[{"date":"2026-09-23","inputTokens":50,"cacheCreationTokens":2,"cacheReadTokens":5,"outputTokens":1,"totalTokens":58,"totalCost":0}]}}"#.utf8)
        let rejectedReport = try CCUsageNormalizer.normalize(unified, projects: excess, version: "20.0.24", timezone: "UTC")
        #expect(rejectedReport.daily[0].projects == nil)
        #expect(rejectedReport.daily[0].agents.first { $0.agent == "claude" }?.totals.totalTokens == 12)
    }

    @Test func sessionProjectEnrichmentUsesOnlyMatchingAgentSessionIDs() throws {
        let report = try CCUsageNormalizer.normalize(unified, projects: nil, version: "20.0.24",
                                                   codexProjectPaths: ["codex-session": "/projects/alpha",
                                                                       "other": "/projects/wrong"], timezone: "UTC")
        #expect(report.sessions?.first?.project == "/projects/alpha")
        #expect(report.daily[0].projects == nil)

        let claude = Data(#"{"sessions":[{"sessionId":"claude-session","projectPath":"-Users-sarthak-Desktop-vaultwealth-polaris"}]}"#.utf8)
        let both = try CCUsageNormalizer.normalize(unified, projects: nil, version: "20.0.24",
                                                  sessionProjects: ["claude": claude],
                                                  codexProjectPaths: ["codex-session": "/projects/alpha"], timezone: "UTC")
        #expect(both.sessions?.first { $0.agent == "claude" }?.project == "-Users-sarthak-Desktop-vaultwealth-polaris")
        #expect(UsageProjectIdentity.name("-Users-sarthak-Desktop-vaultwealth-polaris") == "vaultwealth-polaris")

        let invalid = Data(#"{"sessions":[{"sessionId":"claude-session","projectPath":"relative/path"}]}"#.utf8)
        let ignored = try CCUsageNormalizer.normalize(unified, projects: nil, version: "20.0.24",
                                                    sessionProjects: ["claude": invalid], timezone: "UTC")
        #expect(ignored.sessions?.first { $0.agent == "claude" }?.project == nil)
    }

    @Test func missingBinaryIsAnUnavailableState() async {
        let client = CCUsageClient(executableURL: URL(fileURLWithPath: "/private/tmp/contextdaddy-missing-ccusage"))
        do {
            _ = try await client.loadUsage()
            Issue.record("Missing ccusage must not become a zero report")
        } catch let error as CCUsageError {
            #expect(error == .missingBinary)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func installedBinaryIntegrationWhenConfigured() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundled = root.appendingPathComponent("artifacts/ContextDaddy.app/Contents/Helpers/ccusage")
        guard let path = ProcessInfo.processInfo.environment["CONTEXTDADDY_CCUSAGE_TEST_BIN"] ??
                (FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled.path : nil) else { return }
        let report = try await CCUsageClient(executableURL: URL(fileURLWithPath: path)).loadUsage()
        #expect(report.status == "ready")
        #expect(report.provenance.engine == "ccusage")
        #expect(report.provenance.version == CCUsageClient.pinnedVersion)
        #expect(report.daily.allSatisfy { $0.period.count == 10 })
    }
}
