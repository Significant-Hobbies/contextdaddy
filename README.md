# ContextDaddy

ContextDaddy is a local-first macOS control plane for coding-agent context. It answers two questions without reading secrets or capturing prompt bodies:

1. Which skills can Codex, Claude, Cursor, Devin, and Grok discover, and how can each runtime invoke them?
2. What are those agents consuming in context tokens, logical network events, and tool calls when trustworthy local telemetry exists?

The app combines a focused usage desk with a unified skill library and agent-policy inspector. Every value is labelled as measured, derived, estimated, partial, or unavailable. Missing instrumentation stays missing; ContextDaddy does not manufacture precision.

The primary navigation is **Usage**, **Skills**, **Projects**, and **OpenTelemetry**. **Files & diagnostics** is a secondary, always-visible route to raw source inventory and configuration checks. Skills explains how each agent can use a skill; Projects shows discovered files rather than claiming they entered a live prompt. OpenTelemetry is directly reachable and uses a separate fixed 24-hour window.

## Current milestone

- Bounded discovery for global and project skill roots across five agent runtimes.
- Physical-skill deduplication with every logical exposure retained.
- Project catalog with per-agent startup-context estimates, pressure bands, and global/parent/local attribution.
- Full source inventory with provider, kind, and scope filters; deterministic sorting; and paginated drill-down.
- Safe on-demand previews for eligible instruction, skill, rule, and agent-definition text (256 KiB maximum).
- Persisted custom discovery roots, explicit scan limits, and previous-result preservation during refresh.
- Portable frontmatter policy plus Codex `agents/openai.yaml` policy resolution.
- Agent-scoped governance totals and filters for automatic, manual-only, model-only, disabled, not-exposed, and review-needed skills.
- Cross-agent sharing coverage that separates all-agent, multi-agent, single-agent, and same-runtime definition conflicts.
- Exact manual invocation syntax for non-auto skills, with copy actions and expected exposure-root guidance.
- Installed plugin caches remain inventory evidence but do not count as active runtime exposure.
- Read-only redundancy review for exact copies, same-name version drift, and likely purpose overlap, with confidence, evidence, affected agents, deterministic keep candidates, and a separate managed-cache queue.
- Duplicate-byte estimates cover exact local file copies only; the app does not claim context savings or infer that an unobserved skill is unused.
- In-app local telemetry for Prometheus metrics and Tempo sessions, with no external dashboard required for the core workflow.
- Usage first scan shows side-by-side Codex/Claude allowance followed by one local history chart including Devin. The historical chart has shared agent filters, model/model-provider/project grouping where supported, range, day/week/month scale, generated/cache/cost metrics where available, selectable periods and exact breakdown. Model, project, and session drill-downs remain below. Cache reads, generated tokens, and estimated cost stay separate; unpriced models are flagged.
- Skills can run an explicit, read-only **Read local history** scan. Claude and Devin `skill` tool calls are counted separately from Cursor/Grok skill-file reads and Codex tool calls that reference a `SKILL.md` path. The library shows last-seen dates, agent and folder evidence, 30/90-day or all-history windows, and an evidence-only filter. Cursor dates use transcript modification time because its records lack event timestamps. Name-only tool calls cannot identify a particular same-name copy; no recorded event never means unused. This backfill is held in memory for the app session and does not automatically remove skills.
- Project grouping is a separately labelled session ledger, joining ccusage session IDs to Codex's read-only thread-index `cwd`, Grok's project paths, and Claude's encoded project slugs. It queries only Codex rollout path and working directory metadata, never prompt bodies. Buckets use session last activity, not an invented daily allocation; totals may not reconcile to daily accounting. Missing session identity remains **Unattributed**. Model-provider labels are inferred from reported model names, not billing endpoints; unknown aliases remain unknown. Devin's indexed daily tokens participate in the shared model and provider grouping; project attribution remains unavailable.
- Provider allowance for Codex and Claude is fetched on **Check both allowances**, or on opening Usage after the user enables the opt-in automatic switch (at most once per 15 minutes). It is never added to local token history. Codex's reported credit balance appears in credit units, separately from full-reset grants; unlimited, unavailable, and unreported balances remain explicit. Codex reset-credit expiry is shown only when reported; detail rows may be capped. Claude's available usage-reset count is shown when its CLI emits a limit-reset notice; absent counts are explicitly not reported, never assumed to be zero. These grants are separate from paid usage credits and may cover only particular limits. ContextDaddy only reads the notices and never invokes `/limit-reset` or consumes a grant.
- Skills and OTEL review panels can **Copy all issues** into an agent-ready brief with IDs, evidence, source scope, and verification limits. After skill edits, **Verify after changes** rescans and distinguishes detector-cleared, still-detected, and unverified findings. The library supports previewed local skill edits with recovery; OTEL signals need a new comparable observation window.
- Files & diagnostics configuration findings have the same copy-all and rescan handoff without copying configuration values or modifying files. This file audit detects the two misplaced `otel.*` keys but cannot detect launch-time `session-flags.token_budget`; that warning must be traced to the launcher supplying the flag.
- Cursor remains inventory-only for usage until a verified source exists.
- Derived 24-hour Codex total-token, model, token-component, tool, MCP, API-error, compaction, and operation-time range estimates. Claude Code's documented OTLP token, model, session-start, and estimated-cost metrics are mapped separately when the local collector receives them. A reachable collector without verified Claude samples displays an explicit unavailable state and a route to separate Usage history rather than a grid of dashes; Claude tool/API event counts remain unavailable without a verified logs/trace adapter.
- Recent Tempo session roots with trace IDs, start times, end-to-end durations, and span counts.
- Native named-skill injection evidence with explicit/implicit mode and status; injection is not presented as proof of successful execution.
- Explicitly unavailable bandwidth bytes and partial Cursor/Devin telemetry. Devin's indexed local history is not labelled live OTEL.
- Read-only configuration health for ignored Codex settings and enabled MCP launch commands that cannot resolve, with deduplicated file/line evidence and remediation.
- No automatic configuration writes, prompt bodies, responses, tool arguments, or results.

