# fleet-board

Turns a GitHub issue board into a work queue for a fleet of Claude Code agents. You write cards with an `## Acceptance` section and mark them ready. Each tick, a manager agent moves every open card one step: an implementor writes a failing test first and opens a draft PR, a reviewer checks it on evidence (an Acceptance-to-test map, mutation testing, one re-run claim), and a fixer addresses what the review found. Each role works in its own git worktree. Finished cards land in Human QA or as a PR ready for review, and you do the merge. A hook keeps agents from releasing Human QA, merging when they shouldn't, or starting a card without acceptance criteria.

## Install

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

You need:

- `gh`, logged in, with the `repo` scope. A GitHub Projects board also needs the `project` scope. `/fleet-board:init` checks this and prints the `gh auth refresh -s ...` command to run when a scope is missing.
- `jq` and `git` on `PATH`.
- Claude Code 2.1.x.

The scripts are plain bash and were tested with macOS's `/bin/bash` 3.2.

## Your first hour

This walks one card through a fresh repo on the labels board. Commands run from the repo root.

1. **Create a repo** on GitHub with a little code and a test runner that can run one test file at a time, and clone it.
2. **Run `/fleet-board:init`.** Choose **Labels**. It proposes commands from `package.json` when there is one; confirm or edit them. `commands.test_one` is the one that matters most: a command with `{file}` where one test file goes, such as `node --test {file}`. Init creates the eight `fleet:<state>` labels plus `needs-human-qa` (and `bug`, when the repo has none), and writes `.fleet-board.yml`.
3. **Commit and push `.fleet-board.yml`.** Role agents work in worktrees branched from `origin/HEAD`. `config.sh` falls back to the main checkout's copy when a worktree has none, but pushing keeps every clone consistent.

   ```bash
   git add .fleet-board.yml && git commit -m "chore: add fleet-board config" && git push
   ```

4. **Write one card.** Open an issue whose body has an `## Acceptance` section listing, as `- ` bullets, what must be true when it's done. Each bullet must be something a test can check; on-device checks go under `## Human QA` instead (see [Writing a card](#writing-a-card)). Keep it small: one function and its tests. Add the `needs-human-qa` label if you want to look at the result before any PR is marked ready.
5. **Label it `fleet:ready`.** That's your move; the manager never takes cards out of Backlog. A ready card without `## Acceptance` gets one comment explaining why it won't start.
6. **Run `/fleet-board:tick`** a few times, or `/fleet-board:run` to keep ticking until nothing is left to do. Each tick prints a report ending in `dispatchable: true` or `dispatchable: false`.
7. **Watch the card move.** With the defaults and a clean review:

   | After | Card | What you'll see |
   |---|---|---|
   | tick 1 | `fleet:in_progress` | A branch `fleet/<n>-<slug>` and a worktree under `../.fleet-worktrees/`. A draft PR whose first commit holds only the failing tests. The implementor's report and the manager note as comments on the card. |
   | tick 2 | `fleet:in_review` | The reviewer's round 1 report on the card, with its findings and mutation counts. |
   | tick 3 | `fleet:human_qa`, or still `fleet:in_review` | With `needs-human-qa` (or a diff touching `human_qa_paths`): the card is in Human QA with a "What to check in Human QA" comment quoting its Acceptance section. Otherwise the PR is marked ready for review. If the review found Critical or Important issues, the fixer ran instead and a new review round followed in the same tick. |
   | tick 4 | unchanged | Nothing left to dispatch: `dispatchable: false`. |

   In a live sandbox run, two such cards reached Human QA in 3 ticks. The run stopped after the fourth, 11 minutes in, at an estimated $2.08.
8. **Release Human QA yourself**, in the GitHub UI. Check the change, merge the PR, and move the card to `fleet:done` (or back to `fleet:ready`). No agent can do this step; the gate blocks it. On the no-QA path, merge the ready PR yourself. The next two ticks check `main` and move the card to Done.

