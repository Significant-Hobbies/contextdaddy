import Foundation

public enum PluginAction: String, CaseIterable, Sendable, Identifiable {
    case disable = "Disable", enable = "Enable", uninstall = "Uninstall"
    public var id: String { rawValue }
}
public struct PluginActionPlan: Identifiable, Sendable {
    public let id: UUID
    public let owner: AgentRuntime
    public let pluginKey: String
    public let action: PluginAction
    public let scope: String
    public let workingDirectory: String
    public let executable: String
    public let arguments: [String]
    public var explanation: String {
        if action == .uninstall {
            return owner == .claude ? "Claude will uninstall this registration and preserve persistent plugin data. Other scopes are not selected. Reinstallation may require network access; cache retention is controlled by Claude."
                : "Codex will uninstall this plugin and remove its local cache. Reinstallation may require network access and the original version may no longer be available. This cannot be undone by ContextDaddy."
        }
        return "Claude will \(action.rawValue.lowercased()) this plugin in the selected scope. Cached files stay on disk. New sessions may be required. You can use the opposite action to change this setting again."
    }
}
public struct PluginActionReceipt: Identifiable, Codable, Sendable {
    public let id: UUID
    public let pluginKey: String
    public let owner: String
    public let action: String
    public let scope: String
    public let workingDirectory: String
    public let date: Date
    public let status: String
}

