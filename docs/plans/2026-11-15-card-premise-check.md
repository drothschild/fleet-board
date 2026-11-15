# Card Premise Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before a Ready card starts, check that it still agrees with the default branch, and settle what the check finds: add a missing dependency unattended, and bring an already-built or stale card to the owner as one question. Draft the follow-ups roles file the same way.

**Architecture:** Each card carries a `premise` stamp (the default-branch commit it last agreed with). The planner compares the stamp with the current head and plans `check_premise` in place of `start` when a file the card names has changed. That action runs a headless session with a shell in a throwaway checkout of the default branch; it posts one fixed-shape report, and the supervisor's driver acts on the verdict. Follow-ups are filed mechanically as today, marked as awaiting a draft, and the same session in a second mode drafts them.

**Tech Stack:** bash 3.2 + jq (store scripts, planner), Python 3 standard library (supervisor, board server), plain JavaScript (board page), plain-bash and `unittest`-style suites with the existing fakes.

**Spec:** `docs/specs/2026-11-15-card-premise-check-design.md`. Read it and `plugins/fleet-board/CLAUDE.md` before any task.

## Global Constraints

- All paths below are relative to `plugins/fleet-board/` unless they start with `docs/` or `.claude-plugin/`.
- The supervisor never executes a command taken from a card or a report. Only the check session runs such commands.
- The fleet never moves a card to Done or rewrites its Scope or acceptance on a verdict. Those need `premise-settle.sh`, run by a person.
- Clean-room files (`agents/*.md`, `skills/{reporting,status}/SKILL.md`) are not edited. The check session has no agent file.
- Card writes go through `fl_write_card` under `fb_lock`. A card with no `premise` key has no stamp; there is no migration.
- A stamp or proposal that does not have the shape given in Task 1 or Task 6 is read as absent, never as valid.
- Bash 3.2, BSD and GNU tools: no bash 4 features, `sed -i.bak`, `unset CDPATH` before `cd`, `LC_ALL=C` for awk decimals. Python standard library only. No new dependencies.
- The default branch is `origin/HEAD` without the prefix, else `main`, as `merge-reviewed.sh` already resolves it. Nothing may assume the name `main`.
- Nothing here may assume this repository's test layout. Fixtures use the neutral example project the existing suites use (`node --test {file}`, `test/**/*.test.js`).
- One PR per task, test-first: the first commit holds only the failing test. Leave `.claude-plugin/plugin.json` and the fleet-board entry of the repo's `.claude-plugin/marketplace.json` alone; the merge lane bumps the version.
- Run only the suite the task names, then `bash plugins/fleet-board/tests/test-clean-room.sh`. Never the full suite.
- Each task updates the matching contract lines in `plugins/fleet-board/CLAUDE.md` for what it adds.
- User-visible copy, exact:
  - plan reasons: `ground moved: <path>`, `no premise stamp`, `premise stamp commit is unknown`, `follow-up awaits a draft`;
  - failure: `premise check failed: <first line>; move the card to Ready to start it without a check`;
  - comments: `Premise check: needs #<n>, which is <state>. Added as a dependency.`, `Waiting for a person: close as already built?`, `Waiting for a person: approve this rewrite?`, `Waiting for a person: the premise check could not settle this card.`;
  - label: `fleet:closed-as-built`.

## Before Task 1: re-check the plan against the code

This plan was written against `main` at `5b6283f3` on 2026-11-15, and the board runs between
then and the build. Before any task starts, fetch `origin/main`, re-read each task's Files and
Interfaces blocks against the code, correct this plan, and show the owner the corrections. In
particular:

- **`scripts/tick-plan.sh` line numbers.** The Ready branch of `decide` (near 1070) and the
  per-card gathering for Ready cards (near 763) move often.
- **#286, #287, #288, #463 (review rounds).** They touch `driver.py` and the note; re-check
  Task 4's session bookkeeping against them.
- **#469 and #464.** #469 is covered by Task 8; move it to Won't do with a link to this plan
  once Task 8 merges. #464 (epics) is a separate design and is not touched here.
- **Which columns the planner lists.** Task 8 needs Backlog cards that await a draft in the
  plan. Confirm how `tick-plan.sh` chooses columns before writing its test.

## Review Focus

1. **A stamp whose commit the local repository does not have** (a fresh clone, a rewritten history, a hand-edited card). Expected: the card is checked, with reason `premise stamp commit is unknown`; it never starts unchecked and the planner never fails. (Task 2.)
2. **Acceptance items whose backticked spans are commands, not paths** (`` `npm test -- --grep add` ``, `` `curl localhost:3000/health` ``). Expected: only tokens that pass the existing Scope path rule count as paths; a command with no such token adds nothing and breaks nothing. (Task 2.)
3. **The card changes while its check session runs** (the owner edits the acceptance, or moves it to Backlog). Expected: the verdict is dropped with one event line and the card is planned again from its new state; nothing is written to it from the stale verdict. (Task 4.)
4. **A session that posts no report, two reports, or a `needs` naming the card itself, a closed card or a card that depends on this one.** Expected: no report or two reports count as a failed check; the bad `needs` is handled as `stale` with a question naming #n and its state. (Tasks 4 and 5.)
5. **Two drafting sessions finish in the same cycle with one place left under the cap, or a supervisor restarts mid-run.** Expected: exactly one follow-up goes to Ready; the count is per supervisor run and starts at zero after a restart. (Task 8.)

