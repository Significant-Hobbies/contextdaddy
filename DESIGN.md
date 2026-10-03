# ContextDaddy design contract

Platform: native-macos
Supported minimum width: 960

Codex credit evidence reviews the native Provider allowance panel in AppKit-hosted
SwiftUI windows at 960, 1180 and 1440 logical points, captured at the display's
2x backing scale. Credit balance uses the existing secondary-text treatment and
stays separate from reset grants, dollar amounts and local history.

The allowance grouping pass uses direction A with the owner's constraint to make
few changes from the current design. The two existing provider cards keep their
headings, percentage meters and controls. Labelled credit and reset-grant groups
sit below the meters; source/check details use native disclosure. Claude grant
counts stay distinct from scheduled resets, with an explicit unreported state
and a link to Claude Usage when the CLI supplies no count. Native full-window
evidence covers 960, 1180 and 1440 points, including missing and stale readings.

## Selected direction

Owner-directed StorageDaddy family fork: keep the A+C information architecture (live operations plus a policy ledger), but express it through StorageDaddy's warm black-and-mint visual language, rounded typography, fine outlines, and editorial Daddy doodles.

For the Usage landing surface, the owner initially selected **Focus Desk (direction A)** from three visual systems. The owner then specified CodeVetter Usage as the information-architecture reference, apart from ContextDaddy's colors and theme. The first scan presents both provider allowances before one unified history chart and breakdown, including Devin. The owner subsequently selected **Decision Desk (direction A)** for skills and telemetry navigation: direct Telemetry access, task-first Skills, and secondary raw Evidence. Daddy art remains.

The general usage dashboard extends the same visual direction: metric/scale/group/range controls and model/project attribution belong to the unified chart, while session-level projects and recent sessions follow the one-page scroll and evidence-chapter grammar. Live OTEL has its own destination. This is a migration of capability and information hierarchy, not a transplant of CodeVetter's visual system.

## Thesis

ContextDaddy should feel unmistakably related to StorageDaddy while solving a different job. It is a friendly local instrument rather than a generic observability console: compact and precise, but human enough to make a dense subject approachable.

## System

- Pure black canvas with thin mint-outlined surfaces and minimal elevation, matching the StorageDaddy shell.
- Mint means measured/healthy; blue means derived; amber means partial/estimated; coral means failure or disabled.
- Rounded display typography, compact monospaced paths, and the same button geometry and secondary-text tint as StorageDaddy.
- A two-column native shell with four task destinations: Usage, Skills, Projects, OpenTelemetry. A secondary Files & diagnostics control opens raw Inventory and Diagnostics without making them peer destinations. Page headings carry the fuller explanation.
- Evidence badges accompany values rather than relying on color alone.
- The inherited Daddy doodle sheet is functional art: the context-cart hero explains the product, section scenes reinforce location, and the agent scene becomes the in-app family mark.

## Signature element

Friendly artwork and hard provenance coexist. Every operational number and policy decision still carries measured, derived, estimated, partial, or unavailable evidence; expanded skill rows explain the rule and provide invocation syntax.

The owner selected **A — Skill Library** for skill management on 2026-09-26. Skills now opens a searchable library with an adjacent inspector at wide widths and a stacked layout at smaller widths. All agents and all owners are the defaults. Source paths, linked exposures, ownership, local tags, and favorites are attached to one physical definition. Overview, Content, and Access separate the key decisions. Locations explains coverage and accepts additional skill folders. Create/import, edits, local folder updates, link sharing, and archive actions have explicit previews; History offers guarded recovery. Sharing chooses an agent and global or project scope before showing the destination. Plugin/system controls remain with their owner. Remote update discovery is not claimed.

The secondary Agent policies view begins with an agent-scoped view of how skills run. Three clickable, exclusive invocation totals answer what is automatic, manual-only, or unavailable for discovery. A separate needs-review queue explicitly overlaps those statuses. The sharing strip shows whether skills are portable across all agents, several agents, or only one. Installed cache copies remain visible in rows without receiving an active-policy color.

