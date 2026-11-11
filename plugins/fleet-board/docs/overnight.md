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

`--repo` defaults to the current directory. The wrapper runs from that repo's git root, checks the config (`config.sh --check`; exit 3 when there is no `.fleet-board.yml`), takes the run lock, prints the path of its run log, and starts ticking.

### One run per repo

The wrapper holds a run lock for its whole life: `$HOME/.fleet-board/runs/<owner>-<name>.lock` (in `$FLEET_BOARD_LOG_DIR` when that is set, beside the run logs). The file holds the wrapper's pid on line 1 and that process's start time on line 2 (`ps -o lstart=` in the C locale and UTC). While the lock names a live process with that start time, a second wrapper for the same repo prints `fleet-board-run: another run holds <lock> (pid N)` and exits 1 before it writes a log. A lock whose pid is gone, or now belongs to a process started at another time, is stale: the next wrapper replaces it. The wrapper uses Python 3 and an advisory lock on the adjacent `.lock.guard` file to serialize claims and stale-lock replacement. A simultaneous claimant exits 1 before writing a run log. The wrapper removes its lock on exit, including after Ctrl-C or TERM; after `kill -9` the lock stays until the next start finds it stale. The board page reads the same file, so a run started from a terminal or launchd shows as running there and the page's Start refuses a second one.

## When it stops

`stop-file`, `max-hours` and `max-cost` are checked before every tick. `nothing-dispatchable`, `cost-unknown` and `max-cost` are checked right after a successful tick, and `consecutive-failures` after a failed one. `permission-mode-mismatch` is checked first, right after any tick, failed or not.

| Stop reason | Condition | Config key | Exit |
|---|---|---|---|
| `stop-file` | `<repo root>/.fleet-board.stop` exists | none | 0 |
| `max-hours` | elapsed hours exceed the limit | `limits.max_hours` (default 8) | 0 |
| `max-cost` | the cost estimate exceeds the limit | `limits.max_cost_usd` (default 40) | 0 |
| `nothing-dispatchable` | a successful tick's report ends `dispatchable: false` | none | 0 |
| `consecutive-failures` | this many failed ticks in a row, including ticks whose plan failed | `limits.max_consecutive_failures` (default 3) | 1 |
| `rate-limit-wait-cap` | waiting out GitHub rate limits would pass the total wait cap | `limits.rate_limit_max_wait` (default 3600 seconds) | 1 |
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

### Rate limits and sharing a token

When a tick's `Plan failed:` reason names a rate limit and gives a reset time as `resets at <UTC time like 2026-10-30T12:00:00Z>`, the run does not stop. It sleeps until that reset plus `limits.rate_limit_margin` seconds (default 5), then runs the next tick. Such a tick does not count toward `limits.max_consecutive_failures`. The log shows `tick N RATE LIMITED` and `rate limit: waiting <n>s`. The waits add up: when the next wait would push the total past `limits.rate_limit_max_wait` seconds (default 3600), the run stops with `rate-limit-wait-cap` and exit 1, and the log gives the reason. A rate limit with no reset time, and any other `Plan failed:`, stay failed ticks.

Several runs on one GitHub token can exhaust its quota together. Set `limits.min_tick_gap` (seconds, default 0, off) and every run that shares the lock file keeps its tick starts at least that far apart. The lock file is `$HOME/.fleet-board/token.lock` (override with `FLEET_BOARD_TOKEN_LOCK`); it holds the last reserved start time, and a `.d` directory beside it guards the update (one older than 10 seconds is treated as stale and removed). Runs on different tokens should use different lock files.

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
| 1 | stopped: `consecutive-failures`, `cost-unknown` or `permission-mode-mismatch`; `rate-limit-wait-cap`; or a setup failure (not a git repo, `claude` not found, the log cannot be written, another run holds the run lock) |
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

