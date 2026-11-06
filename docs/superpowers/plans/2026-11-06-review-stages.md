# Review Stages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extra review columns on the fleet-board, each with its own reviewer agent and model, routed per card by path globs and labels, with a per-column fix loop or advisory mode.

**Architecture:** `review.stages` in the config becomes a list of canonical states `review_<name>` inserted after `in_review`; the state list is derived from the config at load time so adapters, init, settle, status and the gate see the columns. A routing script applies stage labels at the start of review and picks the next stage from them. `tick-plan.sh` treats every stage column as an In Review variant with two new actions (`advance_stage`, `review_stage`); the clean-room manager and reporting skill learn the actions and a lighter `stage-reviewer` report role.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), jq, `gh`, plain-bash test suites with `fake-gh.sh`; clean-room re-authoring via `claude -p --bare`.

**Spec:** `docs/superpowers/specs/2026-11-06-review-stages-design.md`

## Global Constraints

- Scripts run under `/bin/bash` 3.2 with BSD and GNU tools: no bash 4 features, `sed -i.bak` only, `unset CDPATH` before a captured `cd`, `LC_ALL=C awk` for decimals.
- Never hand-edit `agents/*.md` or `skills/{reporting,tick,run,status}/SKILL.md`; change the spec and brief, then re-author in isolation (Task 10).
- Stage name: `^[a-z][a-z0-9_]*$`, unique. Agent: `^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$`. Canonical state: `review_<name>`. Default label: `needs-<name>-review`. Default board names: labels `fleet:review_<name>`, Projects `Review: <name>`.
- Stage defaults: `model` = `models.reviewer`, `paths` = `[]`, `advisory` = `false`, `max_rounds` = `review.max_rounds`, `brief` = `null`.
- New note fields: `stage` (null or a stage name), `reviewed_stages` (list of stage names, default `[]`); `last_review.stage`; `blocked_from` also accepts `review_<name>`.
- New plan actions: `advance_stage` (no agent; settle keeps it), `review_stage` (agent; settle turns it into `skip`, reason `review_stage waits for the next tick`).
- Report role `stage-reviewer`: Status `clean|findings`, Findings, For the card, one VERIFIED line; no Acceptance map, Mutation or Claim check.
- Git: feature branch, draft PR first, test committed before implementation, run only the suite you touched, push after each task. `bash plugins/fleet-board/tests/test-clean-room.sh` after any change under the plugin.
- Plugin version `0.10.0` → `0.11.0` in both `plugins/fleet-board/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (Task 11).
- Deviation from the spec, decided here: the `start_review` plan card carries no `route` list. The manager and settle run `review-stages.sh route` and take the list from its stdout. Stage labels are created by `review-stages.sh setup`, not `init.sh`, because `init.sh` refuses to run on an existing config and stages are added to one.

## Review Focus

1. A stage named in `board.states` after it was removed from `review.stages` must be rejected at config load, not silently ignored (Task 1 test `board.states key review_x names no stage`).
2. A card still labelled with a stage state that was removed from `review.stages` has no canonical state; `tick-plan.sh --settle <n>` must plan `skip` for it and exit 0, never crash (Task 5 `stage-not-configured`).
3. A stage label added by hand for a stage already in `reviewed_stages` must not send the card back (Task 2 `next` test, Task 5 `stage-skip-done`).
4. `review-stages.sh route` on a PR with more changed files than `gh` lists must add every stage label and warn, so a large PR never skips a review by accident (Task 2).
5. The labels adapter `move` must strip a stage state label when moving to any other state, so a card never carries two state labels (Task 1 `test-board-labels.sh`).

---

### Task 0: Branch and draft PR

**Files:** none changed.

- [ ] **Step 1: Confirm the branch and open the draft PR**

Run from the repo root:
```bash
git switch -c fleet/review-stages 2>/dev/null || git switch fleet/review-stages
git push -u origin HEAD
gh pr create --draft --title "Review stages: per-column reviewer agents and models" --body "Implements docs/superpowers/specs/2026-11-06-review-stages-design.md. Plan: docs/superpowers/plans/2026-11-06-review-stages.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
Expected: a draft PR URL. (If this session already sits on a feature branch with the spec committed, keep that branch and only push and create the PR.)

---

### Task 1: Config `review.stages` and config-derived states

**Files:**
- Modify: `plugins/fleet-board/scripts/config-defaults.json` (add `"stages": []` under `review`)
- Modify: `plugins/fleet-board/scripts/config.sh` (defaults fill-in after the merge; validation errors)
- Modify: `plugins/fleet-board/scripts/board-lib.sh:8` (`FB_STATES`), `fb_load_config`, `fb_default_name`
- Create: `plugins/fleet-board/fixtures/config/stages.yml`
- Test: `plugins/fleet-board/tests/test-config.sh`, `plugins/fleet-board/tests/test-board-labels.sh`

**Interfaces:**
- Produces: `config.sh` stdout `.review.stages[]` = `{name, agent, model, paths, label, advisory, max_rounds, brief}` with every default filled.
- Produces in `board-lib.sh`: `FB_STATES_FIXED` (the old constant); `fb_set_states` (reads `$FLEET_CFG`, sets `FB_STATES` to the fixed list with `review_<name>` for each stage inserted after `in_review`, in config order); `fb_load_config` calls it; `fb_stage_states` prints the stage states one per line; `fb_stage_of_state <review_x>` prints that stage's JSON object or nothing; `fb_default_name review_<name>` → `fleet:review_<name>` (labels) or `Review: <name>` (Projects).

- [ ] **Step 1: Write the failing config tests**

Append to `test-config.sh`, using its `make_inline_repo`, `run_config`, `assert_key`, `invalid_field_case` helpers:

```bash
# review.stages: defaults fill in
REPO="$(printf 'board:\n  repo: a/b\nmodels: { reviewer: opus }\nreview: { max_rounds: 4, stages: [ { name: security, agent: "acme:sec" } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: minimal stage is valid" 0
assert_eq "stages: defaults filled" "$(jq -c '.review.stages[0]' <<<"$LAST_OUT")" \
  '{"name":"security","agent":"acme:sec","model":"opus","paths":[],"label":"needs-security-review","advisory":false,"max_rounds":4,"brief":null}'
# explicit values kept
REPO="$(printf 'board:\n  repo: a/b\nreview: { stages: [ { name: ux, agent: ux-reviewer, model: sonnet, paths: ["src/ui/**"], label: ux-pls, advisory: true, max_rounds: 1, brief: "Check copy." } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_eq "stages: explicit values kept" "$(jq -c '.review.stages[0]' <<<"$LAST_OUT")" \
  '{"name":"ux","agent":"ux-reviewer","model":"sonnet","paths":["src/ui/**"],"label":"ux-pls","advisory":true,"max_rounds":1,"brief":"Check copy."}'
assert_eq "stages: empty by default" "$(jq -c '.review.stages' <<<"$(run_config "$(printf 'board:\n  repo: a/b\n' | make_inline_repo)"; printf '%s' "$LAST_OUT")")" '[]'
invalid_field_case "stages not a list" 'review: { stages: 3 }' "review.stages must be a list"
invalid_field_case "stage bad name" 'review: { stages: [ { name: "Sec-1", agent: a } ] }' "review.stages[0].name must match ^[a-z][a-z0-9_]*$"
invalid_field_case "stage duplicate name" 'review: { stages: [ { name: s, agent: a }, { name: s, agent: b } ] }' "review.stages[1].name s is not unique"
invalid_field_case "stage missing agent" 'review: { stages: [ { name: s } ] }' "review.stages[0].agent must match ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$"
invalid_field_case "stage bad agent" 'review: { stages: [ { name: s, agent: "a b" } ] }' "review.stages[0].agent must match ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$"
invalid_field_case "stage empty model" 'review: { stages: [ { name: s, agent: a, model: "" } ] }' "review.stages[0].model must be a non-empty string"
invalid_field_case "stage paths" 'review: { stages: [ { name: s, agent: a, paths: [""] } ] }' "review.stages[0].paths must be a list of non-empty strings"
invalid_field_case "stage label reserved" 'review: { stages: [ { name: s, agent: a, label: needs-human-qa } ] }' "review.stages[0].label must be a non-empty string"
invalid_field_case "stage label duplicate" 'review: { stages: [ { name: s, agent: a, label: x }, { name: t, agent: a, label: x } ] }' "review.stages[1].label must be a non-empty string"
invalid_field_case "stage advisory" 'review: { stages: [ { name: s, agent: a, advisory: yes_please } ] }' "review.stages[0].advisory must be boolean"
invalid_field_case "stage max_rounds" 'review: { stages: [ { name: s, agent: a, max_rounds: 0 } ] }' "review.stages[0].max_rounds must be a positive integer"
invalid_field_case "stage brief" 'review: { stages: [ { name: s, agent: a, brief: 7 } ] }' "review.stages[0].brief must be a string"
invalid_field_case "board.states names no stage" 'board: { states: { review_x: "X Review" } }' "board.states key review_x names no stage"
REPO="$(printf 'board:\n  repo: a/b\n  states: { review_security: "Sec" }\nreview: { stages: [ { name: security, agent: a } ] }\n' | make_inline_repo)"
CLEANUP_DIRS+=("$REPO"); run_config "$REPO"
assert_exit "stages: board.states may map a stage" 0
```
(Where `invalid_field_case` appends YAML to a `board: {repo: a/b}` base; keep the label-reserved and label-duplicate messages exactly as above, matching the spec's single label message.)

- [ ] **Step 2: Run the suite to see the new cases fail**

Run: `bash plugins/fleet-board/tests/test-config.sh`
Expected: the new cases FAIL (defaults not filled, validation messages missing); existing cases pass.

- [ ] **Step 3: Commit the failing tests**

```bash
git add plugins/fleet-board/tests/test-config.sh
git commit -m "test(config): review.stages parsing, defaults and validation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 4: Implement in `config.sh` and `config-defaults.json`**

Add `"stages": []` to the defaults. After `MERGED` is built, fill stage defaults with one jq pass (a stage that is not an object is left as is so validation can name it). Add validation entries producing the exact messages above; the `board.states` key regex becomes `^(backlog|ready|in_progress|in_review|human_qa|blocked|done|wont_do)$` **or** `^review_` with a stage of that name, else `board.states key <key> names no stage` for `review_*` keys and the existing `is not canonical` for others.

- [ ] **Step 5: Write the failing board-lib tests**

Append to `test-board-labels.sh` (it already drives `board-move.sh` through `fake-gh`): with a config holding `review: { stages: [{name: security, agent: a}] }`, (a) `board-move.sh 12 review_security` on a card labelled `fleet:in_review` adds `fleet:review_security` and removes `fleet:in_review`; (b) `board-move.sh 12 human_qa` on a card labelled `fleet:review_security` removes `fleet:review_security`; (c) with `board.states: { review_security: "Sec Review" }` the added label is `Sec Review`. Assert through the fake's `calls.log` as the suite's existing move tests do.

- [ ] **Step 6: Run `test-board-labels.sh`, expect the three new cases to fail; commit the tests**

```bash
git add plugins/fleet-board/tests/test-board-labels.sh
git commit -m "test(board-labels): stage states move like any state

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 7: Implement in `board-lib.sh`**

Rename the constant to `FB_STATES_FIXED` and keep `FB_STATES="$FB_STATES_FIXED"` at load. Add `fb_set_states` (jq over `$FLEET_CFG`: `[.review.stages[].name | "review_" + .] | join(" ")` spliced after `in_review`), call it at the end of `fb_load_config`, and add `fb_stage_states` and `fb_stage_of_state`. Extend `fb_default_name` with a `review_*)` arm before the backend switch. Add the `stages.yml` fixture (a full config with two stages, `security` with paths and `ux` advisory) for later suites.

- [ ] **Step 8: Run both suites**

Run: `bash plugins/fleet-board/tests/test-config.sh && bash plugins/fleet-board/tests/test-board-labels.sh && bash plugins/fleet-board/tests/test-clean-room.sh`
Expected: all pass.

- [ ] **Step 9: Commit and push**

```bash
git add plugins/fleet-board/scripts/config.sh plugins/fleet-board/scripts/config-defaults.json plugins/fleet-board/scripts/board-lib.sh plugins/fleet-board/fixtures/config/stages.yml
git commit -m "Config: review.stages with config-derived canonical states

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 2: `review-stages.sh` (route, next, setup) and the shared glob matcher

**Files:**
- Create: `plugins/fleet-board/scripts/review-stages.sh` (mode 100755)
- Modify: `plugins/fleet-board/scripts/board-lib.sh` (add `fb_glob_match`), `plugins/fleet-board/scripts/needs-human-qa.sh` (use it; delete its local `matches`)
- Create: `plugins/fleet-board/tests/test-review-stages.sh`, fixtures under `plugins/fleet-board/fixtures/gh/stages/`
- Test: also `plugins/fleet-board/tests/test-needs-human-qa.sh` (unchanged, must still pass)

**Interfaces:**
- Consumes: Task 1's `fb_stage_states`, `.review.stages`.
- Produces: `fb_glob_match <path> <pattern>` (exit 0 on match; the `**`→`*` and optional leading `**/` rule from `needs-human-qa.sh`).
- Produces: `review-stages.sh route <n> <pr>` → stdout a JSON list of the stage names whose label the card carries after the call; adds missing labels with `gh issue edit <n> --repo R --add-label <label>`, one call per label; never removes. Exit 1 when the card or the PR files cannot be read; exit 2 on usage. With no stages: prints `[]`, makes no `gh` call. Truncated file list: adds every stage's label and prints `fleet-board: warning: PR #<pr> changes more files than gh listed; routing it to every review stage` on stderr.
- Produces: `review-stages.sh next [--labels <json>] [--after <state>] [--done <json>] <n>` → stdout the next stage name or nothing; `--after` defaults to `in_review`; `--done` defaults to `[]`; a stage counts only when its label is on the card, it comes after `--after` in config order, and its name is not in `--done`. Exit 2 on a bad `--after` (not `in_review` or a configured `review_<name>`) or a malformed JSON argument.
- Produces: `review-stages.sh setup` → creates each stage's routing label (`--force`, colour `d93f0b`, description `fleet-board: route to review stage <name>`) on both backends, and on `github-labels` each stage's state label (colour `5319e7`, description `fleet-board state: review_<name>`); on `github-projects` reads the Status options as `init.sh` does and exits 1 naming the missing columns: `project <N> Status field lacks option(s): <names>; add it in the project's Status field or map it in board.states`. Exit 1 on a failed `gh` call.

- [ ] **Step 1: Write the failing suite**

Create `test-review-stages.sh` by copying the harness of `test-needs-human-qa.sh` (setup_case with a fake `gh`, routes file per case under `fixtures/gh/stages/<case>/routes`). Config for every case: Task 1's two stages (`security` paths `["src/auth/**"]`, `ux` paths `["src/ui/**"]` advisory). Cases and assertions:

```bash
# route
run_stages route 12 34   # files: src/auth/login.js
assert_exit "route: exit 0" 0
assert_stdout_exact "route: prints the routed names" '["security"]'
assert_eq "route: adds the security label" "$(cnt 'issue edit 12 --repo acme/toy --add-label needs-security-review')" 1
assert_eq "route: does not add ux" "$(cnt 'issue edit 12 --repo acme/toy --add-label needs-ux-review')" 0
run_stages route 12 34   # card already labelled needs-security-review, same files
assert_eq "route: idempotent, no edit" "$(cnt 'issue edit 12 --repo acme/toy --add-label needs-security-review')" 0
run_stages route 12 35   # changedFiles 400 > files listed
assert_stdout_exact "route: truncated list routes everywhere" '["security","ux"]'
assert_stderr_contains "route: truncated warning" "changes more files than gh listed; routing it to every review stage"
run_stages route 12 36   # pr view fails
assert_exit "route: files unreadable -> exit 1" 1
# no stages configured
run_stages route 12 34   # with a config without stages
assert_stdout_exact "route: no stages prints []" '[]'
assert_eq "route: no stages, no gh edit" "$(cnt_prefix 'issue edit')" 0
# next
run_stages next --labels '["needs-security-review","needs-ux-review"]' 12
assert_stdout_exact "next: after in_review by default" 'security'
run_stages next --labels '["needs-security-review","needs-ux-review"]' --after review_security 12
assert_stdout_exact "next: after a stage" 'ux'
run_stages next --labels '["needs-ux-review"]' --done '["ux"]' 12
assert_stdout_exact "next: a done stage is skipped" ''
run_stages next --labels '["needs-security-review"]' --after review_ux 12
assert_stdout_exact "next: nothing after the last stage" ''
run_stages next --labels '[]' 12
assert_stdout_exact "next: no label, nothing" ''
run_stages next 12           # labels read from the card (fixture card has needs-ux-review)
assert_stdout_exact "next: reads the card when --labels is absent" 'ux'
run_stages next --after review_nope 12
assert_exit "next: unknown --after -> exit 2" 2
# setup (labels backend)
run_stages setup
assert_eq "setup: routing label" "$(cnt 'label create needs-security-review --repo acme/toy --color d93f0b --description fleet-board: route to review stage security --force')" 1
assert_eq "setup: state label" "$(cnt 'label create fleet:review_security --repo acme/toy --color 5319e7 --description fleet-board state: review_security --force')" 1
# setup (projects backend) with Status options lacking "Review: ux"
assert_exit "setup projects: missing option exits 1" 1
assert_stderr_contains "setup projects: names the column" "Status field lacks option(s): Review: ux"
```
Add a `cnt`/`cnt_prefix` helper that counts exact argv matches in `$FAKE_GH_DIR/argv/*` (copy `call_count` from `test-tick-plan.sh`).

- [ ] **Step 2: Run it, expect every case to fail (script missing)**

Run: `bash plugins/fleet-board/tests/test-review-stages.sh`

- [ ] **Step 3: Commit the suite and fixtures**

```bash
git add plugins/fleet-board/tests/test-review-stages.sh plugins/fleet-board/fixtures/gh/stages
git commit -m "test(review-stages): route, next and setup

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 4: Implement `fb_glob_match` in `board-lib.sh`, switch `needs-human-qa.sh` to it, write `review-stages.sh`**

`route` reads the card with `board-read.sh`, the files with `gh pr view <pr> --repo R --json files,changedFiles` (the same query and truncation test as `needs-human-qa.sh`). `next` loops `fb_stage_states` in order. `setup` reuses the `gh label create` form of `init.sh`.

- [ ] **Step 5: Run the three suites**

Run: `bash plugins/fleet-board/tests/test-review-stages.sh && bash plugins/fleet-board/tests/test-needs-human-qa.sh && bash plugins/fleet-board/tests/test-clean-room.sh`
Expected: all pass (clean-room check 5 needs the new script executable in the index: `git add --chmod=+x`).

- [ ] **Step 6: Commit and push**

```bash
git add --chmod=+x plugins/fleet-board/scripts/review-stages.sh
git add plugins/fleet-board/scripts/board-lib.sh plugins/fleet-board/scripts/needs-human-qa.sh
git commit -m "review-stages.sh: route by globs and labels, pick the next stage, set up labels

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 3: Note fields `stage`, `reviewed_stages`, stage `blocked_from`

**Files:**
- Modify: `plugins/fleet-board/scripts/note.sh:118-160` (DEFAULTS, `invalid_field`)
- Modify: `plugins/fleet-board/scripts/accept.sh:60,75` (BACK accepts `review_*`)
- Test: `plugins/fleet-board/tests/test-note.sh`, `plugins/fleet-board/tests/test-accept.sh`

**Interfaces:**
- Produces: `note.sh get` returns `stage` (null|string), `reviewed_stages` (array) with defaults `null` and `[]`; rejects (`{}` + warning naming the field) `stage` not matching `^[a-z][a-z0-9_]*$`, `reviewed_stages` not a list of such strings, `blocked_from` not in `ready|in_progress|in_review|review_<name>`.
- Produces: `accept.sh` returns a card to `blocked_from` when it is `review_<name>`; a round-0 card with `blocked_from: review_x` goes to `in_progress`, as for `in_review`.

- [ ] **Step 1: Write the failing note tests** (append, using `set_note_json`, `run_note get`, `assert_eq`, `assert_stdout_exact`):

```bash
set_note_json '{"state":"review_security","stage":"security","reviewed_stages":["ux"]}'
run_note get 12
assert_eq "stage: kept" "$(jq -c .stage <<<"$LAST_OUT")" '"security"'
assert_eq "reviewed_stages: kept" "$(jq -c .reviewed_stages <<<"$LAST_OUT")" '["ux"]'
set_note_json '{"state":"in_review"}'
run_note get 12
assert_eq "stage: defaults null" "$(jq -c .stage <<<"$LAST_OUT")" 'null'
assert_eq "reviewed_stages: defaults []" "$(jq -c .reviewed_stages <<<"$LAST_OUT")" '[]'
set_note_json '{"stage":"Sec"}';            run_note get 12; assert_stdout_exact "stage: bad name rejected" "{}"
assert_stderr_contains "stage: names the field" "ignoring invalid manager note on #12: stage"
set_note_json '{"reviewed_stages":"ux"}';   run_note get 12; assert_stdout_exact "reviewed_stages: not a list rejected" "{}"
set_note_json '{"blocked_from":"review_security"}'; run_note get 12
assert_eq "blocked_from: a stage state is accepted" "$(jq -c .blocked_from <<<"$LAST_OUT")" '"review_security"'
set_note_json '{"blocked_from":"review_"}'; run_note get 12; assert_stdout_exact "blocked_from: review_ alone rejected" "{}"
```
And in `test-accept.sh`, next to its existing `blocked_from` cases: a note `{"state":"blocked","blocked_from":"review_security","round":1,"pr":34,...}` makes `accept.sh 12` call `board-move.sh 12 review_security`; with `round: 0` it calls `board-move.sh 12 in_progress`.

- [ ] **Step 2: Run both suites, expect the new cases to fail; commit the tests**

```bash
git add plugins/fleet-board/tests/test-note.sh plugins/fleet-board/tests/test-accept.sh
git commit -m "test(note, accept): stage, reviewed_stages and stage blocked_from

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 3: Implement** the DEFAULTS and `invalid_field` arms in `note.sh` (place the `stage` and `reviewed_stages` checks after `round`), and the `case "$BACK"` in `accept.sh` (`review_*` joins the accepted list; line 75's round-0 rule applies to `in_review` and `review_*`).

- [ ] **Step 4: Run, expect pass, commit and push**

Run: `bash plugins/fleet-board/tests/test-note.sh && bash plugins/fleet-board/tests/test-accept.sh`
```bash
git add plugins/fleet-board/scripts/note.sh plugins/fleet-board/scripts/accept.sh
git commit -m "Note: stage, reviewed_stages; accept returns a card to its stage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 4: `parse-report.sh --role stage-reviewer`

**Files:**
- Modify: `plugins/fleet-board/scripts/parse-report.sh:40,69-72,369-373,414-418,437-441`
- Create: `plugins/fleet-board/fixtures/reports/stage-reviewer-ok.md`, `stage-reviewer-findings.md`, `stage-reviewer-clean-with-critical.md`, `stage-reviewer-done.md`
- Test: `plugins/fleet-board/tests/test-parse-report.sh`

**Interfaces:**
- Produces: `--role stage-reviewer` accepted; Status `clean|findings`; `clean` with a Critical or Important finding → `status clean needs zero Critical and Important findings, found <n>`; `findings` with none → `status findings needs at least one Critical or Important finding`; `done`/`blocked` → `role stage-reviewer does not allow status: <word>`; no required role sections; the usage line reads `usage: parse-report.sh [--role implementor|reviewer|fixer|stage-reviewer] <file>`.

- [ ] **Step 1: Write the fixtures and failing tests** (append to `test-parse-report.sh` with `run_parse`, `assert_exit`, `assert_stderr_line`, `assert_jq`):

`stage-reviewer-ok.md`: `## Status` `clean`, `## Findings` `- [Minor] prefer const`, `## For the card` one line, `` VERIFIED: `npm audit --json` -> 0 vulnerabilities ``. `stage-reviewer-findings.md`: Status `findings`, one `- [Important] token logged in plain text`. `stage-reviewer-clean-with-critical.md`: Status `clean` with a `[Critical]` line. `stage-reviewer-done.md`: Status `done`.

```bash
run_parse --role stage-reviewer "$REPORTS/stage-reviewer-ok.md"
assert_exit "stage-reviewer-ok: exit 0" 0
assert_jq "stage-reviewer-ok: acceptance_map null" '.acceptance_map' 'null'
run_parse --role stage-reviewer "$REPORTS/stage-reviewer-findings.md"
assert_exit "stage-reviewer-findings: exit 0" 0
assert_jq "stage-reviewer-findings: counts" '.counts.important' '1'
run_parse --role stage-reviewer "$REPORTS/stage-reviewer-clean-with-critical.md"
assert_exit "stage-reviewer clean+critical: exit 1" 1
assert_stderr_line "stage-reviewer clean+critical: message" "parse-report: status clean needs zero Critical and Important findings, found 1"
run_parse --role stage-reviewer "$REPORTS/stage-reviewer-done.md"
assert_stderr_line "stage-reviewer done: not allowed" "parse-report: role stage-reviewer does not allow status: done"
run_parse --role stage-reviewer "$REPORTS/reviewer-missing-mutation.md"
assert_exit "stage-reviewer: a full reviewer report without Mutation passes" 0
run_parse --role nope "$REPORTS/stage-reviewer-ok.md"
assert_stderr_line "usage names the role" "parse-report: usage: parse-report.sh [--role implementor|reviewer|fixer|stage-reviewer] <file>"
```

- [ ] **Step 2: Run, expect the new cases to fail; commit**

```bash
git add plugins/fleet-board/tests/test-parse-report.sh plugins/fleet-board/fixtures/reports/stage-reviewer-*.md
git commit -m "test(parse-report): the stage-reviewer role

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 3: Implement**: add the role to the `case "$ROLE"` list and USAGE; in the awk END block apply the clean/findings consistency check when `role == "reviewer" || role == "stage-reviewer"` (the Acceptance map entry check stays reviewer-only); add `stage-reviewer:done|stage-reviewer:blocked` to the disallowed status case; `REQUIRED=""` for the role.

- [ ] **Step 4: Run, expect pass, commit and push**

Run: `bash plugins/fleet-board/tests/test-parse-report.sh`
```bash
git add plugins/fleet-board/scripts/parse-report.sh
git commit -m "parse-report: stage-reviewer role with no evidence sections

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 5: `tick-plan.sh` stage columns, `advance_stage` and `review_stage`

**Files:**
- Modify: `plugins/fleet-board/scripts/tick-plan.sh` (header comment, column list at :289, the per-card gather function around :94-275, the jq table)
- Create: fixtures `plugins/fleet-board/fixtures/gh/tick/stage-*/` (routes, issue, comments, list JSON) and `fixtures/gh/tick/common/issue-12-review_security.json`, `list-review_security-12.json`
- Test: `plugins/fleet-board/tests/test-tick-plan.sh`

**Interfaces:**
- Consumes: Task 1 `fb_stage_states`, `fb_stage_of_state`; Task 2 `review-stages.sh next`; Task 3 note fields.
- Produces plan card fields: `stage` = for `advance_stage` the stage being entered, for a card in a stage column that column's stage object `{name, agent, model, advisory, brief, max_rounds}`, else `null`. Actions `advance_stage` (reason `review clean; next stage <name>`), `review_stage` (reasons as `review`'s, with `round <r> of <stage> not reviewed yet` for the fresh case), `fix` and `block` in a stage column (block reason `<ci> Critical/Important findings survive round <r> of <max> in <stage>`). A card whose label names a removed stage reads with no canonical state and gets the table's existing `skip` (`state <state> is not planned`).
- Lookups: for `in_review` and every stage column, when the review is clean and current, `review-stages.sh next --labels <labels> --after <state> --done <reviewed_stages> <n>` runs first; `needs-human-qa.sh` runs only when it prints nothing. A failed `next` is `lookup failed: review-stages.sh next <n>`.
- Settle mode: `advance_stage` kept; `review_stage` → `skip`, reason `review_stage waits for the next tick`.

