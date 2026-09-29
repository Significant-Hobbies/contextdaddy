import Foundation
import CryptoKit

/// Bounded, read-only checks of documented local settings. Never executes a launcher,
/// connects to a server, retains a document body or includes config values in findings.
public enum AgentSetupAudit {
    public struct Target: Sendable {
        public let runtime: AgentRuntime
        public let url: URL
        public init(_ runtime: AgentRuntime, _ url: URL) { self.runtime = runtime; self.url = url }
    }

    public static func targets(home: URL, project: URL? = nil) -> [Target] {
        var result: [Target] = []
        func add(_ runtime: AgentRuntime, _ base: URL, _ paths: [String]) {
            result += paths.map { Target(runtime, base.appendingPathComponent($0)) }
        }
        add(.codex, home, [".codex/config.toml"])
        add(.claude, home, [".claude/settings.json"])
        add(.cursor, home, [".cursor/mcp.json", ".cursor/cli-config.json"])
        add(.devin, home, [".config/devin/config.json", ".config/devin/mcp_config.json"])
        add(.grok, home, [".grok/config.toml"])
        if let project, project.standardizedFileURL != home.standardizedFileURL {
            add(.codex, project, [".codex/config.toml"])
            add(.claude, project, [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"])
            add(.cursor, project, [".cursor/mcp.json"])
            add(.devin, project, [".devin/config.json", ".devin/config.local.json", ".devin/mcp_config.json", ".devin/mcp_config.local.json"])
            add(.grok, project, [".grok/config.toml"])
        }
        return result
    }

    public static func audit(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             project: URL? = nil, targets override: [Target]? = nil,
                             executableSearchPaths: [String]? = nil,
                             maximumBytes: Int = 512 * 1_024) -> ConfigurationHealthReport {
        let configuration = AgentConfigurationAuditor.Configuration(home: home, executableSearchPaths: executableSearchPaths)
        var files: [ConfigurationFileCheck] = []
        var issues: [ConfigurationHealthIssue] = []
        for target in override ?? targets(home: home, project: project) {
            let url = target.url
            let runtime = target.runtime
            func record(_ status: ConfigurationFileCheck.Status, _ detail: String) {
                files.append(.init(runtime: runtime, path: url.path, status: status, detail: detail))
            }
            // Resolve no linked component: an ordinary config name could point at credentials.
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let base = home.resolvingSymlinksInPath().standardizedFileURL
            let logicalBase = home.standardizedFileURL.path
            let normalized = url.path.hasPrefix(logicalBase + "/")
                ? base.appendingPathComponent(String(url.path.dropFirst(logicalBase.count + 1))).standardizedFileURL
                : url.standardizedFileURL
            guard canonical == normalized else { record(.unverified, "Linked configuration path; inspect its target in the agent."); continue }
            guard FileManager.default.fileExists(atPath: url.path) else {
                record(.missing, "Optional file absent. The agent may use defaults or another scope."); continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes, maximumBytes > 0,
                  let handle = try? FileHandle(forReadingFrom: url) else {
                record(.unverified, "Unreadable, non-regular or above the scan size limit."); continue
            }
            let data = try? handle.read(upToCount: maximumBytes + 1)
            try? handle.close()
            guard let data, data.count <= maximumBytes, let body = String(data: data, encoding: .utf8) else {
                record(.unverified, "Could not read a bounded UTF-8 configuration."); continue
            }
            if url.pathExtension == "toml" {
                issues += AgentConfigurationAuditor.auditCodexConfig(body, url: url, configuration: configuration, runtime: runtime)
                record(.checked, "MCP executable references" + (runtime == .codex ? " and supported misplaced settings" : "") + ". Full TOML schema and runtime connectivity are not validated.")
            } else {
                let json = runtime == .devin ? stripJSONComments(body) : body
                guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                    issues.append(issue(runtime, url, "json", "Configuration is not a JSON object", "This file could not be parsed as an object. The agent may reject these settings.", "Correct the JSON syntax in the source file, then recheck. Configuration contents are not included in this report."))
                    record(.unverified, "JSON syntax check failed; remaining checks could not run."); continue
                }
                if let raw = object["mcpServers"] {
                    if let servers = raw as? [String: Any] {
                        for name in servers.keys.sorted() {
                            let key = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                            guard let server = servers[name] as? [String: Any] else {
                                issues.append(issue(runtime, url, "mcp-\(key)", "Invalid MCP entry", "An MCP entry is not an object.", "Review the mcpServers structure in this file.")); continue
                            }
                            if server["disabled"] as? Bool == true || server["enabled"] as? Bool == false { continue }
                            let remote = server["url"] is String || server["serverUrl"] is String
                            if remote { continue } // URLs may contain secrets; never emit or request them.
                            guard let command = server["command"] as? String, !command.isEmpty else {
                                issues.append(issue(runtime, url, "mcp-\(key)", "MCP launcher is missing", "A local server entry has no command or remote URL.", "Add the documented launcher or remote transport fields, or remove the unused server through the agent.")); continue
                            }
                            // Runtime substitutions and relative commands need the agent's launch context.
                            guard !command.contains("$"), !command.contains("{{"),
                                  !(command.contains("/") && !command.hasPrefix("/") && !command.hasPrefix("~/")) else { continue }
                            if !AgentConfigurationAuditor.commandExists(command, cwd: nil, configURL: url, configuration: configuration) {
                                issues.append(issue(runtime, url, "mcp-\(key)", "MCP launcher not found", "A configured executable was not found in the checked paths. The agent's environment may differ.", "Review the command in this file. Confirm its executable in the agent's environment, repair its path or disable the unused server."))
                            }
                        }
                    } else {
                        issues.append(issue(runtime, url, "servers", "Invalid MCP server map", "mcpServers must be an object.", "Use the agent's documented server configuration format, then recheck."))
                    }
                }
                record(.checked, "JSON object and declared MCP executable references. No connections or commands executed.")
            }
        }
        return .init(issues: issues, scannedFiles: files.filter { $0.status == .checked }.map(\.path), files: files)
    }

    private static func issue(_ runtime: AgentRuntime, _ url: URL, _ key: String, _ title: String, _ detail: String, _ remediation: String) -> ConfigurationHealthIssue {
        .init(id: runtime.rawValue + "-" + url.path + "-" + key, severity: .error, runtime: runtime,
              title: title, detail: detail, path: url.path, line: 1, remediation: remediation)
    }

    /// Preserve quoted URLs, escapes and newlines; strip only comments outside strings.
    static func stripJSONComments(_ body: String) -> String {
        let chars = Array(body)
        var output = "", index = 0, quoted = false, escaped = false
        while index < chars.count {
            let c = chars[index]
            if quoted {
                output.append(c)
                if c == "\"" && !escaped { quoted = false }
                escaped = c == "\\" && !escaped
                index += 1; continue
            }
            if c == "\"" { quoted = true; output.append(c); index += 1; continue }
            if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { output.append(" "); index += 1 }
            } else if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                output += "  "; index += 2
                var closed = false
                while index < chars.count {
                    if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "/" { output += "  "; index += 2; closed = true; break }
                    output.append(chars[index] == "\n" ? "\n" : " "); index += 1
                }
                if !closed { return "invalid unterminated comment" }
            } else { output.append(c); index += 1 }
        }
        return output
    }
}
