import AppKit
import ContextCore
import SwiftUI

enum SkillOrganizationAction: String, Identifiable {
    case move = "Move skills", share = "Share with agents", invocation = "Set invocation", cleanup = "Clean up duplicates"
    var id: String { rawValue }
}

struct SkillOrganizationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let action: SkillOrganizationAction
    let records: [SkillRecord]
    let manager: SkillLibraryManager
    let refreshed: () async -> Void
    @State private var parent: URL?
    @State private var project: URL?
    @State private var projectOnly = false
    @State private var agents: Set<AgentRuntime> = [.codex]
    @State private var runtime: AgentRuntime = .codex
    @State private var automatic = false
    @State private var groupPage = 0
    @State private var keep: [String: String] = [:]
    @State private var plans: [SkillChangePlan] = []
    @State private var approved = Set<UUID>()
    @State private var problems: [String] = []
    @State private var working = false
    @State private var reviewed = false
    @State private var finished = false
    @State private var result: String?
    private let groups: [SkillRedundancyFinding]
    private let differentVersions: Int

    init(action: SkillOrganizationAction, records: [SkillRecord], manager: SkillLibraryManager,
         refreshed: @escaping () async -> Void) {
        self.action = action; self.records = records; self.manager = manager; self.refreshed = refreshed
        self.groups = action == .cleanup ? SkillRedundancyAnalyzer.exactCopyFindings(records: records) : []
        self.differentVersions = Dictionary(grouping: records, by: \.name).values.filter {
            Set($0.compactMap(\.contentFingerprint)).count > 1
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.rawValue).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("\(records.count) definitions in this review · Changes apply only after you review the plan.")
                .font(.callout).foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !reviewed { controls }
                    if reviewed && plans.isEmpty && !finished {
                        Text("No eligible changes in this plan.").font(.headline)
                    }
                    ForEach(plans) { plan in
                        Panel(padding: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(plan.title, isOn: Binding(get: { approved.contains(plan.id) }, set: {
                                    if $0 { approved.insert(plan.id) } else { approved.remove(plan.id) }
                                })).disabled(working || finished)
                                Text(plan.detail).font(.callout).foregroundStyle(DaddyTheme.muted)
                                ForEach(plan.fileChanges, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                DisclosureGroup("Before and after") {
                                    Text("BEFORE\n\(plan.before)\n\nAFTER\n\(plan.after)")
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !problems.isEmpty {
                        Text("Needs review / skipped").font(.headline).foregroundStyle(DaddyTheme.amber)
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let result { Text(result).foregroundStyle(DaddyTheme.mint).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(finished ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                else if !finished {
                    if reviewed {
                        Button("Revise plan") { reviewed = false; plans = []; problems = []; approved = [] }
                        Button("Apply \(approved.count) changes") { apply() }.disabled(approved.isEmpty)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Preview changes") { prepare() }.disabled(!canPrepare).keyboardShortcut(.defaultAction)
                    }
                }
            }.buttonStyle(ContextDaddyButtonStyle())
        }.padding(24).frame(width: 760, height: 660)
            .background(DaddyTheme.canvas).interactiveDismissDisabled(working)
    }

    @ViewBuilder private var controls: some View {
        switch action {
        case .move:
            Text("Choose the folder that will contain the selected skill folders.").font(.headline)
            Button(parent?.path ?? "Choose destination folder…") { parent = chooseFolder("Choose the new parent folder for these skills") }
            Text("The preview lists every destination. Original locations become links, preserving current agent access. Moving into an agent or project skills directory can add access in that scope.")
                .foregroundStyle(DaddyTheme.muted)
        case .share:
            Text("Agents that should discover these skills").font(.headline)
            ForEach(AgentRuntime.allCases) { agent in
                Toggle(agent.rawValue, isOn: Binding(get: { agents.contains(agent) }, set: {
                    if $0 { agents.insert(agent) } else { agents.remove(agent) }
                }))
            }
            Toggle("Project scope", isOn: $projectOnly)
            if projectOnly { Button(project?.path ?? "Choose project…") { project = chooseFolder("Choose the project receiving access") } }
            Text("Creates links, preserving one physical source. Existing destinations are skipped. Devin’s local routes remain unverified until checked in Devin. Shared .agents routes may be discovered by more than one agent.")
                .foregroundStyle(DaddyTheme.muted)
        case .invocation:
            Picker("Agent policy", selection: $runtime) {
                Text("Codex").tag(AgentRuntime.codex)
                ForEach(AgentRuntime.allCases.filter { $0 != .codex }) { Text($0.rawValue).tag($0) }
            }
            Picker("Mode", selection: $automatic) {
                Text("Manual invocation").tag(false)
                Text("Automatic when relevant").tag(true)
            }.pickerStyle(.segmented)
            Text("Codex uses its skill-local policy; Devin uses triggers. Claude, Cursor and Grok share a frontmatter control, so changing one affects the others using that source. The preview identifies the change. Tool permissions and agent-level overrides are preserved.")
                .foregroundStyle(DaddyTheme.muted)
        case .cleanup:
            Text("\(groups.count) identical-instruction groups · \(differentVersions) names with different versions").font(.headline)
            Text("These are matching instructions, not a count of removable copies. Preview checks complete folders and permissions. Independent repositories and worktrees keep their own copies; plugin caches stay with their installer. Local copies can share a source, with recovery in History.")
                .foregroundStyle(DaddyTheme.muted)
            if groups.isEmpty { Text("No identical instruction groups in this selection. Select all copies you want to compare, or clear the selection to review the whole library.") }
            ForEach(Array(groups.dropFirst(groupPage * 8).prefix(8))) { group in
                Panel(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(group.members.first?.name ?? "Skill") · \(group.members.count) copies").font(.headline)
                        Text(cleanupSummary(group)).font(.caption).foregroundStyle(DaddyTheme.muted)
                        if group.members.filter({ SkillOwnership.classify(path: $0.id) == .local }).count < 2 {
                            Text("Fewer than two owner-managed copies. Plugin/system copies stay with their installer; cache presence does not establish activation.")
                                .font(.caption).foregroundStyle(DaddyTheme.amber)
                        } else {
                            Picker("Keep source", selection: Binding(get: { canonical(group) }, set: { keep[group.id] = $0 })) {
                                Text("Choose source to keep…").tag("")
                                ForEach(group.members.filter { SkillOwnership.classify(path: $0.id) == .local }) { member in
                                    Text(short(member.id)).tag(member.id)
                                }
                            }
                        }
                        DisclosureGroup("Locations and access") {
                            ForEach(group.members) { member in
                                Text("\(short(member.id))\nAgents: \(member.exposedRuntimes.map(\.rawValue).joined(separator: ", "))")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Previous groups") { groupPage = max(0, groupPage - 1) }.disabled(groupPage == 0)
                Spacer()
                Text("\(groupPage + 1) / \(max(1, (groups.count + 7) / 8)) · \(keep.values.filter { !$0.isEmpty }.count) chosen")
                    .font(.caption)
                Spacer()
                Button("Next groups") { groupPage += 1 }.disabled((groupPage + 1) * 8 >= groups.count)
            }
            if differentVersions > 0 {
                Text("Different versions need a content review before they can be combined. Close this dialog, search the skill name, and open Content on each version. Only matching complete folders can be consolidated here.")
                    .font(.caption).foregroundStyle(DaddyTheme.amber)
            }
        }
    }
    private var canPrepare: Bool {
        switch action {
        case .move: parent != nil && !records.isEmpty
        case .share: !agents.isEmpty && (!projectOnly || project != nil) && !records.isEmpty
        case .invocation: !records.isEmpty
        case .cleanup: keep.values.contains { !$0.isEmpty }
        }
    }
    private func canonical(_ group: SkillRedundancyFinding) -> String {
        keep[group.id] ?? ""
    }
    private func cleanupSummary(_ group: SkillRedundancyFinding) -> String {
        let local = group.members.filter { SkillOwnership.classify(path: $0.id) == .local }
        let repository = local.filter { SkillConsolidationBoundary.repositoryRoot(for: URL(fileURLWithPath: $0.id)) != nil }.count
        return "\(local.count - repository) local library copies · \(repository) repository/worktree copies · \(group.members.count - local.count) installer-managed copies"
    }
    private func prepare() {
        working = true; problems = []; plans = []; result = nil
        Task {
            defer { working = false; reviewed = true; approved = Set(plans.map(\.id)) }
            var destinations = Set<String>()
            if action == .cleanup {
                for group in groups {
                    let keepID = canonical(group)
                    guard !keepID.isEmpty else { continue }
                    for member in group.members where member.id != keepID {
                        do {
                            plans.append(try await manager.prepareConsolidation(duplicate: URL(fileURLWithPath: member.id), canonical: URL(fileURLWithPath: keepID)))
                        } catch { problems.append("\(short(member.id)): \(error.localizedDescription)") }
                    }
                }
                return
            }
            for record in records {
                let skill = URL(fileURLWithPath: record.id)
                do {
                    switch action {
                    case .move:
                        let destination = parent!.appendingPathComponent(skill.deletingLastPathComponent().lastPathComponent).path
                        guard destinations.insert(destination).inserted else { throw SkillManagementError(message: "Two selected skills have the same destination name. Move them separately.") }
                        plans.append(try await manager.prepareMove(skill: skill, parent: parent!))
                    case .invocation:
                        plans.append(try await manager.prepareInvocation(skill: skill, runtime: runtime, automatic: automatic))
                    case .share:
                        for agent in agents.sorted(by: { $0.rawValue < $1.rawValue }) {
                            let root = projectOnly ? project! : FileManager.default.homeDirectoryForCurrentUser
                            let directory: String = switch agent {
                            case .codex: ".agents/skills"
                            case .claude: ".claude/skills"
                            case .cursor: ".cursor/skills"
                            case .devin: projectOnly ? ".agents/skills" : ".config/devin/skills"
                            case .grok: ".grok/skills"
                            }
                            let destination = root.appendingPathComponent(directory)
                            guard destinations.insert(destination.appendingPathComponent(skill.deletingLastPathComponent().lastPathComponent).path).inserted else { continue }
                            do { plans.append(try await manager.prepareLink(skill: skill, parent: destination)) }
                            catch { problems.append("\(record.name) → \(agent.rawValue): \(error.localizedDescription)") }
                        }
                    case .cleanup: break
                    }
                } catch { problems.append("\(short(record.id)): \(error.localizedDescription)") }
            }
        }
    }
    private func apply() {
        working = true
        let selected = plans.filter { approved.contains($0.id) }
        Task {
            var completed = 0
            for plan in selected {
                do {
                    _ = try await ContextUpdateActivity.perform { try await manager.apply(plan.id) }
                    completed += 1
                    if action == .move || action == .share {
                        let parent = URL(fileURLWithPath: plan.destination).deletingLastPathComponent().path
                        var roots = UserDefaults.standard.stringArray(forKey: "contextDaddySkillRoots") ?? []
                        if !roots.contains(parent) { roots.append(parent); UserDefaults.standard.set(roots, forKey: "contextDaddySkillRoots") }
                    }
                } catch {
                    problems.append("Stopped at \(plan.destination): \(error.localizedDescription). Later changes were not applied. Review History before preparing a new plan.")
                    break
                }
            }
            result = "Applied \(completed) of \(selected.count) changes. \(completed > 0 ? "Recovery is available in History." : "No completed changes.")"
            await refreshed()
            finished = true; working = false
        }
    }
    private func chooseFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func short(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
