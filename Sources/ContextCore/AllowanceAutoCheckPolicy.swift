import Foundation

public enum AllowanceAutoCheckPolicy {
    public static let minimumInterval: TimeInterval = 15 * 60

    public static func shouldCheck(enabled: Bool, lastAttempt: Date?, now: Date,
                                   isVisible: Bool = true, isActive: Bool = true) -> Bool {
        guard enabled, isVisible, isActive else { return false }
        guard let lastAttempt else { return true }
        // A future timestamp can result from a clock correction. It must not
        // suppress automatic checks indefinitely.
        let age = now.timeIntervalSince(lastAttempt)
        return age < 0 || age >= minimumInterval
    }

    public static func isStale(checkedAt: String, now: Date) -> Bool {
        shouldCheck(enabled: true, lastAttempt: checkDate(checkedAt), now: now)
    }

    public static func checkDate(_ checkedAt: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: checkedAt)
        formatter.formatOptions.insert(.withFractionalSeconds)
        return date ?? formatter.date(from: checkedAt)
    }
}