## Skill management

Skills opens **Library**: search names, descriptions, paths, agents, and app-local tags; filter by agent, owner, or location; favorite frequently used definitions. A physical skill appears once, with every discovered link and policy attached to it. **Agent policies** and **Review duplicates** retain the existing evidence views.

- **Add skill** creates a definition or imports one local skill folder, including its support files. Add search locations for skills outside the known agent roots.
- **Overview** shows the physical source, ownership, and logical exposures. **Content** explicitly reads SKILL.md and supports editing local definitions. **Access** explains each agent's effective policy and invocation syntax.
- **Share** chooses an agent and a global/project scope, then previews a directory link. Existing destinations are never overwritten. Discovery does not prove runtime activation.
- **Update from folder** previews replacement content and a file-change manifest, retaining the previous folder. Remote repositories are not fetched or checked for updates.
- **Archive** moves a local skill into recovery storage. Linked exposures stop resolving until restored. Removing an exposure moves only that directory link.
- **History** stores change receipts and recoverable originals under `~/Library/Application Support/ContextDaddy/SkillHistory`. Restore rejects newer content edits and occupied original destinations. Incomplete operations remain visible for inspection.

Plugin/system definitions are read-only in this workflow and identify their owning mechanism. Imports never execute scripts; protected configuration files and symlinks inside a skill folder are rejected. Management is bounded to 2,000 entries and 16 MiB per skill folder, with a 256 KiB document editing limit. This feature does not modify global agent configuration or claim automatic upstream update detection.

## Run locally

```sh
swift run ContextDaddy
```

The app requires macOS 14 or newer. Its Codex adapter reads the loopback-only local telemetry stack and renders Prometheus metrics and Tempo sessions inside ContextDaddy. A separate Claude adapter reads Claude Code metrics from the same local Prometheus path only if Claude exports to that collector; ContextDaddy does not enable or reroute Claude telemetry. The rest of the product still works when either source is absent or partial.