public actor PluginActionManager {
    private let home: URL
    private let storage: URL
    private var plans: [UUID: PluginActionPlan] = [:]
    private var expected: [UUID: PluginInventoryEntry] = [:]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                storage: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ContextDaddy/PluginHistory")) {
        self.home = home.resolvingSymlinksInPath(); self.storage = storage.standardizedFileURL
    }
    public func prepare(entry: PluginInventoryEntry, action: PluginAction, registration: PluginRegistration? = nil) throws -> PluginActionPlan {
        try verifyDefaultHome(entry.owner)
        guard [.claude, .codex].contains(entry.owner), entry.pluginKey.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { throw error("Unsupported plugin identity or owner.") }
        let executable = try executable(entry.owner)
        var arguments = ["plugin"], scope = "user", directory = home.path
        if entry.owner == .claude {
            guard entry.registryVerified, let registration, entry.registrations.contains(registration), ["user", "project", "local"].contains(registration.scope) else { throw error("Select a verified user, project or local registration first. Managed registrations are read-only.") }
            scope = registration.scope
            if scope != "user" {
                guard let project = registration.project, project.hasPrefix(home.path + "/"), URL(fileURLWithPath: project).standardizedFileURL.path == URL(fileURLWithPath: project).resolvingSymlinksInPath().path else { throw error("The project registration has no safe working folder.") }
                directory = project
            }
            arguments += [action.rawValue.lowercased(), entry.pluginKey, "--scope", scope, "--json"]
            if action == .uninstall { arguments.append("--keep-data") }
        } else {
            guard action == .uninstall else { throw error("This Codex CLI exposes removal only. Use Codex settings for enablement.") }
            guard entry.preferences.contains(where: { MemoryPaths.same($0.path, home.appendingPathComponent(".codex/config.toml").path) }) else { throw error("No user-scope Codex declaration was verified. Review this installation in Codex before removing it.") }
            arguments += ["remove", entry.pluginKey, "--json"]
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw error("The registered working folder is unavailable.") }
        let plan = PluginActionPlan(id: UUID(), owner: entry.owner, pluginKey: entry.pluginKey, action: action, scope: scope, workingDirectory: directory, executable: executable, arguments: arguments)
        plans[plan.id] = plan
        expected[plan.id] = entry
        return plan
    }
    public func apply(_ id: UUID) async throws -> PluginActionReceipt {
        guard let plan = plans.removeValue(forKey: id) else { throw error("Preview expired. Review the action again.") }
        guard let before = expected.removeValue(forKey: id) else { throw error("Plugin evidence expired.") }
        try verifyDefaultHome(plan.owner)
        guard try executable(plan.owner) == plan.executable else { throw error("The plugin manager changed since preview.") }
        let checked = try PluginInventory.scan(home: home, folder: URL(fileURLWithPath: plan.workingDirectory))
        let targetSetting = plan.owner == .codex ? home.appendingPathComponent(".codex/config.toml").path
            : plan.scope == "user" ? home.appendingPathComponent(".claude/settings.json").path
            : URL(fileURLWithPath: plan.workingDirectory).appendingPathComponent(plan.scope == "local" ? ".claude/settings.local.json" : ".claude/settings.json").path
        guard MemoryPaths.same(targetSetting, URL(fileURLWithPath: targetSetting).resolvingSymlinksInPath().path) else {
            throw error("The target settings path is linked. Manage it through the owning agent.")
        }
        guard let current = checked.entries.first(where: { $0.id == before.id }),
              current.registrations == before.registrations,
              current.preferences.filter({ $0.path == targetSetting }) == before.preferences.filter({ $0.path == targetSetting }),
              current.versions == before.versions, current.registryVerified == before.registryVerified else {
            throw error("Plugin evidence changed since preview. Recheck and review the action again.")
        }
        let intent = receipt(plan, status: "Started · completion unverified")
        try save(intent)
        // No shell interpolation, input prompts, raw command output or credentials in receipts.
        let status = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "Could not launch the plugin manager. No success was verified." }
            let deadline = Date().addingTimeInterval(45)
            while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate(); return "Timed out · result unknown. Recheck before retrying." }
            return process.terminationStatus == 0 ? "Owner command completed · rescan required" : "Owner command failed (exit \(process.terminationStatus)) · recheck before retrying"
        }.value
        let result = receipt(plan, status: status)
        try save(result)
        return result
    }
    public func history() throws -> [PluginActionReceipt] {
        guard FileManager.default.fileExists(atPath: storage.path) else { return [] }
        try safeStorage()
        return try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
            guard MemoryPaths.same($0.path, $0.resolvingSymlinksInPath().path) else { throw error("Linked history rejected.") }
            return try JSONDecoder().decode(PluginActionReceipt.self, from: Data(contentsOf: $0))
        }.sorted { $0.date > $1.date }
    }
    public func recordVerification(_ id: UUID, verified: Bool) throws {
        guard let receipt = try history().first(where: { $0.id == id }) else { throw error("Plugin receipt unavailable.") }
        try save(.init(id: receipt.id, pluginKey: receipt.pluginKey, owner: receipt.owner, action: receipt.action, scope: receipt.scope,
                       workingDirectory: receipt.workingDirectory, date: receipt.date,
                       status: receipt.status + (verified ? " · requested local state verified" : " · requested state not verified")))
    }
    private func executable(_ owner: AgentRuntime) throws -> String {
        let name = owner == .claude ? "claude" : "codex"
        let candidates = [home.appendingPathComponent(".local/bin/\(name)").path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw error("\(owner.rawValue)'s command-line manager is not installed in a supported location. Use its own plugin settings.") }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    private func verifyDefaultHome(_ owner: AgentRuntime) throws {
        let variable = owner == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty,
           !MemoryPaths.same(URL(fileURLWithPath: value).standardizedFileURL.path, home.appendingPathComponent(owner == .codex ? ".codex" : ".claude").path) {
            throw error("A custom agent home is active. This action only supports the default location shown in the inventory.")
        }
    }
    private func receipt(_ plan: PluginActionPlan, status: String) -> PluginActionReceipt {
        .init(id: plan.id, pluginKey: plan.pluginKey, owner: plan.owner.rawValue, action: plan.action.rawValue, scope: plan.scope, workingDirectory: plan.workingDirectory, date: Date(), status: status)
    }
    private func safeStorage() throws {
        guard MemoryPaths.same(storage.path, storage.resolvingSymlinksInPath().path) else { throw error("Linked history rejected.") }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func save(_ receipt: PluginActionReceipt) throws { try safeStorage(); try JSONEncoder().encode(receipt).write(to: storage.appendingPathComponent(receipt.id.uuidString + ".json"), options: .atomic) }
    private func error(_ text: String) -> SkillManagementError { .init(message: text) }
}
