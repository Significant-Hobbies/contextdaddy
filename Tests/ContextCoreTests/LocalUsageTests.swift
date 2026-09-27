import Foundation
import Testing
@testable import ContextCore

struct LocalUsageTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!

    @Test func filtersServiceModelAndRangeWithoutDoubleCountingCacheReads() throws {
        let report = try fixture()
        let codex = try #require(report.slice(service: .codex, model: nil, range: .week, now: now))
        #expect(codex.generatedTokens == 14) // 3 input + 4 cache creation + 7 output
        #expect(codex.cacheReadTokens == 20)
        #expect(codex.observations == 1)
        #expect(codex.fallbackPricing)
        #expect(report.models(for: .codex, range: .week, now: now) == ["gpt-a"])

        let allCodex = try #require(report.slice(service: .codex, model: nil, range: .all, now: now))
        #expect(allCodex.generatedTokens == 19)
        #expect(allCodex.points.map(\.day) == ["2026-08-01", "2026-09-20"])
        let selected = try #require(report.slice(service: .codex, model: "gpt-a", range: .week, now: now))
        #expect(selected.generatedTokens == 14)
        #expect(report.slice(service: .cursor, model: nil, range: .all, now: now) == nil)
    }

    @Test func devinSurvivesIndependentCcusageFailure() throws {
        let report = try fixture(status: "unavailable")
        #expect(report.slice(service: .codex, model: nil, range: .week, now: now) == nil)
        let devin = try #require(report.slice(service: .devin, model: nil, range: .week, now: now))
        #expect(devin.generatedTokens == 23)
        #expect(devin.cacheReadTokens == 8)
        #expect(devin.source.contains("SQLite"))
        #expect(report.models(for: .devin, range: .week, now: now) == ["devin-model"])
    }

    @Test func dashboardReconcilesHistoryAndKeepsSessionAttributionSeparate() throws {
        let report = try fixture()
        let dashboard = UsageDashboardProjection(report: report, service: .codex, model: nil,
                                                 range: .week, scale: .week, metric: .generated, now: now)
        #expect(dashboard.slice?.generatedTokens == 14)
        #expect(dashboard.trend.count == 1)
        #expect(dashboard.trend.first?.period == "2026-09-14")
        #expect(dashboard.trend.first?.value == 14)
        #expect(dashboard.models.map(\.name) == ["gpt-a"])
        #expect(dashboard.sessionCount == 1)
        #expect(dashboard.attributedSessionCount == 1)
        #expect(dashboard.projects.first?.name == "alpha")
        #expect(dashboard.projects.first?.generatedTokens == 14)
        #expect(dashboard.recentSessions.first?.projectName == "alpha")

        let cost = UsageDashboardProjection(report: report, service: .codex, model: "gpt-a",
                                            range: .week, scale: .day, metric: .estimatedCost, now: now)
        #expect(cost.trend.first?.value == 0.02)
        #expect(cost.sessionCount == 1)
        let old = UsageDashboardProjection(report: report, service: .codex, model: nil,
                                           range: .all, scale: .month, metric: .cacheRead, now: now)
        #expect(old.trend.map(\.period) == ["2026-08", "2026-09"])
        #expect(old.trend.map(\.value) == [3, 20])
        #expect(old.sessionCount == 2)
        #expect(old.projects.contains { $0.name == "Unattributed" })
    }

    @Test func dashboardDoesNotFoldDevinIntoCcusageOrInventDailyHistory() throws {
        let report = try fixture(status: "unavailable")
        let dashboard = UsageDashboardProjection(report: report, service: .devin, model: nil,
                                                 range: .week, scale: .day, metric: .generated, now: now)
        #expect(dashboard.slice?.generatedTokens == 23)
        #expect(dashboard.sessionCount == 2)
        #expect(dashboard.trend.isEmpty)
        #expect(dashboard.recentSessions.isEmpty)
        #expect(dashboard.models.map(\.name) == ["devin-model"])
    }

    @Test func unifiedHistoryReconcilesModelsProjectsAndAgentFilters() throws {
        let report = try fixture()
        let all = UsageHistoryProjection(report: report, agents: [], range: .week, scale: .day,
                                         grouping: .model, metric: .generated, now: now)
        #expect(all.total == 18) // Codex 14 + Claude 4; This legacy fixture has no Devin daily records.
        #expect(all.buckets.count == 1)
        #expect(all.series.first?.label == "gpt-a")
        #expect(all.unattributed == 4) // Claude's missing model breakdown.
        #expect(all.buckets.first?.total == all.total)

        let project = UsageHistoryProjection(report: report, agents: [], range: .week, scale: .day,
                                             grouping: .project, metric: .generated, now: now)
        #expect(project.series.contains { $0.label == "alpha" && $0.value == 14 })
        #expect(project.total == 14) // Separate session ledger; no Claude session in fixture.
        #expect(project.unattributed == 0)

        let providers = UsageHistoryProjection(report: report, agents: [], range: .week, scale: .day,
                                               grouping: .provider, metric: .generated, now: now)
        #expect(providers.series.contains { $0.label == "OpenAI" && $0.value == 14 })
        #expect(providers.unattributed == 4)

        let devin = try #require(report.devin)
        let devinProviders = UsageHistoryProjection(devin: devin, range: .week, scale: .day,
                                                    grouping: .provider, metric: .generated, now: now)
        #expect(devinProviders.grouping == .provider)
        #expect(devinProviders.total == 0) // This old fixture has windows, not indexed days.

        let codex = UsageHistoryProjection(report: report, agents: ["codex"], range: .week, scale: .day,
                                           grouping: .model, metric: .cacheRead, now: now)
        #expect(codex.total == 20)
        #expect(codex.unattributed == 0)
    }

    @Test func decodesProviderAllowanceAsSeparateReceipt() throws {
        let json = Data(#"{"schema_version":"codevetter.provider-quota/v1","generated_at":"2026-09-23T12:00:00Z","providers":[{"provider":"claude","status":"ready","source":"app-server","checked_at":"2026-09-23T12:00:00Z","plan":"max","windows":[{"id":"primary","label":"5 hours","used_percent":25.0,"remaining_percent":75.0,"window_duration_minutes":300,"resets_at_unix":1790164800,"reset_description":"Soon"},{"id":"weekly","label":"7 days","remaining_percent":45.0}],"credits":{"remaining_percent":60.0},"reset_credits":2,"message":null}]}"#.utf8)
        let receipt = try JSONDecoder().decode(ProviderQuotaReceipt.self, from: json)
        #expect(receipt.providers.first?.windows.first?.remainingPercent == 75)
        #expect(receipt.providers.first?.windows.first?.windowDurationMinutes == 300)
        #expect(receipt.providers.first?.windows.count == 2)
        #expect(receipt.providers.first?.plan == "max")
        #expect(receipt.providers.first?.credits?.remainingPercent == 60)
        #expect(receipt.providers.first?.resetCredits == 2)
        #expect(UsageService.devin.quotaKey == nil)
    }

    @Test func devinDailyHistoryJoinsUnifiedTotalsAndRespectsFilters() throws {
        let json = Data(#"{"status":"ready","source":"fixture","windows":[],"daily":[{"period":"2026-09-20","sessions":2,"generated_tokens":30,"cache_read_tokens":5,"models":[{"model":"swe-2-high","sessions":1,"generated_tokens":20,"cache_read_tokens":3,"cost_usd":0},{"model":"glm-5-2","sessions":1,"generated_tokens":10,"cache_read_tokens":2,"cost_usd":0}]}],"limitations":[],"cost_available":false}"#.utf8)
        let devin = try JSONDecoder().decode(DevinUsage.self, from: json)
        let projection = UsageHistoryProjection(devin: devin, range: .week, scale: .day,
                                                grouping: .provider, metric: .generated, now: now)
        #expect(projection.total == 30)
        #expect(projection.series.contains { $0.label == "Cognition" && $0.value == 20 })
        #expect(projection.series.contains { $0.label == "Z.ai" && $0.value == 10 })
        let report = try fixture().withDevin(devin)
        for scale in UsageChartScale.allCases {
            let combined = UsageHistoryProjection(report: report, agents: [], range: .week, scale: scale,
                                                   grouping: .provider, metric: .generated, now: now)
            #expect(combined.total == 48)
            #expect(combined.buckets.reduce(0) { $0 + $1.total } == 48)
            #expect(combined.series.contains { $0.label == "Cognition" && $0.value == 20 })
            #expect(combined.series.contains { $0.label == "OpenAI" && $0.value == 14 })
        }
        let excluded = UsageHistoryProjection(report: report, agents: ["codex", "claude"], range: .week,
                                               scale: .day, grouping: .model, metric: .generated, now: now)
        #expect(excluded.total == 18)
        let cache = UsageHistoryProjection(report: report, agents: [], range: .week,
                                           scale: .day, grouping: .model, metric: .cacheRead, now: now)
        #expect(cache.total == 26)
        let onlyDevin = UsageHistoryProjection(report: report, agents: ["devin"], range: .week,
                                               scale: .day, grouping: .model, metric: .generated, now: now)
        #expect(onlyDevin.total == 30)
        let cost = UsageHistoryProjection(report: report, agents: [], range: .week,
                                          scale: .day, grouping: .model, metric: .estimatedCost, now: now)
        #expect(abs(cost.total - 0.03) < 0.000001)
        let project = UsageHistoryProjection(report: report, agents: ["devin"], range: .week,
                                             scale: .day, grouping: .project, metric: .generated, now: now)
        #expect(project.buckets.isEmpty)
        let independent = UsageHistoryProjection(report: LocalUsageReport.unavailable(message: "offline").withDevin(devin),
                                                 agents: [], range: .week, scale: .day,
                                                 grouping: .model, metric: .generated, now: now)
        #expect(independent.total == 30)
        let outside = UsageHistoryProjection(report: report, agents: ["devin"], range: .week,
                                             scale: .day, grouping: .model, metric: .generated,
                                             now: now.addingTimeInterval(30 * 86400))
        #expect(outside.total == 0)
        let incomplete = DevinUsage(status: "ready", source: "fixture", windows: [],
            daily: [DevinUsageDay(period: "2026-09-20", sessions: 1, generatedTokens: 50,
                                  cacheReadTokens: 1, models: devin.daily![0].models)], limitations: [], costAvailable: false)
        let reconciled = UsageHistoryProjection(devin: incomplete, range: .week, scale: .day,
                                               metric: .generated, now: now)
        #expect(reconciled.total == 50)
        #expect(reconciled.unattributed == 20)
        let inconsistent = UsageHistoryProjection(devin: incomplete, range: .week, scale: .day,
                                                  metric: .cacheRead, now: now)
        #expect(inconsistent.total == 1)
        #expect(inconsistent.unattributed == 1)

    }

    private func fixture(status: String = "ready") throws -> LocalUsageReport {
        let json = """
        {
          "status":"\(status)","stale":false,"error":null,
          "provenance":{"engine":"ccusage","version":"20.0.24","generated_at":"2026-09-23T12:00:00Z","timezone":"UTC","pricing_complete":true,"fallback_models":[],"unpriced_models":[]},
          "daily":[
            {"period":"2026-08-01","agents":[{"agent":"codex","totals":\(totals(1, 1, 3, 3, 8, 0.01)),"models":[{"model":"gpt-old","totals":\(totals(1, 1, 3, 3, 8, 0.01)),"fallback":false,"priced":true}]}]},
            {"period":"2026-09-20","agents":[{"agent":"codex","totals":\(totals(3, 4, 20, 7, 34, 0.02)),"models":[{"model":"gpt-a","totals":\(totals(3, 4, 20, 7, 34, 0.02)),"fallback":true,"priced":true}]},{"agent":"claude","totals":\(totals(2, 0, 1, 2, 5, 0.01)),"models":[]}],"projects":[{"project":"/projects/alpha","agent":"codex","totals":\(totals(3, 4, 20, 7, 34, 0.02))}]}
          ],
          "sessions":[
            {"session_id":"codex-new","agent":"codex","last_activity":"2026-09-20T12:00:00Z","project":"/projects/alpha","reasoning_output_tokens":2,"totals":\(totals(3, 4, 20, 7, 34, 0.02)),"models":[{"model":"gpt-a","totals":\(totals(3, 4, 20, 7, 34, 0.02)),"fallback":true,"priced":true}]},
            {"session_id":"codex-old","agent":"codex","last_activity":"2026-08-01T12:00:00Z","project":null,"reasoning_output_tokens":0,"totals":\(totals(1, 1, 3, 3, 8, 0.01)),"models":[{"model":"gpt-old","totals":\(totals(1, 1, 3, 3, 8, 0.01)),"fallback":false,"priced":true}]}
          ],
          "devin":{"status":"ready","source":"CodeVetter SQLite · indexed Devin sessions.db","limitations":[],"windows":[{"window":"1w","sessions":2,"generated_tokens":23,"cache_read_tokens":8,"cost_usd":0.3,"models":[{"model":"devin-model","sessions":2,"generated_tokens":23,"cache_read_tokens":8,"cost_usd":0.3}]}]}
        }
        """
        return try JSONDecoder().decode(LocalUsageReport.self, from: Data(json.utf8))
    }

    private func totals(_ input: Int, _ creation: Int, _ read: Int, _ output: Int, _ total: Int, _ cost: Double) -> String {
        "{\"input_tokens\":\(input),\"cache_creation_tokens\":\(creation),\"cache_read_tokens\":\(read),\"output_tokens\":\(output),\"total_tokens\":\(total),\"cost_usd\":\(cost)}"
    }
}