ContextDaddy runs [ccusage](https://github.com/ccusage/ccusage) 20.0.24 directly in offline mode for local history. The packaged app carries its own pinned helper and [MIT acknowledgement](CONTEXTDADDY_NOTICES.md); no CodeVetter installation or CLI is needed at runtime. A **Refresh history** action rescans local logs. **Check allowance** separately calls Codex app-server and Claude Code `/usage` through their installed CLIs; opt-in automatic checking uses the same adapters with a 15-minute minimum interval. These readings are not ccusage totals.

The general usage dashboard lives in ContextDaddy's Focus Desk. Devin's distinct indexed history comes from a bounded, read-only scan of the Devin CLI SQLite session index, separate from ccusage. It deduplicates repeated assistant message IDs and reports daily token classes and models for each range. Devin is included by default in Historical usage and can be filtered with the other agent chips. Devin cost remains explicitly unavailable until a provider-verified rate source exists; a missing or unreadable index is never presented as zero usage.

To create the local `.app` after a build, run `python3 scripts/package-contextdaddy.py --ccusage /path/to/ccusage`. The packager verifies the exact 20.0.24 helper, copies it into ContextDaddy's bundle, and selects the newest available release or debug executable so an older build product cannot silently replace the interface. A matching helper already installed in a standard command location is detected automatically; CodeVetter is not searched.

For a public download, use `scripts/release-contextdaddy.py` only after building the release executable. It requires an installed Developer ID Application identity, either an existing notarization Keychain profile or an App Store Connect API key, an explicit ccusage 20.0.24 path, and explicit version, build, and source SHA. It creates a new, isolated signed and notarized DMG with a checksum and receipt; it does not publish anything. The protected GitHub workflow is dispatched manually with a tag at the current `main` commit. It recovers the pinned helper from the checksum-verified prior public DMG, signs and notarizes the new build, deploys the qualified DMG to the app-owned Worker, verifies the live download bytes, and creates the GitHub release. The `production-release` environment holds the signing, notary, and Cloudflare inputs. Ordinary pushes run candidate CI only. Installed-app acceptance remains a separate check. StorageDaddy's separate release tooling does not apply to ContextDaddy.

## Architecture

- `Sources/ContextCore`: bounded discovery, policy normalization, redundancy analysis, evidence models, separate read-only Codex/Claude telemetry mapping, direct ccusage history, and opt-in provider allowance adapters.
- `Sources/ContextDaddy`: native SwiftUI shell, Usage, skill access, project context, direct OpenTelemetry view, and secondary files/diagnostics browser.
- `Tests/ContextCoreTests`: policy, discovery, grouping, sorting, and safe document-reading behavior.
- `Tests/ContextDaddyTests`: application-model behavior.

ContextDaddy was extracted from StorageDaddy's MIT-licensed context work, with the product attribution retained. Its public source snapshot excludes inherited storage, cleanup, website, and release code. No StorageDaddy working tree was modified.

## Privacy boundary

ContextDaddy inspects well-known agent roots and opens at most 64 KiB of each `SKILL.md` to parse frontmatter and compute a one-way SHA-256 fingerprint; it does not retain or display the skill body during discovery. Other eligible document bodies open only after an explicit Preview action, through a guarded regular-file reader capped at 256 KiB, and MCP configuration bodies are never previewed. Configuration health reads only bounded structural fields and ignores credential, header, environment, and MCP argument values. It skips secret-shaped and generated directories during discovery. The explicit skill-history scan reads local transcript records, extracts structured skill tool calls and file-path evidence, and retains only names, agents, session keys, dates, project paths, and evidence classes in memory; prompt, response, and command bodies are discarded. Telemetry is fetched from a loopback-only local stack whose collector removes prompt, response, command, argument, result, account, and host fields before persistence. Offline ccusage history remains in memory for the current app session. ContextDaddy performs no config writes and makes no claim about exact internet bytes without a dedicated sensor.

## Status

ContextDaddy 0.1.0 is a public early-access beta: a signed, notarized and stapled Apple-silicon build for macOS 14 or later, distributed from [context.daddyrad.com](https://context.daddyrad.com/download). There is no automatic updater yet; new builds are manual downloads.
