# fleet-board

Last verified: 2026-11-12

## Purpose

Turns a local card board into a work queue for coding agents. A command-line supervisor
(`scripts/supervisor.sh`) plans each card's next action and runs it; role agents (implementor, reviewer, fixer,
merger) work in worktrees; a PreToolUse hook enforces the human-QA and merge gates. The tick system (the `tick` and
`run` skills, the headless wrapper and the manager agent) was removed in 0.26.0.

This public repo carries only the clean-room specs from the implementation plan, under
`docs/implementation-plans/2026-09-28-fleet-board/specs/`. The plan itself, its rehearsal
notes and its handoff stay in the author's private repo, so references to them below have
no file here. The gate's residual bypasses and false positives are listed in the README's
`## Gates`.

## Contracts

- **Local store.** The board is always local: cards are JSON files under `board.dir`
  (default `.fleet-board`). Callers use only the `scripts/board-*.sh` contract scripts
  (`read`, `list`, `move`, `create`, `comment`, `note`, `cache-clear`). Each validates its
  arguments (exit 2 on usage), loads config, and execs `scripts/adapters/local/<verb>.sh`.
  There is no `board.backend`: `config.sh` exits 5 on `board.backend`, `board.project_number`
  and `board.project_owner`, pointing at `scripts/import-github.sh`. The github-labels and
  github-projects adapters, `cards.sh` and `migrate-to-local.sh` are gone; no script under
  `scripts/` or `hooks/` calls `gh issue`, `gh label`, `gh project` or GraphQL, except the
  read-only importer `import-github.sh` (pinned by `test-no-github-board.sh`). `list` reads
  every card file, has no truncation rule and fails closed (exit 1) when a file is
  unparsable; `--allow-truncated` is accepted and ignored.
  Card JSON keys: `number`, `title`, `body` (prose only), `state` (canonical, else read as
  null with a warning), `labels`, `acceptance` (array of strings), `blocked_by` (array of
  card numbers on this board), `pr_url`, `pr_url_source` (`note`, `person` or null),
  `created_at`, `updated_at`, `next_comment_id`, `comments`. Every write goes through
  `fl_write_card` under `fb_lock`. `fl_split_body` moves `## Acceptance` and `## Depends on`
  sections out of a body into the fields (first real heading wins, not inside a fence);
  `read` returns the stored prose and the fields side by side, never a rendered section.
  `blocked_by` naming a missing card or the card itself is refused on write (exit 2). A
  dependency outside this board stays in the body as prose. `migrate-card-fields.sh
  [--dry-run]` upgrades an older store in place (idempotent).
  Canonical states (`FB_STATES` in `board-lib.sh`, set by `fb_load_config`, not a
  constant): backlog ready in_progress in_review, then `review_<name>` for each
  `review.stages` entry in config order, then human_qa blocked done wont_do
  (`FB_STATES_FIXED` is the list without stages); board names come from `board.states.*` or
  the default (`Review: <name>` for a stage).
- **Active marker** (`fb_mark_active` in `board-lib.sh`). `worktree.sh create|review`
  and `stage-review.sh` write `<board.dir>/active/<n>`; the `comment` verb removes it
  for validated CLI role reports. Web comments and notes leave it in place. `stage-review.sh`
  also removes its marker in its EXIT trap. The page lights a card while its marker exists and a
  supervisor is running; the board server never removes a marker (the supervisor owns them, see
  below). A failed write or removal is a warning.
- **Manager note** (`scripts/note.sh get|parse|put|merge|reset-failures|fail`). One comment per
  card, starting with `FB_MARKER`, holding one fenced JSON block. Trust boundary: only a
  marker comment authored by `fb_login` counts (`FLEET_BOARD_USER`, else `$USER`, else `id -un`, with no `gh` call, exit 1 when all are empty; the boundary is filesystem access); `get` validates fields
  that could steer shell commands (`pr`, `branch` = `fleet/<n>-<slug>`, absolute `worktree`
  inside the worktrees base, integer counters, control-char-free `last_action_error`) and
  treats an invalid note as `{}` with a warning. `put`/`merge` refuse to write an invalid
  note; `merge` refuses to overwrite a stored invalid one. Review-stage fields: `stage`
  (null or a stage name), `reviewed_stages` (list of names), `last_review.stage` and
  `last_review.provider` (null for an In Review or agent-stage record), each validated
  against `^[a-z][a-z0-9_]*$` (`provider` also allows `-`).
  Note-to-card mirror: the local `note` verb copies the note's `pr` into the card's `pr_url`
  (`https://github.com/<board.repo>/pull/<pr>`, `pr_url_source: note`); `pr: null` clears a
  note-sourced URL. A URL a person set (`pr_url_source: person`) is kept unless a note names
  a different PR. An unparsable note leaves `pr_url` unchanged and warns.
