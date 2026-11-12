# fleet-board

Last verified: 2026-11-07

## Purpose

Turns a local card board into a work queue for coding agents. A stateless manager
advances eligible cards as workers complete within bounded ticks; role agents (implementor, reviewer, fixer) work in
worktrees; a PreToolUse hook enforces the human-QA and merge gates. Status: 0.1.0.

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
  for validated CLI role reports. Web comments and notes leave it in place. The manager writes the note
  between `worktree.sh` and the dispatch on `start`. `stage-review.sh` also removes its marker
  in its EXIT trap, and `fleet-board-run.sh` removes every marker after each tick's session. The
  page lights a card while its marker exists and a run is alive; Start clears stale markers and
  the server clears them when it sees the run end. A failed write or removal is a warning.
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
  `note.sh reset-failures <n>`. tick-plan only reads the count; the manager writes it.
  `tick-plan.sh --settle <n>...` plans only the named cards (read with `board-read.sh`, no
  column listed) through the same table, keeping only steps that start no agent:
  `to_human_qa`, `block` and `mark_ready` stay, `start_review` becomes `move_to_review`
  (move the card, record `round: 1` and `pr`, no dispatch; only `--settle` emits it), and
  every other action is a `skip`. A settle plan is never dispatchable.
  Reviewed heads only: an in_review PR whose head moved past `last_review.sha` plans
  `review`, not `mark_ready`, `to_human_qa` or `merge`, unless every commit since
  is a merge of the base whose tree equals the `git merge-tree` result for its parents
  (`scripts/review-drift.sh <reviewed-sha> <head-sha>` prints `reviewed` or `unreviewed`;
  a failed check reads as unreviewed). `update-branch.sh` keeps `last_review` as it is.
- **Scope reservations.** A normal plan supplements open cards' declared Scope paths
  with their complete PR file lists when ready cards exist. Missing or truncated PR
  paths hold new starts, while existing work can continue. Selected starts reserve
  scope in ascending card-number order; a waiting card reserves nothing. Normalized
  directory scopes cover descendants with path-boundary matching. Settle plans do
  not fetch scope files or start workers.
- **Review stages** (`scripts/review-stages.sh route|match|next|setup`). `route <n> <pr>` adds
  each stage's routing label (path glob match or the label already on the card; never
  removes one) and prints the routed stage names; exit 1 on a failed read. The manager and
  `settle.sh` run it BEFORE the move to in_review, so a route failure leaves the card in
  in_progress and the next tick retries. `match <pr>` is read-only: it prints the stages
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
  Run by the manager as one Bash call in place of an Agent dispatch. It builds the prompt
  from `providers/stage-review-prompt.md`, calls the stage's provider through
  `providers/chat.sh`, checks the reply with `parse-report.sh --role stage-reviewer`,
  re-asks once on a rejection, posts the report with `board-comment.sh` and prints
  `{status, report_file, parsed, provider, model, input_tokens, output_tokens, cost_usd,
  attempts}`. Exit codes: 0 posted (or checked, with `--no-post`); 1 provider failure,
  empty or truncated reply, a reply holding any `<!-- fleet-board:` marker, or a failed post; 2 usage, unknown
  stage or an agent stage; 3 the key variable is unset or holds a control character (no call); 6 the reply was
  rejected twice; 7 the diff exceeds `max_diff_bytes` or has no text hunks (no call; the
  manager blocks the card). The manager counts 1, 3 and 6 as report errors and records
  `last_review.provider` and `last_review.model`; its `last_review.sha` is the PR head read
  just before the call. Ledger: one line per run that got a reply (exits 0, 1 after a
  reply, and 6) appended to `${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}/provider-spend.jsonl`
  with `cost_usd` and `FLEET_BOARD_RUN_ID`; `fleet-board-run.sh` exports the id
  (`<epoch>-<pid>`) and adds only its own lines to each tick's cost, so
  `limits.max_cost_usd` covers provider spend.
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
  sets exactly one of `agent` and `provider`; a provider stage needs `model` and `price`.
  A provider entry with `command` (the `codex` preset) runs `chat.sh --command` instead of curl: prompt on stdin, repo root as cwd, stdout is the reply, tokens `null`, so `stage-review.sh` counts cost 0; `base_url` and `api_key_env` must be null with it. `tick-plan.sh` warns when a provider stage's key variable is unset and holds
  `review_stage` in that stage as `wait` (`stage <name>: <ENV> is not set`).