The same destination has a Redundancy review mode rather than a sixth sidebar item. Its first scan is decision-oriented: exact-copy groups, same-name drift, likely purpose overlap, and duplicate file bytes. The default queue excludes cache-only groups, which remain available through a dedicated filter and summary count. Every row states confidence, evidence, affected agents, a keep candidate, and why no automatic deletion follows. Managed plugin caches are visibly different from owner-managed definitions, and an always-visible boundary explains that missing usage telemetry is not proof of non-use.

Project rows use the same progressive-disclosure grammar: a compact project summary expands into agent pressure cards and attributed local/inherited locations. The matching set is paginated in stable 12-row slices. Source inventory groups exposures by origin and opens text only through an explicit preview sheet.

Files & diagnostics begins with read-only configuration health. It deduplicates startup noise into root causes, distinguishes ignored file settings from broken MCP launchers, and exposes exact file/line evidence plus copyable single or all-issue remediation briefs and a coverage-aware rescan, without copying credential-bearing values or modifying configuration. Launch-time session flags are outside this file scan. A labelled configuration-issue count on the secondary control keeps unresolved health visible from every destination.

Usage follows CodeVetter's usage hierarchy while making Devin visible in the first scan: both provider allowances first, unified local history including Devin second, then selected-agent detail. Allowance checks remain manual by default; an explicit switch enables a throttled check on opening Usage. Optional Codex reset-credit dates are labelled latest reported expiry, not guaranteed final expiry. Devin joins the shared token timeline, breakdown, and agent filters by default. Its unavailable cost and project attribution are labelled within that view. The direct OpenTelemetry destination has a fixed 24-hour window, a Codex/Claude switch, agent-specific connection status, and in-app breakdowns for tokens, models, tools, MCP, skills, time, and reliability. When the collector is reachable but Claude returns no verified metrics, a dedicated unavailable state replaces empty metric cards and navigates to separate Usage history. Claude shows only verified metrics supplied by the same collector; tool/API counts remain unavailable until a safe logs/trace adapter exists. The core workflow never requires an external dashboard. Bar lengths compare values only within one card; they never imply that overlapping duration categories sum to wall time.

The Skills redundancy mode and Codex Telemetry view lead with a short read-only review queue. Skill conflicts are ranked by runtime exposure and evidence; OTEL flags failed requests, compactions, and concentrated calls only as investigation signals. Every action keeps its source, window, confidence, and limitation visible. No insight claims that missing injections mean a skill was unused or that high call volume alone was inefficient.

Usage project grouping uses a separate session ledger with Codex thread-index working directories, Grok paths, and Claude's encoded project slugs. The chart buckets whole sessions by last activity and explicitly disclaims reconciliation with daily totals; it never fabricates daily project token allocation. Model-provider grouping uses a narrow model-name classifier and retains unknown aliases. Devin's deduplicated daily tokens join model and provider totals from the other local agents; overlapping upstream Devin rows take precedence to prevent double counting.

Copy all issues produces a structured handoff for an external coding agent, including every skill finding rather than only the three preview cards. The library can make explicit, previewed changes to local skills; external-agent handoffs remain available for broader remediation. After agent work, Verify after changes rescans skill definitions: an issue is detector-cleared only when its original locations remain covered and no pair of those definitions still forms a finding. Missing locations or scan failure stay unverified. OTEL issue briefs explicitly require a comparable new window; a rolling counter dropping is not presented as proof of a fix.

## Primary risk

Dense operational information can become tiring or ambiguous. Progressive disclosure keeps the first scan compact; explanations and physical/logical paths appear only when a row is expanded.

## Interaction constraints

