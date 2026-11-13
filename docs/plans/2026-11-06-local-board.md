# Local web board with Start/Stop: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `local` board backend that keeps cards in JSON files, and a localhost web page that shows the board, edits and moves cards, starts and stops the headless run, and imports a plan through a Claude session.

**Architecture:** The six board verbs get a third adapter under `scripts/adapters/local/` that reads and writes `<repo>/.fleet-board/cards/<n>.json` under the existing per-card lock. A single-file Python 3 standard-library server (`scripts/board-web.py`) reads those files directly and performs every write by running the same `board-*.sh` scripts the agents run. The page is static HTML, CSS and JavaScript served by that process.

**Tech Stack:** bash 3.2 + jq (adapters, tests), Python 3.9+ standard library (server), vanilla HTML/CSS/JS (page), plain-bash assertion suites with `curl` and the existing `fake-claude.sh`.

**Spec:** `docs/specs/2026-11-06-local-board-design.md`

## Global constraints

- Shell: `/bin/bash` 3.2, BSD and GNU tools: no bash 4 features, `sed -i.bak` only, `unset CDPATH` before any captured `cd`, `LC_ALL=C` for any `awk` reading or printing a decimal.
- Python: 3.9+, standard library only, no network fetches, bound to `127.0.0.1` only.
- Page: no build step, no CDN, no `innerHTML` from card text.
- Clean-room files are never edited: `agents/*.md`, `skills/{reporting,tick,run,status}/SKILL.md`. `tests/test-clean-room.sh` must pass after every task.
- Portability: no absolute or personal paths in the plugin; runtime data under `$HOME/.fleet-board/` (`FLEET_BOARD_LOG_DIR` overrides the parent).
- Defaults: `board.dir` = `.fleet-board`, `board.port` = `8765`, `board.backend` values `github-labels|github-projects|local`.
- Version: `0.13.0` in `plugins/fleet-board/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
- Tests: one suite per touched area, run only that suite, and prove each new suite can fail once (break, watch, restore) before trusting it.
- Git: every task ends in a commit on `feat/local-board`; push after each task (`git push`).
- Commit trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review focus

1. A card title or body holding double quotes, backslashes or newlines must round-trip through create, edit and read unchanged. Test added to Task 2.
2. A corrupt or missing `next` file must make `create` exit 1 with a message naming the file, never allocate number 1 again. Test added to Task 2.
3. `move` to a state that is not in `FB_STATES` for this config (for example `review_security` with no such stage) must exit 2 without writing. Test added to Task 3.
4. `GET /api/cards/999` for a card that does not exist must be 404 with `{"error": ...}`, not a 500 traceback. Test added to Task 7.
5. Stop with no run alive must be 409 with a message, and Start while a run is `stopping` must be 409, so a double click never spawns a second wrapper. Tests added to Task 8.

---

## File structure

**Create**

| File | Responsibility |
|---|---|
| `scripts/adapters/local/local-lib.sh` | store paths, atomic write, timestamp, next-number lock; sourced by every local verb |
| `scripts/adapters/local/{read,list,move,create,comment,note,cache-clear}.sh` | the contract verbs |
| `scripts/adapters/local/edit.sh` | local-only title/body/labels rewrite under the card lock |
| `scripts/board-web.sh` | launcher: config check, backend check, python3 check, exec |
| `scripts/board-web.py` | the HTTP server and the run/import controllers |
| `scripts/board-web/static/index.html`, `board.css`, `board.js` | the page |
| `tests/test-board-local.sh` | adapter suite |
| `tests/test-board-web.sh` | server suite (API through curl) |
| `tests/fake-run.sh` | fake headless wrapper for the server suite |

**Modify**

`scripts/config.sh`, `scripts/config-defaults.json`, `scripts/board-lib.sh`, `scripts/board-cache-clear.sh` (only if it hardcodes backends), `scripts/init.sh`, `scripts/review-stages.sh`, `scripts/deps.sh`, `scripts/import-plan.sh`, `scripts/worktree.sh`, `scripts/stage-review.sh`, `hooks/gate.sh`, `skills/import-plan/SKILL.md`, `skills/init/SKILL.md`, `README.md`, `docs/config.md`, `docs/overnight.md`, `docs/gates.md`, `plugins/fleet-board/CLAUDE.md`, `docs/design.md`, both manifests, and the suites `test-config.sh`, `test-init.sh`, `test-gate.sh`, `test-deps.sh`, `test-import-plan.sh`, `test-review-stages.sh`, `test-worktree.sh`, `test-stage-review.sh`.

All paths below are relative to `plugins/fleet-board/` unless they start with `docs/` or `.claude-plugin/`.

---

### Task 1: Config and identity for the `local` backend

**Files:**
- Modify: `scripts/config.sh:199-203` (backend validation), add `board.dir` and `board.port` rules next to the `worktrees.dir` rule at `:303`
- Modify: `scripts/config-defaults.json` (`board` object)
- Modify: `scripts/board-lib.sh:51-55` (`fb_login`), `:138-165` (`fb_default_name`)
- Test: `tests/test-config.sh`, `tests/test-board-local.sh` (new; this task creates it with the helper block copied from `tests/test-board-labels.sh:1-80` minus the fake-gh helpers)

**Interfaces:**
- Produces: `fb_cfg board.dir` (string, default `.fleet-board`), `fb_cfg board.port` (integer, default `8765`); `fb_login` prints `${FLEET_BOARD_USER:-$USER}` when `fb_cfg board.backend` is `local` (no `gh` call); `fb_default_name` on `local` prints `Backlog`, `Ready`, `In Progress`, `In Review`, `Human QA`, `Blocked`, `Done`, `Won't Do`, and `Review: <stage>` for `review_<stage>`.

- [ ] **Step 1: Add failing config cases to `tests/test-config.sh`** (after Test 11, same `make_test_repo` / `assert_key` / `assert_exit` helpers)

