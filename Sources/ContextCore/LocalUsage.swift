import Foundation

public enum UsageService: String, CaseIterable, Identifiable, Sendable {
    case codex = "OpenAI / Codex"
    case claude = "Anthropic / Claude"
    case grok = "Grok"
    case devin = "Devin"
    case cursor = "Cursor"

    public var id: String { rawValue }
    public var menuTitle: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .devin: "Devin"
        case .cursor: "Cursor"
        }
    }
    public var agentKey: String? {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .grok: "grok"
        case .devin, .cursor: nil
        }
    }
    public var quotaKey: String? {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .grok: "grok"
        case .devin, .cursor: nil
        }
    }
}

public enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case week = "1w"
    case month = "30d"
    case quarter = "90d"
    case all = "all"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .all: "All history"
        }
    }
    private var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }

    public func includes(day: String, now: Date, timezone: String) -> Bool {
        guard let days else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return day >= formatter.string(from: start) && day <= formatter.string(from: now)
    }
}

public struct UsageTotals: Decodable, Sendable, Equatable {
    public let inputTokens: UInt64
    public let cacheCreationTokens: UInt64
    public let cacheReadTokens: UInt64
    public let outputTokens: UInt64
    public let totalTokens: UInt64
    public let costUSD: Double

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", cacheCreationTokens = "cache_creation_tokens"
        case cacheReadTokens = "cache_read_tokens", outputTokens = "output_tokens"
        case totalTokens = "total_tokens", costUSD = "cost_usd"
    }

    public var generatedTokens: UInt64 {
        let (first, firstOverflow) = inputTokens.addingReportingOverflow(cacheCreationTokens)
        let (second, secondOverflow) = first.addingReportingOverflow(outputTokens)
        return firstOverflow || secondOverflow ? UInt64.max : second
    }
}

public struct UsageModel: Decodable, Sendable {
    public let model: String
    public let totals: UsageTotals
    public let fallback: Bool
    public let priced: Bool
}

public struct UsageAgent: Decodable, Sendable {
    public let agent: String
    public let totals: UsageTotals
    public let models: [UsageModel]
}

public struct UsageDay: Decodable, Sendable {
    public let period: String
    public let agents: [UsageAgent]
    /// Optional reconciled daily project attribution from the direct ccusage scan.
    public let projects: [UsageDayProject]?
}

public struct UsageDayProject: Decodable, Sendable {
    public let project: String
    public let agent: String
    public let totals: UsageTotals
}

public struct UsageSession: Decodable, Sendable, Identifiable {
    public let sessionID: String
    public let agent: String
    public let lastActivity: String?
    public let project: String?
    public let reasoningOutputTokens: UInt64
    public let totals: UsageTotals
    public let models: [UsageModel]

    public var id: String { "\(agent):\(sessionID)" }

    enum CodingKeys: String, CodingKey {
        case agent, project, totals, models
        case sessionID = "session_id", lastActivity = "last_activity"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

public struct UsageProvenance: Decodable, Sendable {
    public let engine: String
    public let version: String
    public let generatedAt: String
    public let timezone: String
    public let pricingComplete: Bool
    public let fallbackModels: [String]
    public let unpricedModels: [String]
    public let detectedAgents: [String]?
    public let sourceFingerprint: String?
    public let window: String?

    enum CodingKeys: String, CodingKey {
        case engine, version, timezone
        case generatedAt = "generated_at", pricingComplete = "pricing_complete"
        case fallbackModels = "fallback_models", unpricedModels = "unpriced_models"
        case detectedAgents = "detected_agents", sourceFingerprint = "source_fingerprint", window
    }
}

public struct UsageFailure: Decodable, Sendable {
    public let category: String
    public let message: String
}

public struct DevinUsageModel: Decodable, Sendable {
    public let model: String
    public let sessions: Int64
    public let generatedTokens: Int64
    public let cacheReadTokens: Int64
    public let costUSD: Double

    enum CodingKeys: String, CodingKey {
        case model, sessions
        case generatedTokens = "generated_tokens", cacheReadTokens = "cache_read_tokens", costUSD = "cost_usd"
    }
}

public struct DevinUsageWindow: Decodable, Sendable {
    public let window: String
    public let sessions: Int64
    public let generatedTokens: Int64
    public let cacheReadTokens: Int64
    public let costUSD: Double
    public let models: [DevinUsageModel]

    enum CodingKeys: String, CodingKey {
        case window, sessions, models
        case generatedTokens = "generated_tokens", cacheReadTokens = "cache_read_tokens", costUSD = "cost_usd"
    }
}

public struct DevinUsageDay: Decodable, Sendable {
    public let period: String
    public let sessions: Int64
    public let generatedTokens: Int64
    public let cacheReadTokens: Int64
    public let models: [DevinUsageModel]

