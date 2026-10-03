# ContextDaddy product contract

## Purpose

ContextDaddy helps developers who use multiple coding agents understand and govern what each agent can see, invoke, and consume by combining bounded local skill/context discovery with redacted, provenance-aware run telemetry.

## Audience and job

The primary user is a developer running Codex, Claude, Cursor, Devin, or Grok on a Mac. They need to diagnose a live agent's consumption and audit skill invocation policy without manually tracing symlinks, frontmatter, runtime-specific config, and telemetry dashboards.

## Product promises

- One physical skill is one ledger record, even when it has many logical exposures.
- The primary navigation follows user decisions: Usage, Skills, and OpenTelemetry. Project files and instructions remain a secondary inspector; working-folder selection lives directly in Skills. Raw source files and configuration diagnostics remain available as secondary Files & diagnostics, not competing representations of skills.
- Policy is runtime-specific and explains whether it is explicit or derived.
- Non-auto skills show how to invoke them.
- One selected-agent skill-access view makes automatic, manual-only, model-only, disabled, undiscoverable, and review-needed policy directly filterable.
- Installed cache evidence never masquerades as active runtime exposure.
- Same-name definitions count as a conflict only when their active runtime exposure overlaps.
- Redundancy review separates byte-identical copies, same-name version drift, and heuristic purpose overlap instead of treating every name collision as the same problem.
- Skill and OTEL review signals rank evidence, limits, and a safe next action; high call volume and compactions are investigation prompts, not proven waste or causal attribution.
- Every actionable skill finding and OTEL review signal can be copied as an agent-ready brief. Skill follow-up rescans the same definition locations and reports detector-cleared, still detected, or unverified separately; OTEL improvements need a comparable fresh observation window.
- Every consolidation candidate exposes its confidence, evidence, affected runtimes, physical definitions, managed-cache boundary, and deterministic keep candidate.
- Cache-only duplication is counted separately and excluded from the default review queue so managed installation artifacts do not drown out owner-actionable findings.
- Duplicate savings mean local file bytes only. Context savings are not inferred, and absent activation telemetry never means unused.
- Project context distinguishes global, inherited, local, conditional, and installed-only evidence.
- Context-size estimates remain visibly approximate and never masquerade as live prompt measurements.
- Every source can be traced back to its logical path and, when linked, its physical path.
- Every usage value states its provenance.
- Local agent-log history, provider allowance, and OTEL activity are distinct ledgers; neither quotas nor overlapping telemetry are added to token history.
- Historical usage can be inspected by service, observed model or inferred model provider, time range, metric, and day/week/month scale. Model and provider mix comes from daily accounting. Project grouping and recent activity use separately labelled, verified session identities and may not reconcile to daily totals. Devin's indexed daily tokens join the same model and provider history, with a shared agent filter; cost and project attribution remain unavailable.
- ccusage history is read directly and offline; CodeVetter is not a runtime dependency. Provider allowance has a manual check and an opt-in, throttled check on opening Usage. Devin's indexed daily tokens join local history independently of ccusage availability. Unavailable history is explicitly labelled.
- Codex full-reset credit expiry is shown only when the provider returns detail rows, and is labelled the latest reported expiry because the provider may cap those rows.
- Claude full and 5-hour reset grants are scoped read-only usage readings, separate from scheduled reset times and paid credits. Grant expiry and paused/unusable states remain explicit; unavailable or unsupported responses never imply zero. The existing default Claude Code credential is read only during manual or opted-in allowance checks, without credential writes, refreshes or reset redemption.
- OTEL sessions, tools, models, tokens, compactions, errors, and named skill injections remain distinct signals instead of being flattened into one activity score.
- OTEL is directly reachable and reports a disconnected local source as unavailable, never as zero activity.
- Overlapping operation durations are never added together as wall time.
- Discovery is read-only. Skill changes require an explicit preview and apply action; edits, local imports/updates, sharing links, and archival retain recovery evidence.
- Skills opens one sortable library with folder selection, search and a selected-skill inspector. Cleanup opens as a dialog; agent access is part of the selected skill.
- Local skill names, physical sources, agent routes, archived copies and installer-owned definitions are distinct counts. Names do not establish equivalent capabilities, and the 100–200 curation target never causes automatic retirement.
- Folder context uses a targeted scan of global roots and the selected directory's ancestors, excluding sibling/descendant projects and cache-only material. Policies are resolved after scoping; multiple applicable aliases remain attached to one physical source. Per-agent counts are discovery evidence, with partial coverage and unverified activation shown explicitly.
- Cleanup separates verified whole-folder consolidation, decisions about purpose/version overlap or global links, independent project copies, and plugin ownership. Different versions in non-overlapping project scopes are not treated as competing installations.
- A recommended source is proposed for matching local copies. The owner accepts its destination and impact in a preview before applying. Consolidation cannot make an independent checkout depend on an external source.
- Scope cleanup removes only explicitly previewed global directory links where a project route for the same provider already exists. It preserves the physical source and project routes, and explains loss of availability elsewhere. Moving a source alone does not narrow access.
- Purpose overlap is a review lead, not a semantic merge. The owner can compare sources, preview archiving a chosen local source, or keep the workflows separate. Kept decisions are reversible app-local review state and never count as removed skills.
- Skills opens one searchable library across physical definitions, logical exposures, agents, and ownership. Favorites and tags are app-local organization.
- Skills provides a sortable ledger for physical location and scope, discovered agent access, and per-agent invocation. Mixed policies and unverified activation remain distinct.
- Bulk move, share, invocation, and cleanup actions prepare per-item previews. Moves leave a forwarding link at the original route; consolidation archives a whole-folder-identical copy and replaces it with a link to an explicitly selected source.
- Cleanup compares complete regular-file contents, folder structure, and permissions, and revalidates both folders before applying. Different versions are reviewed separately. Plugin/system caches and protected files are not changed.
- Codex invocation uses the skill-local policy file; Claude/Cursor changes use shared frontmatter and explain cross-agent impact. Unsupported or ambiguous policy edits are declined.
- Bulk apply stops on the first failure, reports the completed count, and retains individual recovery receipts. Each mutation is serialized; a batch is not an all-or-nothing transaction.
- Added skill directories extend bounded discovery without automatically granting an agent access. Recognized agent roots retain their scope and policy evidence.
- Plugin and system definitions are managed by their owner. ContextDaddy does not rewrite their caches or execute imported scripts.
- Whole-folder local updates preserve support files and executable permissions. Conflicting destinations, stale previews, symlinked sources, oversized folders, and protected configuration files are rejected.
- History persists intent before mutation and marks incomplete operations; restoration refuses to overwrite subsequent content edits.
- Unknown or unsupported data remains visible as unavailable.
- Ignored agent settings and enabled MCP launchers that cannot resolve are surfaced once per root cause with file/line evidence and read-only remediation.

