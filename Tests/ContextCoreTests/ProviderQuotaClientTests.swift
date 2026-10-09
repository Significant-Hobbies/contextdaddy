import Foundation
import Testing
@testable import ContextCore

struct ProviderQuotaClientTests {
    @Test func grokAuthenticationFailureIsExplicitWithoutReturningProviderDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok")
        let script = #"""
        #!/bin/sh
        IFS= read -r line
        echo '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}'
        IFS= read -r line
        echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Authentication required","data":"must-not-be-returned"}}'
        IFS= read -r unexpected
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await ProviderQuotaClient(grokURL: executable).loadQuota(for: .grok)
            Issue.record("Expected an authentication failure")
        } catch {
            #expect(error as? ProviderQuotaError == .authenticationRequired("Grok"))
            #expect(!error.localizedDescription.contains("must-not-be-returned"))
        }
    }

    @Test func grokCollectorOnlyInitializesAndReadsBilling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("grok")
        let script = #"""
        #!/bin/sh
        [ "$1" = "agent" ] && [ "$2" = "stdio" ] || exit 1
        IFS= read -r line
        case "$line" in *'"method":"initialize"'*) ;; *) exit 2 ;; esac
        echo '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":1}}'
        IFS= read -r line
        case "$line" in *'"method":"_x.ai/billing"'*) ;; *) exit 3 ;; esac
        echo '{"jsonrpc":"2.0","id":1,"result":{"config":{"creditUsagePercent":40}}}'
        IFS= read -r unexpected && exit 4
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let receipt = try await ProviderQuotaClient(grokURL: executable).loadQuota(for: .grok)
        #expect(receipt.providers.first?.windows.first?.remainingPercent == 60)
        #expect(receipt.providers.first?.resetCredits == nil)
    }

    @Test func grokProjectsAllowanceResetAndSeparatePaidBalances() throws {
        let status = try ProviderQuotaParser.grok([
            "subscription_tier": "SuperGrok", "on_demand_enabled": true,
            "config": ["creditUsagePercent": 25.5,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-15T00:00:00.000Z"],
                "prepaidBalance": ["val": "-1250"], "onDemandUsed": ["val": 500],
                "onDemandCap": ["val": 2000], "isUnifiedBillingUser": true,
                "accountId": "must-not-be-projected"],
        ])
        #expect(status.windows.first?.remainingPercent == 74.5)
        #expect(status.windows.first?.label == "Weekly window")
        #expect(status.windows.first?.resetsAtUnix == 1_792_022_400)
        #expect(status.grokBilling?.prepaidUSD == 12.5)
        #expect(status.grokBilling?.onDemandUsedUSD == 5)
        #expect(status.grokBilling?.onDemandCapUSD == 20)
        #expect(status.grokBilling?.onDemandEnabled == true)
        #expect(status.grokBilling?.periodEnd == "2026-10-15T00:00:00.000Z")
        #expect(status.resetCredits == nil)
        #expect(status.credits == nil)
        #expect(!String(describing: status).contains("must-not-be-projected"))
    }

    @Test func grokPreservesMissingZeroAndLegacyAllowance() throws {
        let zero = try ProviderQuotaParser.grok(["config": ["prepaidBalance": [:]]])
        #expect(zero.grokBilling?.prepaidUSD == 0)
        #expect(zero.grokBilling?.onDemandEnabled == nil)
        #expect(zero.windows.isEmpty)
        let legacy = try ProviderQuotaParser.grok(["config": ["used": ["val": 250], "monthlyLimit": ["val": 1000]]])
        #expect(legacy.windows.first?.remainingPercent == 75)
        #expect(legacy.windows.first?.label == "Usage window")
        #expect(legacy.windows.first?.resetsAtUnix == nil)
        #expect(legacy.grokBilling?.prepaidUSD == nil)
        #expect(throws: ProviderQuotaError.self) { try ProviderQuotaParser.grok(["config": [:]]) }
        #expect(throws: ProviderQuotaError.self) { try ProviderQuotaParser.grok(["config": ["creditUsagePercent": Double.nan]]) }
    }

    @Test func codexProjectsCreditUnitsWithoutMixingResetGrantsOrSpark() throws {
        let response: [String: Any] = ["result": [
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 30.0],
                          "credits": ["balance": "12345.6789000", "hasCredits": true, "unlimited": false]],
                "spark": ["credits": ["balance": "999999", "hasCredits": true, "unlimited": true]],
            ],
            "rateLimitResetCredits": ["availableCount": 2],
        ]]
        let status = try ProviderQuotaParser.codex(response)
        #expect(status.credits?.balance == Decimal(string: "12345.6789000"))
        #expect(status.credits?.hasCredits == true)
        #expect(status.credits?.unlimited == false)
        #expect(status.credits?.limitAmount == nil)
        #expect(status.credits?.remainingPercent == nil)
        #expect(status.resetCredits == 2)
    }

    @Test func codexAcceptsCreditOnlyAndLegacySingleBucketReadings() throws {
        let creditOnly = try ProviderQuotaParser.codex(["result": ["rateLimits": [
            "credits": ["hasCredits": true, "unlimited": true, "balance": NSNull()],
        ]]])
        #expect(creditOnly.windows.isEmpty)
        #expect(creditOnly.credits?.unlimited == true)
        #expect(creditOnly.credits?.balance == nil)

        let depleted = try ProviderQuotaParser.codex(["result": ["rateLimits": [
            "primary": ["usedPercent": 100.0],
            "credits": ["hasCredits": false, "unlimited": false, "balance": "0"],
        ]]])
        #expect(depleted.credits?.balance == 0)
        #expect(depleted.credits?.hasCredits == false)
        #expect(depleted.resetCredits == nil)
    }

    @Test func codexMissingAndMalformedBalancesStayUnknown() throws {
        for value: Any in [NSNull(), [:] as [String: Any]] {
            let status = try ProviderQuotaParser.codex(["result": ["rateLimits": [
                "primary": ["usedPercent": 30.0], "credits": value,
            ]]])
            #expect(status.credits == nil)
        }
        for value: Any in [NSNull(), "NaN", "Infinity", "-1", "12 credits", "", "1,234", 123] {
            let status = try ProviderQuotaParser.codex(["result": ["rateLimits": [
                "primary": ["usedPercent": 30.0],
                "credits": ["balance": value, "hasCredits": true, "unlimited": false],
            ]]])
            #expect(status.credits?.balance == nil)
            #expect(status.credits?.hasCredits == true)
        }
    }

    @Test func codexUsesAccountBucketAndExcludesSparkAndIdentity() throws {
        let response: [String: Any] = [
            "id": 1,
            "result": [
                "rateLimitsByLimitId": [
                    "codex": ["planType": "pro", "primary": ["usedPercent": 92.0, "windowDurationMins": 10080, "resetsAt": 1788750854]],
                    "spark": ["limitName": "Spark", "primary": ["usedPercent": 2.0, "windowDurationMins": 300]],
                ],
                "rateLimitResetCredits": ["availableCount": 2, "credits": [
                    ["id": "not-for-display", "status": "available", "expiresAt": 1_790_000_000],
                    ["id": "also-private", "status": "available", "expiresAt": 1_800_000_000],
                ]],
                "accountId": "must-not-be-projected",
            ],
        ]
        let status = try ProviderQuotaParser.codex(response)
        #expect(status.plan == "pro")
        #expect(status.resetCredits == 2)
        #expect(status.latestReportedResetCreditExpiryUnix == 1_800_000_000)
        #expect(status.earliestReportedResetCreditExpiryUnix == 1_790_000_000)
        #expect(status.resetCreditDetailsCount == 2)
        #expect(!String(describing: status).contains("not-for-display"))
        #expect(status.windows.map(\.id) == ["codex.primary"])
        #expect(status.windows.first?.remainingPercent == 8)
        #expect(!String(describing: status).contains("must-not-be-projected"))
    }

    @Test func codexTreatsMissingOrCappedCreditDetailsAsUnknownExpiry() throws {
        func response(_ reset: [String: Any]) -> [String: Any] {
            ["result": ["rateLimits": ["primary": ["usedPercent": 10.0]], "rateLimitResetCredits": reset]]
        }
        let absent = try ProviderQuotaParser.codex(response(["availableCount": 2]))
        #expect(absent.resetCreditDetailsCount == nil)
        #expect(absent.latestReportedResetCreditExpiryUnix == nil)
        #expect(absent.earliestReportedResetCreditExpiryUnix == nil)

        let capped = try ProviderQuotaParser.codex(response(["availableCount": 2, "credits": [
            ["status": "available", "expiresAt": 1_790_000_000],
        ]]))
        #expect(capped.resetCreditDetailsCount == 1)
        #expect(capped.latestReportedResetCreditExpiryUnix == 1_790_000_000)
        #expect(capped.earliestReportedResetCreditExpiryUnix == 1_790_000_000)

        let noExpiry = try ProviderQuotaParser.codex(response(["availableCount": 1, "credits": [
            ["status": "available", "expiresAt": NSNull()],
        ]]))
        #expect(noExpiry.resetCreditsWithoutExpiryCount == 1)
        #expect(noExpiry.latestReportedResetCreditExpiryUnix == nil)
        #expect(noExpiry.earliestReportedResetCreditExpiryUnix == nil)
    }

    @Test func claudeRequiresBothWindowsAndParsesCredits() throws {
        let text = """
        Claude Code v2.1.236
        Opus 5 · Claude Team · Example
        Current session
        3% 3% used
        Resets 2:20am (Asia/Calcutta)
        Current week (all models)
        32% 32% used
        Resets Sep 6 at 5:30pm (Asia/Calcutta)
        Usage credits
        0% 0% used
        $0.00 / $150.00 spent · Resets Oct 1 (Asia/Calcutta)
        """
        let status = try ProviderQuotaParser.claude(text)
        #expect(status.windows.map(\.id) == ["current", "weekly"])
        #expect(status.windows.map(\.remainingPercent) == [97, 68])
        #expect(status.credits?.limitAmount == 150)
        #expect(status.plan == "Claude Team")
        #expect(status.resetCredits == nil)
        #expect(throws: ProviderQuotaError.self) {
            try ProviderQuotaParser.claude("Current session\n3% used\nResets soon")
        }
    }

    @Test func claudeProjectsReportedResetCountsSeparatelyFromPaidCredits() throws {
        let usage = """
        Current session
        3% used
        Resets 2:20am (Asia/Calcutta)
        Current week (all models)
        32% used
        Resets Oct 6 at 5:30pm (Asia/Calcutta)
        Usage credits
        0% used
        $0.00 / $150.00 spent · Resets Oct 1 (Asia/Calcutta)
        """
        let offered = try ProviderQuotaParser.claude(usage + "\n/limit-reset to refill your limits · 2 resets left · use by Oct 7")
        #expect(offered.resetCredits == 2)
        #expect(offered.credits?.limitAmount == 150)
        #expect(offered.latestReportedResetCreditExpiryUnix == nil)
        #expect(offered.resetCreditDetailsCount == nil)

        let singular = try ProviderQuotaParser.claude(usage + "\n/limit-reset to refill your limits · 1 reset left · use by Oct 7")
        #expect(singular.resetCredits == 1)
        let depleted = try ProviderQuotaParser.claude(usage + "\nReset used · no resets left")
        #expect(depleted.resetCredits == 0)
        let latest = try ProviderQuotaParser.claude(usage + "\n/limit-reset to refill your limits · 2 resets left · use by Oct 7\nLimits reset · your weekly reset day stays Tuesday · 1 reset left")
        #expect(latest.resetCredits == 1)

        for notice in ["Resets Oct 7", "3 resets left", "/limit-reset to reset your session limit now · uses weekly limit · 1/week",
                       "/limit-reset to refill your limits · -1 resets left · use by Oct 7",
                       "/limit-reset to refill your limits · 18446744073709551616 resets left · use by Oct 7"] {
            #expect(try ProviderQuotaParser.claude(usage + "\n" + notice).resetCredits == nil)
        }
    }

    @Test func missingProviderCLIIsUnavailable() async {
        let client = ProviderQuotaClient(codexURL: URL(fileURLWithPath: "/private/tmp/contextdaddy-missing-codex"))
        do {
            _ = try await client.loadQuota(for: .codex)
            Issue.record("Missing CLI must not appear as zero allowance")
        } catch let error as ProviderQuotaError {
            #expect(error == .missingCLI("Codex"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func terminalSequencesDoNotSpoofClaudeHeadings() {
        let output = ProviderQuotaParser.cleanTerminal("\u{001B}[32mCurrent session\u{001B}[0m\r3% used\rResets soon\u{001B}]0;secret title\u{0007}")
        #expect(output == "Current session\n3% used\nResets soon")
    }
}
