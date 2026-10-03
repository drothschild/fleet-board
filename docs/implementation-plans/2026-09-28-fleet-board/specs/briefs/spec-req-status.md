# Spec brief: status skill

You are writing the behavior specification for the fleet-board **status** skill. fleet-board is a Claude Code plugin: a manager agent moves cards (GitHub issues) across a board and dispatches three role agents (implementor, reviewer, fixer) to do the work in git worktrees. The design document describes it. A **tick** is one run of the manager: it advances every open card one step and returns a tick report whose last line is exactly `dispatchable: true` or `dispatchable: false`. The plugin has four user-invocable skills: `init` (setup, already written), `tick`, `run` and `status`, reachable as `/fleet-board:<name>`.

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

## Requirements for `status` (verbatim from the phase plan, then clarifications)

- **`status`** (user-invocable): run `status.sh`, passing `--all` if the user asked for everything, and print the output verbatim. Then print a final line, `Headless wrapper: <absolute path>`. The path is `<this skill's base directory>/../../scripts/fleet-board-run.sh` resolved with `cd … && pwd`. This gives the README a portable way to locate the wrapper without writing down the install path.

Clarifications (the spec must carry each):
- `status.sh` is `bash "<this skill's base directory>/../../scripts/status.sh" [--all]`, run in the user's repository. It prints one section per state, `ready`, `in_progress`, `in_review`, `human_qa` and `blocked` (plus `backlog`, `done` and `wont_do` with `--all`), each card on one line: `#<n> <title> · round <r> · PR #<pr> · <implementor>/<reviewer>`, `(none)` for an empty section. Exit codes: 0 printed; 1 a column or a card's note could not be read (what it could print is still printed); 2 usage; 3 no `.fleet-board.yml`.
- "Asked for everything" means the user asked for all cards or all states, including backlog, done or won't-do cards; otherwise no `--all`.
- On exit 3, tell the user to run `/fleet-board:init` instead of printing a board. On exit 1, print what `status.sh` printed and its stderr, and say the board could not be read completely.
- The `Headless wrapper:` line is printed in every case, as the last line. The directory is resolved with `cd "<this skill's base directory>/../../scripts" && pwd`, and the line is `Headless wrapper: <that directory>/fleet-board-run.sh`. The skill does not check that the file exists.
- The skill is read-only: it never moves a card, writes a note or comment, dispatches an agent, or runs a tick.
- **Leftover worktrees of done cards.** After printing the board, and before the `Headless wrapper:` line, the skill checks read-only whether any done card still has worktree directories. The steps:
  - Run `bash "<this skill's base directory>/../../scripts/board-list.sh" done` in the user's repository. It prints a JSON array of cards, each with a `number`.
  - Read the worktrees directory as `bash "<base directory>/../../scripts/config.sh" worktrees.dir`. That path is relative to the repository root (`git rev-parse --show-toplevel`).
  - List that directory's entries. A done card `<n>` has leftovers when an entry's name starts with `<n>-`.
  - When one or more done cards have leftovers, print one line naming them (for example `Done cards with worktrees left: #12, #15`), then the exact command to remove them: `bash <absolute scripts dir>/cleanup-done.sh`, with the absolute scripts dir resolved by `cd "<base directory>/../../scripts" && pwd`. Suggest running it from the repository root.
  - When there are none, or the directory does not exist, print nothing for this check. When `board-list.sh` fails, skip the check silently; the board output already reports read problems.
- The skill never runs `cleanup-done.sh` itself and never removes a worktree or directory. It only names the command for the user to run.
- Questions about where cards stand ("what's in Human QA", "what's blocked", "what is the fleet doing") are answered from `status.sh` output, never from memory or from guessing.

## Acceptance criteria

None directly (operator convenience; the design names a `status` skill).