---

### Task 1: The stamp on the card

**Files:**
- Create: `scripts/premise.sh`, `tests/test-premise.sh`
- Modify: `scripts/adapters/local/local-lib.sh`, `scripts/adapters/local/create.sh`, `scripts/adapters/local/edit.sh`, `scripts/adapters/local/move.sh`, `scripts/adapters/local/read.sh`

**Interfaces:**
- Produces: card field `premise`: `null`, or `{sha: <40-hex>, at: <UTC ISO>, by: "create"|"edit"|"move"|"check"|"approve"}`.
- Produces: `fl_default_head` (in `local-lib.sh`): prints the 40-hex commit of the local ref for the default branch (`origin/HEAD`, else `origin/main`), no fetch; exit 1 when it cannot be read.
- Produces: `fl_premise_json <by>`: prints the stamp object for the current default head, or `null` when `fl_default_head` fails.
- Produces: `premise.sh stamp <n> --by <by>`: writes the stamp; exit 0, 2 usage, 3 card unreadable. `premise.sh show <n>`: prints the stored `premise` (or `null`).
- Produces: environment variable `FLEET_BOARD_ACTOR`. The supervisor sets it to `supervisor` for every script it runs (Task 4 adds that); a write with it set to `supervisor` never stamps.

- [ ] **Step 1: Write the failing tests** in `tests/test-premise.sh`, using a temp git repo with an `origin` remote and a store made by `init.sh`, as `test-board-local.sh` sets one up:

```
create stamps:           board-create.sh a card -> .premise.sha == origin default head, .premise.by == "create"
create without a remote: no origin ref -> .premise == null, exit 0
edit of acceptance:      edit.sh --acceptance-file -> .premise.by == "edit", sha == current head
edit of Scope in body:   edit.sh --body-file with a changed "## Scope" section -> by == "edit"
edit of title only:      edit.sh --title-file -> .premise unchanged
edit of body, same Scope: --body-file whose "## Scope" section is byte-identical -> unchanged
move into ready:         board-move.sh <n> ready from backlog -> by == "move"
move ready -> ready:     no change
move out of ready:       board-move.sh <n> blocked -> unchanged
supervisor move:         FLEET_BOARD_ACTOR=supervisor board-move.sh <n> ready -> unchanged
supervisor edit:         FLEET_BOARD_ACTOR=supervisor edit.sh --acceptance-file -> unchanged
premise.sh stamp:        --by check -> by == "check"; --by nonsense -> exit 2
malformed stamp:         premise set by hand to "yes" or {sha:"abc"} -> premise.sh show prints null
read returns it:         board-read.sh <n> | jq .premise equals the stored object
default branch not main: origin/HEAD -> origin/trunk -> sha is trunk's head
```

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-premise.sh`. Expected: every case fails (`premise.sh` missing, `.premise` absent).
- [ ] **Step 3: Implement** `fl_default_head`, `fl_premise_json`, the three adapter changes and `premise.sh`. "Scope changed" compares the text of the `## Scope` section before and after, using the section finder `fl_split_body` already has.
- [ ] **Step 4: Run** the suite. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

### Task 2: The planner plans `check_premise`

**Files:**
- Modify: `scripts/premise.sh` (add `moved`), `scripts/tick-plan.sh`, `scripts/config-defaults.json`, `scripts/config.sh`, `tests/test-premise.sh`, `tests/test-tick-plan-ready.sh`, `tests/test-config.sh`
- Create: fixtures under `fixtures/gh/tick/premise-*/`

**Interfaces:**
- Consumes: `premise` field, `fl_default_head` (Task 1); `fb_card_scope_paths` and the planner's Scope token rule.
- Produces: config `premise_check: {enabled: true}` (boolean; `config.sh` refuses anything else with `premise_check.enabled must be true or false`) and `models.checker` (string, default `"sonnet"`).
- Produces: `premise.sh moved <n>`: prints `{moved: bool, reason: string|null, head: <40-hex>|null, paths: [..]}`. `reason` is `no premise stamp`, `premise stamp commit is unknown`, `ground moved: <first matching path>`, or `null`. The card's paths are its Scope paths plus every backticked span in its acceptance items that passes the Scope token rule; a directory path covers its descendants; `supervisor.scope_ignore` is not applied here. Changed files are `git diff --name-only <stamp sha> <head>`. Exit 1 only when the card cannot be read.
- Produces: plan action `check_premise` with reason = the `moved` reason; the plan row carries `premise_head` (the head it was compared with).

