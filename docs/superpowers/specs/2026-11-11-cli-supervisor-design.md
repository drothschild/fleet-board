# Command-line supervisor — design

Date: 2026-11-11. Status: draft for review.
Supersedes: `2026-11-07-persistent-supervisor-design.md` and `2026-11-09-persistent-supervisor-docker-backend-design.md`
(and their plans). Those documents are kept for history; where they disagree with this one, this one wins.

## 1. Goal

Replace the tick system with a supervisor that the user starts from the command line. It drives every card on the
board through implement, review, fix, merge and after-merge work, several cards at once, and shows what it is doing
and what it cost in tokens.

It deliberately does **not**:
- survive a restart. When the process ends (Stop, Ctrl-C, a crash, a reboot), its work ends with it. Nothing brings it
  back until the user starts it again;
- install anything that needs permissions. No launchd, systemd, registry or login item;
- repair work a crash interrupted. It shows the stuck cards and waits for the user;
- sandbox roles. Roles run as they do under ticks today. Sandboxing is later work (section 12).

### Success criteria

1. `supervisor start` in a repository moves Ready cards to Done (or Human QA) with no further input, running up to
   `limits.concurrency` actions at once, with no card waiting on another card's slow role.
2. A refused merge affects only its card. A failed main verification or an unclear merge result pauses the board.
3. After a crash, the next `start` names every stuck card and refuses to start until each is resolved.
4. Every token spent is attributed to a card (or to the planner), a column and an action, and can be drilled into
   from the board page, which also shows a running count for the current run and the all-time total.
5. One real card on HMB Workout Server goes Ready → merged → deployed under the supervisor, after which the tick
   system is removed.

## 2. Decisions this design rests on

| Decision | Choice |
|---|---|
| Restart survival | None. In-memory state; the board is the only durable record. |
| After a crash | Show stuck cards; refuse to start until resolved. No automatic repair. |
| How it runs | Foreground by default; `--detach` for background. The board page can Start it (same as `--detach`). |
| Ticks | Replaced outright in the final phase. No coexistence period (nobody runs the board during development). |
| Who does the manager's job | The supervisor, in code. The model runs only inside roles. |
| Roles | implementor, reviewer, fixer keep today's contract (they post their own reports and push their own branches). A fourth role, **merger**, is added. |
| Merger authoring | Hand-written agent with a short behavior spec and an `exception:` manifest line. No clean-room run. |
| When the merger runs | After a successful merge (after-merge steps) and on a refused merge (decides retry/fix/attention). Never before a merge, and it never merges. |
| Loosening merge rules | Structured config enforced by scripts (`merge.ignore_checks`), never persona text. |
| Cost | Tokens only. No dollar figures anywhere. |

## 3. Architecture

One Python process per repository, under `plugins/fleet-board/scripts/supervisor/`. All live state is in memory.
The board (card columns, manager notes, PRs, worktrees) is the only durable record of work; the usage ledger
(section 8) is the only other file the supervisor writes, and it is never read back to make a decision.

| Unit | Responsibility | Depends on |
|---|---|---|
| **Candidates** | Asks `tick-plan.sh --candidates` which cards can move and what each one's next action is. The script is unchanged apart from the `merging` rows (section 4). | board scripts |
| **Scheduler** | Admits actions within caps: global `limits.concurrency`, per-provider `supervisor.provider_concurrency`, one action per card, no overlapping scope between cards, one merge at a time, aging so nothing starves. | Candidates |
| **Card driver** | The manager's job, in code: turns one admitted action into script calls and at most one role session, reconciles the role's report, moves the card, writes the manager note. | Scheduler, Role runner, board scripts |
| **Role runner** | Launches implementor, reviewer, fixer or merger as a headless `claude -p --agent fleet-board:<role>` session (or a provider command for provider review stages). The session's working directory is the repository root, as under ticks (roles address the card's worktree by path, and the gate reads the root's config). Each session runs in its own process group, with a log file, a deadline and cancellation. Returns exit status, report text and token usage. | provider/model resolver |
| **Resolver** | One place that decides provider, model and escalation for a role and round (`models.*`, `review.stages`, `providers.*`). | config |
| **Control surface** | Private socket; commands `status`, `pause`, `resume`, `stop`, `usage`, `stuck`. Used by the CLI and the board server. | — |
| **Startup check** | Finds work a previous process left half done and reports it (section 7). | board scripts, git |
| **Usage ledger** | Appends one line per completed action (section 8). | — |

