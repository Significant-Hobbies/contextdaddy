# External skill tooling

ContextDaddy should present and reconcile existing tools' evidence rather than
create a competing installer, registry, or updater.

## Credits and ownership

- [Vercel skills](https://github.com/vercel-labs/skills): repository installs,
  agent targeting, source records, and updates. The audit uses version 1.7.0's
  `list --json` interface and disables its telemetry for these calls.
- [Agent Skill Manager (ASM)](https://github.com/luongnv89/agent-skill-manager):
  cross-tool inventory and audit findings. ASM remains an external prerequisite.
- Agent-native plugin managers: authoritative plugin lifecycle operations.
  Marketplace files alone do not establish that a plugin is installed or enabled.

## First integration: source audit

```sh
python3 scripts/audit-skill-sources.py --folder /path/to/workspace \
  --output artifacts/skill-sources/report.json
```

The script calls ASM and skills inventory commands, joins their records by
resolved path, and attaches global lockfile paths/hashes only when the canonical
install path and repository also agree. It does not alter either tool's records
or skill installations. npm can populate its package cache.

Reported states:

- **Recorded GitHub source:** reported by skills inventory; not a fresh integrity
  check. Local edits and upstream revisions still require comparison.
- **Verified GitHub source:** a local receipt ties the SHA-256 of `SKILL.md` to
  a repository and a checked revision. A changed file returns to unresolved.
- **Installed tool source:** the installed CLI or app supplies the skill itself;
  attribution need not claim a public GitHub repository.
- **Plugin-owned:** preserve the plugin owner. A GitHub URL may remain unknown;
  do not turn these files into independently managed skills.
- **Source unresolved:** insufficient evidence. May be locally authored,
  untracked external, or intentionally adapted. Do not infer from names.

Counts represent ASM installation entries, including plugin bundles and
marketplace artifacts. They are not unique capabilities or per-session context.
ASM may omit parent-directory skills when launched in a child project.

## Update boundary

Observed locally: `npx skills@1.7.0 check` updated Humanizer. Do not use that
command as a read-only check. `asm outdated` reported no installs despite its
inventory finding skills; it is not an updater for all discovered files.

Before enabling app update actions, verify the selected tool version's mutation
semantics, capture local changes, and provide recovery. The native Skills page
has an **Audit sources** action for the selected folder. It reads ASM and
Vercel skills inventories once, matches physical paths, and marks local skill
files tracked in a Git repository with a safe GitHub origin. The resulting
counts distinguish Vercel-managed installs, repository-owned files, verified
sources, tool-owned files, and unresolved sources. **Review unresolved sources**
filters the ledger to the last group. The inspector exposes the source evidence
for an individual skill.
Repository origin is ownership evidence, not a Vercel update record. Plugin
files stay with their agent's plugin manager. Missing tools are reported as
unavailable. The CLI report above remains useful for a separate cross-tool
installation audit and can report different counts from this folder-scoped
physical-skill view.

## Local receipts for imports without installer history

The native audit also reads
`~/Library/Application Support/ContextDaddy/skill-source-receipts.json`.
It is a machine-local, read-only attribution file; ContextDaddy does not write
to the Vercel skills lockfile or take over updates. The schema is:

```json
{
  "schema": 1,
  "sources": [{
    "repository": "https://github.com/owner/repo",
    "revision": "checked commit or tag",
    "evidence": "Exact SKILL.md, or instruction body match with local frontmatter changes",
    "digests": ["64-character SHA-256 of installed SKILL.md"]
  }]
}
```

Repository URLs must be plain HTTPS GitHub repository roots. A receipt only
applies while its installed file's digest still matches. This proves the
recorded comparison, not the integrity of every support file or an update path.
For a CLI-bundled skill, set `"sourceType": "tool"` and `"owner"` to the CLI
name, and omit `repository`; the same digest and revision rules apply.
The current Mac has 29 such receipts across 10 sources: [K-Dense AI scientific
skills](https://github.com/K-Dense-AI/scientific-agent-skills),
[Archify](https://github.com/tt-a1i/archify),
[Impeccable](https://github.com/pbakaus/impeccable),
[Graphify](https://github.com/Graphify-Labs/graphify),
[Swift iOS Skills](https://github.com/dpearson2699/swift-ios-skills),
[Preline](https://github.com/htmlstreamofficial/preline),
[XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP),
[Sentry CLI](https://github.com/getsentry/cli),
[Transitions.dev](https://github.com/Jakubantalik/transitions.dev), and
[Terminal Browser](https://github.com/zenbu-labs/terminal-browser).
The Terminal Browser files are attributed to their installed owning app;
they were not compared against repository skill files.
One additional receipt attributes `yukon-cli` to the installed Yukon CLI:
`yukon skill` exactly matches the installed file at v2026.09.23-3. No public
GitHub repository is asserted for it.
