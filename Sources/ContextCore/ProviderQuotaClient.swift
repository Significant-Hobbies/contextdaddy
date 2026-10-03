import Darwin
import Foundation

public enum ProviderQuotaError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedProvider
    case missingCLI(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "This service has no verified provider-allowance adapter."
        case .missingCLI(let provider): "\(provider) CLI was not found. Install it and sign in before checking allowance."
        case .requestFailed(let provider): "\(provider) allowance is unavailable. Open its CLI and check the account session."
        }
    }
}

/// Direct, opt-in provider readings. No response body is logged or persisted.
public struct ProviderQuotaClient: Sendable {
    private let codexURL: URL?
    private let claudeURL: URL?

    public init(codexURL: URL? = nil, claudeURL: URL? = nil) {
        self.codexURL = codexURL
        self.claudeURL = claudeURL
    }

    public func loadQuota(for service: UsageService) async throws -> ProviderQuotaReceipt {
        guard let key = service.quotaKey else { throw ProviderQuotaError.unsupportedProvider }
        let reading = try await Task.detached(priority: .userInitiated) { () throws -> (status: ProviderQuotaStatus?, version: String?) in
            switch key {
            case "codex": return (try collectCodex(), nil)
            case "claude":
                do { return try collectClaude() }
                catch {
                    guard let url = resolve("claude", explicit: claudeURL) else { throw ProviderQuotaError.missingCLI("Claude") }
                    return (nil, claudeVersion(at: url))
                }
            default: throw ProviderQuotaError.unsupportedProvider
            }
        }.value
        var status = reading.status
        if key == "claude" {
            do {
                let remote = try await ClaudeResetGrantReader().load(cliVersion: reading.version)
                status = ClaudeResetGrantReader.mergingCLIDetails(status, into: remote)
            } catch {
                guard status != nil else { throw ProviderQuotaError.requestFailed("Claude") }
                status?.resetGrantError = (error as? ClaudeResetGrantError)?.errorDescription ?? "Claude reset-grant check failed."
            }
        }
        guard let status else { throw ProviderQuotaError.requestFailed("Claude") }
        return ProviderQuotaReceipt(schemaVersion: "contextdaddy.provider-quota/v1",
                                    generatedAt: ISO8601DateFormatter().string(from: Date()), providers: [status])
    }