```bash
# Test 12: local backend accepted, defaults filled
REPO="$(make_test_repo_inline $'board:\n  backend: local\n  repo: acme/toy')"
run_config "$REPO"
assert_exit "local backend exit 0" "0"
assert_key "$REPO" "board.backend" "local" "local backend kept"
assert_key "$REPO" "board.dir" ".fleet-board" "board.dir default"
assert_key "$REPO" "board.port" "8765" "board.port default"
# Test 13: board.dir must be relative and clean
REPO="$(make_test_repo_inline $'board:\n  backend: local\n  repo: acme/toy\n  dir: /tmp/x')"
run_config "$REPO" --check; assert_exit "absolute board.dir exit 5" "5"; assert_stderr_contains "absolute board.dir named" "board.dir"
REPO="$(make_test_repo_inline $'board:\n  backend: local\n  repo: acme/toy\n  dir: ../x')"
run_config "$REPO" --check; assert_exit "dotdot board.dir exit 5" "5"
# Test 14: board.port range
REPO="$(make_test_repo_inline $'board:\n  backend: local\n  repo: acme/toy\n  port: 80')"
run_config "$REPO" --check; assert_exit "low port exit 5" "5"; assert_stderr_contains "port named" "board.port"
# Test 15: the old error text names all three backends
REPO="$(make_test_repo bad-backend.yml)"
run_config "$REPO" --check; assert_stderr_contains "backend list" "github-labels, github-projects or local"
```

