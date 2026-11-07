import Foundation
import Testing
@testable import ContextCore

struct AllowanceAutoCheckPolicyTests {
    @Test func requiresOptInAndThrottlesChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AllowanceAutoCheckPolicy.shouldCheck(enabled: false, lastAttempt: nil, now: now))
        #expect(AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: nil, now: now))
        #expect(!AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-60), now: now))
        #expect(AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-900), now: now))
        #expect(AllowanceAutoCheckPolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(60), now: now))
    }

    @Test func freshnessExpiresEvenWithoutARefreshFailure() {
        let checked = ISO8601DateFormatter().date(from: "2026-11-07T13:00:00Z")!
        #expect(!AllowanceAutoCheckPolicy.isStale(checkedAt: "2026-11-07T13:00:00Z", now: checked.addingTimeInterval(899)))
        #expect(AllowanceAutoCheckPolicy.isStale(checkedAt: "2026-11-07T13:00:00Z", now: checked.addingTimeInterval(900)))
        #expect(AllowanceAutoCheckPolicy.isStale(checkedAt: "2026-11-07T13:00:00Z", now: checked.addingTimeInterval(-1)))
        #expect(AllowanceAutoCheckPolicy.isStale(checkedAt: "invalid", now: checked))
        #expect(!AllowanceAutoCheckPolicy.isStale(checkedAt: "2026-11-07T13:00:00.123Z", now: checked.addingTimeInterval(1)))
    }
}