    private func claudeVersion(at url: URL) -> String? {
        let filename = url.resolvingSymlinksInPath().lastPathComponent
        if filename.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil { return filename }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        do { try process.run() } catch { return nil }
        defer { stop(process) }
        var data = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, data.count < 4096 {
            _ = readAvailable(fd, into: &data)
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        _ = readAvailable(fd, into: &data)
        guard data.count < 4096 else { return nil }
        let output = String(decoding: data, as: UTF8.self)
        guard output.contains("Claude Code"),
              let range = output.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    private func collectCodex() throws -> ProviderQuotaStatus {
        guard let url = resolve("codex", explicit: codexURL) else { throw ProviderQuotaError.missingCLI("Codex") }
        let process = Process()
        process.executableURL = url
        process.arguments = ["app-server"]
        let input = Pipe()
        process.standardInput = input
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("contextdaddy-quota-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ProviderQuotaError.requestFailed("Codex")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ProviderQuotaError.requestFailed("Codex") }
        defer { stop(process) }
        let requests = [
            ["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "contextdaddy", "title": "ContextDaddy", "version": "0.1.0"]]] as [String: Any],
            ["method": "initialized", "params": [:]] as [String: Any],
            ["method": "account/rateLimits/read", "id": 1] as [String: Any],
        ]
        do {
            for request in requests {
                let data = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
                try input.fileHandleForWriting.write(contentsOf: data)
            }
        } catch { throw ProviderQuotaError.requestFailed("Codex") }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes > 256 * 1024 { break }
            if let data = try? Data(contentsOf: outputURL),
               let line = data.split(separator: 0x0a).first(where: { data in
                   guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                   return (value["id"] as? Int) == 1
               }), let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return try ProviderQuotaParser.codex(value)
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ProviderQuotaError.requestFailed("Codex")
    }

    private func collectClaude() throws -> (status: ProviderQuotaStatus, version: String?) {
        guard let url = resolve("claude", explicit: claudeURL) else { throw ProviderQuotaError.missingCLI("Claude") }
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 64, ws_col: 132, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw ProviderQuotaError.requestFailed("Claude")
        }
        defer { if master >= 0 { close(master) }; if slave >= 0 { close(slave) } }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let process = Process()
        // A GUI Process has no controlling terminal. macOS script establishes
        // one for the CLI; /dev/null prevents a terminal transcript on disk.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", url.path, "--safe-mode", "--ax-screen-reader"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment.removeValue(forKey: "COLORTERM")
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do { try process.run() } catch { throw ProviderQuotaError.requestFailed("Claude") }
        close(slave)
        slave = -1
        defer {
            // Ask the interactive CLI to quit before closing script's terminal.
            // Killing only script can otherwise leave its CLI child alive.
            let quit = Array("\u{3}\u{3}".utf8)
            _ = write(master, quit, quit.count)
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            close(master)
            master = -1
            stop(process)
        }
        var bytes = Data()
        let startup = Date().addingTimeInterval(5)
        var lastOutput = Date()
        // The version banner can precede the interactive command handler. A
        // quiet gap after it is not proof that /usage can accept input yet.
        while Date() < startup {
            if readAvailable(master, into: &bytes) { lastOutput = Date() }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let command = Array("/usage\r".utf8)
        guard write(master, command, command.count) == command.count else {
            throw ProviderQuotaError.requestFailed("Claude")
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if readAvailable(master, into: &bytes) { lastOutput = Date() }
            let display = ProviderQuotaParser.cleanTerminal(String(decoding: bytes, as: UTF8.self))
            if let status = try? ProviderQuotaParser.claude(display),
               Date().timeIntervalSince(lastOutput) >= 0.9 {
                return (status, ProviderQuotaParser.claudeVersion(display))
            }
            if bytes.count >= 256 * 1024 || !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ProviderQuotaError.requestFailed("Claude")
    }

    private func readAvailable(_ fd: Int32, into bytes: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var sawOutput = false
        while bytes.count < 256 * 1024 {
            let count = read(fd, &buffer, min(buffer.count, 256 * 1024 - bytes.count))
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer.prefix(count))
            sawOutput = true
        }
        return sawOutput
    }

    private func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    private func resolve(_ name: String, explicit: URL?) -> URL? {
        if let explicit { return FileManager.default.isExecutableFile(atPath: explicit.path) ? explicit : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fixed = [home.appendingPathComponent(".local/bin/\(name)"),
                     URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
                     URL(fileURLWithPath: "/usr/local/bin/\(name)")]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(name)
        }
        return (fixed + path).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum ProviderQuotaParser {
    static func claudeVersion(_ display: String) -> String? {
        guard let range = display.range(of: #"Claude Code v[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        return String(display[range]).replacingOccurrences(of: "Claude Code v", with: "")
    }

    static func codex(_ response: [String: Any]) throws -> ProviderQuotaStatus {
        guard response["error"] == nil, let result = response["result"] as? [String: Any] else {
            throw ProviderQuotaError.requestFailed("Codex")
        }
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let selected: [(String, [String: Any])]
        if let buckets {
            if let account = buckets["codex"] as? [String: Any] {
                selected = [("codex", account)]
            } else {
                selected = buckets.compactMap { id, value in
                    guard !id.lowercased().contains("spark"), let bucket = value as? [String: Any],
                          !(bucket["limitName"] as? String ?? "").lowercased().contains("spark") else { return nil }
                    return (id, bucket)
                }
            }
        } else if let bucket = result["rateLimits"] as? [String: Any] {
            selected = [("codex", bucket)]
        } else { selected = [] }
        var windows: [ProviderQuotaWindow] = []
        var plan: String?
        for (id, bucket) in selected {
            if plan == nil { plan = bucket["planType"] as? String }
            for kind in ["primary", "secondary"] {
                guard let window = bucket[kind] as? [String: Any],
                      let raw = window["usedPercent"] as? Double, raw.isFinite else { continue }
                let duration = (window["windowDurationMins"] as? NSNumber)?.uint64Value
                let label: String
                switch duration {
                case 300: label = "5-hour window"
                case 10_080: label = "Weekly window"
                case .some(let minutes) where minutes % 1_440 == 0: label = "\(minutes / 1_440)-day window"
                case .some(let minutes) where minutes % 60 == 0: label = "\(minutes / 60)-hour window"
                case .some(let minutes): label = "\(minutes)-minute window"
                case nil: label = kind
                }
                let used = min(100, max(0, raw))
                windows.append(ProviderQuotaWindow(id: "\(id).\(kind)", label: id == "codex" ? label : "\(id) · \(label)",
                                                   usedPercent: used, remainingPercent: 100 - used,
                                                   windowDurationMinutes: duration,
                                                   resetsAtUnix: (window["resetsAt"] as? NSNumber)?.int64Value,
                                                   resetDescription: nil))
            }
        }
        let credits = selected.first(where: { $0.0 == "codex" }).flatMap { codexCredits($0.1["credits"]) }
        guard !windows.isEmpty || credits != nil else { throw ProviderQuotaError.requestFailed("Codex") }
        windows.sort { ($0.windowDurationMinutes ?? .max, $0.label) < ($1.windowDurationMinutes ?? .max, $1.label) }
        let resetSummary = result["rateLimitResetCredits"] as? [String: Any]
        let reset = resetSummary?["availableCount"] as? NSNumber
        let resetDetails = resetSummary?["credits"] as? [[String: Any]]
        let availableDetails = resetDetails?.filter { ($0["status"] as? String) == "available" }
        let expiries = availableDetails?.compactMap { ($0["expiresAt"] as? NSNumber)?.int64Value }
        let noExpiryCount = availableDetails?.filter { $0["expiresAt"] is NSNull }.count
        return ProviderQuotaStatus(provider: "codex", status: "ready", source: "codex app-server account/rateLimits/read",
                                   checkedAt: timestamp(), plan: plan, windows: windows,
                                   credits: credits, resetCredits: reset?.uint64Value,
                                   latestReportedResetCreditExpiryUnix: expiries?.max(),
                                   resetCreditDetailsCount: availableDetails.map { UInt64($0.count) },
                                   resetCreditsWithoutExpiryCount: noExpiryCount.map(UInt64.init), message: nil)
    }

    private static func codexCredits(_ value: Any?) -> ProviderCreditBalance? {
        guard let snapshot = value as? [String: Any] else { return nil }
        var balance: Decimal?
        if let raw = snapshot["balance"] as? String,
           raw.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
           let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN {
            balance = amount
        }
        let hasCredits = snapshot["hasCredits"] as? Bool
        let unlimited = snapshot["unlimited"] as? Bool
        guard balance != nil || hasCredits != nil || unlimited != nil else { return nil }
        return ProviderCreditBalance(balance: balance, hasCredits: hasCredits, unlimited: unlimited)
    }

    static func claude(_ output: String) throws -> ProviderQuotaStatus {
        enum Section { case current, weekly, model(String), credits }
        var section: Section?
        var pending: Double?
        var windows: [ProviderQuotaWindow] = []
        var credits: ProviderCreditBalance?
        var resetCredits: UInt64?
        var plan: String?
        for raw in output.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let count = claudeResetCount(line) { resetCredits = count }
            if plan == nil, line.contains(" · Claude ") { plan = line.components(separatedBy: " · ").dropFirst().first }
            switch line {
            case "Current session": section = .current; pending = nil; continue
            case "Current week (all models)": section = .weekly; pending = nil; continue
            case "Usage credits": section = .credits; pending = nil; continue
            default: break
            }
            if line.hasPrefix("Current week (") {
                section = .model(String(line.dropFirst("Current week (".count).dropLast()))
                pending = nil
                continue
            }
            if line.hasSuffix("used"), let token = line.split(separator: " ").first(where: { $0.hasSuffix("%") }),
               let value = Double(token.dropLast()), value.isFinite {
                pending = min(100, max(0, value)); continue
            }
            if line.hasPrefix("Resets "), let used = pending {
                let reset = String(line.dropFirst("Resets ".count))
                switch section {
                case .current: upsert(&windows, id: "current", label: "Current window", used: used, reset: reset)
                case .weekly: upsert(&windows, id: "weekly", label: "Weekly window", used: used, reset: reset)
                case .model(let name): upsert(&windows, id: "weekly_model_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))", label: "\(name) weekly window", used: used, reset: reset)
                case .credits, nil: break
                }
                pending = nil
                continue
            }
            if case .credits = section, let used = pending, line.contains(" / $"),
               let pair = line.components(separatedBy: " spent").first?.components(separatedBy: " / "), pair.count == 2 {
                let amounts = pair.compactMap { Double($0.filter { $0.isNumber || $0 == "." }) }
                credits = ProviderCreditBalance(remainingPercent: 100 - used,
                                                usedAmount: amounts.first, limitAmount: amounts.count > 1 ? amounts[1] : nil)
                pending = nil
            }
        }
        guard windows.contains(where: { $0.id == "current" }), windows.contains(where: { $0.id == "weekly" }) else {
            throw ProviderQuotaError.requestFailed("Claude")
        }
        windows.sort { ($0.id == "current" ? 0 : $0.id == "weekly" ? 1 : 2, $0.id) <
                       ($1.id == "current" ? 0 : $1.id == "weekly" ? 1 : 2, $1.id) }
        return ProviderQuotaStatus(provider: "claude", status: "ready", source: "Claude Code /usage",
                                   checkedAt: timestamp(), plan: plan, windows: windows,
                                   credits: credits, resetCredits: resetCredits,
                                   latestReportedResetCreditExpiryUnix: nil, resetCreditDetailsCount: nil,
                                   resetCreditsWithoutExpiryCount: nil, message: nil)
    }

    /// Claude's limit-reset notices report a count independently of paid usage
    /// credits. Missing notices mean unknown, not zero. Do not invoke the reset
    /// command to collect this reading: it can consume a grant.
    private static func claudeResetCount(_ line: String) -> UInt64? {
        guard line.hasPrefix("/limit-reset to refill your limits · ") ||
              line.hasPrefix("Reset used · ") || line.hasPrefix("Limits reset · ") else { return nil }
        for component in line.components(separatedBy: " · ") {
            if component == "no resets left" { return 0 }
            let words = component.split(separator: " ")
            guard words.count == 3, words[2] == "left",
                  words[1] == "reset" || words[1] == "resets",
                  words[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let count = UInt64(words[0]) else { continue }
            return count
        }
        return nil
    }

    static func cleanTerminal(_ input: String) -> String {
        let bytes = Array(input.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x1b, index < bytes.count {
                let kind = bytes[index]
                index += 1
                if kind == 0x5b { // CSI: ESC [ ... final byte
                    while index < bytes.count {
                        let next = bytes[index]
                        index += 1
                        if (0x40...0x7e).contains(next) { break }
                    }
                } else if kind == 0x5d { // OSC: ESC ] ... BEL or ESC \
                    while index < bytes.count {
                        if bytes[index] == 0x07 { index += 1; break }
                        if bytes[index] == 0x1b, index + 1 < bytes.count, bytes[index + 1] == 0x5c {
                            index += 2; break
                        }
                        index += 1
                    }
                }
                continue
            }
            if byte == 0x0d { output.append(0x0a) }
            else if byte == 0x0a || byte == 0x09 || byte >= 0x20 { output.append(byte) }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func upsert(_ windows: inout [ProviderQuotaWindow], id: String, label: String,
                               used: Double, reset: String) {
        let window = ProviderQuotaWindow(id: id, label: label, usedPercent: used, remainingPercent: 100 - used,
                                         windowDurationMinutes: nil, resetsAtUnix: nil, resetDescription: reset)
        if let index = windows.firstIndex(where: { $0.id == id }) { windows[index] = window }
        else { windows.append(window) }
    }

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
