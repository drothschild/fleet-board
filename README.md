# fleet-board

A Claude Code plugin that turns a GitHub issue board into a work queue for a fleet of coding agents, with hook-enforced human-QA and merge gates.

Install it from this repo's marketplace:

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

Everything else is in the [plugin README](plugins/fleet-board/README.md): requirements, a first-hour walkthrough on a fresh repo, [adding fleet-board to an existing project](plugins/fleet-board/README.md#adding-fleet-board-to-an-existing-project), the config reference and the gates.

## How the agents were written

The four agents (manager, implementor, reviewer, fixer) and four of the five skills (`reporting`, `tick`, `run`, `status`) were written **clean-room**. Here, that means the model that wrote each file could see only a written description of what the file must do, never another plugin's prompts or code.

How it was done:

- **Behavior specs first.** Each file has a spec saying what the agent or skill must do. The specs were written from a short brief, the design document and the notes of the process as it was first run by hand.
- **One isolated run per file.** Each spec and each prompt file was produced by its own `claude -p --bare` run, started with an empty Claude config directory so that no installed plugins, skills or personal instructions were loaded. Each run could read only its inputs: a prompt file could read its spec, and nothing else.
- **Every run checked.** Each run's startup record was checked to confirm that only Claude Code's built-in plugins were present, and that the run read and wrote only the files it was allowed to.
- **Changes the same way.** Later fixes did not regenerate the files. An isolated run edited the existing file in place, and the diff was checked to touch only the intended lines.

Why bother: the test-first, adversarial-review process fleet-board encodes is common practice, and other plugins encode similar processes. Writing the prompts from specs, in sessions that couldn't see any of that material, keeps fleet-board's prompts its own work rather than a derivative of someone else's.

None of this is needed to use the plugin. For checking it, the specs, the briefs they were written from, and a record of every authoring run (inputs, isolation checks, costs and file hashes) are in [`docs/implementation-plans/2026-09-28-fleet-board/specs/`](docs/implementation-plans/2026-09-28-fleet-board/specs/README.md). The `init` skill and the shell scripts were written directly and are not part of that record.

MIT licensed.
