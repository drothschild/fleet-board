---
name: run
description: 'Use when the user wants fleet-board to keep processing the board until nothing is left to do: "run the fleet", "work the board until done", "keep going", "process the board until it''s empty". Runs fleet-board ticks one after another in this session, waiting limits.tick_interval seconds between them, and repeats until a tick reports nothing dispatchable or a .fleet-board.stop file exists. Not for a single pass: a plain request to process or work the board once, "run a tick" or "what''s next on the board" is the tick skill, and that is the default unless the user asks to keep going. Not for where cards stand or what the fleet is doing (status), not for setting up fleet-board (init), and not for questions about how fleet-board works, such as its gate hook, hooks, config keys, design or setup, which are answered without running a skill.'
user-invocable: true
---

# fleet-board: run

## Principle

This skill is a loop around the `tick` skill and nothing more. It runs one tick at a time through the Skill tool, waits the configured `limits.tick_interval` seconds between ticks, and stops when a tick reports `dispatchable: false`, when `<repo root>/.fleet-board.stop` exists, or when a tick gives no stop signal. It does none of the tick's or the manager's work itself, sets no limits of its own, and never guesses a stop signal. After every tick it prints one summary line, and when it ends it prints one final line saying why.

## Locating the scripts

When this skill loads, the Skill tool announces the skill's base directory. The plugin's scripts are at `<base directory>/../../scripts/`. Substitute the real announced base directory into that path every time you use it. If you need an absolute scripts path, get it with `cd "<base directory>/../../scripts" && pwd`. Never guess, hardcode or write down an install path.

The skill takes no arguments. Ignore any words after `/fleet-board:run` for control purposes: they do not add an hour or cost limit and do not change the interval.

## Method

1. **Read the interval before the first tick.** In the user's repository (the current working directory), run:

   ```
   bash "<base directory>/../../scripts/config.sh" limits.tick_interval
   ```

   with the real base directory substituted. Read `.fleet-board.yml` only through `config.sh`.
   - Exit 0: stdout, trimmed, is the tick interval in seconds. Call it `N`.
   - Exit 3: print a message saying fleet-board is not set up in this repository and to run `/fleet-board:init`. Stop. Run no tick, and do not create `.fleet-board.yml`.
   - Any other non-zero exit (2, 4, 5 or anything else): print that command's stderr and stop. Run no tick.
   - If stdout is not a non-negative integer: print the value that came back and stop. Run no tick.

2. **Find the repo root.** Run `git rev-parse --show-toplevel`. The stop file is `<repo root>/.fleet-board.stop`. If the command fails, print its stderr and stop.

3. **Start a tick counter `i` at 0.**

4. **Check the stop file before every tick, including the first.** Test whether `<repo root>/.fleet-board.stop` exists, for example with `test -e "<repo root>/.fleet-board.stop"`. If it exists, print `stopped: stop file after <i> ticks` (with `<i>` the number of ticks completed so far) and stop. Leave the file where it is.

5. **Run exactly one tick.** Increment `i`, then invoke the Skill tool with `fleet-board:tick`. Only one tick runs at a time: never start the next tick until the current one has returned, and run nothing alongside it.

6. **Read the stop signal.** Take the last non-blank line of the tick's report.
   - If it is exactly `dispatchable: true` or `dispatchable: false` (ignoring trailing whitespace), that is the tick's signal.
   - Anything else is a failed tick: a Skill tool error, an empty result, a missing line, or a `dispatchable:` line that is not the last non-blank line. Print `stopped: tick <i> gave no stop signal` and stop. Do not guess a value, do not retry the tick, and do not start another tick. Do not print the per-tick summary line for a failed tick.

7. **Print the per-tick summary.** After the tick's report has been shown, print exactly one line:

   ```
   tick <i>: dispatchable: <true|false>, <cost>
   ```

   `<cost>` is the report's `cost_estimate_usd` value, exactly as the report gives it. If the report has no cost estimate, `<cost>` is the literal `cost n/a`.

8. **Stop when nothing is dispatchable.** If the signal is `dispatchable: false`, print `stopped: nothing dispatchable after <i> ticks` and stop.

9. **Announce the wait.** If the signal is `dispatchable: true`, print one line saying the next tick starts after `N` seconds and that creating `<repo root>/.fleet-board.stop` stops the loop, for example:

   ```
   next tick in <N> seconds; create <repo root>/.fleet-board.stop to stop the loop
   ```

10. **Sleep in bounded chunks.** Wait `N` seconds in total using foreground Bash `sleep` calls.
    - Each call sleeps `min(540, remaining)` seconds and is made with a Bash timeout of 600000 ms.
    - Repeat chunks until `N` seconds have been slept. `N = 300` is one `sleep 300`. `N = 1200` is `sleep 540`, `sleep 540`, `sleep 120`.
    - If `N = 0`, make no sleep call.

11. **Check the stop file between chunks.** After every sleep chunk except the last, test for `<repo root>/.fleet-board.stop`. If it exists, print `stopped: stop file after <i> ticks` and stop without finishing the wait.

12. **Repeat.** After the wait, go back to step 4. The check there covers the time after the last chunk.

13. **No limits of your own.** The loop has no hour limit, cost limit, tick-count limit or consecutive-failure allowance. It ends only through steps 1, 2, 4, 6, 8 or 11, or when the user interrupts it.

14. **Every ending gets exactly one final line**, one of:
    - `stopped: nothing dispatchable after <i> ticks`
    - `stopped: stop file after <i> ticks`
    - `stopped: tick <i> gave no stop signal`

    The exception is a setup failure in steps 1–2, which prints only the setup message or the stderr.

## Output

Print this, in order, and nothing else:

1. On setup failure, only one of:
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

## What not to do

- Never create, modify or delete `.fleet-board.stop`.
- Never create or edit `.fleet-board.yml`, and never proceed with any tick when `config.sh` exits non-zero.
- Never do any of the tick's or the manager's work yourself:
  - Never run `tick-plan.sh` or any `board-*.sh` script.
  - Never move, comment on or note a card.
  - Never run `gh` against issues, projects or PRs.
  - Never create worktrees.
  - Never dispatch any agent (manager, implementor, reviewer or fixer). Your only way to do work is the Skill tool with `fleet-board:tick`.
- Never run two ticks at once, or start a tick while a previous one is still running.
- Never guess, infer or default the stop signal when a tick's report lacks a final `dispatchable: true|false` line, and never keep looping after such a tick.
- Never retry a failed tick.
- Never sleep longer than 540 seconds in one Bash call, never sleep without a 600000 ms timeout, and never run the sleep in the background.
- Never impose an hour, cost or tick-count limit of your own, and never invent a tick interval other than the configured one.
- Never invoke the headless wrapper (`fleet-board-run.sh`) or `claude -p`.
- Never hardcode, guess or write down an install path for the plugin's scripts.
- Never run any test command or test suite.