- Refresh is explicit and preserves the last valid inventory if a scan fails.
- Usage service, model, and range filters only affect data that supports those dimensions. Panels with a fixed 24-hour or account-level scope keep their own scope label rather than pretending to follow the filter.
- Local usage, provider allowance, and OTEL are separate ledgers; their numbers are never summed or treated as interchangeable. Local usage combines bundled offline ccusage and Devin's deduplicated index buckets, with their source provenance retained. Provider allowance makes authenticated provider calls only on explicit refresh or after the user enables a throttled automatic check.
- Search and policy filtering stay visible above the ledger.
- Redundancy search, evidence type, and agent scope stay visible above consolidation candidates; All agents is the default scope.
- Selecting an agent changes both summary counts and filters; policies from other agents remain visible for comparison.
- Project filters reset pagination and expansion; matching projects remain reachable through stable page slices. Source filters reset pagination and expansion so stale selection never points at hidden data.
- Long source groups paginate instead of silently truncating results.
- Each list destination has one vertical scroll surface. Headers, filters, results, and pagination remain reachable at the minimum window height rather than competing for a fixed-height inner list.
- Toolbars, policy grids, file rows, and telemetry panels reflow at the minimum supported window width instead of shrinking labels into clipped fragments.
- Restored windows are constrained to the current display's visible frame, including when moving between displays with different usable heights.
- Content editing changes declared skill instructions only. No generic toggle implies that ContextDaddy can change global runtime settings or plugin activation.
- Empty, partial, and unavailable states are first-class visual states.

## Skills usability correction

The owner selected A, Guided Library, for onboarding. A dismissible three-step guide explains finding a skill, inspecting agent access, and local versus plugin-owned changes. It sits beside the workspace on wide windows and above it on smaller windows, can be reopened with Guide, and never performs a skill mutation. Native titled window chrome owns the traffic-light space; the root and skill scroll viewport use explicit available dimensions. Selecting a skill brings its inspector into view, with a route back to the guide.


## Skill organization ledger (owner selected B, 2026-09-27)

Skills now uses a sortable, selectable ledger with columns for skill, location/scope, agent access, invocation, and instruction-copy count. Compact windows stack the same data into labelled rows; the existing bounded page scroll remains the only main scroll area. Search, ownership, agent, location, scope, and invocation filters compose. Selection persists across pages and filters and states that explicitly.

The change tray offers Move to folder, Share with agents, Set invocation, and Compare selected copies. Clean up duplicates in the header opens the full catalog when no rows are selected. Every operation has one configuration-and-preview sheet, a visible Apply count, per-item inclusion, and a completion or partial-failure report. History retains undo.

Cleanup requires an explicit keep-source choice for each group; there is no default canonical source that might select an archived project. Groups are paginated eight at a time. Plugin/system groups explain ownership. Full-folder comparison follows the instruction-only grouping and rejects mismatched support files or permissions. Version drift stays reviewable through Agent policies. The preview calls out location-dependent references and the future shared-edit impact before consolidation.

The visual system remains native black/mint with rounded headings, monospaced paths, amber uncertainty, and existing button geometry. Owner previews and selection are retained under artifacts/design/skill-organization. No new runtime dependencies.

## Recommended cleanup and folder context

The owner clarified that folder counts alone do not solve cleanup, then requested implementation of the described recommended-plan workflow. The new Skills entry follows that action-first hierarchy using the established native ledger and preview components: scope selector, local name/source totals, an optional collapsed agent comparison, and a paginated decision queue. It develops the cleanup-workbench direction shown in the folder-context previews; no new visual identity replaces the previously selected system.

Ready to preview, Needs a decision, Plugin ownership, and Keep independent separate verified actions from interpretation. Suggested source paths and affected agents are visible before opening a recommendation. Full-source and exposure evidence is disclosed on demand. The source library, History and refresh are reachable from the header.