On a `local` board, the Start and Stop buttons on the board page do the same thing by hand: Start spawns this wrapper in its own session, and Stop writes the same `.fleet-board.stop` file. The page counts a wrapper that holds the run lock as a live run even when the page did not start it. After each tick's session exits, the wrapper on a `local` board also removes every `<board.dir>/active/` marker, so a card whose role crashed without a report stops showing as worked on. The page keeps its own state (the run's pid and log) under `${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}/web/<owner>-<name>/`. `FLEET_BOARD_RUN` makes Start spawn a different script.

## The run log

Each run appends every tick to one file:

```
$HOME/.fleet-board/runs/<owner>-<name>-<YYYYmmdd-HHMMSS>.log
```

Set `FLEET_BOARD_LOG_DIR` to put the logs somewhere else. A relative path is taken from the directory the wrapper is started in. A log directory the wrapper creates is mode 700, and the files it writes are mode 600, because they hold tick reports and raw session output.

A successful tick's block is a header line (`=== tick <n> <time> rc=0 cost_estimate_usd=<x> (estimate) ===`), the tick report, and the output of the worktree cleanup. A failed tick's block starts `=== tick <n> FAILED <time> rc=<rc> ===`, then gives the reason, the path of the tick's whole output, and the last 20 lines of that output, each cut to 2000 characters. The whole output of a failed tick is kept next to the log as `<log name>-tick-<n>.jsonl`. Successful ticks keep no such file.

## The cost figure is an estimate

A tick's cost is the session's `total_cost_usd`, which Claude Code computes on the client. When a session reports none, the wrapper prices its `modelUsage` with `scripts/prices.json`, a dated price snapshot. The figure is not a bill. On a subscription, it measures usage, not money. A failed tick's cost counts too, when its session reports one. A failed tick whose session ends without a `result` event, or whose result carries no cost, adds $0 and is logged `cost_estimate_usd=unknown`, even though it may have spent money.

### Provider spend counts toward `max_cost_usd`

A review stage that runs on a provider model (not a Claude subagent) is billed by that provider, outside the Claude session. `stage-review.sh` appends each call's cost to a ledger, `provider-spend.jsonl`, in `FLEET_BOARD_LOG_DIR` (default `$HOME/.fleet-board`, so not the `runs` subdirectory). The wrapper exports `FLEET_BOARD_RUN_ID` (`<epoch>-<pid>`) before the first tick, and each ledger line carries it. After each tick the wrapper adds the `cost_usd` of the lines appended during that tick with this run's id to the tick's cost, so `max_cost_usd` holds on the combined total, and two runs sharing one ledger never count each other's spend. When the provider part is non-zero the log line reads `cost_estimate_usd=<total> (estimate; provider <x>)`. A missing ledger counts as zero, and a malformed line (not JSON, or this run's with a `cost_usd` that is not a non-negative number) is skipped with a warning. A line appended during the tick with no run id (a `stage-review.sh` run outside the wrapper's environment) is not counted, and the tick warns once: `ledger line without a run id in tick <n>; provider spend may be uncounted`. Like the Claude figure, the provider figure is an estimate: the stage's `price` settings times the token counts the provider reports.

The provider key variables (for example `OPENAI_API_KEY`) must be exported in the environment that starts the wrapper. A tick inherits the wrapper's environment, and nothing else supplies them; with a variable unset, its stage fails (`stage-review.sh` exits 3) and is counted as an action failure in the tick report, like any report error.

## Permissions

- The wrapper never passes `--dangerously-skip-permissions`.
- `--permission-mode` comes from `headless.permission_mode`, which defaults to `auto`. In `auto` mode, Claude Code approves or denies each tool call itself, with its safety classifier, so a tick can run unattended without skipping permission checks. No one is there to answer a permission prompt, so a stricter mode such as `default` leaves the tick's commands denied.
- With `headless.permission_mode: bypassPermissions`, the wrapper prints a one-line warning, to stderr and to the log, before the first tick.

## Merges under merge.policy auto

