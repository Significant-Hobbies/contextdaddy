import CryptoKit
import CoreFoundation
import Foundation

public struct PluginPreference: Sendable, Equatable, Identifiable {
    public let path: String
    public let enabled: Bool
    public var id: String { path }
}

public struct PluginRegistration: Sendable, Equatable, Identifiable {
    public let path: String
    public let scope: String
    public let project: String?
    public var id: String { path + scope + (project ?? "") }
}

public struct PluginCacheVersion: Sendable, Equatable, Identifiable {
    public let path: String
    public let version: String
    public let bytes: Int64
    public let sizeComplete: Bool
    public let skillNames: [String]
    public let fingerprints: Set<String>
    public let components: [String]
    public let modified: Date?
    public var id: String { path }
}

public struct PluginInventoryEntry: Sendable, Equatable, Identifiable {
    public let owner: AgentRuntime
    public let marketplace: String
    public let name: String
    public let summary: String
    public let versions: [PluginCacheVersion]
    public let registrations: [PluginRegistration]
    public let registryVerified: Bool
    public let preferences: [PluginPreference]
    public let localMatches: [String]
    public var id: String { owner.rawValue + ":" + marketplace + ":" + name }
    public var pluginKey: String { name + "@" + marketplace }
    public var bytes: Int64 { versions.reduce(0) { $0 + $1.bytes } }
    public var sizeComplete: Bool { versions.allSatisfy(\.sizeComplete) }
    public var skillNames: [String] { Array(Set(versions.flatMap(\.skillNames))).sorted() }
    public var unreferencedVersions: [PluginCacheVersion] {
        guard registryVerified else { return [] }
        return versions.filter { !isReferenced($0) }
    }
    public func isReferenced(_ version: PluginCacheVersion) -> Bool {
        registrations.contains { Self.pathKey($0.path) == Self.pathKey(version.path) }
    }
    private static func pathKey(_ path: String) -> String {
        let value = URL(fileURLWithPath: path).standardizedFileURL.path
        // macOS directory enumeration and URL normalization disagree on these aliases.
        for prefix in ["/private/var/", "/private/tmp/"] where value.hasPrefix(prefix) {
            return String(value.dropFirst("/private".count))
        }
        return value
    }
    public var settingLabel: String {
        guard !preferences.isEmpty else { return "Enablement unverified" }
        if Set(preferences.map(\.enabled)).count > 1 { return "Mixed settings" }
        return preferences[0].enabled ? "Enabled in checked settings" : "Disabled in checked settings"
    }
    public var reviewReason: String {
        if !unreferencedVersions.isEmpty { return "\(unreferencedVersions.count) versions not referenced by the checked registry" }
        if versions.count > 1 { return "\(versions.count) cached versions; current installation needs verification" }
        if !localMatches.isEmpty { return "Matching instructions also exist in your local library" }
        if preferences.isEmpty { return "Check whether this plugin is enabled" }
        return "Review its settings and included capabilities"
    }
    public var managementBrief: String {
        """
        Review \(pluginKey) using \(owner.rawValue)'s plugin manager.
        \(reviewReason).
        Cache paths:
        \(versions.map(\.path).joined(separator: "\n"))
        Registry references:
        \(registrations.map { "\($0.scope): \($0.project ?? "User scope") → \($0.path)" }.joined(separator: "\n"))
        Explicit settings (not proof of runtime loading):
        \(preferences.map { "\($0.path): enabled=\($0.enabled)" }.joined(separator: "\n"))
        Verify the intended folder and scope in the owning manager. Disable only if unwanted; uninstall only after reviewing dependencies and recovery. An unreferenced cache version is a review candidate, not proof that a running session or custom path cannot use it. Do not delete cache directories based on age or name alone. Rescan ContextDaddy after the change.
        """
    }
}

public struct PluginInventorySnapshot: Sendable, Equatable {
    public let entries: [PluginInventoryEntry]
    public let notes: [String]
    public let checkedSources: [String]
    public let generatedAt: Date
    public var versionCount: Int { entries.reduce(0) { $0 + $1.versions.count } }
    public var repeatedPluginCount: Int { entries.filter { $0.versions.count > 1 }.count }
    public var unreferencedVersionCount: Int { entries.reduce(0) { $0 + $1.unreferencedVersions.count } }
    public var isPartial: Bool {
        notes.contains { note in ["Scan limit", "Entry limit", "Could not", "Skipped", "Unsupported JSON"].contains { note.hasPrefix($0) } }
    }
}

