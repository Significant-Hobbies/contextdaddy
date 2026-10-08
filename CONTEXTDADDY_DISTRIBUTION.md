ContextDaddy
============

Apple silicon Mac · macOS 14 Sonoma or later

Install
-------
Drag ContextDaddy to Applications, eject this disk image, then open the app
from Applications. ContextDaddy is a local workspace for coding-agent skills, project context,
usage history, and available OpenTelemetry signals. Skill changes are explicit,
previewed actions with recovery history.

Start with Usage for local history and provider allowance. Skills brings definitions from different directories into one library, explains
agent access, and supports local create/import, editing, folder updates, link
sharing, and recoverable archival. Plugin-managed skills remain with their owner. Projects shows
discovered context files; it does not claim those files were loaded into a
live prompt. Memory shows discovered instruction and memory files. Run telemetry
shows recorded runs and verified signals from a compatible local collector.
Missing sources are shown as unavailable, not as zero activity.

Privacy and limitations
-----------------------
The app reads bounded local metadata and configuration structure, but does not
copy prompt bodies, tool arguments, or credential values into its dashboards.
An explicit document preview opens the selected eligible text file. The
bundled ccusage helper reads local history offline. Provider allowance checks
use installed provider CLIs only when requested or after you opt in to an
automatic check; local OpenTelemetry uses a loopback collector if available.
ContextDaddy does not measure internet bandwidth, and estimated token or
project values are labelled as such. Skill and invocation-policy changes use an
explicit preview, apply and recovery path. Configuration-health discovery is
read-only. Live agent status, attention, conversations and replies belong in
Agent Inbox; measured Mac and workload diagnosis belongs in PerformanceDaddy.

ContextDaddy includes ccusage under the MIT license; its acknowledgement and
license text are in CONTEXTDADDY_NOTICES.md inside the app bundle.