Merges stay human by default: under `merge.policy: human` an overnight run merges nothing and leaves reviewed PRs to be merged by hand. Under `merge.policy: auto` the run merges them itself.

**How.** Claude Code's auto-mode safety classifier blocks an unattended `gh pr merge` in a headless session ("Merge Without Review"), so no tick merges. Instead, after `settle.sh` and before `cleanup-done.sh`, the wrapper runs `scripts/merge-reviewed.sh` from the repo root, as a plain shell step outside any Claude session, the same way it runs `settle.sh` and `cleanup-done.sh`. The classifier is never involved. The wrapper adds no permission rule and never uses `--dangerously-skip-permissions`.

**What it merges.** It lists the in_review column and every review stage column and asks `tick-plan.sh --settle-merge` for a plan. It merges (`gh pr merge <pr> --squash`, never `--admin`) only a card whose review is clean for the PR head, whose PR is open, not a draft and has every check green (a failing or pending check waits), and which does not need Human QA. A card in Human QA is never listed and never merged. The gate hook G2 still applies to any merge a Claude session makes. After the merge it records `merged_pr`, runs `verify-main.sh`, moves the card to Done and writes the note. A card with an `## After merge` section is left for the manager's finish step, which runs those commands under the allowlist. An ordinary per-card failure is logged and the next tick plans what is left. Verification or recovery failures stop the wrapper with `main-verification-failed` before cleanup or another tick. Set `FLEET_BOARD_MERGE_REVIEWED` to use another script.

**Why not the alternatives.** A user allow rule for `gh pr merge` in their own Claude Code settings depends on personal settings, which a plugin must not assume. `gh pr merge --auto` depends on branch protection being configured on the repo.

## Worktree cleanup

After each successful tick, the wrapper first runs `scripts/settle.sh` from the repo root, in its own shell and outside any Claude session. It lists the in_progress and in_review columns and every review stage column, runs `tick-plan.sh --settle`, and does only the steps that start no agent: an in_progress card with a PR gets its routing labels (`review-stages.sh route`, before the move) and moves to in_review, a clean review in a stage column moves the card to the next stage (`advance_stage`), a clean review reaches Human QA (with the hand-off comment), a clean draft PR is marked ready, and a card whose findings survive the last round is blocked. It reads the manager note, not posted reports, and it never merges and never moves a card out of Human QA. It writes no failure count: if a step fails, the next tick plans the same action and counts it. Its output goes into the log; a failure logs `warning: settle.sh exited <rc>` and its stderr, and the run goes on with the same stop reason and exit code. A person's interactive `/fleet-board:tick` does not run it. Then the wrapper runs `scripts/cleanup-done.sh` from the repo root, in its own shell and outside any Claude session. It removes the worktrees of cards that reached done. It first lists the worktrees directory locally and reads the board only for done cards that still have a `<n>-*` entry there, so its cost grows with the leftover directories, not with the Done column. The manager never removes worktrees itself, because the auto-mode classifier denies that as irreversible local destruction. The cleanup's output goes into the log. If it fails, the log gets `warning: cleanup-done.sh exited <rc>` and its stderr. That is a warning only: the tick still counts as successful, and the run goes on.

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
| `FLEET_BOARD_TOKEN_LOCK` | `$HOME/.fleet-board/token.lock` | the lock file shared by runs on one token, used when `limits.min_tick_gap` is above 0 |
| `FLEET_BOARD_SETTLE` | `settle.sh` next to the wrapper | the settle script run after each successful tick, before the cleanup |
| `FLEET_BOARD_CLEANUP` | `cleanup-done.sh` next to the wrapper | the cleanup script run after each successful tick |
| `FLEET_BOARD_LIST_LIMIT` | 1000 | how many issues or project items `import-github.sh` asks `gh` for. A reply of exactly this many may be truncated, so the import stops (exit 1); raise this variable and run it again. Nothing else reads it |

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