- [ ] **Step 1: Write the failing tests.**

In `tests/test-premise.sh`:

```
moved, no stamp:              premise null -> moved true, reason "no premise stamp"
moved, unknown commit:        sha of 40 zeros -> moved true, reason "premise stamp commit is unknown"
not moved:                    a commit on the default branch touching only docs/x.md, Scope `src/a.js` -> moved false, reason null
moved by Scope file:          commit touches src/a.js -> moved true, reason "ground moved: src/a.js"
moved by directory Scope:     Scope `src/`, commit touches src/deep/b.js -> moved true
moved by acceptance path:     Scope `src/a.js`, acceptance names `test/a.test.js`, commit touches it -> moved true
acceptance command spans:     acceptance "`npm test -- --grep add` passes" and "`curl localhost:3000/health` prints ok" -> paths holds neither; exit 0
head equals stamp:            moved false
```

In `tests/test-tick-plan-ready.sh`, with `plan <case>` and `assert_jq`:

```
premise-moved:       Ready card, stamp behind, Scope file changed -> action "check_premise", reason "ground moved: src/calc.js", premise_head set
premise-fresh:       stamp at head -> action "start"
premise-no-stamp:    -> action "check_premise", reason "no premise stamp"
premise-disabled:    premise_check.enabled false, no stamp -> action "start"
premise-deps-first:  unmet dependency and no stamp -> action "wait" (the dependency reason), not check_premise
premise-stacked:     a stacked start (stacking.enabled, one unmet in-review parent) -> action "start"; no check for a stacked child
premise-lint-first:  card lint fails and no stamp -> "skip_card_lint"
premise-no-scope:    no Scope paths and no stamp -> "wait", reason "Scope lists no paths"
premise-scope-free:  two Ready cards with overlapping Scope, both unstamped -> both "check_premise" (no Scope wait)
premise-failures:    note.action_failures == max_rounds and no stamp -> "block" (the existing rule wins)
```

In `tests/test-config.sh`: `premise_check.enabled: "yes"` is refused with the message above; defaults print `enabled: true` and `models.checker: "sonnet"`.

- [ ] **Step 2: Run** the three suites. Expected: the new cases fail.
- [ ] **Step 3: Implement.** In the per-card gathering for a Ready card that has acceptance, passes lint and has no unmet dependency, call `premise.sh moved` once and pass the result into the card object as `premise`. In `decide`, where the Ready branch would return a non-stacked `start`, return `act("check_premise"; $c.premise.reason)` when `premise_check.enabled` and `$c.premise.moved`. Keep the `Scope lists no paths` wait ahead of it, and do not apply the Scope-overlap wait to it.
- [ ] **Step 4: Run** the three suites. Expected: `failed: 0` in each.
- [ ] **Step 5: Commit.**

### Task 3: The checker's report

**Files:**
- Modify: `scripts/parse-report.sh`, `tests/test-parse-report.sh`
- Create: fixtures under `fixtures/reports/checker-*.md`

**Interfaces:**
- Produces: `parse-report.sh --role checker --mode check|draft <file>`. `--mode` is required with this role. Common sections as for the stage-reviewer (`## Status`, `## Findings`, `## For the card`, one `VERIFIED:` line).
- Status values, mode `check`: `go`, `needs`, `built`, `stale`. Mode `draft`: `duplicate`, `fixed`, `drafted`.
- Role sections and the JSON keys they produce:

| Status | Required section | JSON |
|---|---|---|
| `needs`, `duplicate` | `## Card` holding exactly one `#<n>` | `card: <n>` |
| `built` | `## Evidence`, one line per acceptance item: ``- <item text> :: `<command>` :: <one line of output>`` | `evidence: [{item, command, output}]` |
| `stale` | `## What changed` (one paragraph); optional `## Proposed scope` (free text) and `## Proposed acceptance` (bullets), both or neither | `summary`, `proposal: {scope, acceptance: [..]}` or `null` |
| `fixed` | `## Evidence`, one line: ``- `<command>` :: <one line of output>`` | `evidence: [{command, output}]` |
| `drafted` | `## Why`, `## Proposed scope`, `## Proposed acceptance`; optional `## Repro`: ``- `<command>` :: failed|passed :: <one line of output>`` | `why`, `proposal`, `repro: {command, result, output}` or `null` |

- Rejection messages, exact: `role checker requires --mode check or draft`, `role checker does not allow status: <s> in mode <m>`, `role checker requires ## <section> for status <s>`, `## Card must hold exactly one card number (#<n>)`, `## Proposed scope and ## Proposed acceptance must both be present or both absent`, `## Proposed acceptance has no bullet`, `## Evidence has no entry`.

