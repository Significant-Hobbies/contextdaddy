import Foundation

public struct ManagedSkillHealth: Decodable, Sendable {
    public struct Summary: Decodable, Sendable {
        public let entryCount: Int
        public let problemCount: Int
        public let unmanagedCount: Int
    }

    public struct Target: Decodable, Sendable {
        public let name: String
        public let path: String
        public let status: String
    }

    public struct Skill: Decodable, Sendable {
        public let name: String
        public let type: String
        public let physicalPath: String
        public let sourceURL: String?
        public let revision: String?
        public let patch: String?
        public let status: String
        public let targets: [Target]
    }

    public struct Maintenance: Decodable, Sendable {
        public let status: String
        public let scope: String
        public let lastExitCode: Int?
    }

    public let schemaVersion: Int
    public let generatedAt: String
    public let scope: String
    public let repositoryDirty: Bool
    public let summary: Summary
    public let skills: [Skill]
    public let maintenance: Maintenance

    public var installationsHealthy: Bool {
        scope == "all registered targets" && summary.problemCount == 0 && summary.unmanagedCount == 0
    }

    public var healthy: Bool { installationsHealthy && maintenance.status == "healthy" }

    public var findings: [String] {
        skills.flatMap { skill in
            (skill.status == "ok" ? [] : ["\(skill.name): \(skill.status)"]) + skill.targets.compactMap {
                $0.status == "ok" ? nil : "\(skill.name) · \($0.name): \($0.status)"
            }
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.schemaVersion == 1, report.summary.entryCount == report.skills.count,
              report.summary.problemCount >= 0, report.summary.unmanagedCount >= 0,
              !report.skills.isEmpty,
              report.summary.problemCount > 0 || report.findings.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return report
    }

    public static func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> Self {
        let root = home.appendingPathComponent(".agent-config", isDirectory: true)
        let executable = root.appendingPathComponent("bin/agent-config")
        guard FileManager.default.isReadableFile(atPath: executable.path),
              FileManager.default.isReadableFile(atPath: root.appendingPathComponent("skills.lock.json").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try await ExternalSkillSources.run(tool: "node", arguments: [executable.path, "status", "--json"],
                                                     folder: root, acceptableStatuses: [0, 1])
        return try decode(data)
    }

    public static func isManagedPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path].contains {
            $0.contains("/.local/share/agent-config/skills/") || $0.contains("/.local/share/agent-config/src/")
        }
    }

    public func sourceEvidence(skillPath: String) -> ExternalSkillSourceEvidence? {
        let url = URL(fileURLWithPath: skillPath).resolvingSymlinksInPath().standardizedFileURL
        let path = url.lastPathComponent == "SKILL.md" ? url.deletingLastPathComponent().path : url.path
        guard let skill = skills.filter({ path == $0.physicalPath || path.hasPrefix($0.physicalPath + "/") })
            .max(by: { $0.physicalPath.count < $1.physicalPath.count }) else { return nil }
        let urlParts = skill.sourceURL.flatMap(URLComponents.init(string:))
        let safeURL = urlParts.flatMap { parts -> String? in
            guard parts.scheme == "https", parts.host == "github.com", parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, parts.path.split(separator: "/").count == 2 else { return nil }
            return skill.sourceURL
        }
        let revision = skill.revision.map { " Revision \($0)." } ?? ""
        let patch = skill.patch.map { " Local patch: \($0)." } ?? ""
        return .init(kind: .managed, sourceURL: safeURL, owner: "agent-config",
                     note: "\(skill.type), manager state \(skill.status).\(revision)\(patch) Updates belong to agent-config; npx records are attribution only. This does not prove runtime activation.")
    }
}
