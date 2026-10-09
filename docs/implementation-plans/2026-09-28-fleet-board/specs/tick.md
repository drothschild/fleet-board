# Behavior spec: `tick` skill

## 1. Purpose

`tick` runs one tick of the fleet-board: one pass that moves every open card on the board forward by one step. The skill is a thin dispatcher and does none of the tick's work itself. It reads the project's fleet-board config, dispatches the `fleet-board:manager` agent once, on the model the config names, and waits for it in the foreground. Then it prints the manager's tick report exactly as returned. The report's last line is the stop signal (`dispatchable: true` or `dispatchable: false`). The overnight headless wrapper reads that line from the output of `claude -p "/fleet-board:tick"`.

## 2. Trigger

Requirements for the frontmatter `description`:

- It starts with "Use when" and gives the trigger condition before the capability.
- It names the plugin as "fleet-board" and also refers to "the board" and "the fleet".
- It lists the plain-English triggers: advancing the board one step, processing or working the board once, "run a tick", "process the board", "what's next on the board".
- It says that a plain request to process or work the board means **one** tick unless the user asks to keep going.
- It says what the skill is **not** for:
  - looping until nothing is left or "keep going" (that is `run`);
  - where cards stand or what the fleet is doing (that is `status`);
  - setup (that is `init`);
  - questions about how fleet-board works (its gate hook, hooks, config keys, design or setup). Those are answered without running a skill.
- It is at most 900 characters.

Proposed description:

> Use when the user wants to advance the fleet-board one step: run a tick, process the board, work the board once, or asks what's next on the board. A plain request to process or work the board means exactly one tick unless the user asks to keep going. Reads the fleet-board config, dispatches the manager agent to move every open card on the board one step and dispatch the fleet's role agents, and prints the tick report ending in a dispatchable stop signal. This is also what the overnight headless run invokes. Not for looping until the board is empty or "keep going" (use run), not for where cards stand or what the fleet is doing (use status), not for setup (use init), and not for questions about how fleet-board works (its gate hook, hooks, config keys, design or setup), which are answered without running a skill.

## 3. Inputs

- **The user's request.** A slash invocation (`/fleet-board:tick`) or plain English such as "using the fleet-board skills, process the board". It can also be the headless prompt `claude -p "/fleet-board:tick"` sent by the overnight wrapper. Whatever the wording, the skill does one tick. Arguments do not change what it does.
- **The skill's base directory.** The Skill tool announces it when the skill loads. The plugin's scripts are at `<base directory>/../../scripts/`, and the absolute scripts dir comes from `cd "<base directory>/../../scripts" && pwd`. The skill uses the real announced directory. It never guesses an install path or writes one down.
- **The current repository.** The user's working repository. Its root comes from `git rev-parse --show-toplevel`, and its `.fleet-board.yml` is read through `config.sh`.
- **The clock.** The start time is the current UTC time in ISO 8601, from `date -u +%Y-%m-%dT%H:%M:%SZ`.

## 4. Required behavior

1. The skill runs `bash "<base directory>/../../scripts/config.sh"` (no key argument) in the user's repository, with the announced base directory filled in. On exit 0 it keeps stdout as the config JSON.
2. On exit 3 (no `.fleet-board.yml`), the skill tells the user that fleet-board is not set up in this repository and to run `/fleet-board:init`, then stops. It does not create or edit any config. Nothing is dispatched.
3. On exit 4 (the YAML is invalid, or `yq` is missing), 5 (invalid values) or 2 (usage error), the skill shows `config.sh`'s stderr to the user and stops. Nothing is dispatched. Any other non-zero exit is handled the same way.
4. The skill gets the absolute scripts dir by running `cd "<base directory>/../../scripts" && pwd`.
5. The skill gets the repo root by running `git rev-parse --show-toplevel`.
6. The skill gets the start time by running `date -u +%Y-%m-%dT%H:%M:%SZ`.
7. The skill reads `models.manager` from the config JSON from step 1, for example `sonnet`.
8. The skill makes exactly one Agent tool call with:
   - `subagent_type: fleet-board:manager`;
   - `model` set explicitly to the `models.manager` value. It is never the session's model, never a hardcoded value, and never left out;
   - `run_in_background: false`, passed explicitly and never left out. If the parameter is missing, the runtime may run the agent in the background anyway. A background manager would leave the skill with no tick report, so the wrapper would find no `dispatchable:` line;
   - a prompt containing the absolute scripts dir, the repo root, the full config JSON and the start time.