- [ ] **Step 1: Write the failing tests** in `tests/test-parse-report.sh`: one accepted fixture per status (seven), asserting the JSON keys above with `jq`; one rejected fixture per message above, asserting exit 1 and the exact stderr line; `--role checker` with a reviewer status (`clean`) rejected; `--mode check` with `--role reviewer` still rejected as today.
- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-parse-report.sh`. Expected: the new cases fail with `unknown role`.
- [ ] **Step 3: Implement** the role in the usage text, the role and mode checks and the awk section handling, following how `stage-reviewer` and the merger's `--mode` are done.
- [ ] **Step 4: Run** the suite. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

### Task 4: The check session, and the `go` verdict

**Files:**
- Create: `scripts/supervisor/defaults/premise-check-prompt.md`, `tests/test-premise-prompt.sh`
- Modify: `scripts/worktree.sh`, `scripts/supervisor/resolver.py`, `scripts/supervisor/roles.py`, `scripts/supervisor/sessiontext.py`, `scripts/supervisor/driver.py`, `scripts/supervisor/scheduler.py`, `scripts/supervisor/scripts.py`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/scheduler_cases.py`, `fixtures/supervisor/resolver_cases.py`, `fixtures/supervisor/roles_cases.py`, `tests/test-worktree.sh` (or the suite that covers `worktree.sh review`)