### Persistent supervisor: boot registration (experimental)

The persistent supervisor (`supervisor.enabled`, default `false`) can be registered with the OS so a domain is restored after a reboot. Registration is always an explicit action; a YAML value alone never installs a service.

```bash
FLEET_BOARD_DOMAIN=/path/to/repo supervisor.sh service install            # register + render, nothing is started
FLEET_BOARD_DOMAIN=/path/to/repo supervisor.sh service install --apply    # also run the unprivileged activation commands
FLEET_BOARD_DOMAIN=/path/to/repo supervisor.sh service status
supervisor.sh service rollback                                            # restore the previous runtime after an upgrade
FLEET_BOARD_DOMAIN=/path/to/repo supervisor.sh service uninstall --apply
```

- Install never calls `sudo`. On macOS the default `--kind boot` renders a LaunchDaemon that runs as your user (`UserName`), which is the only way to recover before anyone logs in. Installing it needs an administrator, so the command prints the exact `sudo` commands for you to run. `--kind login` is a LaunchAgent that starts at login only; status reports it as `login_fallback`, never as boot recovery.
- On Linux the unit is a systemd user service. Pre-login recovery also needs lingering (`loginctl enable-linger <user>`); status reports `lingering_missing` and prints the command, but never runs it for you.
- `boot_registration` in status is `missing` (nothing registered), `pending_activation` (registered but not confirmed active), `verified`, `login_fallback` or `lingering_missing`. Only a probe by `service status` can make it `verified`.
- The registry (`~/.fleet-board/supervisor-registry`, or `FLEET_BOARD_REGISTRY_DIR`; 0700 directory, 0600 files) records executable paths, the protocol version and the names of credential variables (`--credential-env NAME`, repeatable). Secret values are never written. The watcher reads credentials from its own environment and from `credentials.env` in the registry directory (a regular file you own with mode 0600; `NAME=value` lines, optional `export`, optional quotes; it is parsed as data, never run by a shell). The file is re-read on every check, so creating it or fixing its mode needs no restart: the next check launches the service with the values it read, through the service's environment only.
- First install leaves the desired mode `stopped`. The boot entry is a resident watcher: while the domain is registered the OS unit's process stays alive whatever the desired mode, and every `FLEET_BOARD_BOOT_INTERVAL` seconds (default 15) it re-reads the YAML, the registry and the host boot id and checks for a live owner by asking the service's socket (the watcher never takes any lock on `service.lock`, so it cannot make a starting service lose the lock). At boot, `supervisor.start_on_boot: true` restores `running` (recovery, then scheduling) and `paused` (recovery, then paused); `stopped` stays stopped. `false` skips boot activation, but an explicit Start (or Resume) after that still works: the watcher sees it and, whenever a running or paused domain has no live owner, relaunches it through the normal launcher, which runs recovery. So a crashed owner is relaunched, whether it was started at boot or by an explicit Start in this boot, and whether another owner was already serving when the entry started. Keep-alive never overrides stopped intent: after a Stop nothing is relaunched until the next explicit Start. A service the watcher launches is detached, and the units are written so that ending the watcher never takes it down: the systemd unit has `KillMode=process`, and the launchd job has `AbandonProcessGroup`. So `systemctl --user stop` / `restart` and `launchctl bootout` stop or restart only the watcher; the service and its runners keep running. To stop the domain, use the supervisor Stop (`supervisor.sh stop`, or Stop on the board); that is the only thing that stops work.
- Problems that need you (invalid YAML, repository missing, executable missing, credentials missing, incompatible store or protocol, malformed registry entry) are shown as `last_error` in status, launch nothing, and never touch stored state. The watcher stays alive and re-checks each interval, so fixing the problem is enough. The bash launcher itself exits 75 (retry every 30 seconds) only when the recorded python or plugin scripts are gone; after `service install` or `service rollback` the watcher re-executes the new launcher in place (same process id), so the unit is not restarted and a running service is untouched; it exits 75 only if that re-exec is impossible. An unregistered or uninstalling domain ends the watcher with exit 0, so the manager does not restart it.
- Upgrade compatibility compares real things: the live service's reported `runtime.protocol`, the store's schema version, and the runner protocol recorded for each active attempt. `service install` refuses (changing nothing) when the store schema or an active attempt's runner protocol is not one this runtime speaks, or when a live service with active attempts is on another protocol (an idle mismatched service only produces a warning). The boot entry applies the same checks before every launch. A refusal is visible as `last_error` (`incompatible_store`, `incompatible_runner`, `incompatible_protocol`), is recoverable, and never wipes state.
- An upgrade that changes the registry or launcher first backs up the runtime files and, with the sqlite backup API and private permissions, the domain's store under `backups/<version>-<n>/`. `service rollback` restores the registry and launcher only. Add `--restore-store` (with `--domain`) to also restore the backed-up store; this discards events recorded after the backup, is refused while a service holds the store, and first saves the replaced store as `store-before-restore-<n>.sqlite3`.
- `service uninstall` removes the unprivileged files. While the unit still exists (a macOS LaunchDaemon, which needs your `sudo` commands, or without `--apply`) the registration stays and status reports `uninstall_pending`; it becomes `missing` once `service status` sees the unit gone. `started_work` in the install result is true only when an applied LaunchAgent will start a restorable (`start_on_boot: true`, running or paused) domain at load; `will_start_work_on_load` says the same for a unit you bootstrap yourself.
- Service output goes to `supervisor-service.log` and `supervisor-boot.log` in the log directory. Upgrading re-runs `service install`; the previous runtime is backed up and `service rollback` restores it.
- Known limits: the two logs are append-only and never rotated (rotate or truncate them yourself). A Phase 5 service still listening on a socket under an old `TMPDIR` path is not migrated; Phase 5 was never deployed and the supervisor is disabled by default, so stop it and start it again after upgrading.

