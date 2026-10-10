# fleet-board

Last verified: 2026-10-02

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
  Canonical states (`FB_STATES` in `board-lib.sh`): backlog ready in_progress in_review
  human_qa blocked done wont_do; board names come from `board.states.*` or the backend
  default. A new backend implements the same verbs.
- **Manager note** (`scripts/note.sh get|parse|put|merge|reset-failures|fail`). One comment per
  card, starting with `FB_MARKER`, holding one fenced JSON block. Trust boundary: only a
  marker comment authored by the authenticated `gh` login counts; `get` validates fields
  that could steer shell commands (`pr`, `branch` = `fleet/<n>-<slug>`, absolute `worktree`
  inside the worktrees base, integer counters, control-char-free `last_action_error`) and
  treats an invalid note as `{}` with a warning. `put`/`merge` refuse to write an invalid
  note; `merge` refuses to overwrite a stored invalid one.
- **Tick plan** (`scripts/tick-plan.sh`). Prints one JSON plan: an action per card from a
  single jq decision table (start, continue_implementor, start_review, review, fix,
  mark_ready, merge, verify_main, finish, to_human_qa, file_pending, block, unblock,
  skip, skip_no_acceptance, wait). Precedence: failed lookup, invalid note, file_pending,
  the `action_failures` rules, then the table. `action_failures` bound: at `max_rounds`
  consecutive no-progress actions the card is blocked; at `2*max_rounds` (or `max_rounds`
  for a blocked card awaiting unblock) it is skipped for a person, who clears it with
  `note.sh reset-failures <n>`. tick-plan only reads the count; the manager writes it.
- **Gate hook** (`hooks/gate.sh`, lexer `hooks/gate-lex.awk`). PreToolUse(Bash); exit 2
  blocks; inert without `.fleet-board.yml` in the command's effective cwd. G1: nothing
  moves a card out of human_qa. G2: `gh pr merge` blocked under `merge.policy: human`;
  under `auto` only explicit, non-draft, green, non-`--admin`. G3: moving to ready needs an
  `## Acceptance` section. Fails closed on anything it cannot resolve. It is a text check:
  documented residual bypasses (scripts run from files, other HTTP clients, push-merges,
  obfuscation) and false positives are listed in the plan's `rehearsal-notes.md`
  (Phase 4). Policy: add a residual to that list, do not claim the hook covers it.
- **Headless wrapper** (`scripts/fleet-board-run.sh`): exit codes and stop reasons are
  documented in `README.md`; keep the README table and the script in step.

## Invariants

- Merges stay human in headless runs; the wrapper never adds permission rules or
  `--dangerously-skip-permissions`. Worktree removal runs in `cleanup-done.sh`, outside any
  Claude session. It reads a done card's note only when the worktrees base holds a
  `<n>-*` entry (a local prefilter), so its cost scales with the local dirs, not the Done
  column; keep any new per-card network call behind that prefilter.
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
