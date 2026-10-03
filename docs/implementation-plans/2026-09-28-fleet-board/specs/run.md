# Behavior spec: `run` skill

## 1. Purpose

`run` keeps fleet-board working in the current session until the board has nothing left to do. It runs ticks one after another by invoking the `tick` skill, and waits `limits.tick_interval` seconds between ticks. It stops when a tick reports `dispatchable: false`, when the stop file `.fleet-board.stop` appears in the repo root, or when a tick gives no stop signal. It prints a one-line summary after every tick and one final line saying why it stopped. It is a loop around `tick` and nothing more: it does none of the tick's or the manager's work itself.

## 2. Trigger

Requirements for the frontmatter `description`:

- It starts with "Use when" and states the trigger condition before the capability.
- It names the plugin as "fleet-board" and also refers to "the board" and "the fleet".
- It names the plain-English triggers for continuous processing: "run the fleet", "work the board until done", "keep going", and processing the board until nothing is left.
- It says the skill repeats ticks until nothing is dispatchable or a stop file exists.
- It says what the skill is **not** for:
  - Processing or working the board once, or "run a tick". That is `tick`. A plain request to process the board means one tick unless the user asks to keep going.
  - Where cards stand. That is `status`.
  - Setup. That is `init`.
  - Questions about how fleet-board works (its gate hook, hooks, config keys, design or setup). These are answered without running a skill.
- It is at most 900 characters.

Proposed description:

> Use when the user wants fleet-board to keep processing the board until nothing is left to do: "run the fleet", "work the board until done", "keep going", "process the board until it's empty". Runs fleet-board ticks one after another in this session, waiting limits.tick_interval seconds between them, and stops when a tick reports nothing dispatchable or a .fleet-board.stop file exists. Not for a single pass: a plain request to process or work the board once, "run a tick" or "what's next on the board" is the tick skill, and that is the default unless the user asks to keep going. Not for where cards stand or what the fleet is doing (status), not for setting up fleet-board (init), and not for questions about how fleet-board works, such as its gate hook, hooks, config keys or design, which are answered without running a skill.

Frontmatter holds exactly `name: run`, the `description` above, and `user-invocable: true`. Nothing else goes in it. In particular there is no `allowed-tools`, because a skill that declares it fails silently under headless `claude -p`.

## 3. Inputs

- **The user's request.** It asks fleet-board to keep working the board until done. The skill takes no arguments. Any words after `/fleet-board:run` are ignored for control purposes: they do not add an hour or cost limit, and they do not change the interval.
- **The skill's base directory.** The Skill tool announces it when the skill loads. The plugin's scripts are at `<base directory>/../../scripts/`, and the skill substitutes the real announced directory into that path. If it needs an absolute scripts path, it gets one with `cd "<base directory>/../../scripts" && pwd`. It never guesses or writes down an install path.
- **The current repository.** This is the user's working directory. The repo root is the output of `git rev-parse --show-toplevel`. The config is `.fleet-board.yml`, read only through `config.sh`. The stop file is `<repo root>/.fleet-board.stop`.
- **The `tick` skill's output.** Each tick returns a report. The report includes a cost estimate (the `cost_estimate_usd` value) and ends with a line that is exactly `dispatchable: true` or `dispatchable: false`.

## 4. Required behavior

1. **Read the interval before the first tick.** In the user's repository, run `bash "<base directory>/../../scripts/config.sh" limits.tick_interval`, with the real base directory substituted.
   - Exit 0: stdout, trimmed, is the tick interval in seconds (`N`).
   - Exit 3: print a message telling the user that fleet-board is not set up in this repository and to run `/fleet-board:init`. Then stop. No tick runs, and no `.fleet-board.yml` is created.
   - Any other non-zero exit (2, 4, 5 or anything else): print that command's stderr and stop. No tick runs.
   - If stdout is not a non-negative integer, print the value that came back and stop. No tick runs.
2. **Find the repo root.** Run `git rev-parse --show-toplevel`. The stop file path is `<repo root>/.fleet-board.stop`. If the command fails, print its stderr and stop.
3. **Keep a tick counter `i`.** It starts at 0.
4. **Check the stop file before every tick, including the first.** Test whether `<repo root>/.fleet-board.stop` exists, for example with `test -e`. If it exists, print `stopped: stop file after <i> ticks`, where `<i>` is the number of ticks completed so far, and stop. The file is left where it is.
5. **Run exactly one tick.** Increment `i`, then invoke the Skill tool with `fleet-board:tick`. Only one tick runs at a time: the next tick is never started until the current one has returned. Nothing else runs alongside it.
6. **Read the stop signal.** Take the last non-blank line of the tick's report.
   - Exactly `dispatchable: true` or `dispatchable: false` (trailing whitespace ignored): that is the tick's signal.
   - Anything else, including a Skill tool error, an empty result, or a `dispatchable:` line that is not the last line: the tick has failed. Print `stopped: tick <i> gave no stop signal` and stop. The skill does not guess a value, does not retry the tick, and does not start another tick.
