# ContextDaddy v1 acceptance

Issue [#1](https://github.com/Significant-Hobbies/contextdaddy/issues/1) is a
local-source milestone. Signing, release publication, provider credential
provisioning and universal vendor activation are outside its v1 contract.

## Policy and discovery

Discovery deduplicates physical definitions while retaining logical exposure
paths. Broken links remain coverage findings. Installed plugin-cache material
does not establish active exposure.

The policy resolver implements runtime-specific invocation controls, desired
versus derived defaults, exact invocation syntax, and bounded precedence:

- Ordinary Claude personal definitions are preferred over project definitions
  among discovered routes. Shadowed definitions retain their paths and an
  explanation; they do not contribute an automatic invocation reading.
- Codex definitions in qualified `.agents/skills` routes can coexist. No single
  exclusive winner is invented.
- Custom or renamed routes, project-only ambiguity, case-only collisions, and
  unqualified Cursor, Devin or Grok winner rules remain **Needs review**.
- An unreadable or oversized definition cannot establish automatic invocation.
  Claude controls that disable both model and direct-user invocation produce
  **Disabled**.

These are local evidence states. Enterprise configuration, synced skills,
session overrides and live activation require separate runtime evidence.
The qualified rules follow [Claude's skill-resolution documentation](https://code.claude.com/docs/en/skills#resolve-skills-that-share-a-name)
and [Codex's local skill documentation](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills).

## Redundancy review

Exact copies use bounded whole-document SHA-256. Same-name drift requires
different readable content and overlapping runtime exposure. Differently named
purpose overlap is a heuristic lead, not an instruction to merge. Enumeration
order cannot change the nominated keep candidate.

The default queue excludes cache-only findings. Candidate bytes are duplicated
local file bytes, not context-token savings or physically reclaimed storage.
Missing activation telemetry never establishes that a skill is unused.
Redundancy Review makes no changes. The separately approved skill-management
workflow requires explicit previews and recovery for supported local changes.

## Reproducible checks

```sh
swift test --filter 'SkillPolicyResolverTests|SkillPrecedenceTests|SkillRedundancyAnalyzerTests|IssueOneAcceptanceTests'
swift test --skip DesignSnapshotTests
swift build -c release
```

`IssueOneAcceptanceTests` renders the complete native shell at the supported
minimum, standard and wide window sizes. It exercises the single scroll
surface, separate managed-cache filter, handoff's still-detected result, and
empty state with synthetic records. Captures are local under
`artifacts/design/issue-1/`; they contain no private skill inventory.
`DesignSnapshotTests` is the existing machine-inventory suite, excluded by CI;
the portable acceptance suite replaces it for this bounded issue review.
Release builds and native fixture renders are separate from installed-app,
published-binary and real-vendor acceptance.

On 5 October 2026, the focused policy/precedence/redundancy suite passed 24
core tests and the new native acceptance test. The CI-equivalent Swift suite
passed with its existing opt-in screenshot skip, and the optimized release
build passed. Tests ran with private agent and credential roots blocked.
Fleet's v2 preserve preflight and completion checks passed using the local
`.fleet/design-review-issue-1.json` receipt. Direct rendered review corrected
truncated mode labels and evidence descriptions; it is not owner acceptance.

The real landing download supplied public 0.2.6 build 16. Its SHA-256 matched
`site/release.json`; code-signature verification and Gatekeeper's notarized
Developer ID assessment passed. The read-only mounted app opened Skills and
Access, and Tab reached the search field. Provider checks remained off and
credential roots were blocked. The app was quit and the volume ejected;
no installed app was replaced. That public build's source is
`437c7b8b50fb4b10ae8d7bc0ba1ad14b338b455c`, separate from this source review.

## Branch reconciliation

The 5 October review began at current GitHub `main`
`86b1c17ce7bf22752a1c4097fd1ffbdeda5d39de`. No PRs were open. The workflow-sources,
allowance, Claude-grant and Codex-credit branches have patch-equivalent changes
already on main; PR #12 supplies the existing precedence resolver.

`codex/daddy-visual-core-20260926` contains three unmerged menu-bar/visual-core
commits outside issue #1. The image-optimization branch belongs to closed PR #2.
The sweep branches retain old inherited StorageDaddy history and are not v1
implementation sources. No branch was deleted or merged during this audit.
The original checkout's uncommitted allowance work was preserved.