    enum CodingKeys: String, CodingKey {
        case period, sessions, models
        case generatedTokens = "generated_tokens", cacheReadTokens = "cache_read_tokens"
    }
}

public struct DevinUsage: Decodable, Sendable {
    public let status: String
    public let source: String
    public let windows: [DevinUsageWindow]
    /// Local calendar days from Devin's indexed, deduplicated message metrics.
    public let daily: [DevinUsageDay]?
    public let limitations: [String]
    public let costAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case status, source, windows, daily, limitations
        case costAvailable = "cost_available"
    }

    public static func unavailable(message: String) -> Self {
        Self(status: "unavailable", source: "Devin CLI sessions.db · read-only", windows: [], daily: [],
             limitations: [message], costAvailable: false)
    }
}

public struct UsagePoint: Sendable, Identifiable {
    public let day: String
    public let generatedTokens: UInt64
    public var id: String { day }
}

public struct UsageSlice: Sendable {
    public let generatedTokens: UInt64
    public let cacheReadTokens: UInt64
    public let costUSD: Double
    public let observations: Int
    public let points: [UsagePoint]
    public let fallbackPricing: Bool
    public let unpriced: Bool
    public let source: String
}

public struct LocalUsageReport: Decodable, Sendable {
    public let status: String
    public let stale: Bool
    public let error: UsageFailure?
    public let provenance: UsageProvenance
    public let daily: [UsageDay]
    public let sessions: [UsageSession]?
    public let devin: DevinUsage?

    public func withDevin(_ value: DevinUsage) -> Self {
        Self(status: status, stale: stale, error: error, provenance: provenance,
             daily: daily, sessions: sessions, devin: value)
    }

    public static func unavailable(message: String) -> Self {
        Self(status: "unavailable", stale: false,
             error: UsageFailure(category: "collection", message: message),
             provenance: UsageProvenance(engine: "ccusage", version: CCUsageClient.pinnedVersion,
                                         generatedAt: ISO8601DateFormatter().string(from: Date()),
                                         timezone: TimeZone.current.identifier, pricingComplete: false,
                                         fallbackModels: [], unpricedModels: [], detectedAgents: [],
                                         sourceFingerprint: nil, window: "all"),
             daily: [], sessions: [], devin: nil)
    }

    public func models(for service: UsageService, range: UsageRange, now: Date = Date()) -> [String] {
        if service == .devin {
            return devin?.windows.first(where: { $0.window == range.rawValue })?.models.map(\.model).sorted() ?? []
        }
        guard let key = service.agentKey else { return [] }
        return Array(Set(daily.filter { range.includes(day: $0.period, now: now, timezone: provenance.timezone) }
            .flatMap { $0.agents.filter { $0.agent == key }.flatMap { $0.models.map(\.model) } })).sorted()
    }

    public func slice(service: UsageService, model: String?, range: UsageRange, now: Date = Date()) -> UsageSlice? {
        if service == .devin {
            guard let devin, devin.status == "ready", let window = devin.windows.first(where: { $0.window == range.rawValue }) else { return nil }
            let days = (devin.daily ?? []).filter { range.includes(day: $0.period, now: now, timezone: TimeZone.current.identifier) }
            if let model {
                guard let item = window.models.first(where: { $0.model == model }) else { return nil }
                return UsageSlice(generatedTokens: UInt64(max(0, item.generatedTokens)), cacheReadTokens: UInt64(max(0, item.cacheReadTokens)),
                                  costUSD: item.costUSD, observations: Int(max(0, item.sessions)),
                                  points: days.compactMap { day in day.models.first(where: { $0.model == model }).map {
                                      UsagePoint(day: day.period, generatedTokens: UInt64(max(0, $0.generatedTokens)))
                                  } },
                                  fallbackPricing: false, unpriced: devin.costAvailable == false, source: devin.source)
            }
            return UsageSlice(generatedTokens: UInt64(max(0, window.generatedTokens)), cacheReadTokens: UInt64(max(0, window.cacheReadTokens)),
                              costUSD: window.costUSD, observations: Int(max(0, window.sessions)),
                              points: days.map { UsagePoint(day: $0.period, generatedTokens: UInt64(max(0, $0.generatedTokens))) },
                              fallbackPricing: false, unpriced: devin.costAvailable == false, source: devin.source)
        }
        guard status == "ready" || status == "stale" else { return nil }
        guard let key = service.agentKey else { return nil }
        var generated: UInt64 = 0
        var cacheRead: UInt64 = 0
        var cost: Double = 0
        var observations = 0
        var points: [UsagePoint] = []
        var fallback = false
        var unpriced = false
        for day in daily where range.includes(day: day.period, now: now, timezone: provenance.timezone) {
            guard let agent = day.agents.first(where: { $0.agent == key }) else { continue }
            let selected = model.flatMap { selected in agent.models.first { $0.model == selected } }
            if model != nil && selected == nil { continue }
            let totals = selected?.totals ?? agent.totals
            let (nextGenerated, generatedOverflow) = generated.addingReportingOverflow(totals.generatedTokens)
            generated = generatedOverflow ? UInt64.max : nextGenerated
            let (nextCacheRead, cacheOverflow) = cacheRead.addingReportingOverflow(totals.cacheReadTokens)
            cacheRead = cacheOverflow ? UInt64.max : nextCacheRead
            cost += totals.costUSD
            observations += 1
            points.append(UsagePoint(day: day.period, generatedTokens: totals.generatedTokens))
            if let selected {
                fallback = fallback || selected.fallback
                unpriced = unpriced || !selected.priced
            } else {
                fallback = fallback || agent.models.contains(where: { $0.fallback })
                unpriced = unpriced || agent.models.contains(where: { !$0.priced })
            }
        }
        return UsageSlice(generatedTokens: generated, cacheReadTokens: cacheRead, costUSD: cost, observations: observations,
                          points: points.sorted { $0.day < $1.day }, fallbackPricing: fallback, unpriced: unpriced,
                          source: "\(provenance.engine) \(provenance.version) · local logs")
    }
}

public struct ProviderQuotaWindow: Decodable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double?
    public let remainingPercent: Double
    public let windowDurationMinutes: UInt64?
    public let resetsAtUnix: Int64?
    public let resetDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, label
        case usedPercent = "used_percent", remainingPercent = "remaining_percent"
        case windowDurationMinutes = "window_duration_minutes"
        case resetsAtUnix = "resets_at_unix", resetDescription = "reset_description"
    }
}

