# Running fleet-board overnight

`fleet-board-run.sh` runs ticks headless, one after another, until a stop condition holds. Each tick is a `claude -p "/fleet-board:tick"` session, the same tick that `/fleet-board:tick` runs.

## Finding the wrapper

Run `/fleet-board:status`. Its last line is:

```
Headless wrapper: <absolute path to fleet-board-run.sh>
```

Use that path. The install location depends on the machine and the plugin version, so these docs do not write it down.

## Starting a run

From the repo root:

```bash
bash <path from /fleet-board:status> --repo .
```

`--repo` defaults to the current directory. The wrapper runs from that repo's git root, checks the config (`config.sh --check`; exit 3 when there is no `.fleet-board.yml`), prints the path of its run log, and starts ticking.

## When it stops

`stop-file`, `max-hours` and `max-cost` are checked before every tick. `nothing-dispatchable`, `cost-unknown` and `max-cost` are checked right after a successful tick, and `consecutive-failures` after a failed one. `permission-mode-mismatch` is checked first, right after any tick, failed or not.

| Stop reason | Condition | Config key | Exit |
|---|---|---|---|
| `stop-file` | `<repo root>/.fleet-board.stop` exists | none | 0 |
| `max-hours` | elapsed hours exceed the limit | `limits.max_hours` (default 8) | 0 |
| `max-cost` | the cost estimate exceeds the limit | `limits.max_cost_usd` (default 40) | 0 |
| `nothing-dispatchable` | a successful tick's report ends `dispatchable: false` | none | 0 |
| `consecutive-failures` | this many failed ticks in a row, including ticks whose plan failed | `limits.max_consecutive_failures` (default 3) | 1 |
| `cost-unknown` | a successful tick reports no cost at all | none | 1 |
| `permission-mode-mismatch` | a tick's `system/init` event reports a `permissionMode` other than the requested one | `headless.permission_mode` (default `auto`) | 1 |
| `interrupted (INT)`, `interrupted (TERM)` | the wrapper got Ctrl-C or `kill` | none | 130, 143 |

The limits are checked between ticks, never during one, so a single tick can run past `max_hours` or `max_cost_usd`. What bounds a tick is `--max-turns`. The comparisons are strict: with `max_hours: 0` or `max_cost_usd: 0`, the first tick still runs, and the run stops after it.

A tick fails when `claude` exits non-zero, when the session has no `result` event, when the result is an error (for example `error_max_turns`), or when the report's last non-blank line is not `dispatchable: true` or `dispatchable: false`. A failed tick is logged and the run goes on to the next tick. A successful tick resets the failure count.