- **Dependency gate** (`scripts/deps.sh parse|check`). `parse-card` reads a card's `blocked_by`
  card numbers (`parse` still reads a body file's `## Depends on` bullets); `check` looks
  each up in the local store and prints `{unmet, warnings}`; a failed lookup exits 1 and names its command on stderr as
  `deps-lookup-failed: <command>`. `tick-plan.sh` plans `wait` (with `waiting_on`) for a
  Ready card with an unmet dependency; the manager records the refs it last commented on
  in the note's `deps_commented`. Only Ready cards are gated.
- **Gate hook** (`hooks/gate.sh`, lexer `hooks/gate-lex.awk`). PreToolUse(Bash); exit 2
  blocks; inert without `.fleet-board.yml` in the command's effective cwd. G1: nothing
  moves a card out of human_qa. G2: `gh pr merge` blocked under `merge.policy: human`;
  under `auto` only explicit, non-draft, green, non-`--admin`, and, for a `fleet/<n>-*`
  branch, a head whose commits after the note's `last_review.sha` are all clean merges of
  main (`review-drift.sh`; otherwise blocked as unreviewed). G3: moving to ready needs a non-empty
  `acceptance` field on the card. Fails closed on anything it cannot resolve. It is a text check:
  documented residual bypasses (scripts run from files, other HTTP clients, push-merges,
  obfuscation) and false positives are listed in the plan's `rehearsal-notes.md`
  (Phase 4). Policy: add a residual to that list, do not claim the hook covers it.
- **Headless wrapper** (`scripts/fleet-board-run.sh`): exit codes and stop reasons are
  documented in `README.md`; keep the README table and the script in step. It exports
  `FLEET_BOARD_RUN_ID` before the first tick (see Provider stages). It holds the run lock
  `<LOG_DIR>/<owner>-<name>.lock` (pid, then `ps -o lstart=` in C/UTC; the board page's
  `run.pid` format) for its life and exits 1 while another live run holds it; `board-web.py`
  reads the same path, so keep the two in step.
- **Command-line supervisor** (`scripts/supervisor/`, `scripts/supervisor.sh`; design:
  `docs/superpowers/specs/2026-11-11-cli-supervisor-design.md`). A process you start yourself that
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
    child runs, writing `{pgid, supervisor_pid}` atomically (`markers.py`), and removes it when the
    action ends (finish, cancel, reap, `State.end`) only while it still names that action's
    process group. Board scripts still create an empty marker (`fb_mark_active`, which never
    truncates one) and remove it when a role posts its report (`comment.sh`).
  - `stuck [--json] [--release N [--force]]` (`stuck.py`) reads the board itself, asking a running
    supervisor only for the cards it owns (never reported). Kinds: `in_flight` (in_progress with no
    owning session, or merging with `pending_merge` and no record of how it ended), `live_orphan` (a
    marker naming a process group that still runs), `marker` (a marker whose pgid is dead or absent),
    `dirty_worktree` (uncommitted changes to tracked files; `git --no-optional-locks status
    --porcelain --untracked-files=no`), `unreadable_worktree` (that status failed or timed out:
    never taken as clean), `dead_lock` (a card lock whose holder is gone, or pid-less past
    `LOCK_GRACE`), `unreadable_note`. Every non-terminal state is checked (all but backlog, done,
    wont_do; review stages included). A live process holding the repository run lock that did not
    answer `status` as the supervisor makes `--release` refuse ("a run is active (pid N)") and the
    plain list print a one-line notice.
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
    outcome), typed error codes in `supervisor/errors.py`. Ownership shares the run lock with the
    legacy wrapper (`claim-run-lock.py --kind service`; path `service.default_run_lock_path`). The
    board server has no config switch: its `/api/supervisor*` routes and supervisor-shaped
    `/api/run` answer only while a supervisor socket answers `status` within 1 s
    (`supervisor_running()`), otherwise 404 and the legacy run API; a Start treats a stopping
    supervisor as not running and waits for it to go before launching. Status is
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
    verification. A card in merging is never moved to done by the script, in any form (the legacy
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
    holds it until then; a second refusal after a retry is attention. A merger `attention` keeps
    the card in merging (`skip "merger needs attention; a person decides"`) with `pending_merge`
    cleared. The way out: `note.sh merge <n>` with `merger: null` (plus `merge_refusal: null`
    and `merge_retry: null` to let it merge again), or move the card by hand to another column
    (the lane drops those records when the card is merged from there again).
  - Persona: `merge.persona` null (the default) -> `.fleet-board/merger.md` when present, else the
    plugin default; a set path that is missing, or a tracked persona this PR changed, is attention.
  - Checks: one rule, `scripts/ignore-checks.jq`, shared by the planner and the gate: an unexpired
    `merge.ignore_checks` entry ignores the red checks its glob matches (a `*` entry ignores every
    red check); a pending check is never green.

## Invariants

- Headless merges happen only in `scripts/merge-reviewed.sh`, a plain shell step outside any
  Claude session that the wrapper runs after `settle.sh`. It merges only under
  `merge.policy: auto`, for a clean-reviewed, non-draft, green PR whose card is in_review or a review stage
  and needs no Human QA (it asks `tick-plan.sh --settle-merge`); under `human` it makes no
  call. The helper drains a bounded candidate snapshot with a fresh plan per attempt,
  binds each merge to its planned head, and requires literal `main_check.ok == true`.
  It recovers pending verification before new merges. Exit 3 stops the wrapper before
  cleanup or another tick; other per-card failures remain warnings. The wrapper never adds permission rules or `--dangerously-skip-permissions`, and no
  tick merges headless. `FLEET_BOARD_MERGE_REVIEWED` overrides the script. Worktree removal runs in `cleanup-done.sh`, outside any
  Claude session. It reads a done card's note only when the worktrees base holds a
  `<n>-*` entry (a local prefilter), so its cost scales with the local dirs, not the Done
  column; keep any new per-card network call behind that prefilter.
- **Settle step** (`scripts/settle.sh`): after each successful tick, and before
  `cleanup-done.sh`, the wrapper runs it from the repo root, outside any Claude session. It
  lists in_progress, in_review and every review stage column, runs `tick-plan.sh --settle`, and carries out only the
  steps that start no agent (`move_to_review` (routes via `review-stages.sh route` before the move, so a route failure leaves the card in in_progress), `advance_stage`, `to_human_qa`, `mark_ready`, `block`),
  mirroring the manager's action table. It acts on the manager note, never merges, never
  moves a card out of human_qa, and writes no `action_failures`; a `block` whose reason
  starts with `no progress after` is left to the manager (2.D). A person's interactive
  `/fleet-board:tick` does not run it. `FLEET_BOARD_SETTLE` overrides the script; a failure is
  only a logged warning.
- `ROLE_ISOLATION: none` (decided Phase 5); `FLEET_BOARD_ISOLATE=1` is refused.
- **Clean-room primitives.** Every `agents/*.md` and
  `skills/{reporting,tick,run,status}/SKILL.md` was authored by an isolated
  `claude -p --bare` process with a fresh empty `CLAUDE_CONFIG_DIR`, from a behavior spec
  in the plan's `specs/` (audit trail in `specs/README.md`). Never hand-edit them: change
  the spec or brief and re-author. `skills/init` is not clean-room. No file under this
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
  `fake-claude.sh`, fixtures under `fixtures/`). Run only the suite you touched.
- After any change under this directory: `bash plugins/fleet-board/tests/test-clean-room.sh`
  must pass.
- `behavioral-*.sh` are live: they run real headless sessions against `SANDBOX_REPO` and
  cost plan usage or API spend. Run one scenario at a time, only when asked.
