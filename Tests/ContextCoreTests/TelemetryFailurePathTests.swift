import Foundation
import Testing
@testable import ContextCore

struct TelemetryFailurePathTests {
    private func load(_ scenario: String) async -> ObservabilitySnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryFixtureProtocol.self]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await LocalObservabilityClient(grafanaBaseURL: URL(string: "https://\(scenario).invalid")!, session: session).load()
    }

    @Test(arguments: ["http401", "http500", "transport", "malformed"])
    func errorsNeverRetainResponseOrTransportContent(_ scenario: String) async throws {
        let snapshot = await load(scenario)
        let encoded = try JSONEncoder().encode(snapshot)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(TelemetryFixtureProtocol.canary))
        #expect(snapshot.agents.first { $0.runtime == .codex }?.signals[.contextTokens]?.value == nil)
        if scenario.hasPrefix("http") {
            #expect(text.contains(scenario == "http401" ? "HTTP 401" : "HTTP 500"))
        }
        // Exercise actual persistence, using only a newly allocated synthetic directory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContextDaddy-redaction-" + UUID().uuidString)
        let store = TelemetrySnapshotStore(directory: directory)
        _ = try await store.append(snapshot)
        let saved = try String(contentsOf: directory.appendingPathComponent("telemetry-snapshots.json"), encoding: .utf8)
        #expect(!saved.contains(TelemetryFixtureProtocol.canary))
    }

    @Test func missingSeriesAreUnavailableWhileObservedZeroIsDerived() async throws {
        let absent = await load("missing")
        let zero = await load("zero")
        let missingAgent = try #require(absent.agents.first { $0.runtime == .codex })
        let zeroAgent = try #require(zero.agents.first { $0.runtime == .codex })
        #expect(!missingAgent.connected)
        for signal in [TelemetrySignal.contextTokens, .toolCalls, .networkCalls] {
            #expect(missingAgent.signals[signal]?.value == nil)
            #expect(missingAgent.signals[signal]?.quality == .unavailable)
            #expect(zeroAgent.signals[signal]?.value == 0)
            #expect(zeroAgent.signals[signal]?.quality == .derived)
        }
        #expect(zeroAgent.connected)
    }

    @Test(arguments: ["partial", "nonfinite", "invalid"])
    func oneBadSeriesDoesNotEraseGoodSignalsOrInventNetworkTotal(_ scenario: String) async throws {
        let snapshot = await load(scenario)
        let agent = try #require(snapshot.agents.first { $0.runtime == .codex })
        #expect(agent.signals[.contextTokens]?.value == 42)
        #expect(agent.signals[.toolCalls]?.value == 7)
        #expect(agent.signals[.networkCalls]?.value == nil)
        #expect(agent.signals[.networkCalls]?.quality == .unavailable)
        #expect(agent.signals[.internetUsage]?.value == nil)
        _ = try JSONEncoder().encode(snapshot)
    }
}

/// Claims every request, including unexpected ones: no external/loopback fallback.
private final class TelemetryFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let canary = "synthetic-secret-prompt-error-canary"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET", let scenario = url.host?.split(separator: ".").first else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var status = 200
        var body = "{}"
        if scenario == "transport" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: -1001,
                userInfo: [NSLocalizedDescriptionKey: Self.canary, NSURLErrorFailingURLStringErrorKey: Self.canary]))
            return
        }
        if url.path == "/api/health" { body = "{}" }
        else if scenario == "http401" || scenario == "http500" {
            status = scenario == "http401" ? 401 : 500; body = Self.canary
        } else if scenario == "malformed" { body = "{\"\(Self.canary)\":" }
        else if url.path.hasSuffix("/api/search") { body = "{\"traces\":[]}" }
        else if url.path.hasSuffix("/api/v1/query") {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            // Regression guard: a synthetic zero fallback hides absent range series.
            if query.contains("or vector(0)") {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
            }
            var value: String?
            if query.contains("codex_") {
                switch scenario {
                case "zero": value = "0"
                case "partial", "nonfinite", "invalid":
                    if query.contains("codex_turn_token_usage_sum") { value = "42" }
                    else if query.contains("codex_tool_call_total") { value = "7" }
                    else if query.contains("codex_api_request_total") { value = "2" }
                    else if query.contains("codex_websocket_request_total") { value = "3" }
                    else if query.contains("codex_turn_network_proxy_total") {
                        value = scenario == "nonfinite" ? "NaN" : scenario == "invalid" ? "not-a-number" : nil
                    }
                default: break
                }
            }
            let result = value.map { "{\"metric\":{},\"value\":[1,\"\($0)\"]}" } ?? ""
            body = "{\"status\":\"success\",\"data\":{\"result\":[\(result)]}}"
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
