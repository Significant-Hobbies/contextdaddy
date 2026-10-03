import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LocalObservabilityClient: Sendable {
    public let grafanaBaseURL: URL
    private let session: URLSession

    public init(grafanaBaseURL: URL = URL(string: "http://127.0.0.1:3000")!, session: URLSession = .shared) {
        self.grafanaBaseURL = grafanaBaseURL
        self.session = session
    }

    public func load() async -> ObservabilitySnapshot {
        do {
            let healthURL = grafanaBaseURL.appendingPathComponent("api/health")
            let (_, response) = try await session.data(from: healthURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unavailable
            }

            async let signalLoad = loadAggregateSignalsOutcome()
            async let breakdownLoad = loadBreakdowns()
            async let runLoad = loadRecentRuns()
            async let claudeLoad = loadClaudeOutcome()
            let (signalResult, breakdownResult, runResult, claudeResult) = await (signalLoad, breakdownLoad, runLoad, claudeLoad)

            var notes = [
                "Prometheus supplies 24-hour range estimates; Tempo supplies measured recent session roots.",
                "Network calls are logical telemetry events, not measured bytes on the wire.",
                "Operation durations can overlap. Session end-to-end duration is the authoritative wall time.",
                "Skill injection identifies context supplied to a turn; it does not prove the skill completed useful work.",
                "Prompt, response, command, argument, and tool-result bodies are never requested."
            ]
            notes.append(contentsOf: breakdownResult.errors)
            if let error = signalResult.error { notes.append("Prometheus headline signals unavailable: \(error)") }
            if let error = runResult.error { notes.append(error) }
            if let error = claudeResult.error { notes.append("Claude metrics unavailable: \(error)") }

            return ObservabilitySnapshot(
                generatedAt: Date(),
                collectorReachable: true,
                agents: AgentRuntime.allCases.map { runtime in
                    switch runtime {
                    case .codex:
                        AgentTelemetry(runtime: .codex, connected: signalResult.signals.values.contains { $0.value != nil }, source: "Local OTEL · Prometheus · Tempo", signals: signalResult.signals)
                    case .claude:
                        claudeResult.agent
                    default:
                        adapter(for: runtime)
                    }
                },
                notes: notes,
                recentRuns: runResult.runs,
                breakdowns: breakdownResult.sections,
                claudeBreakdowns: claudeResult.sections,
                sourceSchema: "codex-native-otel+claude-code-metrics/prometheus-tempo-v1"
            )
        } catch {
            return .unavailable(reason: "Local telemetry error: \(Self.safeError(error))")
        }
    }

    private func loadAggregateSignalsOutcome() async -> SignalsOutcome {
        do { return SignalsOutcome(signals: try await loadAggregateSignals(), error: nil) }
        catch {
            let reason = Self.safeError(error)
            return SignalsOutcome(signals: unavailableSignals(reason: reason), error: reason)
        }
    }

    private func loadAggregateSignals() async throws -> [TelemetrySignal: TelemetryValue] {
        async let tokens = sampleOutcome(expression: "sum(increase(codex_turn_token_usage_sum{token_type=\"total\"}[24h]))")
        async let tools = sampleOutcome(expression: "sum(increase(codex_tool_call_total[24h]))")
        async let api = sampleOutcome(expression: "sum(increase(codex_api_request_total[24h]))")
        async let websocket = sampleOutcome(expression: "sum(increase(codex_websocket_request_total[24h]))")
        async let proxy = sampleOutcome(expression: "sum(increase(codex_turn_network_proxy_total[24h]))")
        let (tokenResult, toolResult, apiResult, websocketResult, proxyResult) = await (tokens, tools, api, websocket, proxy)
        func metric(_ result: SamplesOutcome, unit: String, note: String) -> TelemetryValue {
            let value = result.samples.first?.value
            return TelemetryValue(value: value?.rounded(), unit: unit, quality: value == nil ? .unavailable : .derived,
                                  note: result.error ?? (value == nil ? "No range samples returned; missing or one-sample series cannot establish zero activity." : note))
        }
        let network = [apiResult, websocketResult, proxyResult]
        let networkValues = network.compactMap { $0.samples.first?.value }
        let completeNetwork = networkValues.count == network.count
        let networkTotal = networkValues.reduce(0, +)
        return [
            .contextTokens: metric(tokenResult, unit: "estimated tokens / 24h",
                note: "PromQL increase of the total-token counter. Short-lived one-sample series can be missed; components are shown separately."),
            .toolCalls: metric(toolResult, unit: "estimated invocations / 24h",
                note: "PromQL increase of Codex tool calls. Short-lived series can be missed; MCP calls can overlap."),
            .networkCalls: TelemetryValue(value: completeNetwork && networkTotal.isFinite ? networkTotal.rounded() : nil,
                unit: "estimated logical events / 24h", quality: completeNetwork && networkTotal.isFinite ? .derived : .unavailable,
                note: completeNetwork ? "PromQL increase across API, websocket-request, and proxy events. Categories can overlap." : "One or more logical-event series are unavailable; a complete total cannot be established."),
            .internetUsage: TelemetryValue(value: nil, unit: "bytes", quality: .unavailable,
                note: "The current OTLP stream does not measure bytes transferred."),
        ]
    }

    private func unavailableSignals(reason: String) -> [TelemetrySignal: TelemetryValue] {
        Dictionary(uniqueKeysWithValues: TelemetrySignal.allCases.map { signal in
            let unit = signal == .contextTokens ? "tokens" : signal == .internetUsage ? "bytes" : "events"
            return (signal, TelemetryValue(value: nil, unit: unit, quality: .unavailable, note: reason))
        })
    }

    private func loadClaudeOutcome() async -> ClaudeLoad {
        do {
            // Names follow Anthropic's documented OTLP metrics and its published
            // Prometheus example. The fallback handles collectors without unit suffixes.
            async let types = querySamples("sum by (type) (increase(claude_code_token_usage_tokens_total[24h])) or sum by (type) (increase(claude_code_token_usage_total[24h]))")
            async let models = querySamples("sum by (model) (increase(claude_code_token_usage_tokens_total[24h])) or sum by (model) (increase(claude_code_token_usage_total[24h]))")
            async let sessions = querySamples("sum(increase(claude_code_session_count_total[24h]))")
            async let costs = querySamples("sum(increase(claude_code_cost_usage_USD_total[24h])) or sum(increase(claude_code_cost_usage_total[24h]))")
            async let presence = querySamples("count(claude_code_token_usage_tokens_total) or count(claude_code_token_usage_total) or count(claude_code_session_count_total)")
            return Self.claudeLoad(types: try await types, models: try await models,
                                   sessions: try await sessions, costs: try await costs,
                                   presence: try await presence)
        } catch {
            let reason = Self.safeError(error)
            return ClaudeLoad(agent: adapter(for: .claude), sections: [], error: reason)
        }
    }

    static func claudeLoad(types: [PrometheusSample], models: [PrometheusSample],
                           sessions: [PrometheusSample], costs: [PrometheusSample],
                           presence: [PrometheusSample] = []) -> ClaudeLoad {
        let tokenRows = types.compactMap { sample -> TelemetryBreakdownItem? in
            guard let name = sample.metric["type"], sample.value.isFinite, sample.value > 0 else { return nil }
            return TelemetryBreakdownItem(name: name, value: sample.value.rounded(), unit: "tokens", quality: .derived)
        }.sorted { $0.value > $1.value }
        let modelRows = models.compactMap { sample -> TelemetryBreakdownItem? in
            guard let name = sample.metric["model"], sample.value.isFinite, sample.value > 0 else { return nil }
            return TelemetryBreakdownItem(name: name, value: sample.value.rounded(), unit: "tokens", quality: .derived)
        }.sorted { $0.value > $1.value }
        let hasSamples = !types.isEmpty || !models.isEmpty || !sessions.isEmpty || !costs.isEmpty
            || presence.contains { $0.value.isFinite && $0.value > 0 }
        let tokenTotal = types.reduce(0) { $0 + max(0, $1.value.isFinite ? $1.value : 0) }
        let missing = "No Claude Code OTLP samples were returned. Telemetry may not be enabled or routed to this collector."
        let signals: [TelemetrySignal: TelemetryValue] = [
            .contextTokens: TelemetryValue(value: types.isEmpty ? nil : tokenTotal.rounded(), unit: "tokens / 24h",
                quality: types.isEmpty ? .unavailable : .derived,
                note: types.isEmpty ? missing : "Prometheus 24-hour increase across Claude token types, including cache reads; this is not the local-history generated-token total."),
            .toolCalls: TelemetryValue(value: nil, unit: "calls", quality: .unavailable,
                note: "Claude tool events require a logs or trace adapter; token metrics do not count all tools."),
            .networkCalls: TelemetryValue(value: nil, unit: "calls", quality: .unavailable,
                note: "Claude API request events require a logs or trace adapter; no request counter is mapped."),
            .internetUsage: TelemetryValue(value: nil, unit: "bytes", quality: .unavailable,
                note: "Claude Code OTLP does not measure transferred bytes."),
        ]
        let sessionRows = sessions.first.flatMap { $0.value.isFinite && $0.value > 0
            ? [TelemetryBreakdownItem(name: "Started", value: $0.value.rounded(), unit: "sessions", quality: .derived)] : nil } ?? []
        let costRows = costs.first.flatMap { $0.value.isFinite && $0.value > 0
            ? [TelemetryBreakdownItem(name: "Estimated", value: $0.value, unit: "USD", quality: .derived)] : nil } ?? []
        return ClaudeLoad(
            agent: AgentTelemetry(runtime: .claude, connected: hasSamples,
                source: hasSamples ? "Claude Code OTLP · Prometheus · 24h" : "Claude Code OTLP · no samples", signals: signals),
            sections: [
                TelemetryBreakdownSection(title: "Claude tokens · 24h", note: "Provider token types are separate from ccusage local history.", items: tokenRows),
                TelemetryBreakdownSection(title: "Claude models · 24h", note: "Range-derived token counts grouped by reported model.", items: modelRows),
                TelemetryBreakdownSection(title: "Claude sessions · 24h", note: "Session starts reported by Claude Code.", items: sessionRows),
                TelemetryBreakdownSection(title: "Claude cost · 24h", note: "Provider-estimated cost, not subscription spend or official billing.", items: costRows),
            ], error: hasSamples ? nil : missing
        )
    }

    private func loadBreakdowns() async -> BreakdownLoad {
        let queries: [String: String] = [
            "tokens": "sum by (token_type) (increase(codex_turn_token_usage_sum[24h]))",
            "models": "sum by (model) (increase(codex_turn_token_usage_sum{token_type=\"total\"}[24h]))",
            "tools": "sum by (tool) (increase(codex_tool_call_total[24h]))",
            "mcp": "sum by (server) (increase(codex_mcp_call_total[24h]))",
            "skills": "sum by (skill, invoke_type, status) (increase(codex_skill_injected_total[24h]))",
            "apiErrors": "sum(increase(codex_api_request_total{success=\"false\"}[24h]))",
            "compactions": "sum(increase(codex_task_compact_total[24h]))",
            "turnTime": "sum(increase(codex_turn_e2e_duration_ms_milliseconds_sum[24h])) / 1000",
            "inferenceTime": "sum(increase(codex_responses_api_inference_time_duration_ms_milliseconds_sum[24h])) / 1000",
            "shellTime": "sum(increase(codex_tool_call_duration_ms_milliseconds_sum{tool=~\"exec|exec_command|shell\"}[24h])) / 1000",
            "mcpTime": "sum(increase(codex_mcp_call_duration_ms_milliseconds_sum[24h])) / 1000",
        ]
        var outcomes: [String: SamplesOutcome] = [:]
        await withTaskGroup(of: (String, SamplesOutcome).self) { group in
            for (key, expression) in queries {
                group.addTask { (key, await sampleOutcome(expression: expression)) }
            }
            for await (key, outcome) in group { outcomes[key] = outcome }
        }

        var sections: [TelemetryBreakdownSection] = []
        sections.append(TelemetryBreakdownSection(
            title: "Token mix · 24h",
            note: "Input includes cached input. Total is the correct series for the overall range estimate; components are not additive.",
            items: items(outcomes["tokens"], label: "token_type", unit: "tokens", names: [
                "total": "Total", "input": "Input", "cached_input": "Cached input",
                "cache_write_input": "Cache write", "output": "Output", "reasoning_output": "Reasoning"
            ])
        ))
        sections.append(TelemetryBreakdownSection(
            title: "Models · 24h",
            note: "Range-derived total tokens grouped by model.",
            items: items(outcomes["models"], label: "model", unit: "tokens")
        ))
        sections.append(TelemetryBreakdownSection(
            title: "Tools · 24h",
            note: "Range-derived tool invocations. Fractional Prometheus extrapolation is rounded for display.",
            items: items(outcomes["tools"], label: "tool", unit: "calls", limit: 12)
        ))
        sections.append(TelemetryBreakdownSection(
            title: "MCP servers · 24h",
            note: "Range-derived MCP calls grouped by server; these may also appear as tool invocations.",
            items: items(outcomes["mcp"], label: "server", unit: "calls", limit: 12)
        ))
        sections.append(TelemetryBreakdownSection(
            title: "Skills injected · 24h",
            note: "Range-derived native injection evidence, not a claim that the skill completed or caused the result.",
            items: skillItems(outcomes["skills"])
        ))
        sections.append(TelemetryBreakdownSection(
            title: "Operation time · 24h",
            note: "Range-derived durations can overlap. Never add these to derive wall time.",
            items: scalarItems(outcomes, specs: [
                ("turnTime", "Turn end-to-end"), ("inferenceTime", "OpenAI inference"),
                ("shellTime", "Shell tools"), ("mcpTime", "MCP")
            ], unit: "seconds")
        ))
        sections.append(TelemetryBreakdownSection(
            title: "Reliability · 24h",
            note: "Range-derived event deltas. Missing or zero-delta series are not presented as proof of zero activity.",
            items: scalarItems(outcomes, specs: [
                ("apiErrors", "API failures"), ("compactions", "Compactions")
            ], unit: "events")
        ))

        let errors = outcomes.compactMap { key, outcome in
            outcome.error.map { "Prometheus \(key) breakdown unavailable: \($0)" }
        }.sorted()
        return BreakdownLoad(sections: sections, errors: errors)
    }

    private func sampleOutcome(expression: String) async -> SamplesOutcome {
        do { return SamplesOutcome(samples: try await querySamples(expression), error: nil) }
        catch { return SamplesOutcome(samples: [], error: Self.safeError(error)) }
    }

    private func items(_ outcome: SamplesOutcome?, label: String, unit: String,
                       names: [String: String] = [:], limit: Int = 20) -> [TelemetryBreakdownItem] {
        guard let outcome else { return [] }
        return outcome.samples.compactMap { sample -> TelemetryBreakdownItem? in
            guard let rawName = sample.metric[label], sample.value > 0 else { return nil }
            return TelemetryBreakdownItem(name: names[rawName] ?? rawName, value: sample.value.rounded(), unit: unit, quality: .derived)
        }.sorted { $0.value > $1.value }.prefix(limit).map { $0 }
    }

    private func skillItems(_ outcome: SamplesOutcome?) -> [TelemetryBreakdownItem] {
        guard let outcome else { return [] }
        return outcome.samples.compactMap { sample -> TelemetryBreakdownItem? in
            guard let skill = sample.metric["skill"], sample.value > 0 else { return nil }
            let invocation = sample.metric["invoke_type"] ?? "unknown mode"
            let status = sample.metric["status"] ?? "unknown status"
            return TelemetryBreakdownItem(name: skill, value: sample.value.rounded(), unit: "injections", detail: "\(invocation) · \(status)", quality: .derived)
        }.sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }.prefix(20).map { $0 }
    }

    private func scalarItems(_ outcomes: [String: SamplesOutcome], specs: [(String, String)], unit: String) -> [TelemetryBreakdownItem] {
        specs.compactMap { key, name in
            guard let value = outcomes[key]?.samples.first?.value, value > 0 else { return nil }
            let normalized = unit == "events" ? value.rounded() : (value * 10).rounded() / 10
            return TelemetryBreakdownItem(name: name, value: normalized, unit: unit, quality: .derived)
        }
    }

    private func loadRecentRuns() async -> RunsOutcome {
        do {
            var components = URLComponents(
                url: grafanaBaseURL.appendingPathComponent("api/datasources/proxy/uid/tempo/api/search"),
                resolvingAgainstBaseURL: false
            )!
            let now = Date()
            components.queryItems = [
                URLQueryItem(name: "q", value: "{ name = \"session_loop\" }"),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "start", value: String(Int(now.addingTimeInterval(-86_400).timeIntervalSince1970))),
                URLQueryItem(name: "end", value: String(Int(now.timeIntervalSince1970))),
            ]
            let (data, response) = try await session.data(from: components.url!)
            try requireSuccess(response: response, source: "Tempo session search")
            let payload = try JSONDecoder().decode(TempoSearchResponse.self, from: data)
            let runs = payload.traces.compactMap { trace -> OTelRun? in
                guard let nanos = Double(trace.startTimeUnixNano) else { return nil }
                return OTelRun(
                    traceID: trace.traceID,
                    startedAt: Date(timeIntervalSince1970: nanos / 1_000_000_000),
                    durationMilliseconds: trace.durationMs,
                    rootService: trace.rootServiceName,
                    rootOperation: trace.rootTraceName,
                    spanCount: trace.serviceStats.values.reduce(0) { $0 + $1.spanCount }
                )
            }.sorted { $0.startedAt > $1.startedAt }
            return RunsOutcome(runs: runs, error: nil)
        } catch {
            return RunsOutcome(runs: [], error: "Tempo recent sessions unavailable: \(Self.safeError(error))")
        }
    }

    private func queryScalar(_ expression: String) async throws -> Double {
        guard let value = try await querySamples(expression).first?.value else { throw URLError(.cannotParseResponse) }
        return value
    }

    private func querySamples(_ expression: String) async throws -> [PrometheusSample] {
        var components = URLComponents(
            url: grafanaBaseURL.appendingPathComponent("api/datasources/proxy/uid/prometheus/api/v1/query"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "query", value: expression)]
        let (data, response) = try await session.data(from: components.url!)
        try requireSuccess(response: response, source: "Prometheus query")
        let payload = try JSONDecoder().decode(PrometheusResponse.self, from: data)
        guard payload.status == "success" else { throw URLError(.cannotParseResponse) }
        return try payload.data.result.map { result in
            guard let value = Double(result.rawValue), value.isFinite, value >= 0 else {
                throw LocalObservabilityError.invalidSample
            }
            return PrometheusSample(metric: result.metric, value: value)
        }
    }

    private func requireSuccess(response: URLResponse, source: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocalObservabilityError.queryRejected(status: status, source: source)
        }
    }

    // Never forward provider bodies, URLs, decoding debug descriptions or userInfo.
    private static func safeError(_ error: Error) -> String {
        if let error = error as? LocalObservabilityError { return error.localizedDescription }
        if let error = error as? URLError { return "Telemetry transport failed (code \(error.code.rawValue))." }
        if error is DecodingError { return "Telemetry response could not be decoded." }
        return "Telemetry request failed. Error content was omitted."
    }

    private func adapter(for runtime: AgentRuntime) -> AgentTelemetry {
        let supported = runtime == .codex || runtime == .claude || runtime == .grok
        let note = supported
            ? "OTLP is supported by this runtime, but metric queries are not yet mapped."
            : "This runtime does not expose a verified local OTLP adapter."
        return AgentTelemetry(
            runtime: runtime,
            connected: false,
            source: supported ? "OTLP capable · not connected" : "No verified adapter",
            signals: Dictionary(uniqueKeysWithValues: TelemetrySignal.allCases.map {
                ($0, TelemetryValue(value: nil, unit: $0 == .contextTokens ? "tokens" : "events", quality: supported ? .partial : .unavailable, note: note))
            })
        )
    }
}