If `test-config.sh` has no inline-YAML helper, add `make_test_repo_inline <yaml>` beside `make_test_repo` (writes the YAML to a temp repo's `.fleet-board.yml`).

- [ ] **Step 2: Run `bash tests/test-config.sh`; expect the new cases to FAIL** (exit 5 on `backend: local`, message `board.backend must be github-labels or github-projects`).

- [ ] **Step 3: Implement in `scripts/config.sh`**: the backend rule accepts `local` and its message becomes `board.backend must be github-labels, github-projects or local`; add rules `board.dir must be a non-empty relative path without ..` (string, not empty, not starting with `/`, no `..` path segment) and `board.port must be an integer between 1024 and 65535`. Add `"dir": ".fleet-board", "port": 8765` to the `board` object in `config-defaults.json`.

- [ ] **Step 4: Run `bash tests/test-config.sh`; expect PASS.**

- [ ] **Step 5: Create `tests/test-board-local.sh`** with the helper block (`pass`, `fail`, `run_check`, `assert_exit`, `assert_stdout_contains`, `assert_stderr_contains`, `cleanup`, `BASH_EXE`) and a `setup_case` that makes a temp git repo whose `.fleet-board.yml` is:

```yaml
board:
  backend: local
  repo: acme/toy
worktrees:
  dir: .fw
```

committed, with `SCRIPTS="$SCRIPT_DIR/../scripts"`, and `cd "$REPO"` before each `run_check`. Add the first cases:

```bash
setup_case
run_check_in "$REPO" bash -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_stdout_exact "fb_login is USER on local" "$USER"
FLEET_BOARD_USER=robot run_check_in "$REPO" bash -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_login'
assert_stdout_exact "fb_login honors FLEET_BOARD_USER" "robot"
run_check_in "$REPO" bash -c '. "$SCRIPTS/board-lib.sh"; fb_load_config; fb_state_name in_progress; fb_state_name wont_do'
assert_stdout_exact "local default names" $'In Progress\nWon'"'"'t Do'
```

with `PATH` set so that `gh` is a stub that exits 99 (so a stray `gh api user` fails the case).

- [ ] **Step 6: Run `bash tests/test-board-local.sh`; expect the three cases to FAIL** (`fb_login` tries `gh`, names come out as `fleet:in_progress`).

- [ ] **Step 7: Implement in `scripts/board-lib.sh`**: `fb_login` returns early on `local`; `fb_default_name` adds a `local)` branch with the human names and `Review: <stage>` (share the name table with `github-projects` rather than duplicating it).

- [ ] **Step 8: Run `bash tests/test-board-local.sh`; expect PASS. Run `bash tests/test-clean-room.sh`; expect PASS.**

- [ ] **Step 9: Commit**

```bash
git add scripts/config.sh scripts/config-defaults.json scripts/board-lib.sh tests/test-config.sh tests/test-board-local.sh
git commit -m "feat(config): accept the local board backend with board.dir and board.port"
```

---

### Task 2: Local adapter: store library, `create`, `read`, `list`, `cache-clear`

**Files:**
- Create: `scripts/adapters/local/local-lib.sh`, `create.sh`, `read.sh`, `list.sh`, `cache-clear.sh`
- Test: `tests/test-board-local.sh`

**Interfaces:**
- Consumes: `fb_load_config`, `fb_cfg`, `fb_die`, `fb_login`, `fb_valid_state`, `FB_STATES`, `FB_MARKER`, `FB_CREATE_STATE` (exported by `board-create.sh`), `FLEET_ROOT`.
- Produces (`local-lib.sh`, all after `fb_load_config`):
  - `fl_dir` prints `$FLEET_ROOT/$(fb_cfg board.dir)`; `fl_cards_dir` prints `<dir>/cards`; `fl_active_dir` prints `<dir>/active`.
  - `fl_card_file <n>` prints `<cards dir>/<n>.json`.
  - `fl_read_card <n>` prints the card JSON; exit 1 `card #<n> not found in <cards dir>` or `card #<n> is not valid JSON: <file>`.
  - `fl_write_card <n> <json-file>` writes atomically (`mktemp` in the cards dir, then `mv -f`); exit 1 on failure.
  - `fl_now` prints UTC `%Y-%m-%dT%H:%M:%SZ`.
  - `fl_next_number` takes a `mkdir` lock `<dir>/.next.lock` (same wait and stale rules as `fb_lock`), reads `<dir>/next`, writes `next+1`, prints the number; exit 1 naming the file when it is missing or not a positive integer.
  - `fl_url <n>` prints `http://127.0.0.1:<board.port>/cards/<n>`.
  - `fl_require_store` exits 1 with `no local board at <dir>; run /fleet-board:init` when `<dir>/next` is missing.
- Produces (verbs): the shapes in the spec's Adapter table.

- [ ] **Step 1: Add failing cases to `tests/test-board-local.sh`** (init the store in `setup_case`: `mkdir -p "$REPO/.fleet-board/cards"; echo 1 > "$REPO/.fleet-board/next"`)

```bash
body="$(mktemp)"; printf '## Why\nx\n\n## Acceptance\n- a "quoted" \\ thing\n' > "$body"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" 'Title with "quotes"' "$body" --label bug
assert_exit "create exit 0" 0
assert_stdout_exact "create prints number and url" '{"number":1,"url":"http://127.0.0.1:8765/cards/1"}'
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_exit "read exit 0" 0
assert_json "read title round-trips" '.title' 'Title with "quotes"'
assert_json "read body round-trips" '.body' "$(cat "$body")"
assert_json "read state backlog" '.state' backlog
assert_json "read labels" '.labels|join(",")' bug
assert_json "read note null" '.manager_note' null
assert_json "read item_id null" '.item_id' null
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Second "$body" --state ready
assert_stdout_contains "second number is 2" '"number":2'
run_check_in "$REPO" "$SCRIPTS/board-list.sh" backlog
assert_stdout_exact "list backlog" '[{"number":1,"title":"Title with \"quotes\"","url":"http://127.0.0.1:8765/cards/1"}]'
run_check_in "$REPO" "$SCRIPTS/board-list.sh" done
assert_stdout_exact "list empty column" '[]'
echo '{' > "$REPO/.fleet-board/cards/2.json"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" ready
assert_exit "list fails closed on a corrupt card" 1
assert_stderr_contains "list names the file" "2.json"
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 2
assert_exit "read fails on a corrupt card" 1
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 77
assert_exit "read missing card" 1
assert_stderr_contains "read names the card" "card #77"
echo abc > "$REPO/.fleet-board/next"
run_check_in "$REPO" "$SCRIPTS/board-create.sh" Third "$body"
assert_exit "corrupt next fails create" 1
assert_stderr_contains "corrupt next named" "next"
rm "$REPO/.fleet-board/next"
run_check_in "$REPO" "$SCRIPTS/board-list.sh" backlog
assert_exit "missing store exit 1" 1
assert_stderr_contains "missing store says init" "/fleet-board:init"
run_check_in "$REPO" "$SCRIPTS/board-cache-clear.sh"
assert_exit "cache-clear no-op" 0
```

`assert_json <desc> <jq filter> <expected>` applies the filter with `jq -r` to `LAST_OUT`.

- [ ] **Step 2: Run the suite; expect FAIL** (`adapters/local/create.sh: No such file`).

- [ ] **Step 3: Implement `local-lib.sh` and the four verbs.** `read.sh` builds the output with one `jq` program over the card file: `manager_note` is the body of the last comment whose body starts with `$FB_MARKER` and whose author is `fb_login`, with its first line stripped (as the labels adapter does), `manager_note_id` its `id`, `state` null with a stderr warning when not in `FB_STATES`. `list.sh` iterates `cards/*.json`, dies on the first unparsable file, filters with `jq`, sorts by number, prints a compact array; accepts and ignores `--allow-truncated`. `create.sh` builds the card with `jq -n --arg` for every string (never string interpolation), `next_comment_id: 1`, `comments: []`, `state: "$FB_CREATE_STATE"`. Check `scripts/board-cache-clear.sh` dispatches by backend like the others; if it special-cases Projects, add the `local` no-op there instead.

- [ ] **Step 4: Run the suite; expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/adapters/local tests/test-board-local.sh
git commit -m "feat(local): create, read, list and cache-clear on the local backend"
```

---

### Task 3: Local adapter: `move`, `comment`, `note`, `edit`

**Files:**
- Create: `scripts/adapters/local/move.sh`, `comment.sh`, `note.sh`, `edit.sh`
- Test: `tests/test-board-local.sh`

**Interfaces:**
- Consumes: Task 2's `local-lib.sh`; `fb_lock <n>`; `fb_has_acceptance`; `fb_valid_state`.
- Produces: `edit.sh <n> <title-file> <body-file> <labels-json>` (labels is a JSON array of strings; exit 2 on usage, 1 on a missing card); `note.sh` removes `$(fl_active_dir)/<n>` after writing (used by Task 4).

- [ ] **Step 1: Add failing cases**

```bash
setup_case; seed_card 1 backlog 'A card' $'## Acceptance\n- one'   # helper: writes cards/1.json directly
seed_card 2 backlog 'No acceptance' 'just text'
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 1 in_progress
assert_exit "move exit 0" 0
assert_card_state 1 in_progress
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 2 ready
assert_exit "move to ready without Acceptance refused" 1
assert_stderr_contains "refusal names Acceptance" "Acceptance"
assert_card_state 2 backlog
run_check_in "$REPO" "$SCRIPTS/board-move.sh" 1 review_security
assert_exit "move to an unknown state exit 2" 2
assert_card_state 1 in_progress
c="$(mktemp)"; echo 'first comment' > "$c"
run_check_in "$REPO" "$SCRIPTS/board-comment.sh" 1 "$c"
assert_exit "comment exit 0" 0
assert_card_json 1 '.comments|length' 1
assert_card_json 1 '.comments[0].id' 1
assert_card_json 1 '.comments[0].author' "$USER"
n="$(mktemp)"; printf '```json\n{"round":1}\n```\n' > "$n"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$n"
assert_card_json 1 '.comments|length' 2
assert_card_json 1 '.comments[1].body|startswith("<!-- fleet-board:manager-note -->")' true
printf '```json\n{"round":2}\n```\n' > "$n"
run_check_in "$REPO" "$SCRIPTS/board-note.sh" 1 "$n"
assert_card_json 1 '.comments|length' 2
assert_card_json 1 '.comments[1].body|contains("\"round\":2")' true
run_check_in "$REPO" "$SCRIPTS/board-read.sh" 1
assert_json "read returns the note body without the marker line" '.manager_note' $'```json\n{"round":2}\n```'
assert_json "read returns the note id" '.manager_note_id' 2
# concurrency: eight comments at once lose nothing
for i in 1 2 3 4 5 6 7 8; do (cd "$REPO" && bash "$SCRIPTS/board-comment.sh" 1 "$c") & done; wait
assert_card_json 1 '.comments|length' 10
t="$(mktemp)"; echo 'Renamed' > "$t"; b="$(mktemp)"; echo 'new body' > "$b"
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 "$t" "$b" '["x","y"]'
assert_exit "edit exit 0" 0
assert_card_json 1 '.title' Renamed
assert_card_json 1 '.labels|join(",")' x,y
assert_card_json 1 '.comments|length' 10
assert_card_json 1 '.state' in_progress
run_check_in "$REPO" bash "$SCRIPTS/adapters/local/edit.sh" 1 "$t" "$b" 'notjson'
assert_exit "edit bad labels exit 2" 2
```

`seed_card`, `assert_card_state` and `assert_card_json` read and write `cards/<n>.json` with `jq`.

- [ ] **Step 2: Run the suite; expect FAIL.**

- [ ] **Step 3: Implement the four scripts.** `move.sh`: `fb_valid_state "$2" || fb_die 2`, `fb_lock`, read, Ready rule, no-op when already there, else rewrite `state` and `updated_at`. `comment.sh`: `fb_lock`, append with `id = next_comment_id`, bump `next_comment_id`. `note.sh`: `fb_lock`, body = marker line + file, replace the last marker comment by `fb_login` or append; then `rm -f "$(fl_active_dir)/$1"`. `edit.sh`: validate `labels` with `jq -e 'type=="array" and all(.[]; type=="string")'`, `fb_lock`, rewrite only `title`, `body`, `labels`, `updated_at`.

- [ ] **Step 4: Run the suite; expect PASS. Prove the suite can fail: comment out the `mv` in `fl_write_card`, run, see failures, restore.**

- [ ] **Step 5: Commit**

```bash
git add scripts/adapters/local tests/test-board-local.sh
git commit -m "feat(local): move, comment, note and edit on the local backend"
```

---

### Task 4: Active markers

**Files:**
- Modify: `scripts/worktree.sh:118-135` (`create`), `:162-190` (`review`), `scripts/stage-review.sh:85-113`
- Test: `tests/test-worktree.sh`, `tests/test-stage-review.sh`, `tests/test-board-local.sh`

**Interfaces:**
- Consumes: `fl_active_dir` (source `adapters/local/local-lib.sh` only when `fb_cfg board.backend` is `local`).
- Produces: `<board.dir>/active/<n>` exists after `worktree.sh create|review <n> ...` and during `stage-review.sh <n> ...`, on the `local` backend only.

- [ ] **Step 1: Add failing cases.** In `tests/test-worktree.sh`, a second `setup_case` variant whose config adds `board:\n  backend: local` (keep `repo: acme/toy`), then after `create` and after `review`: `[ -f "$REPO/.fleet-board/active/12" ]` → pass `create writes the active marker`; on the default (labels) config: marker absent → pass `labels config writes no marker`. In `tests/test-stage-review.sh`, with a local config and the fake provider: a `--no-post` run leaves no `active/<n>` after exit (`stage-review removes its marker on exit`), and a run whose fake provider sleeps 1 s shows the marker while running (check from a background `sleep 0.3; test -f` → write a flag file). In `tests/test-board-local.sh`: `touch active/1`, run `board-note.sh 1`, assert the marker is gone.

- [ ] **Step 2: Run the three suites; expect the new cases to FAIL.**

- [ ] **Step 3: Implement.** In `worktree.sh`, a function `mark_active <n>` guarded by `[ "$(fb_cfg board.backend)" = local ]` that creates the dir and touches the file, warning on failure; call it right before the `printf '%s\n' "$P"` / `jq -nc` output lines of `create` and `review`. In `stage-review.sh`, the same `mark_active` after `fb_load_config`, and extend the existing `trap 'rm -rf "$TMP"' EXIT` to also remove the marker.

- [ ] **Step 4: Run the three suites; expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/worktree.sh scripts/stage-review.sh tests/test-worktree.sh tests/test-stage-review.sh tests/test-board-local.sh
git commit -m "feat(local): mark a card active while a role works on it"
```

---

### Task 5: Gate, deps, review-stages setup and init on `local`

**Files:**
- Modify: `hooks/gate.sh:761` (backend case), `:873` (`gate_item` returns 0 on `local`), `:965` (label check unchanged, it already tests `github-labels`)
- Modify: `scripts/deps.sh:88-120` (`check_ref`)
- Modify: `scripts/review-stages.sh:212-240` (`setup`)
- Modify: `scripts/init.sh:39`, `:97-105`, `:134`, `:241-318`
- Modify: `skills/init/SKILL.md` Step 2
- Test: `tests/test-gate.sh`, `tests/test-deps.sh`, `tests/test-review-stages.sh`, `tests/test-init.sh`

**Interfaces:**
- Consumes: Task 2's store layout (deps reads `cards/<n>.json` directly through `fl_read_card`).
- Produces: `init.sh --backend local --repo OWNER/NAME` writes the config, creates `<dir>/cards`, writes `<dir>/next` = `1`, appends `<dir>/` to `.gitignore` unless present, makes no `gh label` call; `deps.sh check` on `local` resolves `#n` from the store: state `done` → met, `wont_do` → not planned, a missing card → `deps-lookup-failed: local card #n`.

- [ ] **Step 1: Add failing cases.**
  - `test-gate.sh`: a `local` config variant in `setup_case` (`CONFIG` value `local-auto`); `board-move.sh 14 done` on a human_qa card is blocked with the existing message; `board-move.sh 14 ready` on a card without Acceptance is blocked; a `gh pr merge 5` under `auto` follows the existing rules; and a config with `backend: local` is not `could not verify the board config`.
  - `test-deps.sh`: local config, `cards/22.json` in state `done` → `unmet` empty; `cards/23.json` in `in_review` → unmet with `status: in_review`; `cards/24.json` in `wont_do` → the not-planned warning; missing `cards/25.json` → exit 1 and stderr `deps-lookup-failed: local card #25`; an `acme/other#3` ref still goes through `gh issue view`.
  - `test-review-stages.sh`: `setup` on a local config with one stage exits 0 and makes no `gh` call.
  - `test-init.sh`: `--backend local --repo acme/toy` in a temp repo: exit 0, config has `backend: local`, `.fleet-board/next` is `1`, `.gitignore` has a `.fleet-board/` line (and running init twice leaves one line), `calls.log` has no `label create`; `--backend bogus` message names `local`.

- [ ] **Step 2: Run the four suites; expect the new cases to FAIL.**

- [ ] **Step 3: Implement.** Gate: extend the `case` at `:761` with `"human local"|"auto local"`, and `gate_item` returns 0 for `local` too. Deps: in `check_ref`, when the backend is `local` and `$repo` equals `FLEET_REPO` (case-insensitive), read the card file instead of `gh`. Review-stages `setup`: skip every `gh label create` on `local` (the stage labels are plain strings in card files). Init: accept `local` in the usage text and the case; in Step 6 add a `local` branch doing the store setup and `.gitignore` edit (append with `printf` after a `grep -qxF` check); `REQUIRED` stays `repo`. Init skill: a third bullet in Step 2, `**Local** (\`local\`): cards in \`.fleet-board/\` in this repo, served by the board page; no labels or project needed`, passing `--backend local`.

- [ ] **Step 4: Run the four suites; expect PASS. Run `tests/test-clean-room.sh`.**

- [ ] **Step 5: Commit**

```bash
git add hooks/gate.sh scripts/deps.sh scripts/review-stages.sh scripts/init.sh skills/init/SKILL.md tests/test-gate.sh tests/test-deps.sh tests/test-review-stages.sh tests/test-init.sh
git commit -m "feat(local): gate, deps, stage setup and init know the local backend"
```

---

### Task 6: Plan import on `local`: `import-plan.sh` and the skill's `--preview`

**Files:**
- Modify: `scripts/import-plan.sh:137-148`, `:216-250`
- Modify: `skills/import-plan/SKILL.md` (intro arguments paragraph, Steps 3 and 4)
- Test: `tests/test-import-plan.sh`

**Interfaces:**
- Consumes: `board-create.sh <title> <body-file> [--label L]... --state <backlog|ready>`.
- Produces: on `local`, `import-plan.sh <cards.json> [--status S]` creates each card through `board-create.sh` with the card's labels and `--state S`, prints `Created #<n>: <title>`, and records `REFS[key] = "<FLEET_REPO>#<n>"` so `## Depends on` bullets render as `owner/repo#n` (the same shape the GitHub backends produce and `deps.sh parse` reads). The skill accepts `--preview <file>`: Steps 1 to 3 run, then the cards file is written to `<file>`, the table printed, and the skill ends without asking to create.

- [ ] **Step 1: Add failing cases to `tests/test-import-plan.sh`**: a local config repo with an initialized store; a two-card fixture where card `b` consumes what `a` produces; `echo y | import-plan.sh cards.json --status ready` exits 0, prints `Created #1: A` and `Created #2: B`, `cards/2.json` body has `## Depends on` with `- acme/toy#1`, both cards are in state `ready`, and `calls.log` has no `gh issue create`.

- [ ] **Step 2: Run `bash tests/test-import-plan.sh`; expect FAIL** (`import-plan needs board.backend github-projects or github-labels`).

- [ ] **Step 3: Implement.** Add `local) ;;` to the backend case; in the create loop, branch on `local`: `OUT="$(bash "$FLEET_SCRIPTS/board-create.sh" "$title" "$BODY" "${largs[@]}" --state "$STATUS")"`, `num="$(jq -r .number <<<"$OUT")"`, print `Created #$num: $title`; the labels-only `ENSURED` block and the Projects block stay guarded as they are. In `SKILL.md`: document `--preview <file>` in the arguments paragraph; in Step 3, "With `--preview <file>`, copy the cards file to `<file>` after a clean dry run, print the table, and stop: do not run Step 4, do not ask"; keep Step 4 for the interactive case.

- [ ] **Step 4: Run `bash tests/test-import-plan.sh`; expect PASS. Run `tests/test-import-plan-skill-parse.sh` and `tests/test-clean-room.sh`.**

- [ ] **Step 5: Commit**

```bash
git add scripts/import-plan.sh skills/import-plan/SKILL.md tests/test-import-plan.sh
git commit -m "feat(local): import-plan creates local cards and the skill gains --preview"
```

---

### Task 7: `board-web.sh` and the board API

**Files:**
- Create: `scripts/board-web.sh`, `scripts/board-web.py`, `tests/test-board-web.sh`
- Test: `tests/test-board-web.sh`

**Interfaces:**
- Consumes: Task 2 and 3 scripts; `config.sh --dir <root> --check`; `config.sh --dir <root>` (whole merged JSON); `board-lib.sh` `fb_state_name` through a one-line bash call.
- Produces (`board-web.py`):
  - CLI `python3 board-web.py --root <abs repo root> --port <int> --scripts <abs scripts dir>`; `--port 0` binds an ephemeral port; first stdout line is `listening on http://127.0.0.1:<port>` (flushed).
  - Functions: `load_config(root, scripts) -> dict` (runs `config.sh`, cached by the config file's mtime); `states(cfg) -> list[dict(key, name)]` (one bash call sourcing `board-lib.sh`, `fb_load_config`, printing `key\tname` per state in `FB_STATES` order); `store_dir(root, cfg) -> Path`; `read_cards(dir) -> list[dict]`; `parse_note(card) -> dict|None` (the fenced JSON of the last marker comment); `run_script(root, argv, stdin=None) -> (rc, out, err)`; `json_error(handler, code, msg)`.
  - Routes: the spec's API table rows for `/api/board`, `/api/cards`, `/api/cards/<n>`, `/api/cards/<n>/move`, `/api/cards/<n>/comments`; `/` and `/cards/<n>` serve `index.html`; `/static/<file>` serves `board-web/static/`; anything else 404 JSON.
  - `/api/board` top level: `states`, `cards`, `run`, `repo` (`board.repo`, for PR links). Card fields: `number, title, state, labels, updated_at, active (bool), note: {round, pr, models, stage, action_failures} or null`.
  - CSRF: `POST`/`PATCH` need header `X-Fleet-Board: 1`; with an `Origin` header present it must equal `http://127.0.0.1:<port>` or `http://localhost:<port>`; else 403.
  - `board-web.sh [--repo DIR] [--port N]`: exit 2 on usage, config check exit codes pass through, exit 2 `board.backend is <x>; the board page needs local`, exit 1 `python3 is not on PATH`; `--port` defaults to `board.port`.

- [ ] **Step 1: Write `tests/test-board-web.sh`** with the shared helpers, `require_tool curl` and `require_tool python3` (print `skipped: python3 not on PATH` and exit 0 when missing, so CI without Python is loud but not red), a `setup_case` that builds a local-backend repo with three seeded cards (1 backlog with Acceptance, 2 in_progress with a manager note `{"round":1,"pr":41,"models":{"implementor":"sonnet"}}` and `active/2` present, 3 human_qa), starts the server in the background with `--port 0` and `FLEET_BOARD_LOG_DIR="$TMP/logs"`, reads the port from its first stdout line (poll the output file up to 5 s), and a `cleanup` that kills it. Helpers `api GET /api/board`, `api POST /api/cards '{"title":...}'` (curl with `-s -o body -w '%{http_code}'`, always sending `X-Fleet-Board: 1` unless `NOHDR=1`). Cases:

```bash
api GET /api/board;              assert_code 200; assert_body '.states[0].key' backlog; assert_body '.states|length' 8
assert_body '.cards|length' 3;   assert_body '.cards[]|select(.number==2)|.note.pr' 41
assert_body '.cards[]|select(.number==2)|.active' false      # no run alive, marker ignored
api GET /api/cards/2;            assert_code 200; assert_body '.comments|length' 1; assert_body '.manager_note|type' string
api GET /api/cards/999;          assert_code 404; assert_body '.error|type' string
NOHDR=1 api POST /api/cards '{"title":"t","body":"b"}';  assert_code 403
api POST /api/cards '{"title":"New","body":"## Acceptance\n- x","labels":["bug"]}'; assert_code 200; assert_body '.number' 4
api POST /api/cards/4/move '{"state":"ready"}';         assert_code 200
api POST /api/cards/3/move '{"state":"ready"}';         assert_code 409; assert_body '.error' '*Acceptance*'
api PATCH /api/cards/4 '{"title":"Renamed"}';           assert_code 200; api GET /api/cards/4; assert_body '.title' Renamed
api POST /api/cards/4/comments '{"body":"hi"}';         assert_code 200; api GET /api/cards/4; assert_body '.comments|length' 1
api POST /api/cards '{"title":"x"}';                    assert_code 400
api GET /;                                              assert_code 200   # index.html, even before Task 10 fills it
run_check "$SCRIPTS/board-web.sh" --repo "$LABELS_REPO";  assert_exit "labels repo refused" 2
PATH=/usr/bin:/bin run_check "$SCRIPTS/board-web.sh" --repo "$REPO" ... # with python3 shadowed by a stub dir: exit 1, stderr names python3
```

`assert_body <filter> <expected>` uses `jq -r` on the saved body; a glob pattern (`*Acceptance*`) matches with `case`. Review focus 4 is the 404 case.

- [ ] **Step 2: Run `bash tests/test-board-web.sh`; expect FAIL** (no server to start).

- [ ] **Step 3: Implement `board-web.sh` and `board-web.py` with the board routes only** (run routes return 501 for now). `PATCH` reads the current card, fills the missing fields, writes title and body to temp files, and runs `adapters/local/edit.sh`. Create with `state` runs `board-create.sh --state` when the state is `ready`, else creates then moves. Static serving uses `Path.resolve()` and refuses paths outside the static dir.

- [ ] **Step 4: Run the suite; expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/board-web.sh scripts/board-web.py tests/test-board-web.sh
git commit -m "feat(web): serve the local board over a localhost API"
```

---

### Task 8: Run control

**Files:**
- Create: `tests/fake-run.sh`
- Modify: `scripts/board-web.py`
- Test: `tests/test-board-web.sh`

**Interfaces:**
- Consumes: `FLEET_BOARD_RUN` (path of the wrapper, default `<scripts>/fleet-board-run.sh`), `FLEET_BOARD_LOG_DIR`.
- Produces: `state_dir(root, cfg) -> Path` = `<FLEET_BOARD_LOG_DIR or ~/.fleet-board>/web/<owner>-<name>/` (mode 700); files `run.pid`, `run.out`, `run.log` (path); `run_status() -> dict(state, pid, tick, stop_reason, cost, hours, log_path, log_tail: list[str])` with `state` in `idle|running|stopping|stopped`; `POST /api/run/start` → 200 `{pid}` or 409; `POST /api/run/stop` → 200 or 409; `GET /api/run` → the status dict.
- `tests/fake-run.sh`: prints `fleet-board-run: log /path/to/fake.log` as the wrapper does (copy the exact wording from `fleet-board-run.sh`'s start lines), appends `tick 1 ...` and `tick 2 ...` lines to that log one second apart, then polls for `<root>/.fleet-board.stop` every 0.2 s and, when it appears, prints `fleet-board-run: stopped: stop-file after 2 ticks, 0.01 h, cost_estimate_usd 0.42 (estimate)` and exits 0. It records its argv to `$FAKE_RUN_DIR/args.log`.

- [ ] **Step 1: Add failing cases**

```bash
api GET /api/run;                 assert_body '.state' idle
api POST /api/run/stop;           assert_code 409                         # review focus 5
api POST /api/run/start;          assert_code 200
grep -q -- "--repo $REPO" "$FAKE_RUN_DIR/args.log" && pass "wrapper got --repo root"
api GET /api/run;                 assert_body '.state' running
wait_for 'api GET /api/run; body_is .tick 2'                                # polls up to 5 s
api GET /api/board;               assert_body '.cards[]|select(.number==2)|.active' true   # marker counts now
api POST /api/run/start;          assert_code 409
api POST /api/run/stop;           assert_code 200; [ -e "$REPO/.fleet-board.stop" ] && pass "stop file written"
api GET /api/run;                 assert_body '.state' stopping
api POST /api/run/start;          assert_code 409                         # review focus 5
wait_for 'api GET /api/run; body_is .state stopped'
assert_body '.stop_reason' stop-file; assert_body '.cost' 0.42; assert_body '.log_tail|length' 2
[ ! -e "$REPO/.fleet-board/active/2" ] && pass "markers cleared when the run ended"
api POST /api/run/start;          assert_code 200; [ ! -e "$REPO/.fleet-board.stop" ] && pass "start removes the stale stop file"
```

- [ ] **Step 2: Run the suite; expect FAIL** (501s).

- [ ] **Step 3: Implement** `start_run`, `stop_run`, `run_status` as the spec's Run control section says: `subprocess.Popen([... 'bash', wrapper, '--repo', root], stdin=DEVNULL, stdout=run.out, stderr=STDOUT, start_new_session=True, cwd=root)`; liveness by `os.kill(pid, 0)` (treat `ProcessLookupError` as dead and `PermissionError` as alive); parse the log path from `run.out` on each status call until found; parse the last `fleet-board-run: stopped: <reason> after <n> ticks, <h> h, cost_estimate_usd <x>` line with one regex; parse the tick number from the last line matching `^tick (\d+)` in the run log; when the status flips alive→dead, delete every file in `active/`. `active` in `/api/board` is `marker exists and state in (running, stopping)`.

- [ ] **Step 4: Run the suite; expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add scripts/board-web.py tests/fake-run.sh tests/test-board-web.sh
git commit -m "feat(web): start and stop the headless run from the page"
```

---

### Task 9: Import API

**Files:**
- Modify: `scripts/board-web.py`
- Test: `tests/test-board-web.sh`

**Interfaces:**
- Consumes: `FLEET_BOARD_CLAUDE` (binary, default `claude`), `FLEET_BOARD_PLUGIN_DIR` (adds `--plugin-dir`), `headless.permission_mode`, `limits.max_turns` from the config; Task 6's `import-plan.sh` on `local`; `tests/fake-claude.sh` (`FAKE_CLAUDE_DIR`, `N.jsonl`, `N.touch`, `N.exit`).
- Produces: `start_import(plan_text, status) -> import_id` (`<YYYYmmdd-HHMMSS>-<4 hex>`; dir `<state dir>/imports/<id>/` with `plan.md`, `session.jsonl`, `cards.json` when done); `import_status(id) -> dict(state, elapsed_s, last_text, cards, table, error)` where `state` is `running` while the process lives, `ready` when `cards.json` exists and parses (then `table` is the stdout of `import-plan.sh cards.json --dry-run`), `failed` otherwise with `error` = last stderr or result text; `create_import(id, embed) -> dict(created: [..], output)` runs `import-plan.sh cards.json [--status ready]` with stdin `y\n` + (`e\n` if embed else `m\n`).

- [ ] **Step 1: Add failing cases** (with `FLEET_BOARD_CLAUDE=$TESTS/fake-claude.sh`, `FAKE_CLAUDE_DIR` fresh per case, `1.touch` listing the expected `cards.json` path, which the test learns from the `import_id` by predicting the dir: pass `FLEET_BOARD_TEST_IMPORT_ID=fixed` so the server uses that id in tests)

```bash
api POST /api/import '{"plan":"# Plan\n## Task 1: A\n","status":"ready"}';  assert_code 200; assert_body '.import_id' fixed
grep -q -- '/fleet-board:import-plan .*plan.md --preview .*cards.json --status ready' "$FAKE_CLAUDE_DIR/args.log" && pass "prompt names the skill, preview file and status"
grep -q -- '--permission-mode auto' "$FAKE_CLAUDE_DIR/args.log" && pass "permission mode from config"
wait_for 'api GET /api/import/fixed; body_is .state ready'
assert_body '.cards.cards|length' 2; assert_body '.table' '*| A |*'
api POST /api/import/fixed/create '{"embed_docs":true}';   assert_code 200; assert_body '.created|length' 2
api GET /api/board; assert_body '[.cards[]|select(.state=="ready")]|length' 2    # plus any from earlier cases, adjust
# failure path: fake-claude exits 1 without touching cards.json
api POST /api/import '{"plan":"x","status":"backlog"}'; wait_for 'api GET /api/import/fixed2; body_is .state failed'; assert_body '.error|type' string
api POST /api/import/fixed2/create '{}';  assert_code 409
api POST /api/import '{"status":"ready"}'; assert_code 400
```

`fake-claude.sh` can only touch files, not write JSON, so the suite writes its own `$TMP/fake-import-claude.sh`: it appends its argv to `$FAKE_CLAUDE_DIR/args.log`, finds the path after `--preview` in the prompt argument, copies the suite's two-card fixture there (unless `$FAKE_CLAUDE_DIR/fail` exists, in which case it prints an error to stderr and exits 1), and prints one `{"type":"result","result":"done"}` line. `FLEET_BOARD_CLAUDE` points at it for these cases.

- [ ] **Step 2: Run the suite; expect FAIL.**

- [ ] **Step 3: Implement** the three functions and routes; the session runs with `cwd=root`, `stdout` to `session.jsonl`, `stderr` to `session.err`; `last_text` is the `text` of the last `assistant` event with a text block in `session.jsonl`, read on each status call; `elapsed_s` from the dir's mtime. `FLEET_BOARD_TEST_IMPORT_ID` overrides the generated id (documented in the file header as tests-only).

- [ ] **Step 4: Run the suite; expect PASS. Prove it can fail once (make `create_import` skip the stdin answers, watch the create case fail, restore).**

- [ ] **Step 5: Commit**

```bash
git add scripts/board-web.py tests/test-board-web.sh
git commit -m "feat(web): import a plan through a headless import-plan session"
```

---

### Task 10: The page: board view, drag and drop, header

**Files:**
- Create: `scripts/board-web/static/index.html`, `board.css`, `board.js`
- Test: by hand in the browser (built-in browser against a seeded temp repo), screenshots attached to the PR

**Interfaces:**
- Consumes: Tasks 7 and 8 routes.
- Produces: `board.js` modules (plain functions, one file): `fetchBoard()`, `renderBoard(board)`, `renderCard(card)` (DOM calls only), `moveCard(n, state)`, `pollRun()`, `renderHeader(run)`, `showToast(msg)`, `md(text) -> DocumentFragment` (headings, paragraphs, lists, code fences, inline code, emphasis, links, HTML comments dropped). The index page has `<main id="board">`, `<header id="top">`, `<div id="toast">`, `<aside id="drawer" hidden>`, `<section id="import" hidden>`.

- [ ] **Step 1: Build the board view and header** to the mockups approved in conversation: columns from `board.states` in order, Done and Won't Do collapsed to counts with a toggle, cards with `#n`, title, labels as pills, `round r · PR #p` (PR linked to `https://github.com/<board.repo>/pull/<p>`; the server adds `repo` to `/api/board`), models, an accent border plus a pulsing dot when `active`; HTML5 drag and drop between columns calling `moveCard`, a `Move to` `<select>` on each card; header with the run pill (`idle`, `running · tick n`, `stopping`, `stopped: <reason>`), Start, Stop, cost and hours, a Log toggle showing `log_tail` in a `<pre>`, and `Import plan` and `New card` buttons. Poll `/api/board` every 3 s and `/api/run` every 3 s while alive, else every 15 s. A failed write shows the server's `error` in the toast and re-renders from the server (snap back).

- [ ] **Step 2: Verify by hand.** Start `board-web.sh` against a seeded temp repo (reuse `test-board-web.sh`'s `setup_case` with `KEEP=1` to leave the repo and server up), open the URL in the built-in browser, and check: eight columns in order; drag card 1 to Ready succeeds; drag card 3 (no Acceptance) to Ready shows the toast and snaps back; Start flips the pill to running and card 2 pulses; Stop flips to stopping then stopped with the reason. Save screenshots of the board, the toast and the running state under `docs/plans/screenshots/` and commit them as PR evidence, each under 300 KB.

- [ ] **Step 3: Run `bash tests/test-board-web.sh`** (the `GET /` case now serves the real page); expect PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/board-web/static docs/plans/screenshots
git commit -m "feat(web): the board page with drag and drop and run controls"
```

---

### Task 11: The page: card drawer

**Files:**
- Modify: `scripts/board-web/static/index.html`, `board.css`, `board.js`

**Interfaces:**
- Consumes: `GET /api/cards/<n>`, `PATCH /api/cards/<n>`, `POST /api/cards/<n>/move`, `POST /api/cards/<n>/comments`, `POST /api/cards`; `md()` from Task 10.
- Produces: `openDrawer(n | null)` (null = new card), `saveDrawer()`, `closeDrawer()`.

- [ ] **Step 1: Build the drawer** to the approved mockup: title input, state `<select>`, body `<textarea>` with a live `md()` preview beside it, labels as removable pills plus an input, PR link and note summary line, comments rendered with `md()` in order with author and time, the manager note comment collapsed under a toggle showing the pretty-printed JSON, a comment box, Save, Close. `New card` opens it empty and Save calls `POST /api/cards`. Clicking a card's body opens it; `Escape` closes it. Keyboard: cards are focusable, `Enter` opens.

- [ ] **Step 2: Verify by hand**: open card 2, see the note collapsed and the report rendered; edit the title and Save, see the column update; add a comment, see it appear; create a new card with an Acceptance section and move it to Ready from the drawer. Screenshot the drawer.

- [ ] **Step 3: Commit**

```bash
git add scripts/board-web/static docs/plans/screenshots
git commit -m "feat(web): card drawer with editing, comments and the note"
```

---

### Task 12: The page: import view and the paper-to-cards animation

**Files:**
- Modify: `scripts/board-web/static/index.html`, `board.css`, `board.js`

**Interfaces:**
- Consumes: Task 9 routes.
- Produces: `openImport()`, `startImport()`, `pollImport(id)`, `playSplit(cards)` (returns a Promise that resolves when the animation ends), `createImport(id)`.

- [ ] **Step 1: Build the import view**: a `<textarea>` that also accepts a dropped `.md` file (read with `FileReader`), Backlog/Ready `<select>`, `Group with Claude`; while running, elapsed seconds and `last_text`; on `ready`, `playSplit`: the paper element (the plan text in a monospace sheet) scales down and rotates slightly, N card elements are cloned from it stacked at the same position, then each translates into its slot in the preview row with a 60 ms stagger, using CSS transitions only (`prefers-reduced-motion` skips to the end state). The preview row shows title, acceptance count, labels and `depends on` (from `cards.json`'s `depends_on`, `consumes` and `produces`, resolved client-side by matching names). Then the `embed referenced doc sections` checkbox (default on), `Discard`, `Create N cards`; after create, the board view returns with a toast listing the created numbers. On `failed`, the error text and nothing else.

- [ ] **Step 2: Verify by hand** with `FLEET_BOARD_CLAUDE` pointing at the suite's fake import script: paste a plan, watch the split, create, see the cards in Backlog. Record a short screen capture or three screenshots (before, mid, after).

- [ ] **Step 3: Commit**

```bash
git add scripts/board-web/static docs/plans/screenshots
git commit -m "feat(web): import a plan and watch it split into cards"
```

---

### Task 13: Docs, contracts, design note and version

**Files:**
- Modify: `README.md` (`## Config` table rows for `board.backend`, `board.dir`, `board.port`; a `## Local board` section after `## Running overnight`: init with Local, launch `board-web.sh` from the wrapper's directory, Start/Stop, import; `## Known issues` bullet for the role prompts' `gh issue view` example; `## Install` prerequisites mention `python3` for the page only)
- Modify: `docs/config.md` (a `## board.dir and board.port` section), `docs/overnight.md` (a paragraph: Start and Stop from the page write the same stop file), `docs/gates.md` (`## Limits` gets the raw-store-write residual bullet)
- Modify: `plugins/fleet-board/CLAUDE.md` (backends line lists `local`; a bullet for the active marker contract; the `fb_login` identity note; `Last verified` date)
- Modify: `docs/design.md` (a section `## A local board instead of GitHub issues`: the rate-limit reason, what is given up (card as durable shared state, the login trust boundary), the alternative considered (caching the GitHub board), and why the adapter seam made it cheap)
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` → `0.13.0`
- Test: `tests/test-version.sh`, `tests/test-readme-claims.sh`, `tests/test-clean-room.sh`

- [ ] **Step 1: Write the docs and bump the version.** Keep README rows in the existing table format; the `## Local board` section is under 40 lines; the design section under 300 words.

- [ ] **Step 2: Run** `bash tests/test-version.sh`, `bash tests/test-readme-claims.sh`, `bash tests/test-clean-room.sh`; expect PASS.

- [ ] **Step 3: Run the full set of suites this plan touched once each** (`test-config`, `test-board-local`, `test-worktree`, `test-stage-review`, `test-gate`, `test-deps`, `test-review-stages`, `test-init`, `test-import-plan`, `test-board-web`); expect PASS.

- [ ] **Step 4: Commit and push; mark the PR ready for review**

```bash
git add README.md docs plugins/fleet-board/docs plugins/fleet-board/CLAUDE.md .claude-plugin/marketplace.json plugins/fleet-board/.claude-plugin/plugin.json
git commit -m "docs: local board, active markers, design note; version 0.13.0"
git push
```

---

## Self-review notes

- Spec coverage: store (T2), adapter verbs (T2, T3), identity (T1), active markers (T4), launcher and server (T7), run control (T8), import (T6, T9, T12), page views (T10, T11, T12), changes elsewhere (T1, T5, T6, T13), residuals and known limitations (T13), error handling (T2, T3, T7, T8, T9), testing (every task). No spec section is without a task.
- Names used across tasks: `fl_*` helpers (T2 → T3, T4, T5), `edit.sh <n> <title-file> <body-file> <labels-json>` (T3 → T7), `active/<n>` (T4 → T8), `--state` on `board-create.sh` (existing → T6, T7), `FLEET_BOARD_RUN` (T8 → fake-run), `FLEET_BOARD_TEST_IMPORT_ID` (T9 only).
- The clean-room status skill prints the wrapper path last; this plan adds no line after it and changes no clean-room file.
