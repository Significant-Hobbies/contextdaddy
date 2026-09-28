import Foundation

/// Surgical edits to simple policy mappings. Ambiguous YAML is left for the content editor.
public enum SkillInvocationEditor {
    public struct Result: Sendable {
        public let files: [String: Data]
        public let before: String
        public let after: String
        public let explanation: String
    }

    public static func edit(files: [String: Data], runtime: AgentRuntime, automatic: Bool) throws -> Result {
        var result = files
        let path: String
        let before: String
        let after: String
        let explanation: String
        switch runtime {
        case .codex:
            path = "agents/openai.yaml"
            guard let text = String(data: files[path] ?? Data(), encoding: .utf8) else { throw failure() }
            before = text
            var lines = text.components(separatedBy: "\n")
            let policies = lines.indices.filter { lines[$0].hasPrefix("policy:") }
            guard policies.count <= 1, !text.contains("<<:"), !text.contains("\t") else { throw failure() }
            if let start = policies.first {
                guard lines[start].trimmingCharacters(in: .whitespaces) == "policy:" else { throw failure() }
                let end = lines.indices.dropFirst(start + 1).first {
                    !lines[$0].isEmpty && !lines[$0].hasPrefix(" ") && !lines[$0].hasPrefix("#")
                } ?? lines.count
                let block = Array(lines[(start + 1)..<end])
                // Only a simple policy map can be changed without a full YAML parser.
                guard block.allSatisfy({ line in
                    let value = line.trimmingCharacters(in: .whitespaces)
                    return value.isEmpty || value.hasPrefix("#") || line.range(of: "^  allow_implicit_invocation: (true|false)( *#.*)?$", options: .regularExpression) != nil
                }) else { throw failure() }
                let indexes = (start + 1..<end).filter { lines[$0].hasPrefix("  allow_implicit_invocation:") }
                guard indexes.count <= 1 else { throw failure() }
                let value = "  allow_implicit_invocation: \(automatic ? "true" : "false")"
                if let index = indexes.first { lines[index] = value } else { lines.insert(value, at: start + 1) }
            } else {
                // Reject aliases/flow documents that may hide a second policy key.
                guard !text.contains("policy"), !text.contains("<<:"), !text.contains("---") else { throw failure() }
                lines += ["policy:", "  allow_implicit_invocation: \(automatic ? "true" : "false")", ""]
            }
            after = lines.joined(separator: "\n")
            explanation = "Sets Codex’s skill-local implicit invocation policy. Other agents’ frontmatter stays unchanged. This applies to every Codex route linked to this source; agent-level settings may still override it."
        case .claude, .cursor, .grok:
            path = "SKILL.md"
            guard let data = files[path], let text = String(data: data, encoding: .utf8) else { throw failure() }
            before = text
            var lines = text.components(separatedBy: "\n")
            guard lines.first == "---", let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else { throw failure() }
            let body = Array(lines[1..<end])
            guard !body.contains(where: { $0.contains("<<:") || $0.contains("&") }) else { throw failure() }
            // A hidden manual command needs explicit review before changing invocation.
            guard !body.contains(where: { $0.contains("user-invocable:") && $0.range(of: "^user-invocable: *true( *#.*)?$", options: .regularExpression) == nil }) else {
                throw SkillManagementError(message: "This skill hides user invocation. Review user-invocable in the content editor before changing its mode.")
            }
            let indexes = (1..<end).filter { lines[$0].hasPrefix("disable-model-invocation:") }
            guard indexes.count <= 1 else { throw failure() }
            let value = "disable-model-invocation: \(automatic ? "false" : "true")"
            if let index = indexes.first {
                guard lines[index].range(of: "^disable-model-invocation: *(true|false)( *#.*)?$", options: .regularExpression) != nil else { throw failure() }
                lines[index] = value
            } else { lines.insert(value, at: end) }
            after = lines.joined(separator: "\n")
            explanation = "Changes shared SKILL.md frontmatter. Claude, Cursor and Grok routes to this source receive the same setting. Other agents may also honor it; Codex’s explicit agents/openai.yaml policy takes precedence in this library. For independent behavior, keep separate definitions."
        case .devin:
            path = "SKILL.md"
            guard let data = files[path], let text = String(data: data, encoding: .utf8) else { throw failure() }
            before = text
            var lines = text.components(separatedBy: "\n")
            guard lines.first == "---", let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" }) else { throw failure() }
            let body = Array(lines[1..<end])
            guard !body.contains(where: { $0.contains("<<:") || $0.contains("&") || $0.contains("\t") }) else { throw failure() }
            let indexes = (1..<end).filter { lines[$0].hasPrefix("triggers:") }
            guard indexes.count <= 1 else { throw failure() }
            let replacement = "triggers: " + (automatic ? "[user, model]" : "[user]")
            if let start = indexes.first {
                let finish = (start + 1..<end).first { !lines[$0].hasPrefix(" ") && !lines[$0].isEmpty && !lines[$0].hasPrefix("#") } ?? end
                let block = lines[start..<finish].joined(separator: "\n")
                let inline = lines[start].dropFirst("triggers:".count).trimmingCharacters(in: .whitespaces)
                let simpleInline = inline.range(of: "^\\[(user|model)(, *(user|model))*\\]$", options: .regularExpression) != nil
                let simpleList = inline.isEmpty && lines[(start + 1)..<finish].allSatisfy {
                    $0.range(of: "^  - (user|model)$", options: .regularExpression) != nil || $0.isEmpty || $0.hasPrefix("#")
                }
                guard (simpleInline || simpleList), block.contains("user") else {
                    throw SkillManagementError(message: "Review the existing Devin triggers first. Only simple lists that already allow user invocation can be changed here.")
                }
                lines.replaceSubrange(start..<finish, with: [replacement])
            } else { lines.insert(replacement, at: end) }
            after = lines.joined(separator: "\n")
            explanation = "Sets Devin’s user/model triggers for every route to this source. Other agents’ invocation fields and all tool permissions are preserved. Shared edits affect every Devin project using this source."

        }
        guard before != after else { throw SkillManagementError(message: "This policy already has the requested value.") }
        result[path] = Data(after.utf8)
        return Result(files: result, before: before, after: after, explanation: explanation)
    }

    private static func failure() -> SkillManagementError {
        .init(message: "This policy uses an ambiguous or unsupported YAML structure. Review it in the content editor; nothing was changed.")
    }
}