- **Tick plan** (`scripts/tick-plan.sh`). Prints one JSON plan: an action per card from a
  single jq decision table (start, continue_implementor, start_review, review, fix,
  mark_ready, merge, verify_main, finish, after_merge, merge_refusal, to_human_qa, file_pending, block, unblock,
  skip, skip_no_acceptance, skip_card_lint, wait, advance_stage, review_stage). Precedence: failed lookup, invalid note, file_pending,
  the `action_failures` rules, then the table. `action_failures` bound: at `max_rounds`
  consecutive no-progress actions the card is blocked; at `2*max_rounds` (or `max_rounds`
  for a blocked card awaiting unblock) it is skipped for a person, who clears it with
  `note.sh reset-failures <n>`. tick-plan only reads the count; the supervisor's driver writes it.
  `tick-plan.sh --settle-merge <n>...` (merge-reviewed.sh's planner) plans only the named cards
  (read with `board-read.sh`, no column listed) through the same table, keeping only steps that
  start no agent plus `merge` and `verify_main`: `to_human_qa`, `block` and `mark_ready` stay,
  `start_review` becomes `move_to_review` (only settle mode emits it), and every other action is
  a `skip`. A settle plan is never dispatchable. The by-hand `--settle` flag and the by-hand settle script were
  removed in 0.27.0 (run beside a supervisor, it wrote the board outside the gate and the run lock).
  Reviewed heads only: an in_review PR whose head moved past `last_review.sha` plans
  `review`, not `mark_ready`, `to_human_qa` or `merge`, unless every commit since
  is a merge of the base (second parent on `origin/HEAD`, else `origin/main`) whose tree
  equals the `git merge-tree` result for its parents, or, with `supervisor.version_files`
  set, a version-only change: a single-parent commit that changes only whole-line
  `"version"` values in version files, or a merge of the base that differs from the
  automatic merge only that way. Only the top-level `version` and `plugins[].version` may
  change, each to semver strictly above the old value (a merge: the three-way result, or above both sides);
  every other `"version"` must equal the three-way result, and no key may be repeated
  (`scripts/review-drift.sh <reviewed-sha> <head-sha>` prints `reviewed` or `unreviewed`;
  a failed check reads as unreviewed). `update-branch.sh` keeps `last_review` as it is.
- **Declared Scope parsing.** `tick-plan.sh` reads a card's `## Scope` section for backticked
  spans and plain-text path tokens (no whitespace, holding a `/` or ending in an extension;
  leading `(` and trailing `.,:;)` stripped). A token ending in `/` is a directory scope.
- **Scope reservations.** A normal plan supplements open cards' declared Scope paths
  with their complete PR file lists when ready cards exist. Missing or truncated PR
  paths hold new starts, while existing work can continue. Selected starts reserve
  scope in ascending card-number order; a waiting card reserves nothing. Normalized
  directory scopes cover descendants with path-boundary matching. `start_review`, `review`,
  `review_stage` and `update_branch` (`scheduler.SCOPE_FREE_ACTIONS`) reserve no scope and are never
  scope-checked against other cards; they still take a slot and one action per card. Settle plans do
  not fetch scope files or start workers. Every overlap check (the scheduler,
  `state.reserve`, and tick-plan's Ready-card checks) first drops paths matching
  `supervisor.scope_ignore`; a scope wholly ignored is kept. Globs are
  segment-wise (`*` never crosses `/`, `**` spans segments), defined once per
  language: `scripts/path-glob.jq` and `scopes.glob_regex`, pinned equal by a
  parity test over `fixtures/glob-cases.json`.
- **Version files** (`supervisor.version_files`, default `[]`, `scripts/versions.jq`,
  `scripts/version-lib.sh`). Off when empty. `update-branch.sh` resolves conflicts in
  matching JSON files whose hunks hold only pairwise-identical `"version"` lines, each
  line from its own sides; after any merge it raises keys the branch bumped (changed by
  its own non-merge commits with full history, and differing from the fork point, `vl_changes`) that are not above the base to base + 1 patch.
  `tick-plan.sh` uses the same rule against the PR's `baseRefName`: `update_branch`
  ("version not above base"), or `wait` ("version check needs <ref>") when a ref cannot
  be read; its `git fetch origin <bases>` runs at most once per 60 s. `update-branch.sh`
  refuses a worktree not on the branch, pushes whenever local differs from
  `origin/<branch>` and verifies the push; after the merge starts and until the push is
  verified, any non-zero exit aborts or resets (`git reset --keep`) to the pre-run head,
  never past a head origin already has.
- **Review stages** (`scripts/review-stages.sh route|match|next|setup`). `route <n> <pr>` adds
  each stage's routing label (path glob match or the label already on the card; never
  removes one) and prints the routed stage names; exit 1 on a failed read. The driver runs
  it BEFORE the move to in_review, so a route failure leaves the card in
  in_progress and the next plan retries. `match <pr>` is read-only: it prints the stages
  whose `paths` match the PR's current files (a truncated file list matches every stage
  with non-empty `paths`), adds no label; exit 1 on a failed read. At every clean,
  current review in in_review or a stage column, `tick-plan.sh` runs `match` and then
  `next` with the card's labels plus the matched stages' labels, `--after in_review` and
  `--done` = `reviewed_stages` plus the column's stage; so a stage whose paths a later
  push touches cannot be skipped by removing its label, even one before the current
  column, while a label-only stage (empty `paths`) still can. A failed `match` is
  `lookup failed: review-stages.sh match <pr>`. `next` prints the next stage after `--after` that the card's labels route to and
  `--done` does not list. `setup` has nothing to create on the local store (exit 0). Tick plan:
  a clean, current review with a next stage plans `advance_stage` (move to
  `review_<stage>`, note `stage`, `round: 1`, `reviewed_stages`); a stage column's
  reviews are `review_stage`; an advisory stage's findings count as clean. The plan
  card's `stage` is the config's stage object whole. Reports use
  `parse-report.sh --role stage-reviewer` (Status clean|findings, Findings, For the
  card, one VERIFIED line; no Acceptance map, Mutation or Claim check).
