# Running fleet-board overnight

Run the supervisor with `--detach`. The supervisor (`scripts/supervisor.sh`) is a process you start yourself. It plans with `tick-plan.sh --candidates`, starts each role (implementor, reviewer, fixer, merger) as a headless `claude -p --agent` session, runs provider review stages and the merge lane, and keeps going until you stop it. It keeps all of its state in memory: no database, no OS service, no boot registration.

## Starting it

From the repo:

```bash
fleet-board supervisor start --detach
```

`fleet-board` is the launcher `/fleet-board:init` installs in `~/.local/bin`; it runs the plugin's newest installed `supervisor.sh` with the arguments you give it. Without it, `/fleet-board:status` ends with `Supervisor: <absolute path to supervisor.sh>`, and `bash <that path> start --detach` does the same.

`--detach` starts the supervisor in the background, writes its output to `supervisor.log` in the log directory (`$HOME/.fleet-board/runs/`, or `$FLEET_BOARD_LOG_DIR`), and returns once the new process reports that its startup check is done, within 30 seconds. Without `--detach` it runs in the foreground until Ctrl-C, `kill` or `stop`.

The board page's Start does the same as `start --detach`, and resumes a paused supervisor. A supervisor started from a terminal shows up on the page too.

### The startup check

Before it admits any work, `start` looks for cards a crashed run left behind: a card in `in_progress` or `merging` that no session owns, an active marker, a worktree with uncommitted changes, a lock whose holder is gone, or an unreadable note. It prints each one (`#<n> <kind>: <detail>`), notes it on the card, and exits 4 without starting. Resolve each card by moving it, or with `stuck --release N`, which returns the card to its last stable column and clears its marker without touching its branch or PR. `start --ignore-stuck` starts anyway and keeps those cards out of admission.

```bash
fleet-board supervisor stuck            # list them (--json for JSON)
fleet-board supervisor stuck --release 12
```

### One supervisor per repository

`start` takes an exclusive lock for the repository: `<log dir>/<owner>-<name>.lock`, named after `board.repo`. A second `start` for the same repository, from this checkout or another one, names the running one and exits 1.

## While it runs

```bash
fleet-board supervisor status           # mode, phase, active sessions, tokens (--json for JSON)
fleet-board supervisor pause            # admit nothing new; running sessions finish
fleet-board supervisor resume
fleet-board supervisor usage            # token totals from the usage ledger (--card N for one card)
fleet-board supervisor stop             # --drain (the default): finish running sessions, then exit
fleet-board supervisor stop --cancel    # end every session now and return each card to its column
```

## Limits

| Key | Default | What happens |
|---|---|---|
| `limits.max_hours` | `8` | after this many hours the supervisor drains and exits; `0` turns it off |
| `limits.max_tokens` | `20000000` | once this run's known input, output and cache-write tokens reach it, admissions pause (running sessions finish); cache reads are shown but not counted. `supervisor status` and the board show the counted figure as the Budget line |
| `limits.max_tokens_per_card` | `null` | a card whose input, output and cache-write tokens in this run reach it gets no new action; cache reads are shown but not counted |
| `limits.concurrency` | `6` | role sessions running at once |
| `supervisor.provider_concurrency` | `{}` | a cap per provider (`claude` or a provider name) |
| `limits.max_turns` | `200` | `--max-turns` of each role session |
| `limits.rate_limit_max_wait`, `rate_limit_margin` | `3600`, `5` | a GitHub rate limit holds new work until its reset plus the margin; a reset further away than the cap pauses the supervisor |
| `headless.permission_mode` | `auto` | `--permission-mode` of each role session |

Tokens are the only unit: nothing is priced, and a count the ledger could not read is `unknown`, never 0. The other `supervisor.*` keys (the reconcile interval, timeouts, retry backoff, aging, `scope_ignore` and `version_files`) are in [config.md](config.md#supervisor).

## Permissions

- No role session gets `--dangerously-skip-permissions`.
- `--permission-mode` comes from `headless.permission_mode`, which defaults to `auto`. In `auto` mode, Claude Code approves or denies each tool call itself, with its safety classifier, so a session can run unattended without skipping permission checks. No one is there to answer a permission prompt, so a stricter mode such as `default` leaves the session's commands denied. A session whose `system/init` event reports another mode is a failure.

## Merges under merge.policy auto

Merges stay human by default: under `merge.policy: human` the supervisor merges nothing and leaves reviewed PRs to be merged by hand. Under `merge.policy: auto` it merges them itself, one card at a time, in the `merging` column.

**How.** Claude Code's auto-mode safety classifier blocks an unattended `gh pr merge` in a headless session, so no role session merges. The supervisor's merge lane runs `scripts/merge-reviewed.sh --card <n>` instead, a plain shell step outside any Claude session, bound to the planned head. It merges (`gh pr merge <pr> --squash`, never `--admin`) only a card whose review is clean for the PR head, with no routed review stage left, whose PR is open, not a draft and green, and which does not need Human QA. After the merge it runs `verify-main.sh`. The card's `## After merge` steps run before the merger agent, which then runs and decides whether the card is finished; the card goes to Done only after that. See [the README](../README.md#merger-and-deploys). The gate hook G2 still applies to any merge a Claude session makes.

## Worktree cleanup

The supervisor never removes worktrees, because Claude Code's auto-mode classifier denies that as irreversible local destruction. Remove the worktrees of done cards from the repo root, outside any Claude session. `<scripts dir>` is the directory of the path that `/fleet-board:status` prints:

```bash
bash <scripts dir>/cleanup-done.sh
```

It first lists the worktrees directory locally and reads the board only for done cards that still have a `<n>-*` entry there, so its cost grows with the leftover directories, not with the Done column.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `FLEET_BOARD_CLAUDE` | `claude` | the Claude Code binary |
| `FLEET_BOARD_PLUGIN_DIR` | unset | when set, passed as `--plugin-dir` (for a checkout that is not installed) |
| `FLEET_BOARD_LOG_DIR` | `$HOME/.fleet-board/runs` | the log directory: `supervisor.log`, role logs, the run lock |
| `FLEET_BOARD_SOCKET_DIR` | `/tmp/fleet-board-<uid>` | where the supervisor's private socket lives |
| `FLEET_BOARD_LIST_LIMIT` | 1000 | how many issues or project items `import-github.sh` asks `gh` for. A reply of exactly this many may be truncated, so the import stops (exit 1); raise this variable and run it again. Nothing else reads it |

## Scheduling

The plugin ships no service file and registers nothing at boot. To start the supervisor on a schedule, have your own scheduler (launchd, cron, a terminal multiplexer) run `fleet-board supervisor start --detach` from the repo root, with a `PATH` that has `fleet-board`, `claude`, `gh`, `jq` and `python3`. The launcher finds the newest installed plugin on every run, so plugin updates need no change to the scheduler.

The design is in `docs/specs/2026-11-11-cli-supervisor-design.md` in the fleet-board repository.