/// Reads only known cache metadata, plugin registration and explicit plugin settings.
/// Does not execute plugins, contact services, infer activation, or traverse links.
public enum PluginInventory {
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            folder: URL? = nil, localSkills: [SkillRecord] = [],
                            maximumEntries: Int = 60_000, timeout: TimeInterval = 12) throws -> PluginInventorySnapshot {
        var reader = Reader(home: home.resolvingSymlinksInPath().standardizedFileURL,
                            remaining: maximumEntries, deadline: Date().addingTimeInterval(timeout))
        return try reader.scan(folder: folder, localSkills: localSkills)
    }

    private struct Reader {
        let home: URL
        var remaining: Int
        let deadline: Date
        var notes: [String] = []
        var sources: [String] = []
        let fm = FileManager.default

        mutating func scan(folder: URL?, localSkills: [SkillRecord]) throws -> PluginInventorySnapshot {
            var entries: [PluginInventoryEntry] = []
            let registryPath = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
            let registry = json(registryPath)
            let rawPlugins = registry?["plugins"] as? [String: Any]
            var registrations: [String: [PluginRegistration]] = [:]
            var registryVerified = (registry?["version"] as? Int) == 2 && rawPlugins != nil
            if let rawPlugins {
                for (key, raw) in rawPlugins {
                    guard let list = raw as? [[String: Any]] else { registryVerified = false; continue }
                    for item in list {
                        guard let path = item["installPath"] as? String, path.hasPrefix("/"),
                              let scope = item["scope"] as? String, ["user", "project", "local", "managed"].contains(scope),
                              scope == "user" || scope == "managed" || (item["projectPath"] as? String)?.hasPrefix("/") == true
                        else { registryVerified = false; continue }
                        registrations[key, default: []].append(.init(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                            scope: scope, project: item["projectPath"] as? String))
                    }
                }
            }
            if !registryVerified { notes.append("Claude installation registry is unavailable or unsupported; unreferenced versions cannot be established.") }
            var settings: [AgentRuntime: [String: [PluginPreference]]] = [:]
            for owner in [AgentRuntime.codex, .claude] {
                let relative = owner == .codex ? ".codex/config.toml" : ".claude/settings.json"
                var files = [home.appendingPathComponent(relative)]
                if let folder {
                    var current = folder.resolvingSymlinksInPath().standardizedFileURL
                    var ancestors: [URL] = []
                    for _ in 0..<32 {
                        if current == home || current.path == "/" { break }
                        ancestors.append(current)
                        current.deleteLastPathComponent()
                    }
                    for parent in ancestors.reversed() {
                        files.append(parent.appendingPathComponent(relative))
                        if owner == .claude { files.append(parent.appendingPathComponent(".claude/settings.local.json")) }
                    }
                }
                for file in files {
                    let values: [String: Bool]
                    if owner == .claude {
                        guard let obj = json(file) else { continue }
                        values = (obj["enabledPlugins"] as? [String: Any] ?? [:]).reduce(into: [:]) { result, pair in
                            if let value = pair.value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { result[pair.key] = value.boolValue }
                        }
                    } else {
                        guard let data = read(file), let text = String(data: data, encoding: .utf8) else { continue }
                        values = PluginInventory.codexPreferences(text)
                    }
                    for (key, enabled) in values { settings[owner, default: [:]][key, default: []].append(.init(path: file.path, enabled: enabled)) }
                }
            }
            for owner in [AgentRuntime.claude, .codex] {
                let root = home.appendingPathComponent(owner == .claude ? ".claude/plugins/cache" : ".codex/plugins/cache")
                guard safeDirectory(root) else {
                    notes.append("\(owner.rawValue) default cache is absent, linked or inaccessible."); continue
                }
                sources.append(root.path)
                for market in children(root) where safeDirectory(market) {
                    for plugin in children(market) where safeDirectory(plugin) {
                        try Task.checkCancellation()
                        var versions: [PluginCacheVersion] = []
                        var summary = ""
                        for version in children(plugin) where safeDirectory(version) {
                            if summary.isEmpty {
                                for manifest in [".codex-plugin/plugin.json", ".claude-plugin/plugin.json"] {
                                    if let value = json(version.appendingPathComponent(manifest))?["description"] as? String { summary = String(value.prefix(600)); break }
                                }
                            }
                            versions.append(measure(version))
                        }
                        let key = plugin.lastPathComponent + "@" + market.lastPathComponent
                        let refs = owner == .claude ? registrations[key] ?? [] : []
                        let fingerprints = Set(versions.flatMap(\.fingerprints))
                        let matches = localSkills.filter { $0.ownership == .local && $0.contentFingerprint.map(fingerprints.contains) == true }.map(\.id)
                        entries.append(.init(owner: owner, marketplace: market.lastPathComponent, name: plugin.lastPathComponent,
                            summary: summary, versions: versions.sorted { $0.version.localizedStandardCompare($1.version) == .orderedDescending },
                            registrations: refs, registryVerified: owner == .claude && registryVerified,
                            preferences: settings[owner]?[key] ?? [], localMatches: matches.sorted()))
                    }
                }
            }
            // Registered installations without cache files remain visible as broken/missing installs.
            for (key, refs) in registrations where !entries.contains(where: { $0.owner == .claude && $0.pluginKey == key }) {
                let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                entries.append(.init(owner: .claude, marketplace: parts[1], name: parts[0], summary: "Registered installation with no discovered default-cache directory.", versions: [], registrations: refs, registryVerified: registryVerified, preferences: settings[.claude]?[key] ?? [], localMatches: []))
            }
            notes.append("Default Codex and Claude caches only. Cursor, Devin and Grok plugin inventories, custom homes, managed settings and launch overrides are not resolved. Recorded use is unavailable; modification time is not usage.")
            return .init(entries: entries.sorted { a, b in
                if a.versions.count != b.versions.count { return a.versions.count > b.versions.count }
                return a.id.localizedStandardCompare(b.id) == .orderedAscending
            }, notes: Array(Set(notes)).sorted(), checkedSources: Array(Set(sources)).sorted(), generatedAt: Date())
        }

        func safeDirectory(_ url: URL) -> Bool {
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path,
                  let a = try? fm.attributesOfItem(atPath: url.path) else { return false }
            return a[.type] as? FileAttributeType == .typeDirectory
        }
        mutating func children(_ url: URL) -> [URL] {
            guard remaining > 0, Date() < deadline else { notes.append("Scan limit reached; some plugins or version contents are missing."); return [] }
            do {
                let found = try BoundedDirectoryReader.children(url, timeout: min(2, max(0.01, deadline.timeIntervalSinceNow))).sorted { $0.path < $1.path }
                let count = min(remaining, found.count)
                remaining -= count
                if count < found.count { notes.append("Entry limit reached; inventory is partial.") }
                return Array(found.prefix(count))
            } catch { notes.append("Could not enumerate \(url.path)."); return [] }
        }
        mutating func read(_ url: URL) -> Data? {
            guard fm.fileExists(atPath: url.path) else { return nil }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path,
                  let a = try? fm.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular,
                  ((a[.size] as? NSNumber)?.intValue ?? Int.max) <= 512 * 1024,
                  let handle = try? FileHandle(forReadingFrom: url) else { notes.append("Skipped linked, unreadable or oversized metadata: \(url.path)."); return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 512 * 1024 + 1), data.count <= 512 * 1024 else { return nil }
            sources.append(url.path)
            return data
        }
        mutating func json(_ url: URL) -> [String: Any]? {
            guard let data = read(url) else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { notes.append("Unsupported JSON metadata: \(url.path)."); return nil }
            return obj
        }
        mutating func measure(_ root: URL) -> PluginCacheVersion {
            var bytes: Int64 = 0, complete = true
            var names: [String] = [], fingerprints = Set<String>(), components = Set<String>()
            var queue: [(URL, Int)] = [(root, 0)]
            let beforeNotes = notes.count
            while let (directory, depth) = queue.popLast() {
                guard depth < 16, remaining > 0, Date() < deadline else { complete = false; continue }
                for child in children(directory) {
                    guard let a = try? fm.attributesOfItem(atPath: child.path) else { complete = false; continue }
                    let type = a[.type] as? FileAttributeType
                    if type == .typeSymbolicLink { complete = false; continue }
                    if type == .typeDirectory {
                        if [".git", "node_modules", ".venv"].contains(child.lastPathComponent) { complete = false; continue }
                        if ["agents", "commands", "hooks"].contains(child.lastPathComponent) { components.insert(child.lastPathComponent.capitalized) }
                        queue.append((child, depth + 1))
                    } else if type == .typeRegular {
                        bytes += (a[.size] as? NSNumber)?.int64Value ?? 0
                        if child.lastPathComponent == "SKILL.md" {
                            names.append(child.deletingLastPathComponent().lastPathComponent)
                            if let data = read(child) { fingerprints.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()) }
                        }
                        if [".mcp.json", "mcp.json"].contains(child.lastPathComponent) { components.insert("MCP") }
                    } else { complete = false }
                }
            }
            return .init(path: root.path, version: root.lastPathComponent, bytes: bytes, sizeComplete: complete && notes.count == beforeNotes,
                         skillNames: names.sorted(), fingerprints: fingerprints, components: components.sorted(),
                         modified: (try? fm.attributesOfItem(atPath: root.path)[.modificationDate]) as? Date)
        }
    }

    /// Only the documented literal table/boolean form is recognized. Ambiguous tables are omitted.
    static func codexPreferences(_ text: String) -> [String: Bool] {
        // Without a full TOML parser, a header-looking line inside a multiline
        // string must never be presented as an actual enablement declaration.
        guard !text.contains("\"\"\""), !text.contains("'''") else { return [:] }
        var result: [String: Bool] = [:], seen = Set<String>(), invalid = Set<String>()
        var key: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                key = nil
                let pattern = #"^\[plugins\."([A-Za-z0-9_.@-]+)"\]\s*(?:#.*)?$"#
                if let range = line.range(of: pattern, options: .regularExpression) {
                    let header = String(line[range]); let pieces = header.split(separator: "\"")
                    if pieces.count >= 3 {
                        let candidate = String(pieces[1]); key = candidate
                        if !seen.insert(candidate).inserted { invalid.insert(candidate) }
                    }
                }
            } else if let key, line.hasPrefix("enabled") {
                let parts = line.split(separator: "#", maxSplits: 1)[0].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, parts[0] == "enabled", ["true", "false"].contains(parts[1]), result[key] == nil else { invalid.insert(key); continue }
                result[key] = parts[1] == "true"
            }
        }
        return result.filter { !invalid.contains($0.key) }
    }
}