Each unit is testable alone: Candidates and the board scripts against fixture boards; Scheduler with synthetic
candidates; Card driver and Role runner with fake role sessions; Control surface with a real socket.

## 4. Card states

States: `backlog`, `ready`, `in_progress`, `in_review`, `review_<stage>` (one per configured stage), `human_qa`,
**`merging`** (new), `blocked`, `done`, `wont_do`.

- `ready` → `in_progress` (implementor) → `in_review` (reviewer) → each `review_<stage>` in order → findings send the
  card to the fixer and back to review, as today.
- Clean review under `merge.policy: auto` → `merging` → `done`.
- Clean review under `merge.policy: human`, or a card that needs Human QA → `human_qa`; a person merges it.
  A `human_qa` card never enters `merging` (gate G1 unchanged).
- `blocked` keeps today's meaning and limits: the per-card no-progress count (`note.action_failures`) is checked
  against `review.max_rounds` by the planner, which plans `block` at that count, as today.

Required changes outside the supervisor package:
- `board-lib.sh`: add `merging` to the fixed states, after the review stages (and its display name "Merging").
- `tick-plan.sh`: `merging` in its column lists and decision rows. A card in `merging` whose PR is merged plans
  `verify_main` then `finish`; one whose PR is open at the same head with no merge in flight plans `merge`; anything
  else is reported as stuck.
- `merge-reviewed.sh`: accept `merging` wherever it accepts `in_review|review_*` today, and gain `--no-finish`, which
  stops after main verification without moving the card to `done` (the supervisor moves it after the merger).
- `note.sh` and `accept.sh` accept `merging` as a `blocked_from` value; `status.sh`, `config.sh` (`board.states` keys)
  and `init.sh` list it.
- The gate hook has no card-state check on merges, so `merging` needs no gate change.

## 5. The loop

The supervisor wakes on a timer (`supervisor.reconcile_interval_seconds`), when a role session exits, or when a control
command arrives. Each wake:

1. Re-read `.fleet-board.yml`. An invalid file pauses admissions with the validation message; running sessions continue.
2. Ask Candidates for the current actions. A GitHub rate limit (the planner exits 1 with `resets at <time>`) holds
   admissions until that time plus `limits.rate_limit_margin`, capped in total by `limits.rate_limit_max_wait`, as the
   tick wrapper does today; past the cap, admissions pause with that reason.
3. The Scheduler admits what fits.
4. For each admitted action, the Card driver runs its script steps at once and, if the action needs a role, starts the
   session and returns. No step waits on another card.
5. When a session exits, the Card driver reconciles it (section 6), moves the card, writes the note, appends the
   usage line, frees the slot and wakes the loop.

## 6. Card driver rules

The rules are a port of `agents/manager.md`. Where the manager decides by reading script output, the driver does the
same in code. The port keeps today's behavior except where this section says otherwise.

**Report reconciliation.** Every role report goes through `parse-report.sh`. Exit 0: accept and apply. Exit 1:
re-dispatch the same role once with the rejection message quoted verbatim; a second rejection counts as no progress.
Exit 2: a driver bug; pause admissions and show the message.

**Fixer "not reproducible".** A fixer report with status `not_reproducible` is recorded as
`note.last_fix = {status: "not_reproducible", round}`, which the planner already reads to send the card back to review.

**Failures.**
- A role that crashes, exceeds `supervisor.attempt_timeout_seconds`, or shows no log growth for
  `supervisor.progress_timeout_seconds` is ended (process group) and counts toward the card's no-progress limit.
- **Provider failures do not charge the card** (changed from today). A launch that fails for a provider reason —
  the provider command failing to start, an authentication error, a rate limit — marks that provider unhealthy for
  `supervisor.retry_backoff_seconds` (doubling, capped) and returns the action to the queue. The board page and
  `status` show the unhealthy provider and why. Classification is by exit code and known message patterns; anything
  unrecognised is treated as a card failure.