A tick also fails when its report has a `Plan failed:` line: the tick could not read the board (for example, GitHub's rate limit), so its `dispatchable: false` does not mean the board is settled. The log gives the reason as `plan failed: <the error>`. The line counts after leading whitespace and markdown decoration, in this order:

- leading whitespace;
- any list markers (`-`, `*`, `+`, `1.` or `1)`, each followed by a space) and quote markers (`>`);
- one heading marker (`#` to `######`, then a space);
- up to three `*`, `_` or backtick characters before `Plan`, between `failed` and the colon, and after the colon.

So `- **Plan failed:**`, `**Plan failed**:`, `` `Plan failed:` `` and `- ## Plan failed:` all count. `## - Plan failed:`, a sentence or a table cell before the label, or a `-` with no space after it, do not. Up to three trailing `*`, `_` or backtick characters are removed from every logged reason, so `` `Plan failed: GraphQL error` `` logs `plan failed: GraphQL error`, and `Plan failed: bad glob src/*` logs `plan failed: bad glob src/`; only the log text changes, not whether the tick fails.

Between ticks it waits `limits.tick_interval` seconds (default 300). Each tick runs with `--max-turns` set to `limits.max_turns` (default 200) and `--model` set to `models.manager`.

On stop it prints one line and appends it to the log:

```
fleet-board-run: stopped: nothing-dispatchable after 7 ticks, 2.41 h, cost_estimate_usd 18.3 (estimate)
```

Hours and costs always use a dot as the decimal point, whatever the locale; `claude` itself still runs in the system locale.

For an interrupt, the line is written on a best-effort basis, and the tick count includes the tick that was cut short. A run killed with `kill -9`, or ended by the machine shutting down, writes no stop line.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | stopped: `nothing-dispatchable`, `stop-file`, `max-hours` or `max-cost` |
| 1 | stopped: `consecutive-failures`, `cost-unknown` or `permission-mode-mismatch`; or a setup failure (not a git repo, `claude` not found, the log cannot be written) |
| 2 | usage error, or `FLEET_BOARD_ISOLATE=1` |
| 3 | no `.fleet-board.yml` |
| 4, 5 | the config failed `config.sh --check`; 5 also for a limit that is not a valid number |
| 130, 143 | interrupted by INT (Ctrl-C) or TERM |

## Stopping gracefully

```bash
touch .fleet-board.stop
```

The tick in progress finishes, and the run stops before the next one. Delete the file before the next run, or that run stops before its first tick.

To stop at once, press Ctrl-C or send the wrapper TERM (`kill <pid>`). It passes TERM on to the running `claude` session (or cleanup, or the wait between ticks), waits up to 5 seconds for it to exit, and sends KILL to anything still running after that. Then it logs `stopped: interrupted (<signal>)` and exits 130 or 143. A stop can therefore take up to about 5 seconds. The tick it cut short is logged no further, and its cost is not counted. KILL ends only the process the wrapper started; a helper that process started and left behind is not tracked.

## The run log

Each run appends every tick to one file:

```
$HOME/.fleet-board/runs/<owner>-<name>-<YYYYmmdd-HHMMSS>.log
```

Set `FLEET_BOARD_LOG_DIR` to put the logs somewhere else. A relative path is taken from the directory the wrapper is started in. A log directory the wrapper creates is mode 700, and the files it writes are mode 600, because they hold tick reports and raw session output.

A successful tick's block is a header line (`=== tick <n> <time> rc=0 cost_estimate_usd=<x> (estimate) ===`), the tick report, and the output of the worktree cleanup. A failed tick's block starts `=== tick <n> FAILED <time> rc=<rc> ===`, then gives the reason, the path of the tick's whole output, and the last 20 lines of that output, each cut to 2000 characters. The whole output of a failed tick is kept next to the log as `<log name>-tick-<n>.jsonl`. Successful ticks keep no such file.

## The cost figure is an estimate

A tick's cost is the session's `total_cost_usd`, which Claude Code computes on the client. When a session reports none, the wrapper prices its `modelUsage` with `scripts/prices.json`, a dated price snapshot. The figure is not a bill. On a subscription, it measures usage, not money. A failed tick's cost counts too, when its session reports one. A failed tick whose session ends without a `result` event, or whose result carries no cost, adds $0 and is logged `cost_estimate_usd=unknown`, even though it may have spent money.

## Permissions

- The wrapper never passes `--dangerously-skip-permissions`.
- `--permission-mode` comes from `headless.permission_mode`, which defaults to `auto`. In `auto` mode, Claude Code approves or denies each tool call itself, with its safety classifier, so a tick can run unattended without skipping permission checks. No one is there to answer a permission prompt, so a stricter mode such as `default` leaves the tick's commands denied.
- With `headless.permission_mode: bypassPermissions`, the wrapper prints a one-line warning, to stderr and to the log, before the first tick.

## Merges stay human

`merge.policy: auto` is not supported for headless or overnight runs. Claude Code's auto-mode safety classifier blocks an unattended `gh pr merge` in a headless session ("Merge Without Review"). The wrapper adds no permission rule and does not work around the classifier. An overnight run leaves reviewed PRs to be merged by hand. Auto merges work only where they are explicitly allowed in the user's own Claude Code settings.

## Worktree cleanup

After each successful tick, the wrapper runs `scripts/cleanup-done.sh` from the repo root, in its own shell and outside any Claude session. It removes the worktrees of cards that reached done. It first lists the worktrees directory locally and reads the board only for done cards that still have a `<n>-*` entry there, so its cost grows with the leftover directories, not with the Done column. The manager never removes worktrees itself, because the auto-mode classifier denies that as irreversible local destruction. The cleanup's output goes into the log. If it fails, the log gets `warning: cleanup-done.sh exited <rc>` and its stderr. That is a warning only: the tick still counts as successful, and the run goes on.

It can also be run by hand from the repo root. `<scripts dir>` is the directory of the wrapper path that `/fleet-board:status` prints:

```bash
bash <scripts dir>/cleanup-done.sh
```

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `FLEET_BOARD_CLAUDE` | `claude` | the Claude Code binary |
| `FLEET_BOARD_PLUGIN_DIR` | unset | when set, passed as `--plugin-dir` (for a checkout that is not installed) |
| `FLEET_BOARD_TICK_PROMPT` | `/fleet-board:tick` | the prompt of each tick |
| `FLEET_BOARD_LOG_DIR` | `$HOME/.fleet-board/runs` | where run logs go |
| `FLEET_BOARD_ISOLATE` | unset | fleet-board ships no role-isolation mechanism, so `1` is refused (exit 2) and `0` is the same as unset |
| `FLEET_BOARD_CLEANUP` | `cleanup-done.sh` next to the wrapper | the cleanup script run after each successful tick |
| `FLEET_BOARD_LIST_LIMIT` | 500 (labels), 1000 (Projects) | how many items one board listing asks `gh` for. A reply of exactly this many may be truncated, so the listing fails (exit 1). Two remedies: raise this variable, or shrink what is listed. On labels, the `done` and `wont_do` columns include closed issues and grow without bound: remove the done label (default `fleet:done`) from old closed issues. On Projects, every item counts, done ones included: archive done items. `cleanup-done.sh` alone accepts a done listing at the limit, with a warning; a card it misses only leaves its worktree behind |

## Scheduling with launchd (macOS, optional)

The plugin ships no plist. This is an example to adapt. It starts a run at 22:00 every day.

Save it as `~/Library/LaunchAgents/com.example.fleet-board.plist`. Replace `<repo>` with the absolute path of the repo. Replace `<plugin-dir>` with the plugin directory: the wrapper path that `/fleet-board:status` prints, without its trailing `/scripts/fleet-board-run.sh`. Replace `<PATH>` with the output of `echo $PATH` in a terminal where `claude`, `gh` and `jq` work.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.fleet-board</string>
  <key>WorkingDirectory</key>
  <string><repo></string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string><plugin-dir>/scripts/fleet-board-run.sh</string>
    <string>--repo</string>
    <string><repo></string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string><PATH></string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>22</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string><repo>/.fleet-board-launchd.log</string>
  <key>StandardErrorPath</key>
  <string><repo>/.fleet-board-launchd.log</string>
</dict>
</plist>
```

launchd starts a job with a minimal `PATH` that usually has none of `claude`, `gh` and `jq`, so the plist sets `PATH` itself. Running the wrapper through a login shell (`bash -l`) is not a substitute: a bash login shell reads `~/.bash_profile`, not the zsh files (`~/.zprofile`, `~/.zshrc`) where macOS's default shell, and Homebrew's setup, usually put those tools on `PATH`. The wrapper needs bash, so the program stays `/bin/bash`. Add `.fleet-board-launchd.log` to the repo's `.gitignore`, or point both paths elsewhere. The wrapper's own run log is written under `$HOME/.fleet-board/runs/` either way.

Load it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.fleet-board.plist
```

Remove it:

```bash
launchctl bootout gui/$(id -u)/com.example.fleet-board
rm ~/Library/LaunchAgents/com.example.fleet-board.plist
```

The plugin path changes when the plugin updates. After an update, run `/fleet-board:status` again and fix `<plugin-dir>` in the plist.
