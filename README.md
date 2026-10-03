# fleet-board

A Claude Code plugin that turns a GitHub issue board into a work queue for a fleet of coding agents, with hook-enforced human-QA and merge gates.

Install it from this repo's marketplace:

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

Everything else — requirements, a first-hour walkthrough, the config reference and the gates — is in the [plugin README](plugins/fleet-board/README.md).

The agents and the reporting skill were authored clean-room from behavior specs. The specs, the briefs they were written from, and the audit trail of every authoring run are in [`docs/implementation-plans/2026-09-28-fleet-board/specs/`](docs/implementation-plans/2026-09-28-fleet-board/specs/README.md).

MIT licensed.