## The board

A card is a GitHub issue. Its state is a label (`fleet:<state>`) on the labels board, or the Status column on a Projects board.

```
Backlog → Ready → In Progress → In Review → Human QA → Done
                        ↓             ↓
                     Blocked       Blocked
```

Plus Won't Do.

### Writing a card

- **`## Acceptance` lists only what a test can check.** Write one `- ` bullet per behavior. The reviewer maps every bullet to a test, and a bullet with no test is an Important finding.
- **On-device and manual checks go in their own section.** Put them under a separate `## Human QA` heading. Do not put them in Acceptance: no agent can test them, so a fixer can only block the card. The work reaches Human QA through the `needs-human-qa` label or `human_qa_paths`, and you read that section on the card when you check it.

**Who moves what.**

- **You** move cards from Backlog to Ready, and release them from Human QA (to Done, or back to Ready).
- **The manager** makes every other move: Ready to In Progress, In Progress to In Review, In Review to Human QA or Done, any active card to Blocked, and Blocked back to Ready once the PR it was waiting on has merged. It never touches Backlog, Human QA, Done or Won't Do.
- **Role agents** never move cards. They post their reports as comments, and the manager acts on them.

**One writer per card.** `gh issue edit` sends label additions and removals as separate mutations, so two writers on one issue can leave it with the wrong labels.

**One step per tick.** Each tick, `tick-plan.sh` reads the Ready, In Progress, In Review and Blocked columns and picks exactly one action per card. The manager carries out those actions, dispatching up to `limits.concurrency` role agents at once, and prints the tick report. Under `merge.policy: human` (the default), a clean, reviewed PR is marked ready and waits for you.

**The manager note.** The manager keeps no state between ticks. Everything it needs to resume a card lives in one comment on that card, starting `<!-- fleet-board:manager-note -->`, with a JSON block holding the branch, worktree, PR, review round, models and failure counts. Leave it alone unless the tick report tells you to run a `note.sh reset-failures` command.

**When a card gets blocked.** The manager moves a card to Blocked, with a comment listing why, when:

- Critical or Important findings survive `review.max_rounds` review rounds;
- the implementor has produced no PR after `review.max_rounds` attempts;
- `review.max_rounds` actions in a row on the card made no progress.

From round `models.escalate_after_rounds` on, the implementor and fixer run on the reviewer's model.

**Worktree cleanup.** The manager moves a finished card to Done but never removes its worktrees, because Claude Code's safety classifier blocks that deletion in unattended sessions. The headless wrapper runs `cleanup-done.sh` after each successful tick. If you tick interactively, `/fleet-board:status` lists done cards that still have worktree directories and prints the exact command to remove them.

**Follow-ups.** A role that notices work outside its card reports it under `Out of scope:` or `Bugs found:`. The manager files each item as a Backlog card. A bug gets the `bug` label and a body with repro, expected and observed. An item whose title matches an open issue is linked to it with a comment instead of being filed again. Roles never create cards themselves.

**Checking `main`.** After a PR merges, the next tick checks `main`: the typecheck and the PR's test files, in a separate `main-check` worktree. If `main` is red, it files a `[P0] main is red after #<pr>` card in Backlog.

## Config reference

`.fleet-board.yml` lives at the repo root. `config.sh` reads it, merges it over `scripts/config-defaults.json`, and validates it. Set only what differs from the defaults: a map you give is merged key by key, but a list (`test_paths`, `human_qa_paths`) replaces the default list whole.

