import AppKit
import ContextCore
import SwiftUI

struct RootView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { viewport in
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                BrandMark()
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                VStack(spacing: 5) {
                    ForEach(AppSection.allCases.filter { $0 != .projects }) { section in
                        Button {
                            model.show(section)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.icon).frame(width: 18)
                                Text(section.label)
                                Spacer()
                            }
                            .font(.system(size: 13, weight: model.section == section && !model.evidenceOpen ? .semibold : .regular))
                            .foregroundStyle(model.section == section && !model.evidenceOpen ? DaddyTheme.mint : DaddyTheme.muted)
                            .padding(.horizontal, 11)
                            .frame(height: 36)
                            .background(model.section == section && !model.evidenceOpen ? DaddyTheme.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.section == section && !model.evidenceOpen ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                Rectangle()
                    .fill(DaddyTheme.line)
                    .frame(height: 1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                Button {
                    model.showEvidence(.diagnostics)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full").frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Diagnostics")
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                            if !model.configurationHealth.issues.isEmpty {
                                Text("\(model.configurationHealth.issues.count.formatted()) configuration \(model.configurationHealth.issues.count == 1 ? "issue" : "issues")")
                                    .font(.caption2.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(model.configurationHealth.errorCount > 0 ? DaddyTheme.coral : DaddyTheme.amber)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: model.evidenceOpen ? .semibold : .regular))
                    .foregroundStyle(model.evidenceOpen ? DaddyTheme.mint : DaddyTheme.muted)
                    .padding(.horizontal, 11)
                    .frame(minHeight: model.configurationHealth.issues.isEmpty ? 38 : 52)
                    .background(model.evidenceOpen ? DaddyTheme.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.evidenceOpen ? .isSelected : [])
                .accessibilityLabel(model.configurationHealth.issues.isEmpty
                    ? "Diagnostics"
                    : "Diagnostics, \(model.configurationHealth.issues.count) configuration \(model.configurationHealth.issues.count == 1 ? "issue" : "issues")")
                .help("Discovered files and read-only configuration diagnostics")
                .padding(.horizontal, 10)
                Button("Project files & instructions") { model.show(.projects) }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(DaddyTheme.muted)
                    .padding(.horizontal, 20).padding(.top, 12)
                Spacer(minLength: 8)
                PrivacyFooter()
                    .padding(16)
            }
            .safeAreaPadding(.top, 18)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DaddyTheme.canvas)
            .frame(width: 240)
            Rectangle().fill(DaddyTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    if model.evidenceOpen {
                        SourcesHubView()
                    } else {
                        switch model.section ?? .overview {
                        case .overview: LiveRunsView()
                        case .skills: SkillsLedgerView()
                        case .memory: MemoryLibraryView()
                        case .projects: ProjectsContextView()
                        case .telemetry: TelemetryView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DaddyTheme.canvas)
        }
        .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .task { await model.refresh() }
        .preferredColorScheme(.dark)
        .tint(DaddyTheme.mint)
        .buttonStyle(ContextDaddyButtonStyle())
        .toolbar(.hidden, for: .windowToolbar)
    }
}

private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 8) {
            ContextDoodleArt(topic: .skills)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("contextdaddy")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                Text("AGENT CONTEXT, EXPLAINED")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(DaddyTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrivacyFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Local & redacted", systemImage: "lock.shield")
                .font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
            Text("Local discovery. Document reads and changes are explicit. No prompt collection.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScreenHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let art: ContextDoodleTopic
    var hero = false
    var compact = false

    var body: some View {
        Group {
            if compact {
                compactHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalHeader
                    compactHeader
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var horizontalHeader: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(DaddyTheme.mint)
                Text(title).font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.5)
                Text(subtitle).font(.subheadline).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if hero {
                ContextHeroArt().frame(width: 200, height: 92)
            } else {
                ContextDoodleArt(topic: art).frame(width: 72, height: 72)
            }
        }
        .padding(.bottom, 2)
    }

    private var compactHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(DaddyTheme.mint)
                Text(title).font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.4)
                Text(subtitle).font(.caption).foregroundStyle(DaddyTheme.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            ContextDoodleArt(topic: art).frame(width: 46, height: 46)
        }
    }
}

struct LiveRunsView: View {
    var body: some View { FocusDeskView() }
}