**Interfaces:**
- Consumes: plan action `check_premise` with `premise_head` (Task 2); `parse-report.sh --role checker --mode check` (Task 3); `premise.sh stamp` (Task 1).
- Produces: `worktree.sh check <n>`: fetches the default branch, makes or refreshes a detached worktree `<base>/<n>-check` at its head, prints `{path, head}`. `worktree.sh remove <n>` also removes it.
- Produces: `resolver.resolve` returns `Dispatch('claude', None, CLAUDE, <models.checker>, False)` for `check_premise` and (Task 8) `draft_followup`.
- Produces: `roles.command` with `dispatch.agent is None`: the argv has no `--agent` and carries `--tools Read,Write,Bash,Grep,Glob`; permission mode, output format and `--max-turns` as for any role.
- Produces: `driver.ROLE_ACTIONS` and `_ROLE_OF` gain `check_premise -> 'checker'`; `scheduler.SCOPE_FREE_ACTIONS` gains `check_premise`.
- Produces: the driver exports `FLEET_BOARD_ACTOR=supervisor` to every script it runs.
- Produces: note field `premise_check`: `{head, verdict, at}` for the last finished check, and `premise_started`: `{updated_at}` (the card's `updated_at` when the session began).
- Produces: in `scripts/adapters/local/move.sh` (add it to this task's files, with its cases in `tests/test-premise.sh`): a person's move into Ready of a card whose note `last_action_error` starts with `premise check failed:` resets the note's `action_failures` and `last_action_error`, as `note.sh reset-failures` does. Without this the planner's existing failure rule would block the card again at once, and the owner could not start it without a check.
- Produces: `Driver._settle_premise(c, run, parsed)`, the one place later tasks add verdicts. In this task it handles `go` and treats every other verdict as a failed check with error `verdict <v> is not handled yet`.

Prompt template inputs (`role_prompt('checker', inputs, tmp)`): card number, title, body, acceptance items, the open cards as `#<n> <state> <title> [PR #<pr> <branch>]` lines, the checkout path, the scripts directory, the mode, and the text of `skills/planner/references/persona.md`. The template tells the session: work only in the checkout; change no file in it; run what it needs; write the report to a `mktemp` file; and post it in one Bash call, `bash <scripts>/parse-report.sh --role checker --mode <mode> <path> && bash <scripts>/board-comment.sh <n> <path>`.

- [ ] **Step 1: Write the failing tests.**

In `fixtures/supervisor/driver_cases.py` (run by `tests/test-supervisor-driver.sh`), using `board_for`, `begin` and `run_role`:

```
test_check_premise_starts_a_session_in_a_check_worktree
    begin(b, 'check_premise', premise_head=H).kind == 'session'; calls include ('worktree.sh', 'check', n);
    no ('worktree.sh', 'create', ...); the argv has no '--agent' and has '--tools', 'Read,Write,Bash,Grep,Glob'
test_go_stamps_the_card_and_progresses
    fake report status go -> calls include ('premise.sh', 'stamp', n, '--by', 'check'); note.premise_check.verdict == 'go';
    outcome.progressed; ('worktree.sh', 'remove', ...) for the check worktree
test_scripts_run_with_the_supervisor_actor
    every stub call's env has FLEET_BOARD_ACTOR == 'supervisor'
test_no_report_counts_one_failure
    session ends with no new comment -> action_failures + 1, last_action_error starts 'premise check failed: '
    and ends '; move the card to Ready to start it without a check'; no stamp
test_two_reports_count_one_failure
test_rejected_report_is_redispatched_once_then_fails
test_card_changed_during_the_check_drops_the_verdict
    card.updated_at differs from note.premise_started.updated_at when the session ends -> no stamp, no move, no failure
    counted, one event 'premise verdict dropped: card changed'
test_unhandled_verdict_is_a_failed_check
    status needs -> failure with 'verdict needs is not handled yet'
```

In `scheduler_cases.py`: a `check_premise` row is admitted beside a `start` row of another card whose Scope overlaps it; `check_premise` is in the classified actions. In `resolver_cases.py` and `roles_cases.py`: the dispatch and argv above.

In `tests/test-premise-prompt.sh`: the rendered prompt for a fixture card contains each acceptance item, each open-card line, the checkout path and the exact post command, and no unreplaced placeholder.

In `tests/test-premise.sh`: a card blocked after failed checks (note `action_failures: 3`, `last_action_error: "premise check failed: x; move the card to Ready to start it without a check"`), moved to Ready by a person, has `action_failures` 0 and a stamp `by: "move"`; the same move with another `last_action_error` leaves the count alone; the supervisor's move leaves it alone.

The `worktree.sh` suite: `check 12` prints a path ending `/12-check` and the default head; a second call refreshes it to a newer head; `remove 12` deletes it; a path outside the base is refused.

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-supervisor-driver.sh`, `test-supervisor-scheduler.sh`, the resolver and roles suites, the worktree suite and `test-premise-prompt.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement.** `_do_check_premise` follows `_dispatch_merger`'s shape (resolve, build inputs, `role_prompt`, `_launch`) with no persona guard; the session-end path reads the card's new comments, runs `parse-report.sh`, and calls `_settle_premise`.
- [ ] **Step 4: Run** the same suites. Expected: all pass.
- [ ] **Step 5: Commit.**

### Task 5: The `needs` verdict

**Files:**
- Modify: `scripts/supervisor/driver.py`, `fixtures/supervisor/driver_cases.py`

**Interfaces:**
- Consumes: `_settle_premise` (Task 4); parsed `card` (Task 3); `edit.sh --blocked-by-json`; `deps.sh`.
- Produces: `Driver._premise_needs(c, parsed) -> Outcome`. In-flight states: `ready`, `in_progress`, `in_review`, any `review_*`, `merging`, `human_qa`.
- Produces: `Driver._premise_question(c, text, proposal=None, evidence=None)`, which Task 6 fills in. In this task it moves the card to Blocked with note `blocked_from: "ready"` and one comment starting `Waiting for a person: the premise check could not settle this card.` followed by `text`.

- [ ] **Step 1: Write the failing tests:**

```
test_needs_adds_the_dependency_and_leaves_the_card_ready
    needs #40, #40 in_review -> ('edit.sh', n, '--blocked-by-json', '[..., 40]') keeping existing entries;
    comment == 'Premise check: needs #40, which is in_review. Added as a dependency.'; no board-move; no stamp
test_needs_a_card_already_listed_changes_nothing_and_asks
    #40 already in blocked_by -> question text names #40 (the check found nothing new)
test_needs_a_backlog_card_asks        #40 backlog -> _premise_question, text 'needs #40, which is backlog'
test_needs_a_closed_card_asks         done, wont_do
test_needs_a_missing_card_asks        text 'needs #999, which does not exist'
test_needs_itself_asks
test_needs_a_card_that_depends_on_this_one_asks
    #40.blocked_by == [n], and the two-hop case (#40 -> #41 -> n)
test_needs_never_stamps
```

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-supervisor-driver.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement.** Walk `blocked_by` from #n with a visited set to find a cycle.
- [ ] **Step 4: Run** the suite. Expected: pass.
- [ ] **Step 5: Commit.**

### Task 6: `built`, `stale`, and the owner's decision

**Files:**
- Create: `scripts/premise-settle.sh`, `tests/test-premise-settle.sh`
- Modify: `scripts/supervisor/driver.py`, `fixtures/supervisor/driver_cases.py`, `scripts/adapters/local/move.sh`, `hooks/gate.sh`, `hooks/gate-lex.awk` (if the lexer needs the new command), `tests/test-gate.sh`, `README.md` (the `## Gates` list)

**Interfaces:**
- Consumes: `_premise_question` (Task 5); parsed `evidence`, `summary`, `proposal` (Task 3); `premise.sh stamp` (Task 1).
- Produces: card field `proposal`: `null`, or `{kind: "rewrite", scope: string, acceptance: [string, ..], summary: string, head: <40-hex>, at}` or `{kind: "close", evidence: [{item, command, output}], head, at}`. Written by `premise-settle.sh propose <n> <json-file>` (the supervisor's only use of the script).
- Produces: `premise-settle.sh approve <n>`: the card must be Blocked with a `rewrite` proposal. Replaces the body's `## Scope` section with the proposal's scope (adds the section when the body has none), replaces the acceptance, keeps `blocked_by` (pass `--blocked-by-json` explicitly), clears `proposal`, stamps `--by approve`, moves the card to Ready.
- Produces: `premise-settle.sh confirm <n>`: the card must be Blocked with a `close` proposal. Adds label `fleet:closed-as-built`, clears `proposal`, moves the card to Done, and appends `{card, decision: "confirmed", at}` to `<log dir>/premise-decisions.jsonl`.
- Produces: `premise-settle.sh reject <n>`: clears `proposal` and appends `decision: "rejected"`. `move.sh` calls the same clearing when a card with a proposal leaves Blocked by a person's move, so "move it back to Ready" is a rejection.
- Exit codes: 0 done; 1 the card is not Blocked or has no proposal of that kind (message `card #<n> has no <rewrite|close> proposal to <approve|confirm>`); 2 usage; 3 card unreadable.
- Produces: gate rule G4: a Bash command in a Claude session that runs `premise-settle.sh approve`, `confirm` or `reject` is blocked with `fleet-board gate: only a person approves or confirms a premise proposal; run it in a terminal or use the board page`. `propose` is not blocked.

- [ ] **Step 1: Write the failing tests.**

`tests/test-premise-settle.sh`:

```
approve replaces Scope and acceptance, keeps blocked_by, stamps by approve, lands in ready, proposal null
approve on a body with no ## Scope adds the section
approve on a Ready card / a close proposal / no proposal -> exit 1, the exact message, card unchanged
confirm -> done, label present, proposal null, one "confirmed" line in premise-decisions.jsonl
confirm on a rewrite proposal -> exit 1
reject -> proposal null, state unchanged, one "rejected" line
a person's board-move.sh <n> ready on a card with a proposal -> proposal null, one "rejected" line, stamp by move
FLEET_BOARD_ACTOR=supervisor board-move.sh of that card -> proposal kept
propose with a malformed file (acceptance not a list, kind unknown) -> exit 2, nothing written
```

`fixtures/supervisor/driver_cases.py`:

```
test_built_blocks_with_the_evidence_and_never_closes
    built, evidence for every acceptance item -> ('premise-settle.sh', 'propose', n, <file>) with kind close;
    moved to blocked, never to done; comment starts 'Waiting for a person: close as already built?' and lists
    each item, command and output
test_built_missing_evidence_for_an_item_is_a_plain_question
    two acceptance items, evidence for one -> no proposal; comment starts
    'Waiting for a person: the premise check could not settle this card.'
test_stale_with_a_proposal_blocks_with_the_rewrite
    comment starts 'Waiting for a person: approve this rewrite?', shows the summary, then current and proposed
    Scope and acceptance; proposal kind rewrite stored
test_stale_without_a_proposal_blocks_with_the_summary
test_no_verdict_stamps_except_go
```

`tests/test-gate.sh`: `bash …/premise-settle.sh approve 12`, `confirm 12` and `reject 12` are blocked with the G4 message (also behind `cd x &&` and with an absolute path); `propose 12 f.json` and `premise.sh show 12` are allowed; with no `.fleet-board.yml` the gate is inert.

- [ ] **Step 2: Run** the three suites. Expected: the new cases fail.
- [ ] **Step 3: Implement.** Add G4 to the README's `## Gates` residuals: a script file that calls `premise-settle.sh` is not seen by the gate.
- [ ] **Step 4: Run** the three suites. Expected: pass.
- [ ] **Step 5: Commit.**

### Task 7: The board page

**Files:**
- Modify: `scripts/board-web.py`, `scripts/board-web/` (the drawer script and styles), `tests/test-board-web.sh`
- Create: `tests/test-board-drawer-premise.sh` (model it on `tests/test-board-drawer-accept.sh`)

**Interfaces:**
- Consumes: card `proposal` and `premise` (Tasks 1 and 6); `premise-settle.sh` (Task 6).
- Produces: `GET /api/cards/<n>` includes `proposal` and `premise`. The `/api/board` card summary includes `proposal_kind` (`"rewrite"`, `"close"` or `null`).
- Produces: `POST /api/cards/<n>/premise/approve`, `/confirm`, `/reject`: run the matching `premise-settle.sh` verb through `board_write`; a non-zero exit is a 409 carrying its stderr, as `accept_card` does.
- Page: a Blocked card with a proposal shows it at the top of the drawer. Rewrite: the summary, then current and proposed Scope and acceptance side by side, with buttons `Approve rewrite` and `Reject`. Close: each acceptance item with its command and output, with buttons `Close as built` and `Build it anyway` (which is reject, then a move to Ready). The tile shows `Rewrite proposed` or `Already built?`.

- [ ] **Step 1: Write the failing tests.** In `tests/test-board-web.sh`: the three routes call the right verb; a failing verb gives 409 with the stderr text; the card and board payloads carry the new keys; a card with a malformed proposal reports `proposal: null`. In `tests/test-board-drawer-premise.sh` (DOM harness): each proposal kind renders its buttons with the exact labels; a card with no proposal renders neither; pressing a button posts to its route once and is disabled while the request is open.
- [ ] **Step 2: Run** both suites. Expected: the new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both suites. Expected: pass.
- [ ] **Step 5: Commit.**

### Task 8: Follow-ups are drafted

**Files:**
- Modify: `scripts/file-followups.sh`, `scripts/tick-plan.sh`, `scripts/config-defaults.json`, `scripts/config.sh`, `scripts/supervisor/driver.py`, `scripts/supervisor/state.py`, `scripts/supervisor/scheduler.py`, `scripts/supervisor/resolver.py`, `scripts/supervisor/defaults/premise-check-prompt.md`, `tests/test-followups.sh`, `tests/test-tick-plan-followups.sh`, `tests/test-config.sh`, `tests/test-premise-prompt.sh`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/state_cases.py`, `fixtures/supervisor/scheduler_cases.py`

**Interfaces:**
- Consumes: the session, prompt and report of Tasks 3 and 4 in mode `draft`; `premise.sh stamp`; `card-lint.sh`.
- Produces: config `followups.auto_ready` (`"bugs"` default, or `"none"`; refused otherwise with `followups.auto_ready must be bugs or none`) and `followups.auto_ready_cap` (non-negative integer, default 5). `followups.status` keeps its meaning.
- Produces: card field `followup`: `null`, or `{draft: "pending"|"done"|"failed", kind: "bug"|"out_of_scope", entry: <the report bullet>, from: <card number>}`.
- `file-followups.sh`, with `premise_check.enabled` true: files every new card in Backlog with `followup.draft: "pending"`, whatever `followups.status` says, and posts no "Filed in Backlog" comment. With it false: exactly today's behaviour, and no `followup` field. The "main is red" card `verify-main.sh` files is untouched in both cases.
- Produces: plan action `draft_followup` (reason `follow-up awaits a draft`) for a Backlog card with `followup.draft == "pending"` when `premise_check.enabled`; scope-free; resolves like `check_premise`.
- Produces: `State.followups_auto_ready` (integer, starts at 0 each supervisor run), `State.take_auto_ready(cap) -> bool` (true and counts one when under the cap), and `followups_auto_ready: {count, cap}` in the snapshot.
- Driver, by draft verdict:
  - `duplicate` #n: #n must exist and not be the card itself, else a failed draft. Move the card to Won't do; comment `Follow-up draft: duplicate of #<n>.`
  - `fixed`: move to Won't do; comment `Follow-up draft: already fixed on the default branch.` followed by the evidence line.
  - `drafted`: write the body (`## Why`, `## Scope`) and acceptance with `edit.sh`, set `followup.draft: "done"`, run `card-lint.sh`, stamp `--by check`. Then move to Ready only when all hold: `followup.kind == "bug"`; `repro.result == "failed"`; the lint passed; `followups.auto_ready == "bugs"`; `State.take_auto_ready(cap)` returns true. Otherwise the card stays in Backlog with one comment giving the first reason that failed: `Drafted; left in Backlog: <not a bug report | the repro did not fail on the default branch | no repro was run | card lint failed: <rules> | followups.auto_ready is none | this run's cap of <cap> is used>.`
  - A failed draft (no report, rejected twice, bad verdict): after the card's `action_failures` reach `max_rounds`, set `followup.draft: "failed"` and post today's "Filed in Backlog" comment. The card then stays as mechanically filed and is not planned again.

- [ ] **Step 1: Write the failing tests.**

`tests/test-followups.sh`: with the check enabled, a bug entry and an out-of-scope entry both land in Backlog with `followup.draft == "pending"`, the right `kind`, `entry` and `from`, and no Backlog comment; with it disabled, the existing assertions hold unchanged and `.followup` is absent; an entry linked to an existing card creates nothing, as today.

`tests/test-tick-plan-followups.sh`: `followup-pending` -> `draft_followup`; `followup-done` and `followup-failed` -> no row for a Backlog card, as today; `followup-pending` with the check disabled -> no row; a pending card with `action_failures == max_rounds` -> no `block` (it is Backlog; the driver marks it failed).

`tests/test-config.sh`: the two keys, their defaults and the refusal message; a negative or non-integer cap is refused.

`fixtures/supervisor/state_cases.py`: `take_auto_ready(2)` is true, true, false; the snapshot shows `{count: 2, cap: 2}`; a new `State` starts at 0.

`fixtures/supervisor/driver_cases.py`:

```
test_draft_duplicate_closes_with_a_link
test_draft_duplicate_of_itself_or_a_missing_card_is_a_failed_draft
test_draft_fixed_closes_with_the_evidence
test_drafted_bug_with_a_failing_repro_goes_to_ready
    edit.sh carries the Why, Scope and acceptance; stamp by check; board-move to ready; count is 1
test_drafted_out_of_scope_stays_in_backlog          comment '... not a bug report.'
test_drafted_bug_whose_repro_passed_stays           '... the repro did not fail on the default branch.'
test_drafted_bug_with_no_repro_stays                '... no repro was run.'
test_drafted_bug_failing_lint_stays                 '... card lint failed: manual-check.'
test_auto_ready_none_keeps_every_draft_in_backlog   '... followups.auto_ready is none.'
test_the_cap_admits_exactly_one_of_two_drafts_finishing_together
    cap 1, two drafted bugs settled in one cycle -> one ready, the other '... this run's cap of 1 is used.'
test_cap_zero_sends_nothing_to_ready
test_a_draft_that_keeps_failing_is_marked_failed_and_left_as_filed
```

`tests/test-premise-prompt.sh`: the draft-mode prompt contains the entry text, the filing card's number, every card's `#<n> <state> <title>` line (closed ones included), and the draft post command.

- [ ] **Step 2: Run** the suites named above. Expected: the new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the suites. Expected: pass.
- [ ] **Step 5: Commit.**

### Task 9: Seeing what the check did, and the docs

**Files:**
- Modify: `scripts/supervisor/driver.py`, `scripts/supervisor/state.py`, `scripts/supervisor/cli.py`, `scripts/supervisor/usage.py`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/state_cases.py`, `fixtures/supervisor/usage_cases.py`, `fixtures/supervisor/dump_real_shapes.py`, `README.md`, `skills/init/SKILL.md` (only if it lists config keys), the repo's `.fleet-board.yml`
- Create: `tests/test-premise-docs.sh`

**Interfaces:**
- Consumes: every verdict path of Tasks 4, 5, 6 and 8.
- Produces: one event per settled verdict, text `premise #<n>: <verdict> -> <what was done>`, where the second part is one of `stamped`, `depends on #<m>`, `asked: close as already built`, `asked: approve rewrite`, `asked: could not settle`, `closed as duplicate of #<m>`, `closed as already fixed`, `drafted, to Ready`, `drafted, in Backlog`.
- Produces: snapshot key `premise: {checked, go, needs, built, stale, drafted, auto_ready, failed}` (counts for this run), printed by `supervisor status` as one line `Premise checks: <checked> run, <go> go, <needs> needs, <built> built, <stale> stale; follow-ups: <drafted> drafted, <auto_ready> of <cap> to Ready`.
- Produces: usage ledger lines for the two actions carry `role: "checker"` and the card's column, so `supervisor usage` and the board's column totals include them.

- [ ] **Step 1: Write the failing tests.** Driver cases: each verdict test from earlier tasks also asserts its event text. State cases: the counts and the snapshot key. Usage cases: a `check_premise` ledger line is summed under its column and role. `tests/test-supervisor-ui.sh` shapes: regenerate through `dump_real_shapes.py` so the page's harness sees the new snapshot keys. `tests/test-premise-docs.sh`: the README has a `## Premise check` section naming `premise_check.enabled`, `models.checker`, `followups.auto_ready`, `followups.auto_ready_cap`, `premise-settle.sh approve`, `premise-settle.sh confirm` and `fleet:closed-as-built`; `plugins/fleet-board/CLAUDE.md` names `check_premise` and `draft_followup` in the Tick plan action list; the repo's `.fleet-board.yml` does not set `premise_check.enabled: false`.
- [ ] **Step 2: Run** the driver, state, usage and UI suites and `test-premise-docs.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement,** and write the README section: what a stamp is, when a check runs, the four verdicts and what happens for each, how to approve, confirm or overrule (move the card to Ready), the follow-up rules and the two config keys, and how to turn it all off.
- [ ] **Step 4: Run** the same suites. Expected: pass.
- [ ] **Step 5: Commit.**

## After the last task

- Move plan card #469 to Won't do with a link to this plan.
- One live behavioural scenario for the check session (`behavioral-*.sh` style, against `SANDBOX_REPO`): a card whose acceptance already holds gets `built` with evidence; a card naming a moved file gets `stale` with a proposal. It costs usage, so run it only when the owner asks.
- After a week of runs, measure against the spec's "How we will know it worked": blocked reports that say the acceptance already exists or a dependency is unmerged; the share of follow-ups a person had to rewrite; `checker` session time against the implementor time those blocks used to cost; and the confirmed-to-rejected ratio in `premise-decisions.jsonl`, which decides whether closing can later go unattended.
- Tell the owner to restart the Claude app, the supervisor and the board page after the plugin updates.