| Key | Default | What it does |
|---|---|---|
| `board.backend` | `github-labels` | `github-labels` or `github-projects` |
| `board.repo` | none (required) | `owner/name` of the repo the cards live in |
| `board.project_number` | none | the Projects board number; required for `github-projects` |
| `board.project_owner` | `null` | the project's owner, when it isn't the repo owner |
| `board.states` | `{}` | maps a canonical state to your label or column name |
| `commands.test_one` | none | runs one test file; `{file}` is replaced by its path |
| `commands.typecheck` | none | run by roles, and on `main` after a merge |
| `commands.lint` | none | run by roles |
| `commands.qa_build` | none | run in the worktree before a card goes to Human QA; the last 20 lines go in the Human QA comment |
| `worktrees.dir` | `../.fleet-worktrees` | where card worktrees go, relative to the repo root |
| `worktrees.setup` | none | run once in each new worktree, such as `npm ci` |
| `worktrees.mutate_on_copy` | `false` | the reviewer mutates a copy of the review worktree instead of the worktree itself |
| `test_paths` | `["test/**", "tests/**", "__tests__/**", "**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/test_*"]` | globs that identify test files |
| `human_qa_paths` | `[]` | a PR touching any of these globs sends its card to Human QA |
| `merge.policy` | `human` | `human` or `auto`; see below |
| `review.mutation` | `true` | the reviewer runs mutation testing against the diff |
| `review.verify_claim` | `true` | the reviewer re-runs one claim from the implementor's report |
| `review.max_rounds` | `3` | review rounds, implementor attempts, and no-progress actions allowed before a card is blocked |
| `models.manager` | `sonnet` | the manager's model |
| `models.implementor` | `sonnet` | |
| `models.reviewer` | `opus` | |
| `models.fixer` | `sonnet` | |
| `models.escalate_after_rounds` | `2` | from this round on, implementor and fixer use `models.reviewer` |
| `limits.concurrency` | `6` | role agents running at once |
| `limits.max_hours` | `8` | headless wrapper only |
| `limits.max_cost_usd` | `40` | headless wrapper only |
| `limits.tick_interval` | `300` | seconds between ticks, for the wrapper and `/fleet-board:run` |
| `limits.max_consecutive_failures` | `3` | headless wrapper only |
| `limits.max_turns` | `200` | `--max-turns` for each headless tick |
| `headless.permission_mode` | `auto` | `--permission-mode` for each headless tick |

When `models.implementor` and `models.reviewer` are the same, every tick warns that the reviewer shares the writer's blind spots.

**`merge.policy`.** Under `human`, the gate blocks every `gh pr merge`, and clean PRs wait for you. Under `auto`, the manager merges a PR whose review is clean, whose checks are green, and whose card doesn't need Human QA. `auto` is not supported headless: Claude Code's safety classifier blocks unattended merges ("Merge Without Review"). Merges stay human by default. `auto` works only where you have explicitly allowed merges in your own Claude Code settings.

**`board.states`.** Canonical states are `backlog`, `ready`, `in_progress`, `in_review`, `human_qa`, `blocked`, `done` and `wont_do`. On the labels board each defaults to `fleet:<state>`. On a Projects board they default to `Backlog`, `Ready`, `In Progress`, `In Review`, `Human QA`, `Blocked`, `Done` and `Won't Do`. Map only the ones that differ. HMB Workout keeps its existing column names:

```yaml
board:
  backend: github-projects
  repo: drothschild/HMBWorkout
  project_number: 1
  states: { in_progress: "In progress", in_review: "In review", human_qa: "Require Human Inteteraction", wont_do: "Won't Do" }
```

**Supported YAML.** `config.sh` parses a subset of YAML, and anything else fails with a line number:

- Keys are bare identifiers (`[A-Za-z_][A-Za-z0-9_]*`) at indentation 0 or 2 spaces, at most two levels deep.
- A value is a double- or single-quoted string (no escape sequences), `true`, `false`, `null`, an integer or decimal, a bare string, a flow list `[a, "b"]`, or a flow map `{ k: v, k2: "v2" }`.
- Comments start with `#` at the start of a line or after whitespace, outside quotes.
- Rejected: tabs in indentation, block lists (`- item`), a third nesting level, nested flow collections, anchors and aliases, multi-line strings, and duplicate keys.