private struct BreakdownLoad: Sendable {
    let sections: [TelemetryBreakdownSection]
    let errors: [String]
}

struct ClaudeLoad: Sendable {
    let agent: AgentTelemetry
    let sections: [TelemetryBreakdownSection]
    let error: String?
}

private struct SignalsOutcome: Sendable {
    let signals: [TelemetrySignal: TelemetryValue]
    let error: String?
}

private struct SamplesOutcome: Sendable {
    let samples: [PrometheusSample]
    let error: String?
}

private struct RunsOutcome: Sendable {
    let runs: [OTelRun]
    let error: String?
}

struct PrometheusSample: Sendable, Equatable {
    let metric: [String: String]
    let value: Double
}

enum LocalObservabilityError: LocalizedError {
    case queryRejected(status: Int, source: String)
    case invalidSample

    var errorDescription: String? {
        switch self {
        case let .queryRejected(status, source): "\(source) returned HTTP \(status). Response content was omitted."
        case .invalidSample: "Telemetry returned an invalid numeric sample."
        }
    }
}

struct PrometheusResponse: Decodable {
    struct DataPayload: Decodable {
        struct Result: Decodable {
            let metric: [String: String]
            let rawValue: String

            enum CodingKeys: String, CodingKey { case metric, value }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                metric = try container.decodeIfPresent([String: String].self, forKey: .metric) ?? [:]
                var values = try container.nestedUnkeyedContainer(forKey: .value)
                _ = try values.decode(Double.self)
                rawValue = try values.decode(String.self)
            }
        }
        let result: [Result]
    }
    let status: String
    let data: DataPayload
}

struct TempoSearchResponse: Decodable {
    struct ServiceStats: Decodable { let spanCount: Int }
    struct Trace: Decodable {
        let traceID: String
        let rootServiceName: String
        let rootTraceName: String
        let startTimeUnixNano: String
        let durationMs: Double
        let serviceStats: [String: ServiceStats]
    }
    let traces: [Trace]
}
