import Foundation
import CryptoKit

public enum ConfigurationIssueSeverity: String, Sendable, Equatable {
    case warning = "Warning"
    case error = "Error"
}

public struct ConfigurationHealthIssue: Identifiable, Sendable, Equatable {
    public let id: String
    public let severity: ConfigurationIssueSeverity
    public let runtime: AgentRuntime
    public let title: String
    public let detail: String
    public let path: String
    public let line: Int
    public let remediation: String

    public init(
        id: String,
        severity: ConfigurationIssueSeverity,
        runtime: AgentRuntime,
        title: String,
        detail: String,
        path: String,
        line: Int,
        remediation: String
    ) {
        self.id = id
        self.severity = severity
        self.runtime = runtime
        self.title = title
        self.detail = detail
        self.path = path
        self.line = line
        self.remediation = remediation
    }
}

public struct ConfigurationFileCheck: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable { case checked = "Checked", missing = "Not present", unverified = "Not checked" }
    public let runtime: AgentRuntime
    public let path: String
    public let status: Status
    public let detail: String
    public var id: String { runtime.rawValue + path }
}

public struct ConfigurationHealthReport: Sendable, Equatable {
    public let issues: [ConfigurationHealthIssue]
    public let scannedFiles: [String]
    public let generatedAt: Date
    public let files: [ConfigurationFileCheck]

    public init(issues: [ConfigurationHealthIssue], scannedFiles: [String], generatedAt: Date = Date(), files: [ConfigurationFileCheck] = []) {
        self.issues = issues
        self.scannedFiles = scannedFiles
        self.generatedAt = generatedAt
        self.files = files.isEmpty ? scannedFiles.map { .init(runtime: .codex, path: $0, status: .checked, detail: "Structural checks") } : files
    }

    public func forAgent(_ runtime: AgentRuntime) -> Self {
        let selected = files.filter { $0.runtime == runtime }
        return .init(issues: issues.filter { $0.runtime == runtime },
                     scannedFiles: selected.filter { $0.status == .checked }.map(\.path),
                     generatedAt: generatedAt, files: selected)
    }

    public static let empty = ConfigurationHealthReport(issues: [], scannedFiles: [])
    public var errorCount: Int { issues.count { $0.severity == .error } }
    public var warningCount: Int { issues.count { $0.severity == .warning } }
}

public enum AgentConfigurationAuditor {
    public struct Configuration: Sendable {
        public let home: URL
        public let configURLs: [URL]
        public let executableSearchPaths: [String]
        public let maximumConfigBytes: Int

        public init(
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            configURLs: [URL]? = nil,
            executableSearchPaths: [String]? = nil,
            maximumConfigBytes: Int = 512 * 1_024
        ) {
            self.home = home
            self.configURLs = configURLs ?? [home.appendingPathComponent(".codex/config.toml")]
            let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
            self.executableSearchPaths = executableSearchPaths ?? environmentPaths + [
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                home.appendingPathComponent(".local/bin").path,
                home.appendingPathComponent(".cargo/bin").path,
            ]
            self.maximumConfigBytes = maximumConfigBytes
        }
    }

    public static func audit(configuration: Configuration = .init()) -> ConfigurationHealthReport {
        var issues: [ConfigurationHealthIssue] = []
        var scannedFiles: [String] = []
        for url in configuration.configURLs where FileManager.default.isReadableFile(atPath: url.path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= configuration.maximumConfigBytes,
                  let body = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            scannedFiles.append(url.path)
            issues.append(contentsOf: auditCodexConfig(body, url: url, configuration: configuration))
        }
        return ConfigurationHealthReport(
            issues: issues.sorted {
                if $0.severity != $1.severity { return $0.severity == .error }
                return $0.line < $1.line
            },
            scannedFiles: scannedFiles
        )
    }

    private struct MCPServer {
        let name: String
        var command: String?
        var commandLine = 0
        var cwd: String?
        var enabled = true
        var hasURL = false
    }