**Finding the file.** `config.sh` uses `$FLEET_BOARD_CONFIG` when set, then `.fleet-board.yml` at the git root, then the one in the main checkout (for a linked worktree). Its exit codes: 3 no config, 4 YAML outside the subset, 5 an invalid value.

## Gates

`hooks/gate.sh` is a `PreToolUse` hook on Bash. It reads every Bash command the manager or a role agent is about to run, and blocks it with exit 2 and a one-line reason:

1. **Human QA.** Nothing moves a card out of `human_qa`: not `board-move.sh`, `gh issue edit`, `gh project item-edit`/`item-archive`/`item-delete`, editing or deleting a state label, or a raw label or Status API write.
2. **Merges.** Under `merge.policy: human`, every `gh pr merge` is blocked. Under `auto`, a merge is blocked when it uses `--admin`, names no PR, targets a draft, or the PR's checks are not green. Raw merges through the API are blocked.
3. **Ready.** `board-move.sh N ready` is blocked when the card has no `## Acceptance` section.

The gate is inert in a directory without `.fleet-board.yml`, so it does nothing in your other repos. With an invalid config, it fails closed and blocks board and merge commands until you fix the file. A command with no gated keyword passes after one `jq` call, without reading the config or the network. When it can't tell what a gated command would do (a variable where a card, PR, state or directory belongs) or can't look up the board or PR in time, it blocks.

`FLEET_BOARD_GATE_TIMEOUT` caps the lookups in one call, in seconds: 45 by default, at most 50. The hook's own timeout is 60 seconds, after which Claude Code lets the call through. Without `jq`, the hook exits 0 silently, but every fleet-board script needs `jq` too, so board commands fail anyway.

**Limits.** The gate reads command text before it runs. A string check cannot see:

- commands written to a script file and then run (`bash x.sh`);
- `gh api graphql -F query=@file`, and `-f query="$(cat q.graphql)"`;
- gh aliases (`gh alias set`) and gh extensions;
- HTTP clients other than `curl` and `gh api`: `wget`, `httpie`, `python -c`, `node -e` and so on;
- `gh issue close N` on a Projects board, whose auto-Done workflow moves the card (on the labels board, closing leaves the labels alone);
- `gh issue edit N --remove-project`, which takes the card off the board;
- `git push origin :main` and other pushes: merges by push are not gated;
- obfuscation beyond what the hook decodes: `$'gh'`, `eval "$(printf ...)"`, a variable holding a whole command (`C="gh pr merge 5"; $C`), `alias` with `shopt -s expand_aliases`, `env -C dir` or `sudo -D dir`, and shell functions defined in an earlier Bash call;
- `gh ... -R owner/board` or `GH_REPO=owner/board` from a directory without a config, which is inert by design;
- `parallel board-move.sh ::: 14 ::: done`;
- `cd -P link/..`, which the hook resolves logically and the shell physically.

It also blocks some harmless commands, because it prefers a block to a miss:

- commands that only mention a gated command, such as `git commit -m "fix gh pr merge docs"` or `grep -rn "gh pr merge" docs/` (quoted text is checked too, since `bash -c "..."` runs it);
- here-documents and comments containing a gated command;
- `cd <dir>; gh pr merge N` after `true &&`, in a pipeline, or after `||`;
- `cd "$VAR" && ...`, `source env.sh && ...` and `popd && ...` before a gated command, since the directory is unknown;
- calls over 64 KiB with a gated keyword, more than 32 gated commands in one call, or nesting deeper than 24.

To get past a false positive, put the text in a file (`git commit -F msg.txt`), phrase it differently, `cd` to a literal path, or split the call.

The gates stop agents that use the documented commands. Branch protection on GitHub remains the backstop for merges.

## Other plugins

