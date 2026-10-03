import Foundation
import Testing
@testable import ContextCore

struct ClaudeResetGrantReaderTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func grant(_ count: String = "1", clears: String = #"["five_hour","seven_day","seven_day_overage_included"]"#,
                       end: String = "2030-10-22T16:00:00+00:00", paused: Bool = false, usable: Bool = true) -> String {
        #"{"id":"private-grant-id","resets_left":\#(count),"ends_at":"\#(end)","clears":\#(clears),"paused":\#(paused),"usable_now":\#(usable)}"#
    }

    private func parse(_ grants: [String], eligible: Bool = true) throws -> ClaudeResetGrantSummary {
        let json = #"{"account_id":"private-account","cedar_ember":{"eligible":\#(eligible),"grants":[\#(grants.joined(separator: ","))]}}"#
        return try ClaudeResetGrantReader.parse(Data(json.utf8), now: now)
    }

    @Test func scopesAndExpiryAreProjectedWithoutIdentityOrDoubleCounting() throws {
        let summary = try parse([grant("2"), grant("1", clears: #"["five_hour"]"#, end: "2030-11-01T16:00:00.000Z")])
        #expect(summary.fullCount == 2)
        #expect(summary.fiveHourCount == 1)
        #expect(summary.grants.count == 2)
        #expect(summary.grants.first(where: { $0.kind == "full" })?.expiresAtUnix == 1_918_915_200)
        #expect(!String(describing: summary).contains("private-grant-id"))
        #expect(!String(describing: summary).contains("private-account"))
    }

    @Test func confirmedEmptyAndDepletedAreZeroButIneligibleIsUnknown() throws {
        #expect(try parse([]).fullCount == 0)
        #expect(try parse([]).fiveHourCount == 0)
        #expect(try parse([grant("0")]).grants.isEmpty)
        #expect(throws: ClaudeResetGrantError.self) { try parse([], eligible: false) }
        for json in ["{}", #"{"cedar_ember":null}"#, #"{"cedar_ember":{"eligible":true}}"#,
                     #"{"cedar_ember":{"eligible":true,"grants":[{}]}}"#] {
            #expect(throws: ClaudeResetGrantError.self) { try ClaudeResetGrantReader.parse(Data(json.utf8), now: now) }
        }
    }

    @Test func expiredPausedAndUnusableGrantsRemainDistinct() throws {
        let summary = try parse([grant("5", end: "2020-01-01T00:00:00Z"), grant(paused: true, usable: false),
                                 grant("2", clears: #"["five_hour"]"#, usable: false)])
        #expect(summary.fullCount == 1)
        #expect(summary.fiveHourCount == 2)
        #expect(summary.grants.count == 2)
        #expect(summary.grants.first(where: { $0.kind == "full" })?.paused == true)
        #expect(summary.grants.allSatisfy { !$0.usableNow })
    }

    @Test func malformedUnknownAndOverflowedGrantsCannotLookEmpty() throws {
        for row in [grant("-1"), grant("1.5"), grant("18446744073709551616"), grant(end: "not-a-date"),
                    grant(clears: #"["seven_day"]"#), grant(clears: #"["new_unknown_scope"]"#)] {
            #expect(throws: ClaudeResetGrantError.self) { try parse([row]) }
        }
        #expect(throws: ClaudeResetGrantError.self) { try parse([grant("18446744073709551615"), grant()]) }
        #expect(throws: ClaudeResetGrantError.self) { try parse([grant("18446744073709551615"), grant(clears: #"["five_hour"]"#)]) }
        #expect(throws: ClaudeResetGrantError.self) { try parse(Array(repeating: grant(), count: 129)) }
    }

    @Test func onlyPinnedReadEndpointReceivesValidUnexpiredOAuthCredential() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":2000000000000}}"#.utf8)
        let request = try ClaudeResetGrantReader.request(credential: data, cliVersion: "2.1.288", now: now)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.288 (external, cli)")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.timeoutInterval == 5)
        #expect(ProviderQuotaParser.claudeVersion("Claude Code v2.1.288\nCurrent session") == "2.1.288")
        #expect(ProviderQuotaParser.claudeVersion("Current session\n3% used") == nil)
        #expect(throws: ClaudeResetGrantError.self) {
            try ClaudeResetGrantReader.request(credential: data, cliVersion: "2.1.288\r\nInjected: header", now: now)
        }
        for credential in [#"{"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":1}}"#,
                           #"{"claudeAiOauth":{"accessToken":"token\nInjected","expiresAt":2000000000000}}"#,
                           #"{"claudeAiOauth":{"refreshToken":"never-used"}}"#, "not-json"] {
            #expect(throws: ClaudeResetGrantError.self) {
                try ClaudeResetGrantReader.request(credential: Data(credential.utf8), cliVersion: "2.1.288", now: now)
            }
        }
    }

    @Test func credentialHelperIsBoundedAndRejectsEmptyReads() throws {
        let stalled = Process()
        stalled.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stalled.arguments = ["30"]
        let start = Date()
        #expect(throws: ClaudeResetGrantError.self) {
            try ClaudeResetGrantReader.readCredential(using: stalled, timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 2)
        let empty = Process()
        empty.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        #expect(throws: ClaudeResetGrantError.self) { try ClaudeResetGrantReader.readCredential(using: empty) }
    }

    @Test func sameReadCanPreserveWindowsAndGrantsWithoutInventingCLICreditsOrPlan() throws {
        let json = #"{"five_hour":{"utilization":20,"resets_at":"2030-10-22T16:00:00.123456+00:00"},"seven_day":{"utilization":60,"resets_at":null},"cedar_ember":{"eligible":true,"grants":[\#(grant())]}}"#
        let status = try ClaudeResetGrantReader.quotaStatus(Data(json.utf8), now: now)
        #expect(status.windows.map(\.remainingPercent) == [80, 40])
        #expect(status.windows.first?.resetsAtUnix == 1_918_915_200)
        #expect(status.windows.last?.resetsAtUnix == nil)
        #expect(status.claudeResetGrants?.fullCount == 1)
        #expect(status.credits == nil)
        #expect(status.plan == nil)
        #expect(status.source.contains("CLI display unavailable"))
        let cli = try ProviderQuotaParser.claude("Current session\n0% used\nResets soon\nCurrent week (all models)\n0% used\nResets later\nUsage credits\n0% used\n$0.00 / $150.00 spent")
        let merged = ClaudeResetGrantReader.mergingCLIDetails(cli, into: status)
        #expect(merged.windows.map(\.remainingPercent) == [80, 40])
        #expect(merged.credits?.limitAmount == 150)
        #expect(merged.resetCredits == 1)
        for invalid in [json.replacingOccurrences(of: "\"utilization\":20", with: "\"utilization\":-1"),
                        json.replacingOccurrences(of: "\"utilization\":20", with: "\"utilization\":true"),
                        json.replacingOccurrences(of: "\"utilization\":60", with: "\"utilization\":101"),
                        json.replacingOccurrences(of: "2030-10-22T16:00:00.123456+00:00", with: "bad-date")] {
            #expect(throws: ClaudeResetGrantError.self) { try ClaudeResetGrantReader.quotaStatus(Data(invalid.utf8), now: now) }
        }
    }
}