public struct ProviderCreditBalance: Decodable, Sendable {
    public let remainingPercent: Double?
    public let usedAmount: Double?
    public let limitAmount: Double?
    /// Codex reports a credit-unit balance, not a dollar amount or reset count.
    public let balance: Decimal?
    public let hasCredits: Bool?
    public let unlimited: Bool?

    public init(remainingPercent: Double? = nil, usedAmount: Double? = nil, limitAmount: Double? = nil,
                balance: Decimal? = nil, hasCredits: Bool? = nil, unlimited: Bool? = nil) {
        self.remainingPercent = remainingPercent
        self.usedAmount = usedAmount
        self.limitAmount = limitAmount
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
    }

    enum CodingKeys: String, CodingKey {
        case remainingPercent = "remaining_percent"
        case usedAmount = "used_amount", limitAmount = "limit_amount"
        case balance, unlimited
        case hasCredits = "has_credits"
    }
}

public struct ProviderQuotaStatus: Decodable, Sendable {
    public let provider: String
    public let status: String
    public let source: String
    public let checkedAt: String
    public let plan: String?
    public let windows: [ProviderQuotaWindow]
    public let credits: ProviderCreditBalance?
    public let resetCredits: UInt64?
    public var earliestReportedResetCreditExpiryUnix: Int64? = nil
    /// Only the expiry dates returned in the optional credit-detail list are known.
    /// The provider may return fewer details than its available count.
    public let latestReportedResetCreditExpiryUnix: Int64?
    public let resetCreditDetailsCount: UInt64?
    public let resetCreditsWithoutExpiryCount: UInt64?
    public var claudeResetGrants: ClaudeResetGrantSummary? = nil
    public var resetGrantError: String? = nil
    public var grokBilling: GrokBillingSummary? = nil
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case provider, status, source, plan, windows, credits, message
        case checkedAt = "checked_at"
        case resetCredits = "reset_credits"
        case earliestReportedResetCreditExpiryUnix = "earliest_reported_reset_credit_expiry_unix"
        case latestReportedResetCreditExpiryUnix = "latest_reported_reset_credit_expiry_unix"
        case resetCreditDetailsCount = "reset_credit_details_count"
        case resetCreditsWithoutExpiryCount = "reset_credits_without_expiry_count"
        case claudeResetGrants = "claude_reset_grants"
        case resetGrantError = "reset_grant_error"
        case grokBilling = "grok_billing"
    }
}

public struct GrokBillingSummary: Decodable, Sendable {
    public let prepaidUSD: Double?
    public let onDemandEnabled: Bool?
    public let onDemandUsedUSD: Double?
    public let onDemandCapUSD: Double?
    public let unifiedBilling: Bool?
    public let periodStart: String?
    public var periodEnd: String? = nil
    public var periodType: String? = nil
    public let includedUsedUSD: Double?
    public let includedLimitUSD: Double?
}

public struct ProviderQuotaReceipt: Decodable, Sendable {
    public let schemaVersion: String
    public let generatedAt: String
    public let providers: [ProviderQuotaStatus]

    enum CodingKeys: String, CodingKey {
        case providers
        case schemaVersion = "schema_version", generatedAt = "generated_at"
    }
}
