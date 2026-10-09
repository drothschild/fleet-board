# Spec brief: tick skill

You are writing the behavior specification for the fleet-board **tick** skill. fleet-board is a Claude Code plugin: a manager agent moves cards (GitHub issues) across a board and dispatches three role agents (implementor, reviewer, fixer) to do the work in git worktrees. The design document describes it. A **tick** is one run of the manager: it advances every open card one step and returns a tick report whose last line is exactly `dispatchable: true` or `dispatchable: false`. The plugin has four user-invocable skills: `init` (setup, already written), `tick`, `run` and `status`, reachable as `/fleet-board:<name>`.

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
- **Config.** `bash "<base directory>/../../scripts/config.sh"`, run in the user's repository, prints the merged config as JSON. `config.sh <KEY>` (for example `config.sh limits.tick_interval`) prints one value. Exit codes: 0 ok; 3 no `.fleet-board.yml` (fleet-board is not set up in this repo); 4 the YAML is invalid, or `yq` is missing; 5 invalid values; 2 usage error.
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

## Requirements for `tick` (verbatim from the phase plan, then clarifications)

- **`tick`** (user-invocable):
  1. Run `bash "<this skill's base directory>/../../scripts/config.sh"`. On exit 3, tell the user to run `/fleet-board:init`, and stop.
  2. Dispatch the `fleet-board:manager` agent with `model` = `models.manager` and a prompt containing the scripts dir (absolute), the repo root (`git rev-parse --show-toplevel`), the config JSON, and the start time.
  3. Print the manager's tick report verbatim as the final output. The wrapper parses its last line.

Clarifications (the spec must carry each):
- On exit 4, 5 or 2 from `config.sh`, show its stderr to the user and stop; nothing is dispatched.
- The start time is the current UTC time in ISO 8601 (`date -u +%Y-%m-%dT%H:%M:%SZ`).
- The dispatch is one Agent tool call with `subagent_type: fleet-board:manager` and `model` set explicitly to the config's `models.manager` value (for example `sonnet`), never the session's model and never omitted. The skill waits for the manager to finish (foreground; never a background dispatch) before printing anything else. **The Agent call passes `run_in_background: false` explicitly; it is never omitted.** When the parameter is left out, the runtime may run the agent in the background anyway (observed in Phase 6 Task 9 for a role dispatch: the agent ran in the background and the dispatcher ended with an incomplete report); for the tick, a background manager would leave the skill with no tick report, so the wrapper would read no `dispatchable:` line.
- The skill dispatches no agent other than `fleet-board:manager`, and dispatches it exactly once per invocation.
- The skill does none of the manager's work itself: it never runs `tick-plan.sh`, moves cards, writes notes, dispatches role agents, or merges.
- "Verbatim" means the manager's final message exactly as returned, with nothing added after it. When the manager's reply has no `dispatchable:` line, the skill prints it as returned and says the tick produced no stop signal; it never adds, invents or changes a `dispatchable:` line.
- A plain request to process or work the board is one tick: the skill runs one tick and stops; it never loops (looping is the `run` skill).

## Acceptance criteria

- **fleet-board.AC6.1 Success:** Each role runs on the model named in config; none inherits the session model. *(The tick skill's part: the manager itself is dispatched with `models.manager`.)*
- **fleet-board.AC6.4 Success:** The tick report ends with a stop signal (`dispatchable: true|false`) and a cost estimate labelled as an estimate. *(The tick skill's part: the report is printed verbatim, so its last line reaches the wrapper.)*