## Non-goals for v1

- Silently editing agent configuration; configuration health remains advisory and read-only.
- Capturing prompts, responses, tool arguments, or tool results.
- Acting as a TLS proxy or privileged network extension.
- Claiming exact bandwidth from logical request counters.
- Replacing the existing Codex OTEL stack.
- Treating skill injection as proof that a skill executed successfully or caused an outcome.
- Shipping, notarizing, or distributing before local behavior is proven.
- Reading document bodies during background discovery; previews are explicit, bounded user actions.
- Retaining or displaying config credentials, headers, environment values, MCP arguments, or unrelated configuration bodies; health checks inspect only bounded structural fields.
- Unattended deletion, merging, linking, or rewriting of skills based only on redundancy analysis. Cleanup requires a reviewable source recommendation or explicit source choice, whole-folder verification for consolidation, preview, and apply.

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

## Memory, activity answers and owner actions (build 30)

Memory is a first-class sidebar destination using the approved sortable-ledger direction. It separates instructions/rules from saved-memory stores; supports folder paths, folder browsing, agent/type/search filters, largest-first ordering, explicit bounded content comparison, and exact-copy counterpart navigation. Selected documents can be viewed, edited or archived with a preview, private recovery history, stale-file checks, permission preservation and guarded restore. Codex agent-owned memory stays read-only; no real user memories were automatically rewritten. Default Claude and Codex stores are metadata-indexed; custom roots, cloud memory, imports, managed policies and cross-agent AGENTS loading remain unverified. Claude project-store names are not reverse-decoded into assumed folder ownership.

Activity opens with what happened, what used tokens, and what to review. Agent-isolated session history has a last-activity window and exact folder/descendant matching, excluding unknown attribution when a filter requires it. Token totals are explicitly session-lifetime totals, not period consumption or context-window occupancy. Largest sessions link to Memory and Skills with their folder. Missing indexes and refresh errors remain visible. Live telemetry is separately scoped to its existing aggregate window; history filters do not pretend to filter telemetry.

Plugin management now previews allowlisted owner-CLI commands in the app. Claude supports enable, disable and uninstall for verified user/project/local registrations; uninstall preserves plugin data and never requests dependency pruning. Codex supports removal only when a user-scope declaration is verified. Enablement remains in Codex settings because this installed CLI exposes no persistent enable/disable command. Managed or unknown registrations remain read-only. Actions recheck evidence before launch, discard raw process output, time out after 45 seconds, persist receipts, then rescan to distinguish command completion from verified local state. No real plugin action was executed during development; a disposable owner-CLI fixture exercised the command path.
