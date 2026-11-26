import Foundation
import Testing
@testable import ContextCore
@testable import ContextDaddy

@MainActor
struct UnifiedHistoryTests {
    @Test func devinUsesSharedFiltersAndUnavailableStates() {
        let model = ContextDaddyModel()
        let day = DevinUsageDay(period: "2026-09-20", sessions: 1, generatedTokens: 50, cacheReadTokens: 10,
                                models: [DevinUsageModel(model: "swe-2-high", sessions: 1,
                                                       generatedTokens: 50, cacheReadTokens: 10, costUSD: 0)])
        model.usageReport = LocalUsageReport.unavailable(message: "offline").withDevin(
            DevinUsage(status: "ready", source: "fixture", windows: [], daily: [day], limitations: [], costAvailable: false))
        model.usageRange = .all
        #expect(model.availableHistoryAgents.contains("devin"))
        #expect(model.usageHistory?.total == 50)
        model.usageHistoryAgents = ["codex"]
        #expect(model.usageHistory?.total == 0)
        #expect(model.historySourceNotice.isEmpty)
        model.usageHistoryAgents = ["devin"]
        #expect(model.usageHistory?.total == 50)
        model.usageMetric = .estimatedCost
        #expect(model.historySourceNotice.contains("cost unavailable"))
        #expect(model.usageHistory?.buckets.isEmpty == true)
        model.usageHistoryGrouping = .project
        #expect(model.historySourceNotice.contains("project attribution unavailable"))
        model.usageReport = model.usageReport?.withDevin(.unavailable(message: "Index unreadable"))
        #expect(model.historySourceNotice.contains("Devin history unavailable"))
        #expect(model.historySourceNotice.contains("Index unreadable"))
        model.isDevinLoading = true
        #expect(model.historySourceNotice.contains("Reading Devin"))
    }
}