**Merging.** The merge lane runs one merge at a time per repository:
1. Move the card to `merging` (if it is not already there).
2. Run `merge-reviewed.sh --no-finish` in its keyed form (`--card N --operation-key K --pr P --head SHA`), so that
   `--inspect` can later classify the outcome.
3. **Merged:** run `verify-main.sh`. On success, start a merger session for after-merge work (below). On failure,
   pause admissions for the whole board and show the verification output.
4. **Refused** (`merge-reviewed.sh --inspect` shows the PR open, unmerged, at the same head): only this card is
   affected. The lane is freed and other cards continue. The refusal `{pr, head, reason}` goes in the manager note and a
   merger session is started to decide the next step.
5. **Unclear** (the PR or its head cannot be read, or the head changed): pause admissions for the whole board.

**Merger decisions.**
- After a merge: the merger runs the project's after-merge steps and reports `done` or `attention`. `done` moves the
  card to `done`. `attention` leaves the merge in place and flags the card. The card body's existing `## After merge`
  section still runs (through `after-merge.sh`, under `after_merge.allow`) before the merger.
- On a refusal: the merger reports `retry` (merge again once, after `supervisor.retry_backoff_seconds`), `fix` (a
  conflict goes through the existing update-branch → conflict-fixer path; any other reason goes to a fixer with the
  refusal as its finding) or `attention` (flag the card for the user). A second refusal after a `retry` is `attention`.

## 7. Control, stopping and stuck cards

**Commands** (`scripts/supervisor.sh <command>`):
`start [--detach] [--ignore-stuck]`, `status [--json]`, `pause`, `resume`, `stop [--drain|--cancel]`,
`usage [--card N] [--json]`, `stuck [--json] [--release N]`.

**Socket.** A private socket (mode 0600) in a directory (0700) under `/tmp/fleet-board-<uid>/`, or
`FLEET_BOARD_SOCKET_DIR`. The location never depends on `$TMPDIR`, so the board server and the user's shell always agree.
A directory that is not owned by the user, is a symlink, or is group/other accessible is refused.

**One per repository.** `start` takes an exclusive lock for the repository. A second `start` names the running one and
exits non-zero.

**`--detach`** starts the same process in its own session, writes output to `supervisor.log` in the log directory, and
returns once the socket answers.

**Pause** admits nothing new; running sessions finish. **Resume** reopens admissions.

**Stop.** `--drain` (default) waits for running sessions, then exits. `--cancel` and Ctrl-C end every session's
process group (SIGTERM, `supervisor.shutdown_grace_seconds`, SIGKILL), record `cancelled` in each card's manager
note, return each card to the column it was in before the action, and exit. A second Ctrl-C forces the cancel.
Sessions never outlive the supervisor.

**Startup check.** Before admitting anything, `start` looks for:
- a card in `in_progress` or `merging`, or with an active marker, that no live session owns;
- a worktree with uncommitted changes for a card that is not being worked on;
- a lock whose holder is no longer running.

If any are found, it prints each with what it saw, writes a "stuck" note on each card, and exits non-zero without
admitting work. The user resolves a card by moving it, or with `stuck --release N`, which returns the card to its last
stable column and clears its marker without touching its branch or PR. `start --ignore-stuck` starts anyway and
leaves those cards alone until they are resolved.

