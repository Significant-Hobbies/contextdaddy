import ContextCore
import SwiftUI

struct PluginActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: PluginInventoryEntry
    let manager: PluginActionManager
    let changed: () -> Void
    @State private var action: PluginAction = .disable
    @State private var registrationID = ""
    @State private var plan: PluginActionPlan?
    @State private var busy = false
    @State private var result: String?
    @State private var failure: String?
    private var registrations: [PluginRegistration] { entry.registrations.filter { ["user", "project", "local"].contains($0.scope) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage \(entry.name)").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(entry.pluginKey).font(.headline.monospaced()).textSelection(.enabled)
                    if let result {
                        Text(result).foregroundStyle(DaddyTheme.mint).textSelection(.enabled)
                        Text("Start a new agent session to check runtime availability. This screen verifies local declarations, not loaded context.").foregroundStyle(DaddyTheme.muted)
                    } else if let plan {
                        Text("\(plan.action.rawValue) · \(plan.scope) scope").font(.headline)
                        Text(plan.workingDirectory).font(.caption.monospaced()).textSelection(.enabled)
                        Text(plan.explanation)
                        Text("Command preview").font(.caption.bold())
                        Text(([plan.executable] + plan.arguments).joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled)
                        Text("The owner may update its settings and registration. No dependency pruning or custom cache deletion is requested.").font(.caption).foregroundStyle(DaddyTheme.muted)
                    } else {
                        Text("Use the owning manager from ContextDaddy. Preview the exact action and scope before applying.")
                        Picker("Action", selection: $action) {
                            ForEach(entry.owner == .claude ? PluginAction.allCases : [.uninstall]) { Text($0.rawValue).tag($0) }
                        }
                        if entry.owner == .claude {
                            Picker("Registration", selection: $registrationID) {
                                Text("Select a scope").tag("")
                                ForEach(registrations) { registration in Text("\(registration.scope) · \(registration.project ?? "User installation")").tag(registration.id) }
                            }
                            if registrations.isEmpty { Text("No supported registration verified. Use Claude’s /plugin manager to resolve installation first.").foregroundStyle(DaddyTheme.amber) }
                        } else {
                            Text("Codex removal deletes the local cache. Enable/disable is available in Codex's own plugin settings; this CLI does not expose it.").foregroundStyle(DaddyTheme.amber)
                        }
                        Text("Disabling changes availability. Removing cached versions alone does not reduce an agent’s active context.").font(.callout).foregroundStyle(DaddyTheme.muted)
                        Link("Official management instructions", destination: URL(string: entry.owner == .claude ? "https://code.claude.com/docs/en/discover-plugins#manage-installed-plugins" : "https://learn.chatgpt.com/docs/plugins")!)
                    }
                    if let failure { Text(failure).foregroundStyle(DaddyTheme.amber).textSelection(.enabled) }
                    if busy { ProgressView("Running owner action and checking local evidence…") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if result == nil {
                    if plan != nil {
                        Button("Back") { plan = nil; failure = nil }.disabled(busy)
                        Button("Apply \(action.rawValue.lowercased())") { Task { await apply() } }.disabled(busy)
                    } else {
                        Button("Preview action") { Task { do { failure = nil; plan = try await manager.prepare(entry: entry, action: action, registration: registrations.first { $0.id == registrationID }) } catch { failure = error.localizedDescription } } }
                            .disabled(entry.owner == .claude && registrationID.isEmpty)
                    }
                }
            }
        }.padding(24).frame(width: 650, height: 520).interactiveDismissDisabled(busy)
        .onAppear { action = entry.owner == .claude ? .disable : .uninstall; if registrations.count == 1 { registrationID = registrations[0].id } }
    }
    private func apply() async {
        guard let plan else { return }
        busy = true; failure = nil
        defer { busy = false }
        do {
            let receipt = try await manager.apply(plan.id)
            let directory = URL(fileURLWithPath: plan.workingDirectory)
            let after = try await Task.detached { try PluginInventory.scan(folder: directory) }.value
            let current = after.entries.first { $0.id == entry.id }
            let verified: Bool
            if action == .uninstall {
                if entry.owner == .claude {
                    // A missing row cannot prove success if the registry could not be read.
                    verified = current?.registryVerified == true && current?.registrations.contains(where: { $0.id == registrationID }) == false
                } else { verified = current == nil && !after.isPartial }
            } else {
                let settings = plan.scope == "user" ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
                    : directory.appendingPathComponent(plan.scope == "local" ? ".claude/settings.local.json" : ".claude/settings.json").path
                verified = current?.preferences.contains { $0.path == settings && $0.enabled == (action == .enable) } == true
            }
            result = receipt.status + (verified ? "\nVerified: the requested local state is present after rescan." : "\nThe requested state is not verified. Review current evidence before retrying.")
            try await manager.recordVerification(receipt.id, verified: verified)
            changed()
        } catch { failure = error.localizedDescription; self.plan = nil; changed() }
    }
}

struct PluginHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let manager: PluginActionManager
    @State private var receipts: [PluginActionReceipt] = []
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plugin action history").font(.title2.bold())
            Text("Owner command results are separate from runtime activation. Recheck the plugin ledger for current evidence.").foregroundStyle(DaddyTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if receipts.isEmpty { Text("No plugin actions yet.") }
                    ForEach(receipts) { receipt in
                        Text("\(receipt.action) \(receipt.pluginKey)").font(.headline)
                        Text("\(receipt.owner) · \(receipt.scope) · \(receipt.date.formatted())").font(.caption)
                        Text(receipt.workingDirectory).font(.caption.monospaced())
                        Text(receipt.status).font(.callout)
                        Divider()
                    }
                    if let failure { Text(failure).foregroundStyle(DaddyTheme.amber) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 650, height: 500)
        .task { do { receipts = try await manager.history() } catch { failure = error.localizedDescription } }
    }
}