- **Provider stages** (`scripts/stage-review.sh <n> <pr> --stage <name> --round <r>
  [--prev-sha] [--findings] [--impl-report] [--card-file] [--diff-file] [--no-post]`).
  Run by the supervisor's driver in place of a role session. It builds the prompt
  from `providers/stage-review-prompt.md`, calls the stage's provider through
  `providers/chat.sh`, checks the reply with `parse-report.sh --role stage-reviewer`,
  re-asks once on a rejection, posts the report with `board-comment.sh` and prints
  `{status, report_file, parsed, provider, model, input_tokens, output_tokens, attempts}`. Exit codes: 0 posted (or checked, with `--no-post`); 1 provider failure,
  empty or truncated reply, a reply holding any `<!-- fleet-board:` marker, or a failed post; 2 usage, unknown
  stage or an agent stage; 3 the key variable is unset or holds a control character (no call); 6 the reply was
  rejected twice; 7 the diff exceeds `max_diff_bytes` or has no text hunks (no call; the
  driver blocks the card). The driver counts 1, 3 and 6 as report errors and records
  `last_review.provider` and `last_review.model`; its `last_review.sha` is the PR head read
  just before the call. Ledger: one line per run that got a reply (exits 0, 1 after a
  reply, and 6) appended to `${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}/provider-spend.jsonl`
  with token counts (null when unknown) and `FLEET_BOARD_RUN_ID`. Tokens only: nothing is priced.