9. The skill waits for the manager to finish before it prints anything else. The dispatch is in the foreground and is never a background task.
10. The skill dispatches no agent other than `fleet-board:manager`, and dispatches it once per invocation. That means no second dispatch and no retry dispatch.
11. When the manager returns, the skill's final output is the manager's final message exactly as returned. Nothing is added after it, and no line in it is reworded, reordered, summarized or dropped.
12. If the manager's reply has no line matching `^dispatchable: `, the skill still prints the reply as returned. It also prints one notice, placed before the reply, saying the tick produced no stop signal. The notice does not begin with `dispatchable:`. The skill never adds, invents or changes a `dispatchable:` line.
13. If the Agent call fails or returns nothing, the skill says that the tick produced no tick report and no stop signal, and prints no `dispatchable:` line. It does not re-dispatch.
14. After printing, the skill stops. It runs one tick per invocation and never loops, even on a plain "process the board" request. Looping is the `run` skill's job.

## 5. Must never

- Never create, write or edit `.fleet-board.yml`, including when `config.sh` exits 3. Setup is `/fleet-board:init`.
- Never dispatch anything when `config.sh` exits non-zero.
- Never do the manager's work: never run `tick-plan.sh` or any `board-*` script, move cards, post comments, write manager notes, create worktrees or branches, dispatch implementor, reviewer or fixer agents, mark PRs ready, or merge.
- Never dispatch any agent other than `fleet-board:manager`, and never dispatch it more than once per invocation.
- Never leave out `model` on the manager dispatch, and never let it fall back to the session model.
- Never leave out `run_in_background: false`, and never run the manager in the background.
- Never add anything after the manager's final message, and never change, summarize or reformat it.
- Never add, invent or change a `dispatchable:` line.
- Never loop or start a second tick.
- Never guess or write down an install path, and never use a scripts path not derived from the announced base directory.
- The skill file's frontmatter holds only `name`, `description` and `user-invocable: true`. It never declares `allowed-tools` (a skill that declares it fails silently under headless `claude -p`) or any other key.
- Never run a test suite. If an example ever shows a test command, it is a single file (for example `node --test test/calc.test.js`), never `npm test`, jest or a whole-suite command.

## 6. Output

- **Normal case:** only the manager's tick report, exactly as returned, as the skill's final output. Its last line is `dispatchable: true` or `dispatchable: false`, and it contains the cost estimate labelled as an estimate that the manager produced. The skill writes no commentary before or after it.
- **No stop signal in the reply:** a one-line notice that the tick produced no stop signal, followed by the manager's reply exactly as returned. There is no `dispatchable:` line unless the manager wrote one.
- **Agent call failed or returned nothing:** a short message that the tick produced no tick report and no stop signal. There is no `dispatchable:` line.
- **`config.sh` exit 3:** a message that fleet-board is not set up in this repository and to run `/fleet-board:init`. Nothing else.
- **`config.sh` exit 4, 5, 2 or other non-zero:** `config.sh`'s stderr, shown to the user. Nothing else.

## 7. Acceptance criteria

- **fleet-board.AC6.1 Success:** Each role runs on the model named in config; none inherits the session model. *(The tick skill's part: the manager itself is dispatched with `models.manager`.)*
- **fleet-board.AC6.4 Success:** The tick report ends with a stop signal (`dispatchable: true|false`) and a cost estimate labelled as an estimate. *(The tick skill's part: the report is printed verbatim, so its last line reaches the wrapper.)*
