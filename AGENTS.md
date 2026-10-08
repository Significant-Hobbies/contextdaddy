# ContextDaddy ownership

Read `PRODUCT.md` before changing product scope. ContextDaddy owns skills,
plugins, MCP structural health, instruction/memory scope, persistent invocation
and skill-access policy, token history, provider allowance and run telemetry.

Agent Inbox owns live thread status, the agent-status battery, attention,
conversation linking, replies and individual permission requests. Do not add
conversation resuming, reply transport or permission approval to ContextDaddy.
Inbox execution modes govern only its own explicitly started runs.

PerformanceDaddy owns measured Mac/workload diagnosis, process attribution,
device battery/power and comparable captures. Consumption telemetry does not
prove a bottleneck, task success or a need for a reply.

Preserve provenance and unavailable states. Keep discovery read-only; policy
and context changes require the existing explicit preview/apply/recovery path.
Use XcodeBuildMCP for native build/test/run verification, focused checks first.
Do not commit, push, sign, package or release without explicit owner instruction.