    static func auditCodexConfig(
        _ body: String,
        url: URL,
        configuration: Configuration,
        runtime: AgentRuntime = .codex
    ) -> [ConfigurationHealthIssue] {
        var issues: [ConfigurationHealthIssue] = []
        var table = ""
        var servers: [String: MCPServer] = [:]

        for (offset, rawLine) in body.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            if runtime == .codex, table == "otel", key == "approvals_reviewer" || key == "personality" {
                issues.append(ConfigurationHealthIssue(
                    id: "codex-misplaced-\(key)-\(url.path)",
                    severity: .warning,
                    runtime: .codex,
                    title: "Ignored `\(key)` setting",
                    detail: "`\(key)` is valid at the top level, but Codex ignores it inside `[otel]`.",
                    path: url.path,
                    line: lineNumber,
                    remediation: "Move `\(key)` above `[otel]` and preserve its current value."
                ))
            }

            if runtime == .codex, table.isEmpty, key == "model_reasoning_effort",
               ["low", "minimal"].contains(unquote(rawValue).lowercased()),
               url.standardizedFileURL.path == configuration.home.appendingPathComponent(".codex/config.toml").standardizedFileURL.path {
                issues.append(ConfigurationHealthIssue(
                    id: "codex-low-reasoning-default-\(url.path)",
                    severity: .warning,
                    runtime: .codex,
                    title: "Low global reasoning effort",
                    detail: "`model_reasoning_effort = \"\(unquote(rawValue))\"` is the global default, so every Codex session without an override starts with reduced reasoning.",
                    path: url.path,
                    line: lineNumber,
                    remediation: "Remove the line to use the model default, or set the lower effort in a named profile used only for quick tasks."
                ))
            }

            guard let serverName = directMCPServerName(from: table) else { continue }
            var server = servers[serverName] ?? MCPServer(name: serverName)
            switch key {
            case "command":
                server.command = unquote(rawValue)
                server.commandLine = lineNumber
            case "cwd": server.cwd = unquote(rawValue)
            case "enabled": server.enabled = rawValue != "false"
            case "url": server.hasURL = true
            default: break
            }
            servers[serverName] = server
        }

        for server in servers.values.sorted(by: { $0.name < $1.name }) where server.enabled && !server.hasURL {
            guard let command = server.command, !command.isEmpty, !command.contains("$"), !command.contains("{{"), !(command.contains("/") && !command.hasPrefix("/") && !command.hasPrefix("~/")) else { continue }
            if !commandExists(command, cwd: server.cwd, configURL: url, configuration: configuration) {
                issues.append(ConfigurationHealthIssue(
                    id: "\(runtime.rawValue)-mcp-command-\(SHA256.hash(data: Data(server.name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())-\(url.path)",
                    severity: .error,
                    runtime: runtime,
                    title: "MCP launcher not found",
                    detail: "A configured local MCP executable was not found in the checked paths. Agent-specific PATH overrides may differ.",
                    path: url.path,
                    line: server.commandLine,
                    remediation: "Review this server’s command in the source file. Confirm the executable in the agent’s environment; repair its path or disable the server if it is no longer needed."
                ))
            }
        }
        return issues
    }

    private static func directMCPServerName(from table: String) -> String? {
        guard table.hasPrefix("mcp_servers.") else { return nil }
        let name = String(table.dropFirst("mcp_servers.".count))
        guard !name.contains(".") else { return nil }
        return unquote(name)
    }

    static func commandExists(
        _ command: String,
        cwd: String?,
        configURL: URL,
        configuration: Configuration
    ) -> Bool {
        let manager = FileManager.default
        if command.hasPrefix("~/") { return manager.isExecutableFile(atPath: configuration.home.appendingPathComponent(String(command.dropFirst(2))).path) }
        if command.hasPrefix("/") { return manager.isExecutableFile(atPath: command) }
        if command.contains("/") {
            let base: URL
            if let cwd, cwd.hasPrefix("/") {
                base = URL(fileURLWithPath: cwd, isDirectory: true)
            } else if let cwd {
                base = configURL.deletingLastPathComponent().appendingPathComponent(cwd, isDirectory: true)
            } else {
                base = configURL.deletingLastPathComponent()
            }
            return manager.isExecutableFile(atPath: base.appendingPathComponent(command).standardizedFileURL.path)
        }
        return configuration.executableSearchPaths.contains {
            manager.isExecutableFile(atPath: URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(command).path)
        }
    }

    private static func unquote<S: StringProtocol>(_ value: S) -> String {
        let string = String(value).trimmingCharacters(in: .whitespaces)
        guard string.count >= 2, (string.first == "\"" && string.last == "\"") || (string.first == "'" && string.last == "'") else { return string }
        return String(string.dropFirst().dropLast())
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\"", !escaped { quoted.toggle() }
            if character == "#", !quoted { return String(line[..<index]) }
            escaped = character == "\\" && !escaped
            if character != "\\" { escaped = false }
        }
        return line
    }
}
