import Foundation

public struct ExternalSkillSourceEvidence: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case github = "GitHub source recorded"
        case verified = "GitHub source verified"
        case tool = "Installed tool source"
        case repository = "Tracked in local repository"
        case plugin = "Plugin owned"
        case unresolved = "Source unresolved"
    }

    public let kind: Kind
    public let sourceURL: String?
    public let owner: String?
    public let note: String

    public init(kind: Kind, sourceURL: String? = nil, owner: String? = nil, note: String) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.owner = owner
        self.note = note
    }
}

public struct ExternalSkillSourceAudit: Sendable {
    public let byPath: [String: ExternalSkillSourceEvidence]
    public let unavailableTools: [String]
}

/// Read-only adapters for installed external tools. No update/check/audit --yes command is used.
public struct ExternalSkillSources: Sendable {
    public init() {}

    public func lookup(skillPath: String, folder: URL) async -> ExternalSkillSourceEvidence {
        let audit = await audit(skillPaths: [skillPath], folder: folder)
        return audit.byPath[skillPath] ?? ExternalSkillSourceEvidence(kind: .unresolved,
            note: "Source status could not be resolved.")
    }

    public func audit(skillPaths: [String], folder: URL) async -> ExternalSkillSourceAudit {
        let asm = try? await Self.run(tool: "asm", arguments: ["list", "--json"], folder: folder)
        let skillsGlobal = try? await Self.run(tool: "npx", arguments: ["--yes", "skills@1.7.0", "list", "-g", "--json"], folder: folder)
        let skillsProject = try? await Self.run(tool: "npx", arguments: ["--yes", "skills@1.7.0", "list", "--json"], folder: folder)
        let unavailable = (asm == nil ? ["ASM"] : []) + (skillsGlobal == nil || skillsProject == nil ? ["Vercel skills"] : [])
        var evidenceByPath: [String: ExternalSkillSourceEvidence] = [:]
        let verifiedSources = VerifiedSkillSources()
        for path in skillPaths {
            var evidence = Self.resolve(skillPath: path, asm: asm ?? Data(), skillsLists: [skillsGlobal ?? Data(), skillsProject ?? Data()])
            if evidence.kind == .unresolved {
                if let verified = verifiedSources.lookup(skillPath: path) {
                    evidence = verified
                } else if let repository = await Self.repositorySource(skillPath: path) {
                    evidence = repository
                } else if !unavailable.isEmpty {
                    evidence = ExternalSkillSourceEvidence(kind: .unresolved,
                        note: "Inventory unavailable: \(unavailable.joined(separator: ", ")). Source status cannot be verified.")
                }
            }
            evidenceByPath[path] = evidence
        }
        return ExternalSkillSourceAudit(byPath: evidenceByPath, unavailableTools: unavailable)
    }

    public static func resolve(skillPath: String, asm: Data, skillsLists: [Data]) -> ExternalSkillSourceEvidence {
        let canonical = canonicalPath(skillPath)
        if let entries = try? JSONSerialization.jsonObject(with: asm) as? [[String: Any]] {
            for entry in entries where canonicalPath(entry["path"] as? String ?? "") == canonical {
                let provider = entry["provider"] as? String ?? ""
                if provider == "plugin" || provider == "codex-plugin" {
                    return ExternalSkillSourceEvidence(kind: .plugin,
                        owner: entry["providerLabel"] as? String ?? "Plugin manager",
                        note: "ASM found plugin files. Check the owning agent to verify whether the plugin is enabled and to manage updates.")
                }
            }
        }
        for data in skillsLists {
            guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for entry in entries where canonicalPath(entry["path"] as? String ?? "") == canonical {
                if let url = safeGitHubURL(entry["sourceUrl"] as? String) {
                    return ExternalSkillSourceEvidence(kind: .github, sourceURL: url,
                        owner: "Vercel skills", note: "Recorded by skills list. Installed content and local edits have not been compared with GitHub.")
                }
            }
        }
        return ExternalSkillSourceEvidence(kind: .unresolved,
            note: "Neither installed tool recorded a verified upstream for this path. It may be locally authored or an untracked external copy.")
    }

    private static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let folder = url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent() : url
        return folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func safeGitHubURL(_ raw: String?) -> String? {
        guard let raw, let parts = URLComponents(string: raw), parts.scheme == "https",
              parts.host == "github.com", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.split(separator: "/").count == 2 else { return nil }
        return raw.hasSuffix(".git") ? String(raw.dropLast(4)) : raw
    }

    static func repositorySource(skillPath: String) async -> ExternalSkillSourceEvidence? {
        let source = URL(fileURLWithPath: skillPath).resolvingSymlinksInPath()
        let folder = source.lastPathComponent == "SKILL.md" ? source.deletingLastPathComponent() : source
        guard let rootData = try? await run(tool: "git", arguments: ["-C", folder.path, "rev-parse", "--show-toplevel"], folder: folder),
              let reportedRoot = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reportedRoot.isEmpty else { return nil }
        let rootPath = URL(fileURLWithPath: reportedRoot).resolvingSymlinksInPath().standardizedFileURL.path
        guard source.path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(source.path.dropFirst(rootPath.count + 1))
        guard (try? await run(tool: "git", arguments: ["-C", rootPath, "ls-files", "--error-unmatch", "--", relative], folder: folder)) != nil,
              let originData = try? await run(tool: "git", arguments: ["-C", rootPath, "remote", "get-url", "origin"], folder: folder),
              let raw = String(data: originData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let sshURL = raw.hasPrefix("git@github.com:") ? "https://github.com/" + raw.dropFirst("git@github.com:".count) : raw
        guard let url = safeGitHubURL(String(sshURL)) else { return nil }
        return ExternalSkillSourceEvidence(kind: .repository, sourceURL: url,
            owner: "Git repository", note: "This skill file is tracked in the local repository. This is its repository origin, not a Vercel skills update record.")
    }

    private static func run(tool: String, arguments: [String], folder: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let environment = ProcessInfo.processInfo.environment
            let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
                "\(home)/.local/share/mise/installs/node/lts/bin", "\(home)/.local/share/mise/shims",
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"
            ]
            guard let binary = search.map({ URL(fileURLWithPath: $0).appendingPathComponent(tool) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.environment = environment.merging(["DISABLE_TELEMETRY": "1"]) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 5_000_000 else {
                throw CocoaError(.fileReadUnknown)
            }
            return data
        }.value
    }
}
