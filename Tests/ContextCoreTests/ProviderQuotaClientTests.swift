import Foundation
import Testing
@testable import ContextCore

struct ProviderQuotaClientTests {
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

        let capped = try ProviderQuotaParser.codex(response(["availableCount": 2, "credits": [
            ["status": "available", "expiresAt": 1_790_000_000],
        ]]))
        #expect(capped.resetCreditDetailsCount == 1)
        #expect(capped.latestReportedResetCreditExpiryUnix == 1_790_000_000)

        let noExpiry = try ProviderQuotaParser.codex(response(["availableCount": 1, "credits": [
            ["status": "available", "expiresAt": NSNull()],
        ]]))
        #expect(noExpiry.resetCreditsWithoutExpiryCount == 1)
        #expect(noExpiry.latestReportedResetCreditExpiryUnix == nil)
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