These generated-file tests prove file contents and decisions only. They do not prove that a service starts after a real reboot; that is verified separately on a real host.

### Verified merge draining

After settlement, auto-policy runs drain up to `FLEET_BOARD_MERGE_LIMIT` merge attempts (default 10) from the review-column snapshot. Each attempt uses a fresh plan and binds the merge to its planned head. Failed candidates are attempted once per drain; unrelated eligible cards can proceed. Previously merged cards needing verification are recovered first.

Verification must return literal `ok: true`. Red, malformed, missing, or unrecordable verification stops the wrapper with `main-verification-failed` (exit 1), before cleanup or another tick. Failed verification evidence remains in the card note; the card cannot finish until verification succeeds. The merge helper returns exit 3 for this stop condition. Other per-card errors remain warnings and are retried on a later tick.

A lock directory named `fleet-board-merge.lock` in the Git common directory serializes direct drain invocations as well. Normal exits and handled signals release it. After an uncatchable termination, confirm no drain is running before removing that directory.

### Scope-aware admission

Ready cards are considered in ascending card-number order. Each selected start reserves its declared Scope paths for the rest of that plan, alongside cards already in progress or review. Directory paths cover descendants, so `src/` overlaps `src/model.js` but not `src-other/model.js`. Active PR changed files supplement the declared paths. If a PR file list cannot be read completely, new starts wait; existing review and fix actions can continue. Scope-free cards retain their existing behavior, so declare meaningful paths for work that may overlap.

### Fresh scheduling decisions

After settlement, merge draining and cleanup, the wrapper clears the board cache and reads a new tick plan before deciding whether to stop. This both picks up newly unblocked work and avoids an extra tick when post-tick work emptied the queue. Pending follow-up filing keeps the run active. A failed or malformed refresh stops with `plan-refresh-failed` (exit 1). `FLEET_BOARD_TICK_PLAN` overrides the planner executable for controlled testing.
