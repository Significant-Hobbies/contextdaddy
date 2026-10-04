# Remaining branch reconciliation

Issue #1 was completed in PR #18, main commit
`daa6837a52551bce9bbd1da81fc0aa7867d3ff49`. This follow-up tracks issue #19.

## Allowance checkout

The original `codex/contextdaddy-workflow-sources` checkout is preserved. Its
uncommitted Codex credit fields/parser, provider-card grouping, reset labels
and focused tests are already on main. Main also contains its untracked
`UsageAllowanceViewTests.swift` cases plus newer Claude grant tests. The
remaining differences against main remove newer grant support or the issue #1
acceptance documentation. They are stale source differences, not additional
features to transplant. No private `.wrangler`, environment or config artifacts
were copied.

## Menu-bar branch

The three commits on `codex/daddy-visual-core-20260926` were reviewed against
current main. The owner selected **A — Native command menu** from three rendered
concepts on 5 October 2026. The integration preserves current window styling
and the exact existing palette/control geometry.

| Branch content | Resolution |
| --- | --- |
| Shared Daddy palette and control style | Reused without changing existing colors or control geometry. |
| Persistent menu-bar access | Native menu with status, last successful local refresh, Open, Refresh Local Context and Quit. |
| Local refresh action | Uses the context-only skill-library scan; it does not start allowance, usage-history or telemetry checks. |
| Quit review | Reviews active model-owned context, usage, activity, telemetry and allowance work. Closing the main window keeps the menu available. |
| Older CI pin | Excluded; current immutable tooling pin retained. |
| Unused completion notifications | Excluded; no notification permission or new feature introduced. |

The original branch is retained as historical source. It is superseded by this
reviewed integration, rather than merged wholesale over newer main behavior.
Other patch-equivalent allowance/workflow branches and inherited sweep histories
were retained. No branch deletion or original-checkout reset was performed.

## Qualification boundary

Focused model tests qualify not-yet-scanned, running, failed and ready status,
retention of the last successful refresh after failure, context-only refresh,
and quit-review coverage for model-owned work. Full Swift tests use the existing
CI exclusion of machine-inventory snapshots. Native source fixtures and an
optimized release build are separate from a signed, published or installed
release. The interactive menu fixture uses the same current menu/window code
with synthetic delayed discovery and automatic allowance checks disabled; it
cannot establish real vendor activation or provider availability.

Rendered concepts, owner selection and private local review evidence live in
`artifacts/design/menu-reconciliation/`; the Fleet v2 receipt is
`.fleet/design-review-menu.json`. No deployment, release, or installed-app
replacement is part of this reconciliation.

On 5 October 2026, 26 native/model tests and 138 core tests passed; the existing
opt-in snapshot test was skipped. The optimized build and Fleet v2 preflight
and completion gates passed. Interactive fixture checks verified Open, closing
the main window, duplicate-refresh disabling, retained last-success time,
Keep Running and Quit Anyway. The automation tool could not inspect the native
status item without an open window, so a test-only window exposed the unchanged
menu body for command checks. It is excluded from production. The original
installed app remained running throughout; final status-item geometry, real
provider availability and a published binary remain separate qualification.
