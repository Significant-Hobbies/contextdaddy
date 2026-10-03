import Foundation
import Darwin

public struct ClaudeResetGrant: Decodable, Sendable, Equatable {
    public let kind: String
    public let count: UInt64
    public let expiresAtUnix: Int64
    public let paused: Bool
    public let usableNow: Bool
}

public struct ClaudeResetGrantSummary: Decodable, Sendable, Equatable {
    public let fullCount: UInt64
    public let fiveHourCount: UInt64
    public let grants: [ClaudeResetGrant]
    public let checkedAt: String
}

enum ClaudeResetGrantError: Error, LocalizedError {
    case credentialUnavailable, cliVersionUnavailable, unsupportedResponse, requestFailed

    var errorDescription: String? {
        switch self {
        case .credentialUnavailable: "Reset details unavailable. Open Claude Code to check its sign-in."
        case .cliVersionUnavailable: "Reset details unavailable. Update Claude Code and check again."
        case .unsupportedResponse: "Claude did not provide supported reset-grant details."
        case .requestFailed: "Claude reset-grant check failed. Try checking again."
        }
    }
}

/// Reads the same usage endpoint as Claude Code. Never refreshes a credential,
/// follows a redirect, persists a response, or calls a reset/redemption endpoint.
struct ClaudeResetGrantReader: Sendable {
    func load(cliVersion: String?) async throws -> ProviderQuotaStatus {
        guard let cliVersion else { throw ClaudeResetGrantError.cliVersionUnavailable }
        let request = try Self.request(credential: Self.credential(), cliVersion: cliVersion)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= 256 * 1024 else {
                throw ClaudeResetGrantError.requestFailed
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 256 * 1024 else { throw ClaudeResetGrantError.requestFailed }
                data.append(byte)
            }
            return try Self.quotaStatus(data)
        } catch let error as ClaudeResetGrantError { throw error }
        catch { throw ClaudeResetGrantError.requestFailed }
    }

    private static func credential() throws -> Data {
        // Custom Claude homes have a different account/service. Do not silently
        // substitute the default login for a custom CLI configuration.
        guard ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil else {
            throw ClaudeResetGrantError.credentialUnavailable
        }
        // Legacy Keychain calls can block in securityd even when UI is denied.
        // Isolate the read in Apple's helper so the app can enforce a deadline.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        return try readCredential(using: process)
    }

    static func readCredential(using process: Process, timeout: TimeInterval = 2) throws -> Data {
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        do { try process.run() } catch { throw ClaudeResetGrantError.credentialUnavailable }
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= 64 * 1024 else { throw ClaudeResetGrantError.credentialUnavailable }
                data.append(contentsOf: buffer.prefix(count))
            } else if !process.isRunning {
                guard process.terminationStatus == 0, !data.isEmpty else { throw ClaudeResetGrantError.credentialUnavailable }
                return data
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw ClaudeResetGrantError.credentialUnavailable
    }

    static func request(credential: Data, cliVersion: String, now: Date = Date()) throws -> URLRequest {
        struct Credential: Decodable {
            struct OAuth: Decodable { let accessToken: String; let expiresAt: Double }
            let claudeAiOauth: OAuth
        }
        guard cliVersion.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              credential.count <= 64 * 1024,
              let oauth = try? JSONDecoder().decode(Credential.self, from: credential).claudeAiOauth,
              oauth.expiresAt.isFinite, oauth.expiresAt > now.timeIntervalSince1970 * 1000,
              !oauth.accessToken.isEmpty, oauth.accessToken.utf8.count <= 16 * 1024,
              oauth.accessToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw ClaudeResetGrantError.credentialUnavailable
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // The grant block is surface/version gated. Use the installed CLI's
        // actual version and header format, not a hardcoded supported version.
        request.setValue("claude-cli/\(cliVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> ClaudeResetGrantSummary {
        struct Response: Decodable {
            struct Block: Decodable {
                struct Grant: Decodable {
                    let resets_left: UInt64
                    let ends_at: String
                    let starts_at: String?
                    let clears: [String]
                    let paused: Bool
                    let usable_now: Bool
                }
                let eligible: Bool
                let grants: [Grant]
            }
            let cedar_ember: Block
        }
        guard data.count <= 256 * 1024,
              let block = try? JSONDecoder().decode(Response.self, from: data).cedar_ember,
              block.eligible, block.grants.count <= 128 else {
            throw ClaudeResetGrantError.unsupportedResponse
        }
        var grants: [ClaudeResetGrant] = []
        var full: UInt64 = 0
        var fiveHour: UInt64 = 0
        for grant in block.grants {
            guard let end = isoDate(grant.ends_at) else { throw ClaudeResetGrantError.unsupportedResponse }
            let start = grant.starts_at.flatMap(isoDate)
            guard grant.starts_at == nil || start != nil else { throw ClaudeResetGrantError.unsupportedResponse }
            let kind: String
            let clears = Set(grant.clears)
            if clears.contains("five_hour"), clears.contains("seven_day") { kind = "full" }
            else if clears == ["five_hour"] { kind = "five-hour" }
            else { throw ClaudeResetGrantError.unsupportedResponse }
            guard end > now, grant.resets_left > 0 else { continue }
            let sum = (kind == "full" ? full : fiveHour).addingReportingOverflow(grant.resets_left)
            guard !sum.overflow else { throw ClaudeResetGrantError.unsupportedResponse }
            if kind == "full" { full = sum.partialValue } else { fiveHour = sum.partialValue }
            grants.append(ClaudeResetGrant(kind: kind, count: grant.resets_left,
                                          expiresAtUnix: Int64(end.timeIntervalSince1970), paused: grant.paused,
                                          usableNow: grant.usable_now && (start == nil || start! <= now)))
        }
        guard !full.addingReportingOverflow(fiveHour).overflow else { throw ClaudeResetGrantError.unsupportedResponse }
        grants.sort { ($0.kind, $0.expiresAtUnix) < ($1.kind, $1.expiresAtUnix) }
        return ClaudeResetGrantSummary(fullCount: full, fiveHourCount: fiveHour, grants: grants,
                                       checkedAt: ISO8601DateFormatter().string(from: now))
    }

    /// The same response can keep the grant reading available if the CLI's
    /// interactive display fails. Unreported plan/paid-credit data stays nil.
    static func quotaStatus(_ data: Data, now: Date = Date()) throws -> ProviderQuotaStatus {
        struct Windows: Decodable {
            struct Window: Decodable { let utilization: Double; let resets_at: String? }
            let five_hour: Window
            let seven_day: Window
        }
        let summary = try parse(data, now: now)
        guard let reading = try? JSONDecoder().decode(Windows.self, from: data) else {
            throw ClaudeResetGrantError.unsupportedResponse
        }
        var windows: [ProviderQuotaWindow] = []
        for (value, id, label) in [(reading.five_hour, "current", "Current window"),
                                    (reading.seven_day, "weekly", "Weekly window")] {
            let percent = value.utilization
            guard percent.isFinite, (0...100).contains(percent) else {
                throw ClaudeResetGrantError.unsupportedResponse
            }
            let reset = value.resets_at.flatMap(isoDate)
            guard value.resets_at == nil || reset != nil else { throw ClaudeResetGrantError.unsupportedResponse }
            windows.append(ProviderQuotaWindow(id: id, label: label, usedPercent: percent, remainingPercent: 100 - percent,
                                               windowDurationMinutes: nil, resetsAtUnix: reset.map { Int64($0.timeIntervalSince1970) },
                                               resetDescription: nil))
        }
        return ProviderQuotaStatus(provider: "claude", status: "ready", source: "Claude OAuth usage (CLI display unavailable)",
                                   checkedAt: summary.checkedAt, plan: nil, windows: windows, credits: nil,
                                   resetCredits: nil, latestReportedResetCreditExpiryUnix: nil,
                                   resetCreditDetailsCount: nil, resetCreditsWithoutExpiryCount: nil,
                                   claudeResetGrants: summary,
                                   message: "CLI plan and paid-credit details were unavailable. Windows and reset grants were read from Claude's usage endpoint.")
    }

    static func mergingCLIDetails(_ cli: ProviderQuotaStatus?, into remote: ProviderQuotaStatus) -> ProviderQuotaStatus {
        guard let cli else { return remote }
        // The terminal can show placeholder percentages before its request
        // completes. Keep API windows and grants from one authoritative read.
        return ProviderQuotaStatus(provider: "claude", status: "ready",
                                   source: "Claude OAuth usage · windows and resets; Claude Code /usage · plan and paid credits",
                                   checkedAt: remote.checkedAt, plan: cli.plan, windows: remote.windows, credits: cli.credits,
                                   resetCredits: remote.claudeResetGrants.map { $0.fullCount + $0.fiveHourCount },
                                   latestReportedResetCreditExpiryUnix: nil, resetCreditDetailsCount: nil,
                                   resetCreditsWithoutExpiryCount: nil, claudeResetGrants: remote.claudeResetGrants, message: nil)
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
