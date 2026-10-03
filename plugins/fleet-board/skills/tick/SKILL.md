---
name: tick
description: Use when the user wants to advance the fleet-board one step, such as to run a tick, process the board, work the board once, or asks what's next on the board. A plain request to process or work the board means exactly one tick unless the user asks to keep going. Reads the fleet-board config, dispatches the manager agent to move every open card on the board one step and dispatch the fleet's role agents, and prints the tick report ending in a dispatchable stop signal. This is also what the overnight headless run invokes. Not for looping until the board is empty or "keep going" (use run), not for where cards stand or what the fleet is doing (use status), not for setup (use init), and not for questions about how fleet-board works (its gate hook, hooks, config keys, design or setup), which are answered without running a skill.
user-invocable: true
---

# fleet-board: tick

## Principle

This skill runs exactly one tick of the fleet-board, meaning one pass that moves every open card on the board forward by one step. It only dispatches. It does none of the tick's work itself. Read the project's fleet-board config, dispatch the `fleet-board:manager` agent once in the foreground on the model the config names, wait for it to finish, and print its tick report exactly as returned. The report's last line is the stop signal (`dispatchable: true` or `dispatchable: false`). The overnight headless wrapper reads that line from the output of `claude -p "/fleet-board:tick"`, so the report has to come through unchanged. You do one tick however the request is worded ("/fleet-board:tick", "process the board", the headless prompt). Arguments do not change this.

## Locating the scripts

When this skill loads, the Skill tool announces its base directory. The plugin's scripts are at `<base directory>/../../scripts/`. Every time this skill says `<base directory>`, substitute the real directory that was announced. Get the absolute scripts dir with:

```bash
cd "<base directory>/../../scripts" && pwd
```

Never guess an install path, never write one down, and never use a scripts path that does not come from the announced base directory.

## Method

1. **Read the config.** In the user's repository, run `bash "<base directory>/../../scripts/config.sh"` with no key argument and the announced base directory filled in. On exit 0, keep its stdout as the config JSON.
2. **Not set up (exit 3).** If `config.sh` exits 3, there is no `.fleet-board.yml`. Tell the user fleet-board is not set up in this repository and that they should run `/fleet-board:init`, then stop. Do not create or edit any config. Do not dispatch anything.
3. **Invalid config (exit 4, 5, 2, or any other non-zero).** Exit 4 means the YAML is outside the supported subset, 5 means invalid values, 2 means a usage error. For any of these, or any other non-zero exit, show the user `config.sh`'s stderr and stop. Do not dispatch anything.
4. **Scripts dir.** Run `cd "<base directory>/../../scripts" && pwd` to get the absolute scripts dir.
5. **Repo root.** Run `git rev-parse --show-toplevel` to get the repo root.
6. **Start time.** Run `date -u +%Y-%m-%dT%H:%M:%SZ` to get the start time in UTC ISO 8601.
7. **Manager model.** Read `models.manager` from the config JSON you got in step 1 (for example `sonnet`).
8. **Dispatch the manager, exactly once.** Make exactly one Agent tool call with:
   - `subagent_type: fleet-board:manager`
   - `model`: the `models.manager` value, set explicitly. Never the session's model, never a hardcoded value, and never left out.
   - `run_in_background: false`, passed explicitly and never left out. If this parameter is missing, the runtime may run the agent in the background anyway. A background manager leaves you with no tick report, and then the wrapper finds no `dispatchable:` line.
   - a prompt that contains the absolute scripts dir, the repo root, the full config JSON, and the start time.
9. **Wait in the foreground.** Wait for the manager to finish before you print anything else. The dispatch runs in the foreground and is never a background task.
10. **One agent, one dispatch.** Dispatch no agent other than `fleet-board:manager`, and dispatch it only once per invocation. No second dispatch and no retry.
11. **Print the report verbatim.** When the manager returns, your final output is its final message exactly as returned. Add nothing after it. Do not reword, reorder, summarize or drop any line.
12. **Missing stop signal.** If no line in the manager's reply matches `^dispatchable: `, still print the reply exactly as returned. Before it, print one notice saying the tick produced no stop signal. The notice must not begin with `dispatchable:`. Never add, invent or change a `dispatchable:` line.
13. **Failed or empty dispatch.** If the Agent call fails or returns nothing, say that the tick produced no tick report and no stop signal. Print no `dispatchable:` line. Do not dispatch again.
14. **Stop.** After printing, stop. Run one tick per invocation and never loop, even when the request is a plain "process the board". Looping belongs to the `run` skill.

## Output

- **Normal case:** only the manager's tick report, exactly as returned, as your final output. Its last line is `dispatchable: true` or `dispatchable: false`, and it includes the manager's cost estimate, labelled as an estimate. Write no commentary before or after it.
- **No stop signal in the reply:** a one-line notice that the tick produced no stop signal, then the manager's reply exactly as returned. No `dispatchable:` line appears unless the manager wrote one.
- **Agent call failed or returned nothing:** a short message that the tick produced no tick report and no stop signal. No `dispatchable:` line.
- **`config.sh` exit 3:** a message that fleet-board is not set up in this repository and to run `/fleet-board:init`. Nothing else.
- **`config.sh` exit 4, 5, 2 or any other non-zero:** `config.sh`'s stderr, shown to the user. Nothing else.

## What not to do

- Never create, write or edit `.fleet-board.yml`, and that includes when `config.sh` exits 3. Setup belongs to `/fleet-board:init`.
- Never dispatch anything when `config.sh` exits non-zero.
- Never do the manager's work. Do not run `tick-plan.sh` or any `board-*` script, move cards, post comments, write manager notes, create worktrees or branches, dispatch implementor, reviewer or fixer agents, mark PRs ready, or merge.
- Never dispatch any agent other than `fleet-board:manager`, and never dispatch it more than once per invocation.
- Never leave out `model` on the manager dispatch, and never let it fall back to the session model.
- Never leave out `run_in_background: false`, and never run the manager in the background.
- Never add anything after the manager's final message, and never change, summarize or reformat it.
- Never add, invent or change a `dispatchable:` line.
- Never loop or start a second tick.
- Never guess or write down an install path, and never use a scripts path that does not come from the announced base directory.
- This skill's frontmatter holds only `name`, `description` and `user-invocable: true`. Never add `allowed-tools`, because a skill that declares it fails silently under headless `claude -p`, and never add any other key.
- Never run a test suite. If a test command is ever needed as an example, it is a single file (for example `node --test test/calc.test.js`), never `npm test`, jest, or a whole-suite command.