Choose folder and Quick targets scope discovery to a working directory. Agent comparisons remain collapsed initially so they do not push cleanup actions below the first screen. Partial coverage is visible above totals; plugin activation remains explicitly unverified. Agent rows show distinct names and sources separately, with automatic/manual/model-only/disabled policy and overlapping review counts.

Preview sheets state the full-plan before/after projection, expose per-item inclusion and every mutation path, and keep completion or partial-failure results visible. History offers guarded restoration. Keep as-is records a reopenable review decision; unchanged source counts make clear that it did not clean up files. Unsupported plugin removal is described honestly rather than represented by an inert Apply button.

## Folder-first simplification

After the owner rejected the control-heavy interface and asked us to implement the described simplification, folder search and path entry moved directly into Skills. Cleanup proposals precede inventory totals; counts and coverage remain in a disclosure. Project files and instructions are a secondary inspector rather than a competing primary sidebar destination. Proposal rows expose source, affected agents and invocation policies before review. The existing native visual system and preview/apply/restore mechanics remain.

## Navigation correction: build 16

The approved sortable ledger is the default Skills view. A persistent segmented control names Library, Cleanup, and Agent access rather than requiring users to find differently placed return buttons. Folder scope is shared across the library, cleanup recommendations and agent access summaries; the current path remains visible. Plugin counts use plain ownership language. A source with no known route explains the uncertainty and offers sharing when locally editable.

## Final simplified interface: build 17

Owner explicitly requested one final single-screen output after approving one list and a details panel. Skills now has a compact title, folder menu, search, collapsed filters, and one list. Details sit beside the list when space permits and below it on narrow windows. Cleanup is a dialog; advanced operations and History are under More. No view-mode navigation, hero metrics, automatic onboarding cards or empty bulk-action trays appear.

## Answer-first pages (owner delegated, 2026-09-27)

The owner delegated direction selection for Skills, Agent activity and Diagnostics. The established native black/mint system stays. Skills adds a scoped location map before its ledger: each location discloses logical routes, resolved physical sources, discovered agent access and matching-instruction leads. A location filters the library and its unselected cleanup scope; exact-folder validation still gates consolidation. Route counts are not added as unique skills. Unrecognized locations and partial coverage remain explicit limitations.

Agent activity replaces the OpenTelemetry navigation label. Recent recorded runs and review signals precede collapsed measurements, source notes and interpretation details. Missing adapters are unavailable rather than zero; trace presence is not a successful outcome. Diagnostics always opens configuration health, leads with detected issues and their impact/next step, identifies scanned files, and collapses raw coverage evidence. No new telemetry adapter, memory manager or unattended cleanup is implied.

## All-agent pages (build 23)

Skills, Agent activity and Diagnostics support selecting Codex, Claude, Cursor, Devin and Grok. Activity combines existing agent-isolated indexed history with a separate metadata-only activity-file browser. It reads filenames and modification dates under known per-agent roots, excludes linked roots/descendants and irrelevant Cursor MCP/canvas directories, and reports bounded scan coverage. File writes are never claimed as task completions or token totals. Cursor billing remains in its own dashboard; no new billing or live-trace adapter is implied.

Diagnostics resolves discovered skill availability, invocation uncertainty and overlap per agent, with review briefs and navigation preserving both agent and folder scope. Codex structural startup-configuration checks remain a separately identified adapter; other agents receive clearly labeled setup investigation paths, not invented successful configuration checks. Local history, source files and live OTEL remain separate evidence categories.

## Completed local management workflows (build 25)

The library opens on current local definitions, excluding archived and installer-owned files from the default list and location map. Plugin files have a separate explicit entry, and the folder map is expandable so search and the ledger remain immediately reachable. The existing overlap/scope decision workbench is reachable from More. Cleanup snapshots its reviewed definitions; a post-apply rescan cannot change the approved count.