- **Provider adapter** (`scripts/providers/chat.sh --base-url --key-env --model --max-tokens
  --max-tokens-param --timeout`; request JSON on stdin, `{text, finish_reason,
  input_tokens, output_tokens, model}` on stdout). OpenAI-compatible Chat Completions
  only. The key comes from the environment variable named by `--key-env` (`-` sends no
  Authorization header, loopback only) and reaches curl through a mode-600 header file,
  never argv; provider text on stderr has the key replaced by `[redacted]` and is cut to
  300 characters. Retries HTTP 429 and 5xx twice. Exit 0 reply; 1 HTTP or transport
  failure; 2 usage, or a `--base-url` with userinfo, a control character or a non-loopback
  plain-http host (the same rule `config.sh` applies; no curl call); 3 key variable unset or holding
  a control character (no file written, no curl call). curl runs with `-q` first (no
  `~/.curlrc`) and `--max-filesize 20971520`; `usage` token counts must be non-negative
  integers, else exit 1 `provider: reply has no usage`. Config: `providers` (name ->
  `base_url`, `api_key_env`, `max_tokens_param`) merged over `providers/presets.json`
  (`openai`, `gemini`, `openrouter`, `ollama`); config never holds a key value. A stage
  sets exactly one of `agent` and `provider`; a provider stage needs `model`. An old `price` key (on a stage or
  `models.reviewer`) is ignored.
  A provider entry with `command` (the `codex` preset) runs `chat.sh --command` instead of curl: prompt on stdin, repo root as cwd, stdout is the reply, tokens `null` (unknown); `base_url` and `api_key_env` must be null with it. `tick-plan.sh` warns when a provider stage's key variable is unset and holds
  `review_stage` in that stage as `wait` (`stage <name>: <ENV> is not set`).