struct SourcesHubView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if model.evidenceOpen {
                    Button {
                        model.evidenceOpen = false
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
                ContextModeToggle(
                    title: "View", selection: $model.sourcesMode,
                    choices: SourcesMode.allCases.map { ContextChoice($0, $0.rawValue) }
                )
                .frame(maxWidth: 300)
                Spacer(minLength: 8)
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label(model.isLoading ? "Refreshing…" : model.sourcesMode == .diagnostics ? "Recheck setup" : "Refresh inventory", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 5)
            if model.sourcesMode == .inventory {
                SourceInventoryView()
            } else {
                CoverageView()
            }
        }
    }
}

struct SkillsLedgerView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View { content }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        if model.skillsMode == .plugins {
            PluginInventoryView()
        } else if model.skillsMode == .cleanup {
            SkillCleanupWorkbench()
        } else if model.skillsMode == .library {
            SkillLibraryView()
        } else {
        GeometryReader { proxy in
            let compact = proxy.size.height < 720 || proxy.size.width < 850
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 11 : 16) {
                ScreenHeader(
                    eyebrow: model.skillsMode == .ledger ? "Skill access" : "Decision support",
                    title: model.skillsMode == .ledger ? "Can \(model.selectedRuntime.rawValue) use these skills?" : "Redundancy review",
                    subtitle: model.skillsMode == .ledger
                        ? "See what \(model.selectedRuntime.rawValue) may load automatically, what you invoke manually, and what it cannot discover."
                        : "Evidence-ranked consolidation candidates across agents, with false-positive boundaries left visible.",
                    art: .skills,
                    compact: compact
                )
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        skillsModePicker
                        Spacer()
                        inventoryTimestamp
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        skillsModePicker
                        inventoryTimestamp
                    }
                }
                if model.skillsMode == .ledger {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            runtimePicker
                            Spacer()
                        }
                        runtimePicker
                    }
                    SkillsGovernanceView(
                        runtime: model.selectedRuntime,
                        summary: model.governanceSummary,
                        sharing: model.sharingSummary,
                        selectedFilter: model.filter,
                        selectFilter: { model.filter = model.filter == $0 ? .all : $0 },
                        compact: compact
                    )
                    if let reviewCount = model.redundancySummary?.reviewCount, reviewCount > 0 {
                        Button {
                            model.skillsMode = .redundancy
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkle.magnifyingglass")
                                Text("Review \(reviewCount.formatted()) evidence-backed skill opportunities")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DaddyTheme.mint)
                            .padding(12)
                            .background(DaddyTheme.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DaddyTheme.mint.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            skillSearch
                            policyPicker
                            Spacer(minLength: 8)
                            matchCount
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            skillSearch
                            HStack(spacing: 10) {
                                policyPicker
                                Spacer(minLength: 8)
                                matchCount
                            }
                        }
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(model.visibleSkills) { skill in SkillRow(skill: skill, selectedRuntime: model.selectedRuntime) }
                        if model.visibleSkills.isEmpty {
                            ContentUnavailableView("No matching skills", systemImage: "square.stack.3d.up.slash", description: Text(model.isLoading ? "Scanning bounded local roots…" : "Change the search or policy filter."))
                                .padding(.top, 80)
                        }
                    }
                } else {
                    RedundancyReviewView(compact: compact)
                }
                }
                .padding(compact ? 18 : 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
    }

    private var skillsModePicker: some View {
        ContextModeToggle(
            title: "Skills view",
            selection: Bindable(model).skillsMode,
            choices: SkillsMode.allCases.map { ContextChoice($0, $0.rawValue) }
        )
        .frame(width: 420)
    }

    private var runtimePicker: some View {
        ContextChoiceMenu(
            title: "Agent",
            selection: Bindable(model).selectedRuntime,
            choices: AgentRuntime.allCases.map { ContextChoice($0, $0.rawValue) },
            width: 180
        )
    }

    @ViewBuilder private var inventoryTimestamp: some View {
        if let generated = model.catalog?.generatedAt {
            Text("Inventory \(generated.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var skillSearch: some View {
        TextField("Search skill, path, or description", text: Bindable(model).search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220, maxWidth: 340)
    }

    private var policyPicker: some View {
        ContextChoiceMenu(
            title: "Status",
            selection: Bindable(model).filter,
            choices: SkillFilter.allCases.map { ContextChoice($0, $0.rawValue) },
            width: 170
        )
    }

    private var matchCount: some View {
        Text("\(model.visibleSkills.count) matching · \(model.selectedRuntime.rawValue)")
            .font(.caption).foregroundStyle(DaddyTheme.muted)
            .fixedSize()
    }
}

private struct SkillRow: View {
    let skill: SkillRecord
    let selectedRuntime: AgentRuntime
    @State private var expanded = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 16)
                    }.buttonStyle(.plain).foregroundStyle(DaddyTheme.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(.headline)
                        Text(skill.description).font(.caption).foregroundStyle(DaddyTheme.muted).lineLimit(expanded ? 4 : 1)
                        HStack(spacing: 6) {
                            Text(skill.exposures.first?.source ?? "Unknown source")
                            Text("·")
                            Text(abbreviated(skill.id)).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted.opacity(0.8))
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: skill.logicalBytes, countStyle: .file)).font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    if skill.hasDefinitionConflict {
                        Text("\(skill.definitionConflictCount) definitions").font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.amber)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(skill.policies) { policy in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(policy.runtime.rawValue)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(policy.runtime == selectedRuntime ? DaddyTheme.mint : DaddyTheme.muted)
                            PolicyBadge(policy: policy)
                        }
                        .padding(5)
                        .background(policy.runtime == selectedRuntime ? DaddyTheme.mint.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                Text("\(skill.exposures.count) exposure\(skill.exposures.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if expanded {
                    Divider().overlay(DaddyTheme.line)
                    ForEach(skill.policies) { policy in
                        ViewThatFits(in: .horizontal) {
                            policyDetail(policy, compact: false)
                            policyDetail(policy, compact: true)
                        }
                    }
                    ForEach(skill.exposures) { exposure in
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Image(systemName: "link").foregroundStyle(DaddyTheme.blue)
                                Text(exposure.logicalPath).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Text(exposure.source).font(.caption2).foregroundStyle(DaddyTheme.muted)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Label(exposure.logicalPath, systemImage: "link")
                                    .font(.caption.monospaced()).foregroundStyle(DaddyTheme.blue).textSelection(.enabled)
                                Text(exposure.source).font(.caption2).foregroundStyle(DaddyTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    private func policyDetail(_ policy: SkillRuntimePolicy, compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        policyName(policy)
                        Spacer()
                        EvidenceBadge(quality: policy.evidence)
                    }
                    policyReason(policy)
                    invocationButton(policy)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    policyName(policy)
                    policyReason(policy)
                    Spacer()
                    invocationButton(policy)
                    EvidenceBadge(quality: policy.evidence)
                }
            }
        }
    }

    private func policyName(_ policy: SkillRuntimePolicy) -> some View {
        Text(policy.runtime.rawValue)
            .frame(width: 54, alignment: .leading)
            .font(.caption.weight(.semibold))
            .foregroundStyle(policy.runtime == selectedRuntime ? DaddyTheme.mint : .primary)
    }

    private func policyReason(_ policy: SkillRuntimePolicy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(policy.reason).font(.caption).foregroundStyle(DaddyTheme.muted)
            if policy.runtime == selectedRuntime, !policy.isExposed {
                Text("Expected root: \(expectedRoot(for: policy.runtime))")
                    .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func invocationButton(_ policy: SkillRuntimePolicy) -> some View {
        if policy.runtime == selectedRuntime,
           policy.isExposed,
           policy.mode != .modelOnly,
           policy.mode != .disabled {
            Button {
                copy(policy.invocation)
            } label: {
                Label(policy.invocation, systemImage: "doc.on.doc")
            }
            .buttonStyle(ContextDaddyButtonStyle())
            .help("Copy the exact \(policy.runtime.rawValue) invocation")
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func expectedRoot(for runtime: AgentRuntime) -> String {
        switch runtime {
        case .codex: "~/.codex/skills or ~/.agents/skills"
        case .claude: "~/.claude/skills"
        case .cursor: "~/.cursor/skills"
        case .devin: "~/.config/devin/skills"
        case .grok: "~/.grok/skills"
        }
    }
}

struct CoverageView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diagnostics").font(.title.bold())
                    Text("Find broken agent setup, see its impact, and copy a fix to your agent.").foregroundStyle(DaddyTheme.muted)
                }
                HStack {
                    Label(model.discoveryStatus, systemImage: model.isLoading ? "arrow.triangle.2.circlepath" : model.discoveryReport == nil ? "questionmark.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(model.isLoading ? DaddyTheme.blue : DaddyTheme.muted)
                    Spacer()
                    Button("Add folder…", systemImage: "folder.badge.plus", action: addFolders)
                }
                if model.isLoading {
                    RefreshContinuityBanner(started: model.loadStarted, hasPreviousResults: model.discoveryReport != nil)
                }
                AgentDiagnosticsView()
                if let catalog = model.catalog {
                    DisclosureGroup("Scan coverage and evidence") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(minimum: 120), spacing: 10), count: 4),
                        spacing: 10
                    ) {
                        fact("Physical skills", "\(catalog.physicalSkillCount)")
                        fact("Exposures", "\(catalog.exposureCount)")
                        fact("Visited entries", "\(catalog.coverage.visitedEntries)")
                        fact("Coverage", catalog.coverage.isPartial ? "Partial" : "Complete")
                        fact("Projects", "\(model.projects.count)")
                        fact("Unreadable", "\(catalog.coverage.unreadableCount)")
                        fact("Links skipped", "\(catalog.coverage.skippedLinks)")
                        fact("Roots", "\(catalog.coverage.roots.count)")
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scanned roots").font(.headline)
                            ForEach(catalog.coverage.roots, id: \.self) { root in
                                Label(root, systemImage: "folder").font(.caption.monospaced()).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Added folders").font(.headline)
                                    Text("Persisted locally and included in future bounded discovery runs.")
                                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                                }
                                Spacer()
                                if model.extraRoots.isEmpty { Text("None").font(.caption).foregroundStyle(DaddyTheme.muted) }
                            }
                            ForEach(model.extraRoots, id: \.self) { path in
                                HStack {
                                    Label(path, systemImage: "folder.badge.plus").font(.caption.monospaced())
                                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer()
                                    Button("Remove") {
                                        model.removeExtraRoot(path)
                                        Task { await model.refresh() }
                                    }.controlSize(.small)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Coverage notes").font(.headline)
                            let notes = catalog.coverage.notes + catalog.coverage.limitReasons
                            if notes.isEmpty {
                                Label("No discovery limits were reported.", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(DaddyTheme.mint)
                            }
                            ForEach(notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(DaddyTheme.muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Runtime evidence boundaries").font(.headline)
                            adapter("Codex", "Prometheus aggregates + Tempo sessions + named skill injection", .measured)
                            adapter("Claude", "OTEL metrics when routed to the collector; tool/API events not yet verified", .partial)
                            adapter("Cursor", "Skills and rules discovered; run telemetry unavailable", .partial)
                            adapter("Devin", "Indexed local usage history; live OTEL unavailable", .partial)
                            adapter("Grok", "Local skill exposure only", .partial)
                            Divider().overlay(DaddyTheme.line)
                            Text("Discovery reads bounded metadata. Text bodies are read only when you explicitly preview an eligible file. MCP configuration bodies, prompts, responses, commands, credentials, and tool results are not inventoried.")
                                .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }
                } else if model.isLoading {
                    ProgressView("Scanning bounded local roots…").padding(40)
                } else {
                    Text("Use Recheck setup to scan supported local configuration.").font(.caption).foregroundStyle(DaddyTheme.muted)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        Panel(padding: 12) { VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.bold()); Text(label).font(.caption).foregroundStyle(DaddyTheme.muted) }.frame(maxWidth: .infinity, alignment: .leading) }
    }

    private func adapter(_ name: String, _ detail: String, _ quality: EvidenceQuality) -> some View {
        HStack {
            Text(name).font(.subheadline.weight(.semibold)).frame(width: 70, alignment: .leading)
            Text(detail).font(.caption).foregroundStyle(DaddyTheme.muted)
            Spacer()
            EvidenceBadge(quality: quality)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose project folders to include in bounded context discovery."
        guard panel.runModal() == .OK else { return }
        model.addExtraRoots(panel.urls)
        Task { await model.refresh() }
    }
}
