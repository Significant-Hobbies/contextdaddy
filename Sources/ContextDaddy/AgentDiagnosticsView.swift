import AppKit
import ContextCore
import SwiftUI

struct AgentDiagnosticsView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("skillWorkingFolder") private var workingFolder = ""
    private var runtime: AgentRuntime { model.selectedTelemetryRuntime }

    private var records: [SkillRecord] { model.skillFolderContext?.records ?? model.catalog?.records ?? [] }
    private var relevant: [SkillRecord] { records.filter { $0.policy(for: runtime)?.isExposed == true } }
    private var findings: [SkillRedundancyFinding] {
        (model.skillFolderContext == nil ? model.redundancySummary : SkillRedundancyAnalyzer.analyze(records: records))?.actionableFindings.filter { $0.affectedRuntimes.contains(runtime) } ?? []
    }

    var body: some View {
        let activeFindings = findings
        let invocationIssues = relevant.filter { record in
            guard let policy = record.policy(for: runtime) else { return true }
            return policy.mode == .unverified || (policy.desiredMode != nil && policy.desiredMode != policy.mode)
        }
        VStack(alignment: .leading, spacing: 14) {
            ContextChoiceMenu(title: "Agent", selection: Bindable(model).selectedTelemetryRuntime,
                              choices: AgentRuntime.allCases.map { ContextChoice($0, $0.rawValue) }, width: 180)
            ViewThatFits(in: .horizontal) {
                HStack { folderMenu; Text(workingFolder.isEmpty ? "Global configuration · all discovered skills" : workingFolder).font(.caption.monospaced()) }
                VStack(alignment: .leading) { folderMenu; Text(workingFolder.isEmpty ? "Global configuration · all discovered skills" : workingFolder).font(.caption.monospaced()) }
            }
            if model.isSkillFolderLoading { ProgressView("Reading folder context…") }
            if let failure = model.skillFolderError { Text(failure).font(.caption).foregroundStyle(DaddyTheme.coral) }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(runtime.rawValue) skill access & overlap").font(.headline)
                    Text(model.skillFolderContext.map { "Skill scope: " + $0.path } ?? "Skill scope: all discovered folders")
                        .font(.caption.monospaced()).foregroundStyle(DaddyTheme.muted)
                    if model.isSkillFolderLoading || model.skillFolderError != nil {
                        Text("Folder results are not ready. Review is available after a successful scan.").font(.caption)
                    } else if model.catalog == nil && model.skillFolderContext == nil {
                        Text("Skill discovery has not completed. Recheck setup to scan.").font(.callout)
                    } else {
                        Text("\(relevant.count) accessible definitions · \(invocationIssues.count) invocation policies to review · \(activeFindings.count) overlap findings")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        if !invocationIssues.isEmpty {
                            Text("Some restrictions do not control this agent, or their policy could not be resolved. Review these before relying on manual-only behavior.")
                                .font(.caption).foregroundStyle(DaddyTheme.amber)
                            Button("Review invocation policies") {
                                model.pendingSkillAllFolders = model.skillFolderContext == nil
                                model.pendingSkillRuntime = runtime
                                model.pendingSkillInvocation = .unverified
                                model.show(.skills)
                            }
                        }
                        if activeFindings.isEmpty {
                            Text("No overlap finding in the scanned sources for this agent. This does not verify its full setup or live loading.").font(.caption).foregroundStyle(DaddyTheme.muted)
                        } else {
                            ForEach(Array(activeFindings.prefix(5))) { finding in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(Set(finding.members.map(\.name)).sorted().joined(separator: " ↔ ") + " · \(finding.members.count) definitions").font(.callout.weight(.semibold))
                                    Text(finding.kind.rawValue + " · " + finding.recommendation).font(.caption).foregroundStyle(DaddyTheme.muted)
                                    Button("Copy review brief") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(IssueBriefFormatter.skills([finding]), forType: .string)
                                    }.font(.caption)
                                }
                            }
                            if activeFindings.count > 5 { Text("Showing 5 of \(activeFindings.count); open Skills to review the complete set.").font(.caption) }
                        }
                        Button("Review \(runtime.rawValue) skills and cleanup") {
                            model.pendingSkillAllFolders = model.skillFolderContext == nil
                            model.pendingSkillRuntime = runtime
                            model.pendingSkillInvocation = nil
                            model.show(.skills)
                        }
                    }
                    if (model.skillFolderContext?.coverage ?? model.catalog?.coverage)?.isPartial == true {
                        Text("Partial skill scan · unscanned locations may contain additional issues.").font(.caption).foregroundStyle(DaddyTheme.amber)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ConfigurationHealthView(report: model.configurationHealth.forAgent(runtime), runtime: runtime)
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(runtime.rawValue) activity source").font(.headline)
                    Text(runtime == .codex || runtime == .claude
                         ? (model.telemetry.agents.first { $0.runtime == runtime }?.connected == true ? "Live telemetry is connected. Recorded local history is also available separately." : "Live telemetry is not verified for this agent. Recorded local history may still be available.")
                         : "Local activity files and available indexed history can be inspected. Live traces are not provided by the current adapter.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                    Button("Inspect \(runtime.rawValue) activity") { model.selectedTelemetryRuntime = runtime; model.show(.telemetry) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: workingFolder) {
            await model.loadSkillFolder(workingFolder)
            await model.refreshConfigurationHealth()
        }
    }

    private var folderMenu: some View {
        Menu("Folder") {
            Button("All folders") { workingFolder = "" }
            Button("Choose folder…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                panel.message = "Choose the folder whose agent setup you want to inspect"
                if panel.runModal() == .OK, let url = panel.url { workingFolder = url.path }
            }
            ForEach(Array(model.projects.prefix(20))) { project in
                Button(project.name + " · " + project.path) { workingFolder = project.path }
            }
        }.fixedSize()
    }
}