- **Dependency gate** (`scripts/deps.sh parse|check`). `parse-card` reads a card's `blocked_by`
  card numbers (`parse` still reads a body file's `## Depends on` bullets); `check` looks
  each up in the local store and prints `{unmet, warnings}`; a failed lookup exits 1 and names its command on stderr as
  `deps-lookup-failed: <command>`. `tick-plan.sh` plans `wait` (with `waiting_on`) for a
  Ready card with an unmet dependency; the supervisor records the refs it last commented on
  in the note's `deps_commented`. Only Ready cards are gated.
- **Gate hook** (`hooks/gate.sh`, lexer `hooks/gate-lex.awk`). PreToolUse(Bash); exit 2
  blocks; inert without `.fleet-board.yml` in the command's effective cwd. G1: nothing
  moves a card out of human_qa. G2: `gh pr merge` blocked under `merge.policy: human`;
  under `auto` only explicit, non-draft, green, non-`--admin`, and, for a `fleet/<n>-*`
  branch, a head whose commits after the note's `last_review.sha` are all clean merges of
  main (`review-drift.sh`; otherwise blocked as unreviewed), and, for a `fleet/<n>-*` branch, no
  closing keyword before an issue reference in the title, body or a commit message
  (`pr-closing-check.sh --json`, also run by `merge-reviewed.sh` before every merge, keyed
  form after `pending_merge` so the lane classifies it `refused`). G3: moving to ready needs a non-empty
  `acceptance` field on the card. Fails closed on anything it cannot resolve. It is a text check:
  documented residual bypasses (scripts run from files, other HTTP clients, push-merges,
  obfuscation) and false positives are listed in the plan's `rehearsal-notes.md`
  (Phase 4). Policy: add a residual to that list, do not claim the hook covers it.
- **Command-line supervisor** (`scripts/supervisor/`, `scripts/supervisor.sh`; design:
  `docs/specs/2026-11-11-cli-supervisor-design.md`). A process you start yourself that
  dispatches the board's work: it plans with `tick-plan.sh`, admits actions (`scheduler.py`), runs
  role sessions (`roles.py`, `driver.py`) and the one-merge lane (`merging.py`). `status`, `pause`,
  `resume`, `stop [--drain|--cancel]`, `usage` and `stuck` talk to it or to the board. It keeps
  everything in memory (`state.py`, `scopes.py`): no database, no journal, no restart recovery, no
  OS service or boot registration, no sandbox.
  - `start [--detach] [--ignore-stuck]`: runs in the foreground until Ctrl-C, SIGTERM or `stop`;
    `--detach` starts it in the background (`launcher.py`, output to `<log dir>/supervisor.log`)
    and returns once the child itself reports `startup: "done"` (its own pid in `status`), within
    30 s (`READY_TIMEOUT`). `status.startup` is `checking` while the startup check runs (the socket
    already answers) and `done` once the loop runs. A `FLEET_BOARD_SUPERVISOR_SOCKET` that does not
    point where `start` binds fails fast instead of waiting out the timeout. Exit 4: the startup
    check found stuck items; each is printed (`#<n> <kind>: <detail>`) and noted on the card
    (`stuck {kind, detail, at}`), and nothing is started. `--ignore-stuck` starts anyway and keeps
    those cards out of admission until a fresh check no longer reports them.
  - Active markers: the supervisor owns `<board.dir>/active/<n>` while a role session or merge
    child runs, writing `{pgid, supervisor_pid}` atomically (`markers.py`). Every action, script-only
    ones included, removes the marker when it ends (finish, cancel, reap, `State.end`) unless it
    names another process group: while the supervisor owns the card, a marker naming no pgid (the
    empty one a board script made) is its own. Board scripts still create an empty marker (`fb_mark_active`, which never
    truncates one) and remove it when a role posts its report (`comment.sh`).
  - `stuck [--json] [--release N [--force]]` (`stuck.py`) reads the board itself, asking a running
    supervisor only for the cards it owns (never reported). Kinds: `in_flight` (in_progress with no
    owning session, or merging with `pending_merge` and no record of how it ended), `live_orphan` (a
    marker naming a process group that still runs), `marker` (a marker whose pgid is dead or absent),
    `dirty_worktree` (uncommitted changes to tracked files; `git --no-optional-locks status
    --porcelain --untracked-files=no`), `unreadable_worktree` (that status failed or timed out:
    never taken as clean), `dead_lock` (a card lock whose holder is gone, or pid-less past
    `LOCK_GRACE`, the same grace as board-lib.sh's `FB_LOCK_PIDLESS_GRACE`), `unreadable_note`. Every non-terminal state is checked (all but backlog, done,
    wont_do; review stages included). A live process holding the repository run lock that did not
    answer `status` as the supervisor makes `--release` refuse ("a supervisor of another checkout holds the
    repository run lock (pid N)") and the plain list print a one-line notice; the board page shows the
    same text and keeps Start disabled. Token budget: `limits.max_tokens` and `max_tokens_per_card`
    count input + output + cache_write (`State.run_budget`, `card_tokens`); `cache_read` is recorded
    and shown but not counted (0.27.0). The status carries `run_budget` (`tokens`, `partial` over the
    counted keys only, `cap`, `label`), shown by `supervisor status` and the board's token strip.
  - Release rules: refused for a card with no current finding unless `--force`, for a
    `live_orphan` (stop that process group first) and for a card locked by a running process.
    in_progress -> ready without a PR, else in_review. merging: PR merged -> stays in merging,
    recording `merge_operation` (and `merged_pr`) from `pending_merge`; open or closed -> the merge
    records are cleared and it goes to in_review; an unreadable PR state changes nothing. A dirty or
    unreadable worktree gets a `stuck_released` exemption, which the driver clears (with any stale
    `stuck` note) on its first note read for the card. Release clears the card's marker, a dead lock
    and the `stuck` note; it never touches git (no branch, worktree or PR is changed).
  - The socket is a 0600 file in a 0700 directory under `/tmp/fleet-board-<uid>/` (or
    `FLEET_BOARD_SOCKET_DIR`; never `$TMPDIR`), location from `supervisor/paths.py`, the one
    definition shared by service, CLI and board server; domain ids are a pure hash. The actor comes
    from peer credentials (never a request body), every mutation carries `request_id` +
    `expected_revision` (stale => 409 with current state; request-id replay returns the original
    outcome), typed error codes in `supervisor/errors.py`. One supervisor per repository: besides the socket's
    per-checkout owner lock, the service takes the repository run lock `<log dir>/<owner>-<name>.lock`
    (`claim-run-lock.py --kind service`; path `service.default_run_lock_path`), so a supervisor of another
    checkout of the same repository cannot run beside it. The board server has no config switch. `GET /api/supervisor` answers the v2 status (plus
    `running: true`) while a supervisor socket answers `status` within 1 s (`supervisor_running()`),
    else `{running: false, run: null, all_time, planner, columns}` (ledger totals); `pause|resume|stop` with
    none running is 409 `not_running`; Start launches one, treats a stopping supervisor as not
    running (waits for it to go), sends `resume` to a paused one, and when a CLI start won the run
    lock first reports that supervisor. `GET /api/usage` and `/api/cards/<n>/usage` read the ledger
    here (no supervisor needed; unknown counts stay `unknown`). `GET /api/stuck` and the `stuck`
    and `activity` fields of `/api/board` run `stuck.find` in the board server only while no
    supervisor answers (never in the supervisor loop; while one runs no card is stuck, because the
    loop's `stuck` command computes find() on demand and keeps no cached list), answered at once
    from a cache that one background refresher fills (`{findings, checked_at, error, checking,
    known, suppressed}`, and `run.stuck_*` on the board). A refresh starts only from a poll without
    `refresh_stuck=0` (a hidden tab sends it), never while a page Start is launching, and only when
    due: no result yet, older than max(30 s, 2 x the last scan), or the mtime of `<board.dir>/cards`
    or `<board.dir>/active` changed. `usage.view` is cached on the ledger's (size, mtime). Both `/api/usage` and that not-running `/api/supervisor` reply carry `columns`:
    a `{<board state key>: totals}` map of all-time card tokens (planner and null-column lines left
    out), built by `usage.by_column` from the same cached read. A missing key means the column has no
    ledger line, which is not 0; `columns` is absent when the ledger is unreadable. The page shows each
    column's total in its header, the remainder (`all_time` minus the shown columns) on the Unknown
    state header or the All time tooltip, and never a 0 for unreadable usage. There is no `/api/run` route,
    no tick-stop file and no marker clearing: Start always launches (or resumes) the supervisor, and
    `/api/board`'s `run` is `{state, supervisor}` plus the `stuck_*` fields. Status is
    `Service.status_view()`; `tests/test-supervisor-ui.sh` feeds real service output
    (`fixtures/supervisor/dump_real_shapes.py`) to the DOM harness so UI and service cannot drift.
- **Merging and the merger** (Phase 4; spec section 6). `merging` is a fixed state between the
  review stages and human_qa: a card goes stages -> merging -> done and never through human_qa
  (a PR needing human QA is never merged from merging). Only `merge.policy: auto` merges.
  - One-merge lane (`supervisor/merging.py`): one card at a time; `MergeLane.start` moves the card
    to merging and spawns `merge-reviewed.sh --no-finish --card <n> --operation-key <key> --pr <pr>
    --head <sha>` in its own process group; nothing ever kills it (`stop --cancel` and a second
    Ctrl-C wait). A card entering from another column first drops `merge_refusal`, `merge_retry`,
    `pending_merge` and `merger` left from an earlier stay.
  - `merge-reviewed.sh`: the keyed form writes `pending_merge {operation_key, pr, head_sha}` before
    `gh pr merge` and `merge_operation` (plus `main_check`) after it; `--no-finish` stops after
    verification. A card in merging is never moved to done by the script, in any form (the
    no-argument one included). `--inspect` prints `observed` (marker matches), `unmatched`
    (another operation's marker) or `absent` (no marker, with the PR's state and head).
  - Outcomes: `merged` (exit 0, observed `main_check.ok == true`), `refused` (exit 1, PR open at
    the planned head: `merge_refusal {pr, head, reason, at, required_check?}` noted),
    `verify_failed` and `unclear` (both pause the board), `not_attempted` (exit 0, no marker, PR
    open at the planned head: the script's fresh plan skipped the card; event `merge not
    attempted: planner skipped`, no pause, the card stays in merging and is planned again).
  - Planner (merging row): merges only a clean review covering the head (or a head moved only by
    clean merges of main), with no routed stage left (`next_stage` computed as in the review
    columns, `--done` = `reviewed_stages` plus the last review's stage) and the last review from
    the card's last routed or visited stage (stage-less when routed to none); human QA asked and
    `false`; non-draft; green. Stages are routed per card, never "the last configured stage".
  - Merger gate: after the lane merges or is refused, the merger (`agents/merger.md`) runs as
    `after_merge` or `merge_refusal` (deferred while stopping or paused: the planner plans it when
    the board runs again); a merging card plans `finish` only after
    `note.merger {mode: after_merge, status: done}` for its head. A refusal merger's `retry` sets
    `merge_retry {pr, head, after}`; the next merge row carries `retry_after` and the supervisor
    holds it until then; a second refusal after a retry is attention. A merger `attention` moves
    the card from merging to blocked with `blocked_from: merging` in the note, `pending_merge` cleared and one
    comment starting "Waiting for a person:" that names the reason and the next step; the planner skips such a
    card ("blocked, waiting for a person") and never unblocks it on its own. The way out is a person moving the
    card: a refused merge (PR open) to in_review, where the planner merges it when the review at that head is
    clean and checks are green; a failed after-merge step (PR merged) to merging, to run the steps again, or to
    done. `adapters/local/move.sh` clears `merger`, `merge_refusal` and `merge_retry` in the note when a card
    leaves blocked.
  - Persona: `merge.persona` null (the default) -> `.fleet-board/merger.md` when present, else the
    plugin default; a set path that is missing, or a tracked persona this PR changed, is attention.
  - Checks: one rule, `scripts/ignore-checks.jq`, shared by the planner and the gate: an unexpired
    `merge.ignore_checks` entry ignores the red checks its glob matches (a `*` entry ignores every
    red check); a pending check is green only when an unexpired entry with `pending: true` matches it
    (merge without waiting for that check). config.sh refuses a non-boolean `pending`. Passed, red
    and pending are explicit sets of check-run conclusions/statuses and status-context states; any
    other state is never green, and a check with no name is never ignored.

## Invariants

- Headless merges happen only in `scripts/merge-reviewed.sh`, a plain shell step outside any
  Claude session that the supervisor's merge lane runs. It merges only under
  `merge.policy: auto`, for a clean-reviewed, non-draft, green PR that needs no Human QA (it asks
  `tick-plan.sh --settle-merge`); under `human` it makes no call. It binds each merge to its
  planned head and requires literal `main_check.ok == true`. No role session merges, and nothing
  adds permission rules or `--dangerously-skip-permissions`. Worktree removal runs in
  `cleanup-done.sh`, by hand, outside any Claude session. It reads a done card's note only when
  the worktrees base holds a `<n>-*` entry (a local prefilter), so its cost scales with the local
  dirs, not the Done column; keep any new per-card network call behind that prefilter.
- `ROLE_ISOLATION: none` (decided Phase 5); nothing reads `FLEET_BOARD_ISOLATE`.
- **Clean-room primitives.** Every `agents/*.md` and
  `skills/{reporting,status}/SKILL.md` was authored by an isolated
  `claude -p --bare` process with a fresh empty `CLAUDE_CONFIG_DIR`, from a behavior spec
  in the plan's `specs/` (audit trail in `specs/README.md`), except the named exceptions in
  `clean-room-manifest.txt` (`agents/merger.md`, `agents/reviewer.md`, `skills/status/SKILL.md`).
  Never hand-edit them: change the spec or brief and re-author, or record a named exception. `skills/init` is not clean-room. No file under this
  plugin may contain the forbidden plugin name, a URL, or an attribution phrase in a
  clean-room file.
- API-key spend for clean-room authoring and isolated runs has a ceiling; the rule and the
  running total live in the plan's `HANDOFF.md` and `rehearsal-notes.md`. Check before any
  API-key run.
- Scripts run under `/bin/bash` 3.2 and both BSD and GNU tools: `sed -i.bak` (never bare
  `sed -i` or `sed -i ""`), no bash 4 features, `unset CDPATH` before `cd`, and
  `LC_ALL=C awk` for any decimal.
- Runtime data goes under `$HOME/.fleet-board/` (override `FLEET_BOARD_LOG_DIR`); the board page's state is its `web/<owner>-<name>/` subdirectory.

## Tests

- Offline suites: `bash plugins/fleet-board/tests/test-<name>.sh` (fakes: `fake-gh.sh`,
  `fake-claude.sh`, fixtures under `fixtures/`). `test-no-tick-system.sh` pins that the tick system stays
  gone. Run only the suite you touched.
- After any change under this directory: `bash plugins/fleet-board/tests/test-clean-room.sh`
  must pass.
- `behavioral-*.sh` are live: they run real headless sessions against `SANDBOX_REPO` and
  cost plan usage or API spend. Run one scenario at a time, only when asked.
