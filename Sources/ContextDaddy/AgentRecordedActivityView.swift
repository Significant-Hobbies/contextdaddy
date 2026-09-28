import AppKit
import ContextCore
import SwiftUI

struct AgentRecordedActivityView: View {
    @Environment(ContextDaddyModel.self) private var model
    let runtime: AgentRuntime
    @State private var snapshot: AgentActivityFiles?
    @State private var revision = 0
    @State private var expanded = false
    @State private var loading = false
    @AppStorage("skillWorkingFolder") private var workingFolder = ""

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(runtime.rawValue) recorded activity").font(.headline)
                    Spacer()
                    Button(loading ? "Reading…" : "Refresh history") {
                        revision += 1
                        Task { await model.refreshUsage(force: true) }
                    }.disabled(loading || model.isUsageLoading)
                }
                let sessions = (model.usageReport?.sessions ?? []).filter { $0.agent.lowercased() == runtime.rawValue.lowercased() }
                    .sorted { ($0.lastActivity ?? "") > ($1.lastActivity ?? "") }
                if !sessions.isEmpty {
                    Text("\(sessions.count) indexed sessions · local usage history, separate from live telemetry").font(.caption).foregroundStyle(DaddyTheme.muted)
                    ForEach(Array(sessions.prefix(5))) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.project ?? "Project not recorded").font(.callout).textSelection(.enabled)
                            Text("\(session.lastActivity ?? "Time not recorded") · \(session.totals.generatedTokens.formatted()) generated tokens")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                            if let path = session.project, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
                                Button("Inspect this folder’s skills") {
                                    workingFolder = path
                                    model.pendingSkillAllFolders = false
                                    model.pendingSkillRuntime = runtime
                                    model.show(.skills)
                                }.font(.caption)
                            }
                        }
                    }
                } else if runtime == .devin, let usage = model.usageReport?.devin, usage.status == "ready" {
                    ForEach(Array((usage.daily ?? []).sorted { $0.period > $1.period }.prefix(5)), id: \.period) { day in
                        Text("\(day.period) · \(day.sessions) indexed sessions · \(day.generatedTokens.formatted()) generated tokens").font(.callout)
                    }
                    Text("Devin's indexed daily totals; a session can occur on several days. These are not live traces.").font(.caption).foregroundStyle(DaddyTheme.muted)
                } else {
                    Text(model.isUsageLoading ? "Reading indexed usage…" : "No indexed usage available for this agent. File activity below can still show where its local history lives.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                }
                if let snapshot, snapshot.runtime == runtime {
                    DisclosureGroup("Local activity files · \(snapshot.files.count) retained") {
                    Text(snapshot.status).font(.caption.weight(.semibold)).foregroundStyle(snapshot.partial ? DaddyTheme.amber : DaddyTheme.muted)
                    Text((snapshot.root as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).textSelection(.enabled)
                    Text("File dates show writes, not task completion, token use or successful runs. No transcript bodies are read. Up to 200 newest files from this bounded scan.")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    ForEach(Array(snapshot.files.prefix(expanded ? 200 : 5))) { file in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text((file.path as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("Updated " + file.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(DaddyTheme.muted)
                            }
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }.font(.caption)
                        }
                    }
                    if snapshot.files.count > 5 { Button(expanded ? "Show fewer files" : "Show all \(snapshot.files.count) files") { expanded.toggle() }.font(.caption) }
                    }.font(.caption)
                } else { ProgressView("Finding local activity files…") }
                Button("Open this agent’s usage history") {
                    model.usageHistoryAgents = [runtime.rawValue.lowercased()]
                    model.show(.overview)
                }.font(.caption)
                if runtime == .cursor {
                    Link("Open Cursor usage dashboard", destination: URL(string: "https://cursor.com/dashboard")!).font(.caption)
                    Text("Cursor transcript files provide local activity evidence. Billing and usage analytics remain in Cursor's dashboard; file counts are not usage totals.").font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: runtime.rawValue + String(revision)) {
            loading = true
            expanded = false
            let selected = runtime
            let task = Task.detached(priority: .utility) { AgentActivityFiles.scan(runtime: selected) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            snapshot = result
            loading = false
        }
    }
}