Ticks and role agents load your other plugins and your `~/.claude/CLAUDE.md`, like any Claude Code session. A global instruction such as "open the PR in the browser" or a plugin hook that injects a skill mandate could, in principle, pull a role off its spec.

This was measured before release, on a setup with 16 other plugins (several with `SessionStart` and `UserPromptSubmit` hooks) and a global `CLAUDE.md` with branch, PR, TDD and browser directives. Across every role and tick transcript, no role invoked a foreign skill or agent, asked the user a question, opened a browser, or created a PR beyond the implementor's one required draft PR. Isolated runs of the implementor and reviewer, with no user plugins or `CLAUDE.md`, gave the same counts and results. So fleet-board ships no isolation (`ROLE_ISOLATION: none`). `FLEET_BOARD_ISOLATE` is unset by default, `0` means the same, and the headless wrapper refuses `1` with exit 2.

**Interactive use.** `/fleet-board:tick`, `/fleet-board:run`, or plain English such as "process the board" run inside your own session, where no isolation could apply anyway. The same measurement covers this case, and found nothing (`INTERACTIVE_RISK: none`). For long runs, use the headless wrapper anyway: `/fleet-board:run` keeps your session busy and spends its context on every tick.

Your setup isn't the one measured. A plugin with its own `PreToolUse` hook can still block a role's commands; a rule-based hook plugin with rules that match `gh` or `git`, for example. If a tick report shows commands denied by something other than `fleet-board gate:`, look there first.

Names and gates can't conflict otherwise: plugin skills and agents are namespaced (`fleet-board:tick`, `fleet-board:implementor`), and the gate is the only `PreToolUse` hook fleet-board adds.

## Running overnight

`fleet-board-run.sh` runs ticks headless, one after another, until a stop condition holds. Each tick is a `claude -p "/fleet-board:tick"` session, the same tick you get from `/fleet-board:tick`.

### Finding the wrapper

Run `/fleet-board:status`. Its last line is:

```
Headless wrapper: <absolute path to fleet-board-run.sh>
```

Use that path. The install location depends on the machine and the plugin version, so this README does not write it down.

### Starting a run

From the repo root:

```bash
bash <path from /fleet-board:status> --repo .
```

`--repo` defaults to the current directory. The wrapper runs from that repo's git root, checks the config (`config.sh --check`; exit 3 when there is no `.fleet-board.yml`), prints the path of its run log, and starts ticking.

### When it stops

`stop-file`, `max-hours` and `max-cost` are checked before every tick. `nothing-dispatchable`, `cost-unknown` and `max-cost` are checked right after a successful tick, and `consecutive-failures` after a failed one.

| Stop reason | Condition | Config key | Exit |
|---|---|---|---|
| `stop-file` | `<repo root>/.fleet-board.stop` exists | none | 0 |
| `max-hours` | elapsed hours exceed the limit | `limits.max_hours` (default 8) | 0 |
| `max-cost` | the cost estimate exceeds the limit | `limits.max_cost_usd` (default 40) | 0 |
| `nothing-dispatchable` | a successful tick's report ends `dispatchable: false` | none | 0 |
| `consecutive-failures` | this many failed ticks in a row, including ticks whose plan failed | `limits.max_consecutive_failures` (default 3) | 1 |
| `cost-unknown` | a successful tick reports no cost at all | none | 1 |
| `interrupted (INT)`, `interrupted (TERM)` | the wrapper got Ctrl-C or `kill` | none | 130, 143 |

The limits are checked between ticks, never during one, so a single tick can run past `max_hours` or `max_cost_usd`. What bounds a tick is `--max-turns`. The comparisons are strict: with `max_hours: 0` or `max_cost_usd: 0`, the first tick still runs, and the run stops after it.