Diagnostics now performs bounded structural checks for all five agents: Codex/Grok MCP command references and supported Codex misplaced settings; Claude/Cursor/Devin JSON object validity and declared MCP launcher references. User files and files directly in the selected folder are identified individually as checked, absent or unverified. Linked paths and oversized/unreadable files are not parsed. Credential values, URLs, environment values and arguments never enter findings. No executable is launched and no remote server is contacted. This is not a full agent schema, connectivity, permissions or imported/managed settings validator. Repair handoffs retain the selected issues and verify the same sources.

Invocation editing supports Codex policy files, Devin triggers and shared Claude/Cursor/Grok frontmatter. The resolver follows their distinct rules: Codex ignores other agents' frontmatter invocation flags, Devin uses triggers, and Grok user-invocable=false disables both user and model visibility. A requested restriction that does not control Codex is surfaced as a policy review item with a direct filtered-library handoff. Known project paths in recorded activity can open that folder's skills for the same agent.

Evidence: full suite 117 passed after the bounded scan contention fix; subsequent focused policy/native suites passed after final changes. Native fixture cleanup applied, reduced two definitions to one source retaining Codex and Claude routes, and restored through History with both files intact. Cursor fixture diagnosis was captured, repaired and independently reported detector-cleared. Real skills and agent configuration were not changed. Live telemetry still requires an agent that emits the supported signals; local history and file metadata remain separately labeled.

## Plugin ledger (build 28)

The owner delegated design judgment after seeing three previews. The plugin ledger uses the established native visual system: one row per agent/marketplace/plugin identity, adjacent evidence inspector at wide widths, stacked detail on narrow windows. Skills → Manage plugins and More → Manage plugins both open this view.

A bounded read-only scan inventories the default Codex and Claude cache hierarchies, including plugins with no skills. It groups versions, counts skill directory names, measures regular-file bytes, and labels incomplete sizes as lower bounds. Linked directories are not traversed; dependency trees and repository internals are excluded from size measurement. Whole SKILL.md hashes identify matching local instructions without claiming complete-folder equivalence.

Claude registry version 2 supplies per-version installation references and user/project/local scopes. Missing, malformed or unsupported registry data cannot establish an unreferenced version. Codex and Claude explicit enablement declarations are shown with their source files; selected folders add ancestor/local settings. These are individual declarations, not effective activation or observed invocation. Custom homes, managed configuration, trust, profiles, runtime overrides and Cursor/Devin/Grok plugin ownership remain unresolved and are labelled.

The management sheet supplies the exact plugin identity, scope evidence, an agent-ready brief, official owner instructions and a recheck action. Disable/uninstall is performed in the owning plugin manager. ContextDaddy does not offer direct cache deletion or infer safe deletion from age, modification dates or a missing registry reference. No actual plugins were modified during this implementation.

## Completion workflows, build 30

Preserve the owner-selected sortable ledger and delegated answer-first direction. Memory uses the same black/mint hierarchy, path typography, folder/search controls, paginated list and responsive selected-document inspector. It adds no alternate visual language. Separate Memory navigation reflects the owner's later three-page structure; Skills retains invocation controls, which Memory does not imitate.

Content comparison is explicit because it reads local document bodies. Matching contents link to counterpart locations; independent scope remains a review decision. Document changes require a before/after preview, with archive consequences and guarded recovery visible. Plugin action sheets show exact owner, scope and command before applying. Activity distinguishes filtered session history from unfiltered live aggregates and gives direct folder-preserving review actions.

Responsive native renders cover 390, 768 and 1440 points. These are fixture renders, not evidence that cloud memories or unsupported agent adapters are resolved. Installed interactive checks are tracked separately in artifacts/design/complete-workflows/verification.md.

## Claude reset detail completion

Preserve the released two-provider-card composition. Within Claude Reset grants, label Full resets and 5-hour resets separately, put each reported expiry immediately below its scope, and qualify paused or currently unusable grants. Keep failed details unknown with a visible message and the existing Claude Usage handoff. Provenance and check time remain inside the source disclosure. No redemption control is introduced.
