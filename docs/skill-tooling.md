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
counts distinguish Vercel-managed installs, repository-owned files, and
unresolved sources. **Review unresolved sources** filters the ledger to the
last group. The inspector exposes the source evidence for an individual skill.
Repository origin is ownership evidence, not a Vercel update record. Plugin
files stay with their agent's plugin manager. Missing tools are reported as
unavailable. The CLI report above remains useful for a separate cross-tool
installation audit and can report different counts from this folder-scoped
physical-skill view.
