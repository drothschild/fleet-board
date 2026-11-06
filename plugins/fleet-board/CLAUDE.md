# fleet-board

Last verified: 2026-11-06

## Purpose

Turns a GitHub issue board into a work queue for coding agents. A stateless manager
advances every card one step per tick; role agents (implementor, reviewer, fixer) work in
worktrees; a PreToolUse hook enforces the human-QA and merge gates. Status: 0.1.0.

This public repo carries only the clean-room specs from the implementation plan, under
`docs/implementation-plans/2026-09-28-fleet-board/specs/`. The plan itself, its rehearsal
notes and its handoff stay in the author's private repo, so references to them below have
no file here. The gate's residual bypasses and false positives are listed in the README's
`## Gates`.

## Contracts

- **Board adapter.** Callers use only the `scripts/board-*.sh` contract scripts
  (`read`, `list`, `move`, `create`, `comment`, `note`, `cache-clear`). Each validates its
  arguments (exit 2 on usage), loads config, and execs
  `scripts/adapters/<board.backend>/<verb>.sh`. Backends: `github-labels`,
  `github-projects`. `list` fails closed (exit 1) when `gh` returns exactly its `--limit`
  items (500 labels, 1000 Projects), since the reply may be truncated. Remedies: raise
  `FLEET_BOARD_LIST_LIMIT`, or shrink the listing (labels: remove `fleet:done` from old
  closed issues, as done/wont_do grow without bound; Projects: archive done items).
  `board-list.sh --allow-truncated` downgrades that to a warning; only `cleanup-done.sh`
  passes it. Active-column callers (tick-plan, status) must keep failing closed.
  Canonical states (`FB_STATES` in `board-lib.sh`, set by `fb_load_config`, not a
  constant): backlog ready in_progress in_review, then `review_<name>` for each
  `review.stages` entry in config order, then human_qa blocked done wont_do
  (`FB_STATES_FIXED` is the list without stages); board names come from `board.states.*` or
  the backend default (`fleet:review_<name>` labels, `Review: <name>` columns). A new backend implements the same verbs.
- **Manager note** (`scripts/note.sh get|parse|put|merge|reset-failures|fail`). One comment per
  card, starting with `FB_MARKER`, holding one fenced JSON block. Trust boundary: only a
  marker comment authored by the authenticated `gh` login counts; `get` validates fields
  that could steer shell commands (`pr`, `branch` = `fleet/<n>-<slug>`, absolute `worktree`
  inside the worktrees base, integer counters, control-char-free `last_action_error`) and
  treats an invalid note as `{}` with a warning. `put`/`merge` refuse to write an invalid
  note; `merge` refuses to overwrite a stored invalid one. Review-stage fields: `stage`
  (null or a stage name), `reviewed_stages` (list of names), `last_review.stage` and
  `last_review.provider` (null for an In Review or agent-stage record), each validated
  against `^[a-z][a-z0-9_]*$` (`provider` also allows `-`).
- **Tick plan** (`scripts/tick-plan.sh`). Prints one JSON plan: an action per card from a
  single jq decision table (start, continue_implementor, start_review, review, fix,
  mark_ready, merge, verify_main, finish, to_human_qa, file_pending, block, unblock,
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
  `--done` does not list. `setup` creates labels (both backends; state labels on
  github-labels) or checks Projects columns (exit 1 naming the missing ones). Tick plan:
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
  `tick-plan.sh` warns when a provider stage's key variable is unset.
- **Dependency gate** (`scripts/deps.sh parse|check`). `parse` reads a card body's
  `## Depends on` bullets (`#n` or `owner/repo#n`); `check` looks each up and prints
  `{unmet, warnings}`; a failed lookup exits 1 and names its command on stderr as
  `deps-lookup-failed: <command>`. `tick-plan.sh` plans `wait` (with `waiting_on`) for a
  Ready card with an unmet dependency; the manager records the refs it last commented on
  in the note's `deps_commented`. Only Ready cards are gated.
- **Gate hook** (`hooks/gate.sh`, lexer `hooks/gate-lex.awk`). PreToolUse(Bash); exit 2
  blocks; inert without `.fleet-board.yml` in the command's effective cwd. G1: nothing
  moves a card out of human_qa. G2: `gh pr merge` blocked under `merge.policy: human`;
  under `auto` only explicit, non-draft, green, non-`--admin`, and, for a `fleet/<n>-*`
  branch, a head whose commits after the note's `last_review.sha` are all clean merges of
  main (`review-drift.sh`; otherwise blocked as unreviewed). G3: moving to ready needs an
  `## Acceptance` section. Fails closed on anything it cannot resolve. It is a text check:
  documented residual bypasses (scripts run from files, other HTTP clients, push-merges,
  obfuscation) and false positives are listed in the plan's `rehearsal-notes.md`
  (Phase 4). Policy: add a residual to that list, do not claim the hook covers it.
- **Headless wrapper** (`scripts/fleet-board-run.sh`): exit codes and stop reasons are
  documented in `README.md`; keep the README table and the script in step. It exports
  `FLEET_BOARD_RUN_ID` before the first tick (see Provider stages).

## Invariants

- Headless merges happen only in `scripts/merge-reviewed.sh`, a plain shell step outside any
  Claude session that the wrapper runs after `settle.sh`. It merges only under
  `merge.policy: auto`, for a clean-reviewed, non-draft, green PR whose card is in_review or a review stage
  and needs no Human QA (it asks `tick-plan.sh --settle-merge`); under `human` it makes no
  call. The wrapper never adds permission rules or `--dangerously-skip-permissions`, and no
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
- Runtime data goes under `$HOME/.fleet-board/` (override `FLEET_BOARD_LOG_DIR`).

## Tests

- Offline suites: `bash plugins/fleet-board/tests/test-<name>.sh` (fakes: `fake-gh.sh`,
  `fake-claude.sh`, fixtures under `fixtures/`). Run only the suite you touched.
- After any change under this directory: `bash plugins/fleet-board/tests/test-clean-room.sh`
  must pass.
- `behavioral-*.sh` are live: they run real headless sessions against `SANDBOX_REPO` and
  cost plan usage or API spend. Run one scenario at a time, only when asked.