A tick fails when `claude` exits non-zero, when the session has no `result` event, when the result is an error (for example `error_max_turns`), or when the report's last non-blank line is not `dispatchable: true` or `dispatchable: false`. It also fails when the report has a line starting `Plan failed:`. Before the label, the line may have, in this order: leading whitespace; any list markers (`-`, `*`, `+`, `1.` or `1)`, each followed by a space) and quote markers (`>`); then one heading marker (`#` to `######` followed by a space). A heading marker comes after any list or quote marker, so `- ## Plan failed:` counts but `## - Plan failed:` and `## > Plan failed:` do not. Up to three emphasis or backtick characters (`*`, `_`, `` ` ``) may sit before `Plan`, between `failed` and the colon, and after the colon, so `- **Plan failed:**`, `**Plan failed**:` and `` `Plan failed:` `` all count. Any other text before the label (a sentence, a table cell, a `-` with no space after it) does not count. When the line counts, the tick could not read the board (for example, GitHub's rate limit), so its `dispatchable: false` does not mean the board is settled, and the run does not stop with `nothing-dispatchable`. The log gives the reason as `plan failed: <the error>`, with up to three trailing `*`, `_` or backtick characters removed, so `` `Plan failed: GraphQL error` `` logs `plan failed: GraphQL error`. This applies to every reason, wrapped or not, so `Plan failed: bad glob src/*` logs `plan failed: bad glob src/`; only the log text changes, not whether the tick fails. A failed tick is logged and the run goes on to the next tick. A successful tick resets the failure count.

Between ticks it waits `limits.tick_interval` seconds (default 300). Each tick runs with `--max-turns` set to `limits.max_turns` (default 200) and `--model` set to `models.manager`.

On stop it prints one line and appends it to the log:

```
fleet-board-run: stopped: nothing-dispatchable after 7 ticks, 2.41 h, cost_estimate_usd 18.3 (estimate)
```

Hours and costs always use a dot as the decimal point, whatever your locale; `claude` itself still runs in your locale.

For an interrupt, the line is written on a best-effort basis, and the tick count includes the tick that was cut short. A run killed with `kill -9`, or ended by the machine shutting down, writes no stop line.

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | stopped: `nothing-dispatchable`, `stop-file`, `max-hours` or `max-cost` |
| 1 | stopped: `consecutive-failures` or `cost-unknown`; or a setup failure (not a git repo, `claude` not found, the log cannot be written) |
| 2 | usage error, or `FLEET_BOARD_ISOLATE=1` |
| 3 | no `.fleet-board.yml` |
| 4, 5 | the config failed `config.sh --check`; 5 also for a limit that is not a valid number |
| 130, 143 | interrupted by INT (Ctrl-C) or TERM |

### Stopping gracefully

```bash
touch .fleet-board.stop
```

The tick in progress finishes, and the run stops before the next one. Delete the file before the next run, or that run stops before its first tick.

To stop at once, press Ctrl-C or send the wrapper TERM (`kill <pid>`). It passes TERM on to the running `claude` session (or cleanup, or the wait between ticks), waits up to 5 seconds for it to exit, and sends KILL to anything still running after that. Then it logs `stopped: interrupted (<signal>)` and exits 130 or 143. A stop can therefore take up to about 5 seconds. The tick it cut short is logged no further, and its cost is not counted. KILL ends only the process the wrapper started; a helper that process started and left behind is not tracked.

### The run log

Each run appends every tick to one file:

```
$HOME/.fleet-board/runs/<owner>-<name>-<YYYYmmdd-HHMMSS>.log
```

Set `FLEET_BOARD_LOG_DIR` to put the logs somewhere else. A relative path is taken from the directory you start the wrapper in. A log directory the wrapper creates is mode 700, and the files it writes are mode 600, because they hold tick reports and raw session output.

A successful tick's block is a header line (`=== tick <n> <time> rc=0 cost_estimate_usd=<x> (estimate) ===`), the tick report, and the output of the worktree cleanup. A failed tick's block starts `=== tick <n> FAILED <time> rc=<rc> ===`, then gives the reason, the path of the tick's whole output, and the last 20 lines of that output, each cut to 2000 characters. The whole output of a failed tick is kept next to the log as `<log name>-tick-<n>.jsonl`. Successful ticks keep no such file.

