import CryptoKit
import Foundation

/// Reads local, content-bound receipts for skills installed outside the skills CLI.
/// A changed SKILL.md returns to the unresolved queue until its source is checked again.
struct VerifiedSkillSources: Sendable {
    private struct Store: Decodable {
        let schema: Int
        let sources: [Receipt]
    }

    private struct Receipt: Decodable, Sendable {
        let repository: String?
        let sourceType: String?
        let revision: String
        let evidence: String
        let owner: String?
        let digests: [String]
    }

    private let byDigest: [String: Receipt]

    init(fileURL: URL? = nil) {
        let file = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ContextDaddy/skill-source-receipts.json")
        guard let data = try? Data(contentsOf: file),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.schema == 1 else {
            byDigest = [:]
            return
        }
        var accepted: [String: Receipt] = [:]
        var conflicted: Set<String> = []
        for receipt in store.sources where Self.isValidSource(receipt) {
            for digest in receipt.digests where digest.count == 64 && digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                let key = digest.lowercased()
                guard !conflicted.contains(key) else { continue }
                // Conflicting claims require review; neither source wins by file order.
                if accepted[key] == nil { accepted[key] = receipt }
                else {
                    accepted.removeValue(forKey: key)
                    conflicted.insert(key)
                }
            }
        }
        byDigest = accepted
    }

    func lookup(skillPath: String) -> ExternalSkillSourceEvidence? {
        let supplied = URL(fileURLWithPath: skillPath).resolvingSymlinksInPath()
        let file = supplied.lastPathComponent == "SKILL.md" ? supplied : supplied.appendingPathComponent("SKILL.md")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let receipt = byDigest[digest] else { return nil }
        return ExternalSkillSourceEvidence(kind: receipt.sourceType == "tool" ? .tool : .verified,
            sourceURL: receipt.repository,
            owner: receipt.owner ?? "Verified GitHub source",
            note: "Compared with \(receipt.revision): \(receipt.evidence). Source attribution; updates remain with the installer or owning app.")
    }

    private static func isValidSource(_ receipt: Receipt) -> Bool {
        if receipt.sourceType == "tool" {
            return receipt.repository == nil && !(receipt.owner ?? "").isEmpty
        }
        return receipt.sourceType == nil && receipt.repository.flatMap(safeGitHubURL) != nil
    }

    private static func safeGitHubURL(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw), parts.scheme == "https",
              parts.host == "github.com", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.split(separator: "/").count == 2 else { return nil }
        return parts.url
    }
}
