# Spec brief: run skill

You are writing the behavior specification for the fleet-board **run** skill. fleet-board is a Claude Code plugin: a manager agent moves cards (GitHub issues) across a board and dispatches three role agents (implementor, reviewer, fixer) to do the work in git worktrees. The design document describes it. A **tick** is one run of the manager: it advances every open card one step and returns a tick report whose last line is exactly `dispatchable: true` or `dispatchable: false`. The plugin has four user-invocable skills: `init` (setup, already written), `tick`, `run` and `status`, reachable as `/fleet-board:<name>`.

## Sections the spec must have, in this order

1. **Purpose** — one short paragraph.
2. **Trigger** — when Claude should select this skill, as the requirements for the skill's frontmatter `description` (below), followed by one proposed description text (at most 900 characters) that meets them. The description is the only text Claude matches on when deciding whether to use the skill.
3. **Inputs** — what the skill has at hand: the user's request, the skill's base directory (announced by the Skill tool when the skill loads), the current repository.
4. **Required behavior** — a numbered list. Every item is testable: it names an observable result (a command run, a line printed, an agent dispatched with a given `subagent_type` and `model`, a stop), not an intention.
5. **Must never** — a bullet list of prohibitions.
6. **Output** — exactly what the skill prints.
7. **Acceptance criteria** — the AC ids listed in this brief, each with its text as given below, or "None directly" when the brief lists none.

Every requirement listed in this brief must appear in the spec. You may add behavior from the design document when it is consistent with this brief; the brief wins on any conflict. Describe behavior, not prompt wording. Cite no sources, name no third-party plugin, include no URL.

## Facts every fleet-board skill spec carries

- **Locating scripts.** The plugin's scripts live at `<this skill's base directory>/../../scripts/`. The skill substitutes the real base directory that the Skill tool announced; it never guesses or writes down an install path. An absolute scripts dir is `cd "<base directory>/../../scripts" && pwd`.
- **Config.** `bash "<base directory>/../../scripts/config.sh"`, run in the user's repository, prints the merged config as JSON. `config.sh <KEY>` (for example `config.sh limits.tick_interval`) prints one value. Exit codes: 0 ok; 3 no `.fleet-board.yml` (fleet-board is not set up in this repo); 4 YAML outside the supported subset; 5 invalid values; 2 usage error.
- **No setup, no work.** In a repository with no `.fleet-board.yml`, a skill that needs the board tells the user to run `/fleet-board:init` and stops. It never creates the config itself.
- **Frontmatter.** The skill file has `name`, `description` and `user-invocable: true` and nothing else; in particular no `allowed-tools` (a skill that declares it fails silently under headless `claude -p`).
- **Headless use.** The overnight wrapper runs `claude -p "/fleet-board:tick"` and reads the last line of the result that matches `^dispatchable: `. A result without that line counts as a failed tick.
- **Example commands.** Any test command in an example is a single file (`node --test test/calc.test.js`); never `npm test`, jest or a whole-suite command. (None of these skills runs tests.)

## Descriptions must trigger from plain English (verbatim from the phase plan)

**Descriptions must trigger from plain English.** Users will type things like "using the fleet-board skills, process the board", not only the slash commands. Each description is the only text Claude matches on, so it names its triggers:
- **`tick`:** advancing the board one step, processing or working the board once, "run a tick", "process the board", "what's next on the board". It also says that plain requests to process or work the board mean one tick unless the user asks to keep going.
- **`run`:** keep processing the board until nothing is left, "run the fleet", "work the board until done", "keep going".
- **`status`:** where cards stand, what the fleet is doing, "board status", "what's in Human QA".
- **`init`** already exists, and its description covers setup.

In addition: each description starts with "Use when" and states the trigger condition before the capability; it names the plugin as "fleet-board" (and "the board" / "the fleet"); and it says what the skill is **not** for. None of `tick`, `run` or `status` is for questions about how fleet-board works (its gate hook, hooks, config keys, design, or setup); those are answered without running a skill, and setup is `init`.

## Requirements for `run` (verbatim from the phase plan, then clarifications)

- **`run`** (user-invocable): loop.
  1. Before each tick, stop if `.fleet-board.stop` exists in the repo root.
  2. Invoke the `tick` skill.
  3. Stop when the report's last line is `dispatchable: false`.
  4. Otherwise tell the user the next tick will start after `limits.tick_interval` seconds, run `sleep <tick_interval>` through Bash, and repeat.
  5. Print a one-line summary per tick.

Clarifications (the spec must carry each):
- Before the first tick, run `bash "<this skill's base directory>/../../scripts/config.sh" limits.tick_interval` in the user's repository. On exit 3, tell the user to run `/fleet-board:init`, and stop; on any other non-zero exit, show its stderr and stop.
- The repo root is `git rev-parse --show-toplevel`; the stop file is `<repo root>/.fleet-board.stop`. The skill never creates or deletes it; when it stops because of it, it says so.
- "Invoke the `tick` skill" means the Skill tool with `fleet-board:tick`, one tick at a time, never two at once. The skill does none of the tick's or the manager's work itself (no `tick-plan.sh`, no card moves, no agent dispatch of its own).
- A tick whose output has no final `dispatchable: true|false` line is a failed tick: the loop stops and says the tick produced no stop signal. It never guesses the value.
- **Sleeping.** The Bash tool's default timeout is 2 minutes and its maximum 10 minutes, so the wait is `sleep` in chunks of at most 540 seconds, each Bash call with a timeout of 600000 ms, until `limits.tick_interval` seconds have passed. Between chunks it checks the stop file and stops early if it exists.
- The one-line summary per tick is `tick <i>: dispatchable: <true|false>, <cost_estimate_usd value or "cost n/a">`, printed after each tick's report. When the loop ends, a final line says why: `stopped: nothing dispatchable after <i> ticks`, `stopped: stop file after <i> ticks`, or `stopped: tick <i> gave no stop signal`.
- Unlike the headless wrapper, the in-session loop has no hour or cost limit of its own; the user interrupts it, or creates the stop file.
- A plain request to process or work the board once is the `tick` skill, not this one; this skill is only for requests to keep going until the board has nothing left to do.

## Acceptance criteria

None directly. (The headless wrapper, not this skill, carries AC6.5.)