Lock liveness (cards #253 and #254: takeover of a lock whose holder is dead, including a lock left with no pid) is a
prerequisite of the end-to-end run, because cancelling roles with SIGKILL can leave locks behind.

## 8. Token accounting

**Sources.**
- Claude sessions (all four roles, the board's Planner chat, and the board's import-preview session): the token usage in the final `result` event of
  `claude -p` stream-json output — input, output, cache-write and cache-read tokens, and the model.
- Provider review stages (codex and others): the provider ledger, once card #240 / PR #255 records token counts there.
- Usage that cannot be read is recorded as `unknown` and shown as unknown, never as zero.

**No dollar figures.** `cost_estimate_usd`, `max_cost_usd` and per-provider `price` settings are removed from the
supervisor path. (This absorbs PR #246 and card #215.)

**Ledger.** `.fleet-board/usage.jsonl` in the repository (with the rest of `.fleet-board/`, kept out of git), one JSON
line per completed action: `run_id`, `card` (or null for the planner), `kind` (`card` or `planner`), `column` (the column
the card is in while the role works, after any move the action makes before dispatch; lines written before 0.25.5 used
the column before that move), `action` (`start`, `review`, `review_<stage>`, `fix`, `update_branch`, `merge_refusal`, `after_merge`),
`role`, `provider`, `model`, the four token counts (or `unknown`), `started_at`, `ended_at`, `log` path. Planner lines
use `action` `planner` (a chat turn) or `import_preview`. Appends are
single `write` calls of one line under an advisory lock. The supervisor never reads the ledger to decide anything.

**Views.**
- Board page front: tokens for the current supervisor run, the all-time total beneath it, and a separate planner line.
- Drill-down: board → card → column → action, each action with its token breakdown and a link to its log.
- CLI: `supervisor usage [--card N] [--json]`.

**Limits.** `limits.max_tokens` (per supervisor run) and optional `limits.max_tokens_per_card` replace
`limits.max_cost_usd`. Reaching one pauses admissions and states which limit was reached. Running sessions finish.

## 9. Merge configuration

**Merger persona.** Each project can provide a merger persona file (default `.fleet-board/merger.md` in the repository;
overridable with `merge.persona`, extended with `merge.persona_append`). It tells the merger what to do after a merge and
how to judge a refusal. Example for HMB Workout Server: after a merge to main, deploy the server and the web app, and
report `attention` if a deploy fails. The plugin ships a default persona with the three refusal rules (a conflict is
`fix`; a pending check is `retry`, once; anything else is `attention`).

**What the persona cannot do.** It cannot merge, move a card, or loosen any merge precondition. The merger reads PR
content, CI logs and comments, which may be hostile, so its prose is never trusted to widen what the merge script
allows.

**`merge.ignore_checks`.** The only way to merge with a failing required check:

```yaml
merge:
  ignore_checks:
    - name: "e2e-*"        # glob on the check name
      until: 2026-11-30    # required; an expired entry is ignored and reported
      reason: flaky e2e suite
```

The planner (`tick-plan.sh`, which decides whether a merge is planned) and the gate (`check_pr`) both treat a red check
as green only when its name matches an unexpired entry; a pending check is never treated as green. Each use is
recorded in the card's manager note with the check name and the entry's reason. `config.sh --check` rejects an entry
with no `until` or no `reason`.

Limit: GitHub branch protection still refuses a merge while a check it marks *required* is failing, and fleet-board
never merges with `--admin`. So `ignore_checks` lets a merge through only for checks the repository does not mark
required. `supervisor status` and the merger's refusal note say so when a refusal is caused by a required check.

## 10. Board page

Built in the late phase, on the existing board server and supervisor UI.
- Status strip: running, paused (with reason) or not running; unhealthy providers.
- Controls: Start (same as `start --detach`), Pause, Resume, Stop.
- Tokens: current run, all time, planner line; drill-down as in section 8.
- Per card: current action and its elapsed time.
- **Stuck cards: a loud red border and a "stuck" label on each, and a banner giving the count and saying the supervisor
  will not start until they are resolved.** The board server computes the stuck list itself with the same read-only
  check as `supervisor stuck --json`, so stuck cards show even when the supervisor is not running.
- When the supervisor is not running, the page says so and still shows ledger totals.

## 11. What changes in the repository

**Removed from the supervisor package:** `store.py` (SQLite store), `recovery.py`, runner receipts and result
publication, `processes.py`, `models.py`, the effect journal, store backups, `workers.py`, `inference_broker.py`,
`isolation.py`, `docker_transport.py`, `docker_agent.py`, `docker_probe.py`, the worker socket, `resolve`,
`supervisor.start_on_boot`, and their test suites and fixtures.

**Kept and reshaped:** scheduler admission policy and reservation overlap logic (now in memory); the script adapter as
plain bounded calls; `cli.py`, `webproxy.py`, `errors.py`, `paths.py`; the board server's supervisor routes and UI;
`tick-plan.sh --candidates`; the supervisor config validation that still applies.

**Added:** Card driver, Role runner, Resolver, Startup check, usage ledger, `agents/merger.md` and its behavior spec,
the default merger persona, the `merging` state and its planner/merge-script/gate rows, `merge.ignore_checks`.

**Removed in the final phase:** the `tick` and `run` skills, `fleet-board-run.sh`, `agents/manager.md`, their
clean-room specs and manifest lines; docs and remaining skills are rewritten to point at the supervisor.

**Config.** Removed in the strip phase: `supervisor.enabled` (the supervisor is a command you run; the board server
detects a running supervisor by its socket), `supervisor.start_on_boot`, `supervisor.heartbeat_*`. Removed in the final
phase, with the tick wrapper that reads them: `limits.max_cost_usd`, `limits.tick_interval`, `limits.min_tick_gap`,
`limits.max_consecutive_failures`, `models.manager`. Added: `limits.max_tokens`, `limits.max_tokens_per_card`,
`models.merger` (default `sonnet`), `merge.persona`, `merge.persona_append`, `merge.ignore_checks`. Unchanged: `limits.concurrency`, `limits.max_hours`,
`limits.max_turns`, `limits.rate_limit_max_wait`, `limits.rate_limit_margin`, `headless.permission_mode`,
`supervisor.provider_concurrency`, `supervisor.*_timeout_seconds`, `supervisor.shutdown_grace_seconds`,
`supervisor.retry_backoff_seconds`, `supervisor.aging_seconds`, `supervisor.reconcile_interval_seconds`.

**Open PRs and cards** (each change made only after the user approves the list):
- Close: PR #249 (its substance is section 4, 6 and 9 here); PR #246 (section 8 absorbs it).
- Rewrite to target this design: cards #242, #245, #247, #250 (merging), #243, #244, #248, #249, #251 (merger, no
  clean-room run), #224 (tracking card).
- Fold in: card #215.
- Prerequisite of the end-to-end run: #253, #254 (lock liveness).
- Depends on: #240 / PR #255 for provider token counts.

## 12. Later (not in this design)

- Sandboxing roles (the Docker / isolation / broker work in the superseded docker-backend design).
- Surviving restarts, or installing as a login or boot service.
- A pre-merge merger session.
- An LLM-written card driver.

## 13. Testing

- Plain-bash suites under `plugins/fleet-board/tests/`, as for every plugin script. No external framework.
- A fixture board and **fake role sessions**: small scripts on `PATH` in place of `claude` that print a canned report
  and a stream-json `result` with usage, or that hang, crash, exit with a provider error, or ignore SIGTERM.
- Concurrency, cancellation, process-group and socket tests use real child processes.
- Every new suite is shown failing before it is trusted.
- Markdown primitives (the merger agent) are verified behaviorally: a subagent given the agent and a fixture refusal or
  after-merge task, asserting on its report.
- **End-to-end:** one real card on HMB Workout Server, Ready → merged → deployed, run only with the user's go-ahead
  because it spends real tokens.

## 14. Phases

1. **Strip.** Remove the restart-survival, OS-service and sandbox code and tests from main; keep what section 11 keeps.
   The plugin still passes its focused suites.
2. **Loop with fake roles.** Candidates, Scheduler (in memory), Card driver, Role runner, control socket, foreground
   `start` and Stop/Ctrl-C, all against the fixture board and fake roles.
3. **Real roles and tokens.** `claude -p` role dispatch through the Resolver, provider-failure handling, the usage
   ledger, `usage` CLI, token limits.
4. **Merging.** The `merging` state and its rows, the merge lane, `merge.ignore_checks`, the merger agent and persona,
   merger decisions.
5. **Stuck cards and detach.** Startup check, `stuck`, `--detach`.
6. **Board page.** Status, controls, token views, red-border stuck cards.
7. **End-to-end and retirement.** Lock liveness in place; one real HMB Workout Server card end to end; then remove the
   tick system and update docs.
