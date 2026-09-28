import AppKit
import ContextCore
import SwiftUI

struct ActivityAnswersView: View {
    @Environment(ContextDaddyModel.self) private var model
    @AppStorage("skillWorkingFolder") private var workingFolder = ""
    let runtime: AgentRuntime
    @State private var folder = ""
    @State private var days = 7
    private var answers: ActivityAnswers { .init(sessions: model.usageReport?.sessions ?? [], runtime: runtime, folder: folder, days: days == 0 ? nil : days) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { folderPicker; rangePicker }
                VStack(alignment: .leading) { folderPicker; rangePicker }
            }
            if !folder.isEmpty { Text(folder).font(.caption.monospaced()).textSelection(.enabled) }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What happened?").font(.headline)
                    Text(model.isUsageLoading ? "Reading local history…" : model.usageReport?.sessions?.contains(where: { $0.agent.lowercased() == runtime.rawValue.lowercased() }) != true
                         ? "\(runtime.rawValue) session index unavailable"
                         : "\(answers.sessions.count) indexed \(runtime.rawValue) sessions match").font(.title3.bold())
                    Text("Filtered by last activity\(folder.isEmpty ? "; all recorded projects" : "; this folder and descendants"). Counts do not prove task completion.").font(.caption).foregroundStyle(DaddyTheme.muted)
                    if answers.missingDates > 0 || answers.missingProjects > 0 {
                        Text("Agent index has \(answers.missingDates) sessions without usable dates and \(answers.missingProjects) without project attribution. Relevant filters exclude these records.").font(.caption).foregroundStyle(DaddyTheme.amber)
                    }
                    if answers.sessions.isEmpty {
                        Text("Try All indexed history or another folder. This adapter may have daily totals without session-level records.").font(.callout).foregroundStyle(DaddyTheme.muted)
                        Button("Open agent usage") { model.usageHistoryAgents = [runtime.rawValue.lowercased()]; model.show(.overview) }
                    }
                    if let error = model.usageError { Text("History refresh did not complete: " + error).font(.caption).foregroundStyle(DaddyTheme.amber) }
                    Button(model.isUsageLoading ? "Refreshing…" : "Refresh history") { Task { await model.refreshUsage(force: true) } }.disabled(model.isUsageLoading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !answers.sessions.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What used tokens?").font(.headline)
                        Text("\(answers.input.formatted()) input · \(answers.cached.formatted()) cache reads · \(answers.output.formatted()) output").font(.callout.monospacedDigit())
                        Text("Lifetime totals of the matching sessions, not token use within the selected days or current context-window size. Cache creation and reasoning breakdowns remain in Usage.").font(.caption).foregroundStyle(DaddyTheme.muted)
                        Text("Largest recorded sessions").font(.subheadline.bold())
                        ForEach(answers.largest) { session in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.project ?? "Project not recorded").font(.callout).textSelection(.enabled)
                                Text("\(session.totals.totalTokens.formatted()) total tokens · \(session.lastActivity ?? "Date unavailable")").font(.caption).foregroundStyle(DaddyTheme.muted)
                                DisclosureGroup("Session evidence") { Text("Session: \(session.sessionID)\nModels: \(session.models.map(\.model).joined(separator: ", "))\nNo task outcome or file-by-file token attribution is supplied by this index.").font(.caption.monospaced()).textSelection(.enabled) }
                                if let path = session.project, path.hasPrefix("/") {
                                    HStack {
                                        Button("Review memory") { workingFolder = path; model.show(.memory) }
                                        Button("Review skills") { workingFolder = path; model.pendingSkillRuntime = runtime; model.pendingSkillAllFolders = false; model.show(.skills) }
                                    }
                                }
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What should I change?").font(.headline)
                    Text("Start with repeated instructions and broad skill access in the folder you use. High token totals alone do not identify a bad skill; compare representative sessions after changing it.").font(.callout).foregroundStyle(DaddyTheme.muted)
                    ViewThatFits(in: .horizontal) {
                        HStack { reviewActions }
                        VStack(alignment: .leading) { reviewActions }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var reviewActions: some View {
        Group {
            Button("Inspect memory") { workingFolder = folder; model.show(.memory) }
            Button("Inspect skill access") { if !folder.isEmpty { workingFolder = folder }; model.pendingSkillRuntime = runtime; model.pendingSkillAllFolders = folder.isEmpty; model.show(.skills) }
            Button("Check agent setup") { workingFolder = folder; model.selectedTelemetryRuntime = runtime; model.showEvidence(.diagnostics) }
        }
    }
    private var folderPicker: some View {
        Menu(folder.isEmpty ? "All recorded folders" : "Change folder") {
            Button("All recorded folders") { folder = "" }
            Button("Choose folder…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { folder = url.path } }
            ForEach(Array(Set((model.usageReport?.sessions ?? []).filter { $0.agent.lowercased() == runtime.rawValue.lowercased() }.compactMap(\.project).filter { $0.hasPrefix("/") })).sorted(), id: \.self) { path in Button(path) { folder = path } }
        }
    }
    private var rangePicker: some View { Picker("Last activity", selection: $days) { Text("Last 7 days").tag(7); Text("Last 30 days").tag(30); Text("All indexed history").tag(0) }.frame(maxWidth: 280) }
}