### The cost figure is an estimate

A tick's cost is the session's `total_cost_usd`, which Claude Code computes on the client. When a session reports none, the wrapper prices its `modelUsage` with `scripts/prices.json`, a dated price snapshot. The figure is not a bill. If you run on a subscription, it measures usage, not money. A failed tick's cost counts too, when its session reports one. A failed tick whose session ends without a `result` event, or whose result carries no cost, adds $0 and is logged `cost_estimate_usd=unknown`, even though it may have spent money.

### Permissions

- The wrapper never passes `--dangerously-skip-permissions`.
- `--permission-mode` comes from `headless.permission_mode`, which defaults to `auto`. In `auto` mode, Claude Code approves or denies each tool call itself, with its safety classifier, so a tick can run unattended without skipping permission checks. No one is there to answer a permission prompt, so a stricter mode such as `default` leaves the tick's commands denied.
- If you set `headless.permission_mode: bypassPermissions`, the wrapper prints a one-line warning, to stderr and to the log, before the first tick.
- **Do not run the manager on haiku.** Claude Code runs a haiku session in permission mode `default` even when `--permission-mode auto` is passed, and it does not say so. Every Bash call of the tick is then denied, and the tick ends without a report. The wrapper warns before the first tick when `models.manager` names haiku. Use `sonnet` (the default) or a larger model.

### Merges stay human

`merge.policy: auto` is not supported for headless or overnight runs. Claude Code's auto-mode safety classifier blocks an unattended `gh pr merge` in a headless session ("Merge Without Review"). The wrapper adds no permission rule and does not work around the classifier. An overnight run leaves reviewed PRs for you to merge. Auto merges work only where you have explicitly allowed them in your own Claude Code settings.

### Worktree cleanup

After each successful tick, the wrapper runs `scripts/cleanup-done.sh` from the repo root, in its own shell and outside any Claude session. It removes the worktrees of cards that reached done. It first lists the worktrees directory locally and reads the board only for done cards that still have a `<n>-*` entry there, so its cost grows with the leftover directories, not with the Done column. The manager never removes worktrees itself, because the auto-mode classifier denies that as irreversible local destruction. The cleanup's output goes into the log. If it fails, the log gets `warning: cleanup-done.sh exited <rc>` and its stderr. That is a warning only: the tick still counts as successful, and the run goes on.

You can also run it by hand from the repo root. `<scripts dir>` is the directory of the wrapper path that `/fleet-board:status` prints:

```bash
bash <scripts dir>/cleanup-done.sh
```

### Environment

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

Save it as `~/Library/LaunchAgents/com.example.fleet-board.plist`. Replace `<repo>` with the absolute path of your repo. Replace `<plugin-dir>` with the plugin directory: the wrapper path that `/fleet-board:status` prints, without its trailing `/scripts/fleet-board-run.sh`. Replace `<your PATH>` with the output of `echo $PATH` in the terminal where `claude`, `gh` and `jq` work.

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
    <string><your PATH></string>
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

## Known issues

- **Unblocking a card re-runs the implementor.** When you move a card from Blocked back to Ready, it goes through `start` again: its note's round resets to 0, and the implementor is dispatched once more before review. The card keeps its branch and PR, so no work is lost, but the extra implementor dispatch costs a tick. Planned for 0.1.1.

## Demo

[`docs/demo.cast`](docs/demo.cast) is a terminal recording of `tests/behavioral-tick.sh --scenario ready-path` on a sandbox repo: one card goes from Ready to a PR ready for review in four headless ticks, and the run ends with all 48 checks passing. Play it with `asciinema play docs/demo.cast`, or open it in the [asciinema web player](https://docs.asciinema.org/manual/player/).


## License

MIT