7. **Print the per-tick summary.** After the tick's report has been shown, print exactly one line: `tick <i>: dispatchable: <true|false>, <cost>`.
   - `<cost>` is the report's `cost_estimate_usd` value, as the report gives it.
   - If the report has no cost estimate, `<cost>` is the literal `cost n/a`.
   - On a failed tick (step 6) the summary line is not printed. Only the `stopped:` line is.
8. **Stop when nothing is dispatchable.** If the signal is `dispatchable: false`, print `stopped: nothing dispatchable after <i> ticks` and stop.
9. **Announce the wait.** If the signal is `dispatchable: true`, print a line saying that the next tick will start after `N` seconds and that creating `<repo root>/.fleet-board.stop` will stop the loop.
10. **Sleep in bounded chunks.**
    - Wait `N` seconds in total using Bash `sleep` calls in the foreground.
    - Each call sleeps `min(540, remaining)` seconds and is made with a Bash timeout of 600000 ms.
    - Chunks repeat until `N` seconds have been slept. For example, `N = 300` is one `sleep 300`. `N = 1200` is `sleep 540`, `sleep 540`, `sleep 120`.
    - `N = 0` means no sleep call is made.
11. **Check the stop file between chunks.** After every sleep chunk except the last, test for the stop file. If it exists, print `stopped: stop file after <i> ticks` and stop without finishing the wait.
12. **Repeat.** After the wait, return to step 4. The check there covers the time after the last chunk.
13. **No limits of its own.** The loop has no hour limit, cost limit, tick-count limit or consecutive-failure allowance. It ends only by steps 1, 2, 4, 6, 8 or 11, or when the user interrupts it.
14. **Every ending gets one final line.** Exactly one of these three lines is printed:
    - `stopped: nothing dispatchable after <i> ticks`
    - `stopped: stop file after <i> ticks`
    - `stopped: tick <i> gave no stop signal`

    The exception is a setup failure in steps 1–2. That prints only the setup message or the stderr.

## 5. Must never

- Create, modify or delete `.fleet-board.stop`.
- Create or edit `.fleet-board.yml`, or proceed with any tick when `config.sh` exits non-zero.
- Do any of the tick's or the manager's work itself:
  - It never runs `tick-plan.sh` or any `board-*.sh` script.
  - It never moves, comments on or notes a card.
  - It never runs `gh` against issues, projects or PRs.
  - It never creates worktrees.
  - It never dispatches any agent (manager, implementor, reviewer or fixer) itself. Its only way to do work is the Skill tool with `fleet-board:tick`.
- Run two ticks at once, or start a tick while a previous one is still running.
- Guess, infer or default the stop signal when a tick's report lacks a final `dispatchable: true|false` line, or keep looping after such a tick.
- Retry a failed tick.
- Sleep longer than 540 seconds in one Bash call. Sleep without a 600000 ms timeout. Run the sleep in the background.
- Impose an hour, cost or tick-count limit of its own. Invent a tick interval other than the configured one.
- Invoke the headless wrapper (`fleet-board-run.sh`) or `claude -p`.
- Hardcode, guess or write down an install path for the plugin's scripts.
- Run any test command or test suite.

## 6. Output

This is printed in order, and nothing else:

1. On setup failure, only one of these:
   - A message saying fleet-board is not set up in this repository and to run `/fleet-board:init` (config exit 3).
   - The `config.sh` stderr (any other non-zero exit).
   - The unusable interval value.
   - The `git rev-parse` stderr.
2. For each tick `i` (1, 2, …):
   - The tick's report, as the `tick` skill returned it.
   - `tick <i>: dispatchable: <true|false>, <cost_estimate_usd value or "cost n/a">`
   - If the loop continues, one line saying the next tick starts after `<N>` seconds and that `<repo root>/.fleet-board.stop` stops the loop.
3. One final line, exactly one of:
   - `stopped: nothing dispatchable after <i> ticks`
   - `stopped: stop file after <i> ticks`
   - `stopped: tick <i> gave no stop signal`

Example of a two-tick run with `limits.tick_interval: 300`:

```
<tick 1 report, ending "dispatchable: true">
tick 1: dispatchable: true, 1.84
next tick in 300 seconds; create /path/to/repo/.fleet-board.stop to stop the loop
<tick 2 report, ending "dispatchable: false">
tick 2: dispatchable: false, 0.42
stopped: nothing dispatchable after 2 ticks
```

## 7. Acceptance criteria

None directly. (The headless wrapper, not this skill, carries AC6.5.)