- [ ] **Step 1: Write the failing cases** (append to `test-tick-plan.sh`; each `setup_case <name> "<stages yaml>"` passes Task 1's two stages as the extra YAML, `security` with `max_rounds: 2`, `ux` advisory; routes files list `fleet:review_security` and `fleet:review_ux` columns as the existing ones list `fleet:in_review`):

```bash
# in_review, clean current review, label needs-security-review -> advance_stage
plan stage-advance-from-review
assert_jq "stage-advance: action" "$(card 12 action)" '"advance_stage"'
assert_jq "stage-advance: entering security" "$(card 12 stage.name)" '"security"'
assert_jq "stage-advance: agent carried" "$(card 12 stage.agent)" '"acme:sec"'
assert_eq "stage-advance: no files lookup" "$(call_count pr view 34 --repo acme/toy --json files,changedFiles)" 0
assert_jq "stage-advance: dispatchable" '.dispatchable' 'true'
# the security column is listed
assert_eq "stage columns listed" "$(grep -c 'issue list --repo acme/toy --label fleet:review_security' "$FAKE_GH_DIR/calls.log")" 1
# in review_security, note stage security round 1, no last_review -> review_stage
plan stage-review-needed
assert_jq "stage-review: action" "$(card 12 action)" '"review_stage"'
assert_jq "stage-review: reason" "$(card 12 reason)" '"round 1 of security not reviewed yet"'
assert_jq "stage-review: model" "$(card 12 stage.model)" '"opus"'
# last_review from in_review (stage null, round 1) does not count
plan stage-stale-record
assert_jq "stage-stale: action" "$(card 12 action)" '"review_stage"'
# findings in round 1 of 2 -> fix with stage
plan stage-fix
assert_jq "stage-fix: action" "$(card 12 action)" '"fix"'
assert_jq "stage-fix: stage present" "$(card 12 stage.name)" '"security"'
# findings in round 2 of 2 -> block at the stage's max
plan stage-block
assert_jq "stage-block: action" "$(card 12 action)" '"block"'
assert_jq "stage-block: reason" "$(card 12 reason)" '"1 Critical/Important findings survive round 2 of 2 in security"'
# advisory stage with findings and no later label -> tail (draft PR -> mark_ready)
plan stage-advisory-tail
assert_jq "stage-advisory: action" "$(card 12 action)" '"mark_ready"'
# clean in security, ux label present -> advance to ux
plan stage-advance-next
assert_jq "stage-advance-next: action" "$(card 12 action)" '"advance_stage"'
assert_jq "stage-advance-next: ux" "$(card 12 stage.name)" '"ux"'
# clean in security, ux label present but reviewed_stages has ux -> tail
plan stage-skip-done
assert_jq "stage-skip-done: not revisited" "$(card 12 action)" '"mark_ready"'
# head moved after a clean stage review -> review_stage
plan stage-head-moved
assert_jq "stage-head-moved: action" "$(card 12 action)" '"review_stage"'
# a card labelled fleet:review_legacy with no such stage in the config: settle plan by number
plan_settle stage-not-configured 12
assert_exit "stage-missing: exit 0" 0
assert_jq "stage-missing: action skip" "$(card 12 action)" '"skip"'
assert_jq "stage-missing: not dispatchable" '.dispatchable' 'false'
# settle keeps advance_stage, drops review_stage
plan_settle stage-advance-from-review 12
assert_jq "settle: advance_stage kept" "$(card 12 action)" '"advance_stage"'
plan_settle stage-review-needed 12
assert_jq "settle: review_stage waits" "$(card 12 reason)" '"review_stage waits for the next tick"'
# action_failures rule covers a stage column
plan stage-action-failures-3     # note action_failures 3, review.max_rounds 3
assert_jq "stage failures: block" "$(card 12 action)" '"block"'
```

- [ ] **Step 2: Run the suite, expect the new cases to fail; commit tests and fixtures**

```bash
git add plugins/fleet-board/tests/test-tick-plan.sh plugins/fleet-board/fixtures/gh/tick
git commit -m "test(tick-plan): stage columns, advance_stage and review_stage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 3: Implement**

In the gather function: treat `in_review` and `review_*` states alike for the PR, mergeable, drift and accepted lookups; add the `next` lookup (before `needs-human-qa.sh`, same guard) and emit `next_stage` (string|null) and `stage` (the column's stage object or null). In jq: `def is_review: . == "in_review" or startswith("review_")`; `$smax = ($c.stage.max_rounds // $max)`; `$ci_eff = if $c.stage.advisory then 0 else $ci`; review action name = `if $c.stage then "review_stage" else "review"`; record freshness adds `($lr.stage // null) != ($c.stage.name // null)`; after a clean current review `if $c.next_stage != null then act("advance_stage"; ...)` before the `needs_human_qa` test; the `action_failures` state tests use `is_review`. Plan card `stage`: for `advance_stage` the `next_stage`'s object (look it up in `$cfg.review.stages`), else `$c.stage`. Settle filter: add `advance_stage` to the kept list. Column loop: `ready in_progress in_review $(fb_stage_states) blocked`. Update the header comment's action list and lookups.

- [ ] **Step 4: Run, expect pass, commit and push**

Run: `bash plugins/fleet-board/tests/test-tick-plan.sh && bash plugins/fleet-board/tests/test-tick-plan-comment.sh`
```bash
git add plugins/fleet-board/scripts/tick-plan.sh
git commit -m "tick-plan: stage columns with advance_stage and review_stage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 6: `settle.sh` and `merge-reviewed.sh`

**Files:**
- Modify: `plugins/fleet-board/scripts/settle.sh:62,89-95,155-165`
- Modify: `plugins/fleet-board/scripts/merge-reviewed.sh:52-56,78`
- Test: `plugins/fleet-board/tests/test-settle.sh`, `plugins/fleet-board/tests/test-merge-reviewed.sh`

**Interfaces:**
- Consumes: Task 5's plan card `stage`, action `advance_stage`; Task 2's `route`.
- Produces: settle lists `in_progress in_review` and every stage column; `do_advance_stage <n> <stage> <from-state>` runs `board-move.sh N review_<stage>` then `note.sh merge` with `{stage, round: 1, reviewed_stages: <old> + [<from stage>] (only when from-state is a stage), state: review_<stage>}`; `do_move_to_review` runs `review-stages.sh route N <pr>` after its note write (a failure is a `fail`). `merge-reviewed.sh` lists `in_review` and every stage column and accepts a planned `merge` whose card state is `in_review` or `review_*`.

- [ ] **Step 1: Write the failing settle tests** (append; the suite's `card`, `route`, `cnt`, `run_settle` helpers; config with the two stages):

```bash
# advance_stage from in_review
card 12 in_review '{"state":"in_review","round":1,"pr":34,"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0}}' ; label 12 needs-security-review
run_settle
assert_eq "advance: moved to review_security" "$(cnt "issue edit 12 --repo acme/toy --add-label fleet:review_security")" 1
assert_eq "advance: note stage" "$(jq -c .stage <<<"$NOTE")" '"security"'
assert_eq "advance: note round 1" "$(jq -c .round <<<"$NOTE")" 1
assert_eq "advance: reviewed_stages unchanged from in_review" "$(jq -c .reviewed_stages <<<"$NOTE")" '[]'
assert_eq "advance: state" "$(jq -c .state <<<"$NOTE")" '"review_security"'
# advance_stage from security to ux appends security
card 12 review_security '{"state":"review_security","stage":"security","round":1,"pr":34,"last_review":{"round":1,"stage":"security","sha":"abc1234","critical":0,"important":0}}' ; label 12 needs-ux-review
run_settle
assert_eq "advance 2: reviewed_stages" "$(jq -c .reviewed_stages <<<"$NOTE")" '["security"]'
# move_to_review routes
card 12 in_progress '{"state":"in_progress","round":0,"pr":34}'   # PR files under src/auth
run_settle
assert_eq "move_to_review: route adds the label" "$(cnt "issue edit 12 --repo acme/toy --add-label needs-security-review")" 1
# stage columns are listed
assert_eq "lists review_security" "$(cnt_prefix "issue list --repo acme/toy --label fleet:review_security")" 1
```
(`cnt_prefix` counts calls whose argv starts with the given words; add it beside the suite's `cnt` if absent.)
In `test-merge-reviewed.sh`: a card in `review_security` with a clean stage review, non-draft green PR under `merge.policy: auto` is merged; the `fleet:review_security` column is listed.

- [ ] **Step 2: Run both suites, expect the new cases to fail; commit**

```bash
git add plugins/fleet-board/tests/test-settle.sh plugins/fleet-board/tests/test-merge-reviewed.sh
git commit -m "test(settle, merge-reviewed): stage columns and advance_stage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 3: Implement** the column loops (`for st in in_progress in_review $(fb_stage_states)`), `do_advance_stage`, the route call in `do_move_to_review`, and the merge-reviewed eligibility (`case "$state" in in_review|review_*)`). Update both header comments.

- [ ] **Step 4: Run, expect pass, commit and push**

Run: `bash plugins/fleet-board/tests/test-settle.sh && bash plugins/fleet-board/tests/test-merge-reviewed.sh`
```bash
git add plugins/fleet-board/scripts/settle.sh plugins/fleet-board/scripts/merge-reviewed.sh
git commit -m "settle, merge-reviewed: stage columns, advance_stage, routing on move_to_review

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 7: `init.sh` names the stage setup step

**Files:**
- Modify: `plugins/fleet-board/scripts/init.sh:241-252` (`state_color`), after step 5 (`fb_set_states`), end of the script (hint line)
- Test: `plugins/fleet-board/tests/test-init.sh`

**Interfaces:**
- Consumes: Task 1 `fb_set_states`; Task 2 `review-stages.sh setup`.
- Produces: `init.sh` always renders a config without stages, so it creates no stage labels itself. It ends its success output with the line `fleet-board init: to add review stages, set review.stages in .fleet-board.yml, then run: bash <scripts>/review-stages.sh setup` (`<scripts>` the absolute scripts dir). `state_color review_*` → `5319e7`, and `fb_set_states` runs after `FLEET_CFG` is set, so a later change that keeps a config's stages creates their labels through the existing state loop.

- [ ] **Step 1: Write the failing init test**: in `test-init.sh`'s labels-backend success case, assert stdout contains `then run: bash ` and `/review-stages.sh setup` on one line.

- [ ] **Step 2: Run `bash plugins/fleet-board/tests/test-init.sh`, expect the new case to fail; commit the test**

- [ ] **Step 3: Implement** the hint line, the `state_color` arm and the `fb_set_states` call.

- [ ] **Step 4: Run, expect pass, commit and push**

```bash
git add plugins/fleet-board/tests/test-init.sh plugins/fleet-board/scripts/init.sh
git commit -m "init: name review-stages.sh setup; stage state colour

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 8: `status.sh` stage sections

**Files:**
- Modify: `plugins/fleet-board/scripts/status.sh:53,118,151-205`
- Test: `plugins/fleet-board/tests/test-status.sh`

**Interfaces:**
- Produces: `STATES="ready in_progress in_review <stage states> human_qa blocked"` (stages in config order, after `fb_load_config`); a card line in a stage column reads `  #<n> <title> · round <r> · PR #<pr> · <models.fixer>/<stage.agent>@<stage.model>`, where the stage is the column's; `--forecast` loops the stage columns too.

- [ ] **Step 1: Write the failing test** (in `test-status.sh`'s style: `list_route`, `card`, expected block): a config with the two stages, one card in `fleet:review_security` with note `{"state":"review_security","stage":"security","round":1,"pr":40,"models":{"implementor":"sonnet","reviewer":"opus","fixer":"sonnet"}}`; expect a `review_security` section after `in_review` holding `  #14 Fix divide · round 1 · PR #40 · sonnet/acme:sec@opus`, and an empty `review_ux` section `  (none)` before `human_qa`.

- [ ] **Step 2: Run, expect fail; commit the test**

- [ ] **Step 3: Implement** (the stage object comes from `fb_stage_of_state "$st"`; pass `agent` and `model` into the jq line builder as args).

- [ ] **Step 4: Run `bash plugins/fleet-board/tests/test-status.sh && bash plugins/fleet-board/tests/test-status-readonly.sh`, expect pass, commit and push**

```bash
git add plugins/fleet-board/tests/test-status.sh plugins/fleet-board/scripts/status.sh
git commit -m "status: one section per review stage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 9: Gate check for stage moves

**Files:**
- Test: `plugins/fleet-board/tests/test-gate.sh`

**Interfaces:** none new. The gate resolves state names through `board-lib.sh` after `fb_load_config` (hooks/gate.sh:751), so Task 1 already covers it; this task proves it.

- [ ] **Step 1: Add two gate cases**: with Task 1's stages config, `board-move.sh 12 review_security` on a card in `in_review` is allowed (exit 0), and `board-move.sh 12 review_security` on a card in `human_qa` is blocked by G1 (exit 2, the existing G1 message).

- [ ] **Step 2: Run `bash plugins/fleet-board/tests/test-gate.sh`**. Expected: both pass with no gate change. If the first fails, the gate's state resolution does not see the config-derived list: fix in `hooks/gate.sh` by calling `fb_set_states` after `fb_load_config` where it builds `info`, and re-run.

- [ ] **Step 3: Commit and push**

```bash
git add plugins/fleet-board/tests/test-gate.sh plugins/fleet-board/hooks/gate.sh
git commit -m "test(gate): stage columns move under the existing rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 10: Specs, briefs and clean-room re-authoring (manager, reporting)

**Files:**
- Modify: `docs/implementation-plans/2026-09-28-fleet-board/specs/manager.md` (0.3, 0.4, 0.15, the action table rows `start_review`, `review`, `fix`, `block`; new rows `advance_stage`, `review_stage`; 1.4 plan card fields `stage`; 3.x report check with `--role stage-reviewer`; 4.x note upkeep for `stage` and `reviewed_stages`; tick report line per action)
- Modify: `docs/implementation-plans/2026-09-28-fleet-board/specs/reporting.md` (role list, rule table rows for `stage-reviewer`)
- Modify: `specs/briefs/spec-req-manager.md`, `specs/briefs/spec-req-reporting.md` (a "Revision 16 requirements" section each)
- Modify: `specs/README.md` (a `### Revision 16 (2026-11-xx, review stages)` record), `specs/clean-room-manifest.txt`, `specs/evidence/author-manager.r16.init.json`, `specs/evidence/author-reporting.r16.init.json`
- Re-authored (never by hand): `plugins/fleet-board/agents/manager.md`, `plugins/fleet-board/skills/reporting/SKILL.md`
- Test: `plugins/fleet-board/tests/test-clean-room.sh`, `tests/test-clean-room-manifest.sh`, a new `tests/test-manager-stages.sh` (greps the spec and the agent file for the rules, as `test-manager-blocked-from.sh` does)

**Interfaces:**
- Consumes: every earlier task's names (`advance_stage`, `review_stage`, `stage.{name,agent,model,advisory,brief,max_rounds}`, `review-stages.sh route`, `--role stage-reviewer`, note `stage`/`reviewed_stages`).
- Produces: the manager rules, in spec text (exact wording the implementer writes):
  - 0.3: "…or, for `review_stage` and for the re-review after `fix` on a card whose plan card has a `stage`, the plan card's `stage.agent`. Never any other agent."
  - 0.4: "`model`: … for a stage agent, the plan card's `stage.model`."
  - `start_review` row: after the note write, `review-stages.sh route N <pr>`; its stdout list goes in the tick report line.
  - `advance_stage` row: `board-move.sh N review_<stage.name>` → `note.sh merge` with `stage`, `round: 1`, `reviewed_stages` (the note's list plus the stage the card leaves, when it leaves a stage) → `worktree.sh review N <pr>` → dispatch the stage agent (the `review_stage` inputs) in the same tick.
  - `review_stage` row: `worktree.sh review N <pr>` → dispatch `stage.agent` on `stage.model` with: card number and body, PR number, PR diff (file path over 1500 lines), latest implementor or fixer report, review worktree path, config JSON, stage name and `brief` verbatim, round, `prev_sha`, previous Critical/Important findings from round 2, scripts dir, and the instruction to check and post with `parse-report.sh --role stage-reviewer` and `board-comment.sh` in one Bash call.
  - `fix` row: "…dispatch the reviewer in the same tick" becomes "…dispatch the reviewer, or the plan card's stage agent when the plan card has a `stage`, in the same tick".
  - `block` row: `blocked_from` may be `review_<name>`.
  - Report check: a stage agent's report is checked with `--role stage-reviewer`; `last_review` records `stage`, `agent`, `model`.
  - Reporting spec: role `stage-reviewer` in the role list; rule table rows: `role stage-reviewer does not allow status: <word>` (`clean` and `findings` only) and the note under `role <role> requires ## <section>` that `stage-reviewer` has no role sections.

- [ ] **Step 1: Write the failing `test-manager-stages.sh`**: for each of the rules above, `grep -F` a fixed phrase in both the spec and `agents/manager.md` (phrases: `review-stages.sh route`, `advance_stage`, `review_stage`, `stage.agent`, `stage.model`, `--role stage-reviewer`, `reviewed_stages`); and in `specs/reporting.md` and `skills/reporting/SKILL.md`: `stage-reviewer`. Run it; expect every check `not ok`.

- [ ] **Step 2: Commit the test**

- [ ] **Step 3: Hand-edit the two specs and two briefs** with the rules above (the specs are prose; the briefs get a numbered "Revision 16 requirements" list naming each rule). Run `test-manager-stages.sh`: the spec checks pass, the agent-file checks still fail.

- [ ] **Step 4: Commit the spec and brief edits**

- [ ] **Step 5: Re-author in isolation** (one run per file, the Revision 13 recipe): stage a temp dir with `edit-req.md` (the Revision 16 requirements) and a copy of the edited spec; from `plugins/fleet-board/`:
```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir "$STAGE" --output-format stream-json --verbose --max-turns 40 "$(cat "$STAGE/prompt.md")" < /dev/null > "$TMPDIR/fb-r16/author-manager.log" 2>&1
```
Check the init event (only built-in plugins, tools exactly Edit and Read), the path audit (reads of the two inputs and the target only; edits of the target only), and the cost. Save the init event under `specs/evidence/author-<name>.r16.init.json` with no key or local path. Check the running API-key total in the private handoff before the run; the spec's ceiling applies.

- [ ] **Step 6: Minimality check**: `git diff -U0` of each re-authored file, read hunk by hunk: every hunk maps to a Revision 16 requirement; the frontmatter is unchanged. If a hunk does not, restore the file and re-run with a tighter `edit-req.md`.

- [ ] **Step 7: Update the manifest** (`shasum -a 256` of both files) and write the Revision 16 record in `specs/README.md` (cause, spec and brief sha256 before→after, the run table, isolation, path audit, minimality, cost and running total, output sha256 before→after).

- [ ] **Step 8: Run the checks**

Run: `bash plugins/fleet-board/tests/test-manager-stages.sh && bash plugins/fleet-board/tests/test-clean-room.sh && bash plugins/fleet-board/tests/test-clean-room-manifest.sh`
Expected: all pass.

- [ ] **Step 9: Commit and push**

```bash
git add docs/implementation-plans/2026-09-28-fleet-board/specs plugins/fleet-board/agents/manager.md plugins/fleet-board/skills/reporting/SKILL.md plugins/fleet-board/tests/test-manager-stages.sh
git commit -m "Clean-room revision 16: manager and reporting learn review stages

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```

---

### Task 11: Docs, design note and version bump

**Files:**
- Modify: `plugins/fleet-board/README.md` (key table row `review.stages`; the "Watch it move" table gains a stage row; the first paragraph's "a reviewer checks it" sentence mentions extra review stages)
- Modify: `plugins/fleet-board/docs/config.md` (new `## review.stages` section: the YAML, the label rule, `review-stages.sh setup`, advisory, the trade-off)
- Modify: `docs/design.md` (state diagram edges `in_review --> review_<stage>`, `review_<stage> --> review_<stage>: fix`, `review_<stage> --> human_qa`, `review_<stage> --> done`, `review_<stage> --> blocked`; a section "Review stages are columns" with the alternative, phases inside In Review, and the accepted trade-off that a later stage's fix is not re-seen by the evidence reviewer)
- Modify: `plugins/fleet-board/CLAUDE.md` (Contracts: note fields `stage`, `reviewed_stages`; tick-plan actions `advance_stage`, `review_stage`; `FB_STATES` is set by `fb_load_config`; `review-stages.sh`)
- Modify: `plugins/fleet-board/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (`0.10.0` → `0.11.0`)
- Test: `plugins/fleet-board/tests/test-readme-claims.sh` (new check: the config table has a `review.stages` row), `tests/test-version.sh`

- [ ] **Step 1: Add the readme-claims check** (`grep -qF '| `review.stages` |'` in the Config section); run `bash plugins/fleet-board/tests/test-readme-claims.sh`, expect `not ok`; commit.

- [ ] **Step 2: Write the docs and bump the version.**

- [ ] **Step 3: Run** `bash plugins/fleet-board/tests/test-readme-claims.sh && bash plugins/fleet-board/tests/test-version.sh && bash plugins/fleet-board/tests/test-clean-room.sh`. Expected: pass.

- [ ] **Step 4: Commit, push and open the PR in the browser** (it stays a draft; the user marks it ready and merges)

```bash
git add plugins/fleet-board/README.md plugins/fleet-board/docs/config.md docs/design.md plugins/fleet-board/CLAUDE.md plugins/fleet-board/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/fleet-board/tests/test-readme-claims.sh
git commit -m "Docs: review stages; plugin 0.11.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
gh pr view --web
```

---

### Task 12: Live behavioral scenario `stage-path` (run only when asked)

**Files:**
- Modify: `plugins/fleet-board/tests/behavioral-tick.sh` (add `stage-path` to `SCENARIOS` and a `scenario_stage_path` function)
- Create: `plugins/fleet-board/fixtures/behavioral/card-stage.md` (a card whose Acceptance touches `src/auth/`), `fixtures/behavioral/toy-repo/.claude/agents/stub-stage-reviewer.md` (a project-local agent that writes a clean `stage-reviewer` report with `` VERIFIED: `node --test test/calc.test.js` -> N passing tests `` and posts it as every role does)

**Interfaces:**
- Consumes: everything above; the sandbox repo's `.fleet-board.yml` gets `review: { stages: [{name: security, agent: stub-stage-reviewer, model: sonnet, paths: ["src/auth/**"]}] }`; `review-stages.sh setup` runs in the scenario's setup.

- [ ] **Step 1: Write the scenario**: ticks until the card's PR is ready for review or `--max-ticks`; checks, in the suite's `check` style: the card carried `needs-security-review` after the first review tick; it sat in `fleet:review_security`; the stub's report comment exists with `## Status` `clean` and no `## Acceptance map`; the final note has `reviewed_stages == ["security"]` and `stage == "security"`; the PR is non-draft.

- [ ] **Step 2: Run it once, when the user asks** (`SANDBOX_REPO=<owner/name> bash plugins/fleet-board/tests/behavioral-tick.sh --scenario stage-path`), record the transcript path and cost in the PR description.

- [ ] **Step 3: Commit and push**

```bash
git add plugins/fleet-board/tests/behavioral-tick.sh plugins/fleet-board/fixtures/behavioral
git commit -m "behavioral: stage-path scenario routes a card through one review stage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
git push
```
