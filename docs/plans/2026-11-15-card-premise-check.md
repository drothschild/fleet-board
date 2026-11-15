# Card Premise Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before a Ready card starts, check that it still agrees with the default branch, and settle what the check finds: add a missing dependency unattended, and bring an already-built or stale card to the owner as one question. Draft the follow-ups roles file the same way.

**Architecture:** Each card carries a `premise` stamp (the default-branch commit it last agreed with). The planner compares the stamp with the current head and plans `check_premise` in place of `start` when a file the card names has changed. That action runs a headless session with a shell in a throwaway checkout of the default branch; its final reply is one fixed-shape report, and the supervisor's driver acts on the verdict. Follow-ups are filed mechanically as today, marked as awaiting a draft, and the same session in a second mode drafts them.

**Tech Stack:** bash 3.2 + jq (store scripts, planner), Python 3 standard library (supervisor, board server), plain JavaScript (board page), plain-bash and `unittest`-style suites with the existing fakes.

**Spec:** `docs/specs/2026-11-15-card-premise-check-design.md`. Read it and `plugins/fleet-board/CLAUDE.md` before any task.

## Global Constraints

- All paths below are relative to `plugins/fleet-board/` unless they start with `docs/` or `.claude-plugin/`.
- The supervisor never executes a command taken from a card or a report. Only the check session runs such commands.
- The fleet never moves a card to Done or rewrites its Scope or acceptance on a verdict. Those need `premise-settle.sh`, run by a person.
- Clean-room files (`agents/*.md`, `skills/{reporting,status}/SKILL.md`) are not edited. The check session has no agent file.
- Card writes go through `fl_write_card` under `fb_lock`. A card with no `premise` key has no stamp; there is no migration.
- A stamp, proposal or follow-up record that does not have the shape its task gives is read as absent, never as valid.
- **How the driver reaches a script.** The driver class is `CardDriver` (`scripts/supervisor/driver.py`). It can run only a script named in `scripts.ALLOWED` (`scripts/supervisor/scripts.py`), resolved as `scripts/<name>`, and only dash-flags listed in `driver._FLAGS`. `scripts/adapters/local/edit.sh` is not reachable from the driver and gets no contract script. So every card write the driver needs is a verb of `premise.sh` or `premise-settle.sh`, and each task that adds a call adds the script to `ALLOWED` and its flags to `_FLAGS`.
- Bash 3.2, BSD and GNU tools: no bash 4 features, `sed -i.bak`, `unset CDPATH` before `cd`, `LC_ALL=C` for awk decimals. Python standard library only. No new dependencies.
- The default branch is `origin/HEAD` without the prefix, else `main`, as `merge-reviewed.sh` already resolves it. Nothing may assume the name `main`.
- Nothing here may assume this repository's test layout. Fixtures use the neutral example project the existing suites use (`node --test {file}`, `test/**/*.test.js`).
- One PR per task, test-first: the first commit holds only the failing test. Leave `.claude-plugin/plugin.json` and the fleet-board entry of the repo's `.claude-plugin/marketplace.json` alone; the merge lane bumps the version.
- Run only the suites the task names, then `bash plugins/fleet-board/tests/test-clean-room.sh`. Never the full suite.
- Each task updates the matching contract lines in `plugins/fleet-board/CLAUDE.md` for what it adds.
- User-visible copy, exact:
  - plan reasons: `ground moved: <path>`, `no premise stamp`, `premise stamp commit is unknown`, `follow-up awaits a draft`;
  - failure: `premise check failed: <first line>; move the card to Ready to start it without a check`;
  - comments: `Premise check: needs #<n>, which is <state>. Added as a dependency.`, `Waiting for a person: close as already built?`, `Waiting for a person: approve this rewrite?`, `Waiting for a person: the premise check could not settle this card.`;
  - label: `fleet:closed-as-built`.

## Before Task 1: re-check the plan against the code

This plan was written against `main` at `5b6283f3` on 2026-11-15 and corrected after an
adversarial review against `1cab3430`. The board runs between then and the build. Before a
task starts, fetch `origin/main`, re-read the task's Files and Interfaces blocks against the
code, and correct the card if they disagree. In particular:

- **Line numbers** in `scripts/tick-plan.sh` and `scripts/supervisor/driver.py` move often;
  the names given here are the anchor, the numbers only a hint.
- **#286, #287, #288, #463 (review rounds).** They touch `driver.py` and the note; re-check
  Task 4's use of `_check` and `_Run` against them.
- **#469 and #464.** #469 is covered by Task 8; move it to Won't do with a link to this plan
  once Task 8 merges. #464 (epics) is a separate design and is not touched here.

## Review Focus

1. **A stamp whose commit the local repository does not have** (a fresh clone, a rewritten history, a hand-edited card), and **a repository whose default head cannot be read** (no `origin`). Expected: the first is checked, with reason `premise stamp commit is unknown`; the second is never checked (`moved` false), so a project without a remote is not held. The planner never fails on either. (Task 2.)
2. **Acceptance items whose backticked spans are commands, not paths** (`` `npm test -- --grep add` ``, `` `curl localhost:3000/health` ``). Expected: a span counts as a path only when the whole span passes the existing Scope path rule; a span holding whitespace never does, and one with no `/` or extension never does. (Task 2.)
3. **The card changes while its check session runs** (the owner edits the acceptance, or moves it to Backlog). Expected: the verdict is dropped with one event line and the card is planned again from its new state; nothing is written to it from the stale verdict. A comment or note write alone is not a change. (Task 4.)
4. **A session whose final reply is empty or is rejected twice, or a `needs` naming the card itself, a closed card or a card that depends on this one.** Expected: the first two count as a failed check; the bad `needs` is asked as a question naming #n and its state. (Tasks 4 and 5.)
5. **Two drafting sessions finish in the same cycle with one place left under the cap, or a supervisor restarts mid-run.** Expected: exactly one follow-up goes to Ready; the count is per supervisor run and starts at zero after a restart. (Task 8.)

---

### Task 1: The stamp on the card

**Files:**
- Create: `scripts/premise.sh`, `tests/test-premise.sh`
- Modify: `scripts/adapters/local/local-lib.sh`, `scripts/adapters/local/create.sh`, `scripts/adapters/local/edit.sh`, `scripts/adapters/local/move.sh`, `scripts/adapters/local/read.sh`

**Interfaces:**
- Produces: card field `premise`: `null`, or `{sha: <40-hex>, at: <UTC ISO>, by: "create"|"edit"|"move"|"check"|"approve"}`.
- Produces: `fl_default_head` (in `local-lib.sh`): prints the 40-hex commit of the local ref for the default branch (`origin/HEAD`, else `origin/main`), no fetch; exit 1 when it cannot be read.
- Produces: `fl_premise_json <by> [<sha>]`: prints the stamp object for `<sha>`, or for the current default head; `null` when neither is available.
- Produces: `fl_scope_text <body>`: prints the text of the body's `## Scope` section (heading excluded, up to the next `## ` heading, ignoring headings inside a code fence), or nothing. `fl_split_body` has no such finder today; this is new.
- Produces: `premise.sh stamp <n> --by <by> [--sha <40-hex>]`: writes the stamp; exit 0, 2 usage, 3 card unreadable. `premise.sh show <n>`: prints the stored `premise` (or `null`).
- Produces: environment variable `FLEET_BOARD_ACTOR`. When it is `supervisor`, `move.sh` and `edit.sh` do not stamp. `create.sh` always stamps, whoever runs it, so a card the supervisor files (the "main is red" card, a follow-up) is stamped at creation. Task 4 makes the supervisor set it for the scripts it runs. `tests/test-premise.sh` starts with `unset FLEET_BOARD_ACTOR`, so it behaves the same wherever it is run.
- Every route that creates a card goes through `create.sh` (`import-plan.sh`, the board page, `file-followups.sh`, `verify-main.sh`). `import-github.sh` writes card files itself; its cards have no stamp and are checked before they start, which is acceptable.

- [ ] **Step 1: Write the failing tests** in `tests/test-premise.sh`, using a temp git repo with an `origin` remote and a store made by `init.sh`, as `test-board-local.sh` sets one up. Each "unchanged" case first seeds a stamp with a known old sha, so it can fail:

```
create stamps:            board-create.sh a card -> .premise.sha == origin default head, .premise.by == "create"
supervisor create stamps: FLEET_BOARD_ACTOR=supervisor board-create.sh -> .premise.by == "create"
create without a remote:  no origin ref -> .premise == null, exit 0
edit of acceptance:       edit.sh --acceptance-file -> .premise.by == "edit", sha == current head
edit of Scope in body:    edit.sh --body-file with a changed "## Scope" section -> by == "edit"
edit of title only:       edit.sh --title-file -> seeded stamp unchanged
edit of body, same Scope: --body-file whose "## Scope" section is byte-identical -> seeded stamp unchanged
move into ready:          board-move.sh <n> ready from backlog -> by == "move"
move ready -> ready:      seeded stamp unchanged
move out of ready:        board-move.sh <n> blocked -> seeded stamp unchanged
supervisor move:          FLEET_BOARD_ACTOR=supervisor board-move.sh <n> ready -> seeded stamp unchanged
supervisor edit:          FLEET_BOARD_ACTOR=supervisor edit.sh --acceptance-file -> seeded stamp unchanged
premise.sh stamp:         --by check -> by == "check"; --by check --sha <S> -> sha == S; --by nonsense -> exit 2; --sha xyz -> exit 2
malformed stamp:          premise stored as "yes" or {sha:"abc"} -> premise.sh show prints null
read returns it:          board-read.sh <n> | jq .premise equals the stored object
default branch not main:  origin/HEAD -> origin/trunk -> sha is trunk's head
fl_scope_text:            a "## Scope" heading inside a ``` fence is not taken as the section
```

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-premise.sh`. Expected: the stamping cases fail (`premise.sh` missing, `.premise` absent).
- [ ] **Step 3: Implement** the helpers, the adapter changes and `premise.sh`. "Scope changed" compares `fl_scope_text` of the old and new body.
- [ ] **Step 4: Run** the suite. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

### Task 2: The planner plans `check_premise`

**Files:**
- Modify: `scripts/premise.sh` (add `moved`), `scripts/tick-plan.sh`, `scripts/config-defaults.json`, `scripts/config.sh`, `tests/tick-plan-lib.sh`, `tests/test-premise.sh`, `tests/test-tick-plan-ready.sh`, `tests/test-config.sh`
- Create: fixtures under `fixtures/gh/tick/premise-*/`

**Interfaces:**
- Consumes: `premise` field, `fl_default_head` (Task 1); `fb_card_scope_paths` and the Scope path rule in `board-lib.sh`.
- Produces: config `premise_check: {enabled: false}` (boolean; `config.sh` refuses anything else with `premise_check.enabled must be true or false`) and `models.checker` (string, default `"sonnet"`). **The default is `false` in this task.** Until Task 4 the scheduler and driver do not know `check_premise` (an unknown action goes to attention and is never admitted), and until Task 6 three of the four verdicts are failed checks. A default of `true` here would stall every unstamped Ready card on any board running the plugin in between, this repository's included. Task 6 flips the default to `true`.
- Produces: `premise.sh moved <n>`: prints `{moved: bool, reason: string|null, head: <40-hex>|null, paths: [..]}`.
  - Default head unreadable: `moved` false, `reason` null, `head` null.
  - No stamp: `moved` true, `no premise stamp`.
  - Stamp sha not in the repository: `moved` true, `premise stamp commit is unknown`.
  - Otherwise `moved` is true with `ground moved: <first matching path>` when a file in `git diff --name-only <stamp sha> <head>` matches one of the card's paths, else false.
  - The card's paths are its Scope paths plus every backticked span in its acceptance items that, taken whole, passes the Scope path rule. A directory path covers its descendants. `supervisor.scope_ignore` is not applied here.
  - Exit 1 only when the card cannot be read.
- Produces: plan action `check_premise`, with the `moved` reason as its reason.
- The planner's per-card field for the `moved` result is named `premise_moved`, so it is not confused with the card's `premise` stamp.
- `tests/tick-plan-lib.sh`: `setup_case` writes `premise_check: {enabled: false}` into the case config unless the case's extra YAML sets the key. This matters once Task 6 flips the default: every existing Ready-start scenario in the planner suites must keep planning `start`.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-premise.sh`:

```
moved, no remote:             no origin ref -> moved false, reason null, head null
moved, no stamp:              premise null -> moved true, reason "no premise stamp"
moved, unknown commit:        sha of 40 zeros -> moved true, reason "premise stamp commit is unknown"
not moved:                    a commit on the default branch touching only docs/x.md, Scope `src/a.js` -> moved false, reason null
moved by Scope file:          commit touches src/a.js -> moved true, reason "ground moved: src/a.js"
moved by directory Scope:     Scope `src/`, commit touches src/deep/b.js -> moved true
moved by acceptance path:     Scope `src/a.js`, acceptance names `test/a.test.js`, commit touches it -> moved true
acceptance command spans:     acceptance "`npm test -- --grep add` passes" and "`curl localhost:3000/health` prints ok" -> paths holds neither; exit 0
head equals stamp:            moved false
```

In `tests/test-tick-plan-ready.sh`, with `plan <case> <extra YAML enabling the check>` and `assert_jq`:

```
premise-moved:       Ready card, stamp behind, Scope file changed -> action "check_premise", reason "ground moved: src/calc.js"
premise-fresh:       stamp at head -> action "start"
premise-no-stamp:    -> action "check_premise", reason "no premise stamp"
premise-disabled:    premise_check.enabled false, no stamp -> action "start"
premise-default-lib: after setup_case with no extra YAML, the case's config file sets premise_check.enabled false;
                     with extra YAML that sets it true, the file keeps true
premise-deps-first:  unmet dependency and no stamp -> action "wait" (the dependency reason), not check_premise
premise-stacked:     a stacked start (stacking.enabled, one unmet in-review parent) -> action "start"; no check for a stacked child
premise-lint-first:  card lint fails and no stamp -> "skip_card_lint"
premise-no-scope:    no Scope paths and no stamp -> "wait", reason "Scope lists no paths"
premise-scope-free:  two Ready cards with overlapping Scope, both unstamped -> both "check_premise" (no Scope wait)
premise-failures:    note.action_failures == max_rounds and no stamp -> "block" (the existing rule wins)
```

In `tests/test-config.sh`: `premise_check.enabled: "yes"` is refused with the message above; defaults print `enabled: false` and `models.checker: "sonnet"`.

- [ ] **Step 2: Run** `test-premise.sh`, `test-tick-plan-ready.sh` and `test-config.sh`. Expected: the `moved` cases, `premise-moved`, `premise-no-stamp`, `premise-scope-free` and the config cases fail. The other planner cases (`-fresh`, `-disabled`, `-deps-first`, `-stacked`, `-lint-first`, `-no-scope`, `-failures`) assert behaviour that holds today; they are guards. Show each can fail in Step 4 by breaking the rule it guards for one run, and say so in the PR.
- [ ] **Step 3: Implement.** In the per-card gathering for a Ready card that has acceptance, passes lint and has no unmet dependency, call `premise.sh moved` once and pass the result into the card object as `premise_moved`. In `decide`, where the Ready branch would return a non-stacked `start`, return `act("check_premise"; $c.premise_moved.reason)` when `premise_check.enabled` and `$c.premise_moved.moved`. Keep the `Scope lists no paths` wait ahead of it, and do not apply the Scope-overlap wait to it.
- [ ] **Step 4: Run** the three suites, then `bash plugins/fleet-board/tests/test-tick-plan.sh` (the aggregate of all six planner suites), `test-stack-plan.sh` and `test-scope-reservations.sh`. This task changes what every Ready card plans by default, so those are touched suites here. Expected: `failed: 0` in each.
- [ ] **Step 5: Commit.**

### Task 3: The checker's report

**Files:**
- Modify: `scripts/parse-report.sh`, `tests/test-parse-report.sh`
- Create: fixtures under `fixtures/reports/checker-*.md`

**Interfaces:**
- Produces: `parse-report.sh --role checker --mode check|draft <file>`. Common sections as for the stage-reviewer (`## Status`, `## Findings`, `## For the card`, one `VERIFIED:` line).
- `--role checker` with no `--mode`, or another mode, is a usage error: exit 2, as a bad `--mode` is today. (The driver treats exit 2 as its own bug; it always passes the mode.)
- Status values, mode `check`: `go`, `needs`, `built`, `stale`. Mode `draft`: `duplicate`, `fixed`, `drafted`.
- Role sections and the JSON keys they produce:

| Status | Required section | JSON |
|---|---|---|
| `needs`, `duplicate` | `## Card` holding exactly one `#<n>` | `card: <n>` |
| `built` | `## Evidence`, one line per acceptance item, by its 1-based number: ``- <number> :: `<command>` :: <one line of output>`` | `evidence: [{item: <number>, command, output}]` |
| `stale` | `## What changed` (one paragraph); optional `## Proposed scope` (free text) and `## Proposed acceptance` (bullets), both or neither | `summary`, `proposal: {scope, acceptance: [..]}` or `null` |
| `fixed` | `## Evidence`, one line: ``- `<command>` :: <one line of output>`` | `evidence: [{command, output}]` |
| `drafted` | `## Why`, `## Proposed scope`, `## Proposed acceptance`; optional `## Repro`: ``- `<command>` :: failed|passed :: <one line of output>`` | `why`, `proposal`, `repro: {command, result, output}` or `null` |

- Rejections (exit 1; every stderr line carries the script's `parse-report: ` prefix): `checker status <s> is not allowed in mode <m>`, `checker report needs ## <section> for status <s>` (worded unlike the other roles' `role <r> does not allow status` and `role <r> requires` lines, because `driver._RULES` matches those by an earlier wildcard row and would quote the wrong rule back to the session), `## Card must hold exactly one card number (#<n>)`, `## Proposed scope and ## Proposed acceptance must both be present or both absent`, `## Proposed acceptance has no bullet`, `## Proposed scope names no repository path` (the text yields no path under `fb_card_scope_paths`; such a card could never start), `## Evidence has no entry`, `## Evidence item must be an acceptance item number`.

- [ ] **Step 1: Write the failing tests** in `tests/test-parse-report.sh`: one accepted fixture per status (seven), asserting the JSON keys above with `jq`; one rejected fixture per message above, asserting exit 1 and the exact stderr line; `--role checker` with no `--mode` exits 2; `--role checker` with a reviewer status (`clean`) rejected; `--mode check` with `--role reviewer` still refused as today.
- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-parse-report.sh`. Expected: the new cases fail with the unknown-role usage error.
- [ ] **Step 3: Implement** the role in the usage text, the role and mode checks and the awk section handling, following how `stage-reviewer` and the merger's `--mode` are done.
- [ ] **Step 4: Run** the suite. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

### Task 4: The check session, and the `go` verdict

**Files:**
- Create: `scripts/supervisor/defaults/premise-check-prompt.md`
- Modify: `scripts/worktree.sh`, `scripts/adapters/local/list.sh`, `scripts/supervisor/resolver.py`, `scripts/supervisor/roles.py`, `scripts/supervisor/driver.py`, `scripts/supervisor/scheduler.py`, `scripts/supervisor/scripts.py`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/scheduler_cases.py`, `fixtures/supervisor/resolver_cases.py`, `fixtures/supervisor/roles_cases.py`, `fixtures/supervisor/candidates_cases.py`, `tests/test-worktree.sh`, `tests/test-board-local.sh`

**Interfaces:**
- Consumes: plan action `check_premise` (Task 2); `parse-report.sh --role checker --mode check` (Task 3); `premise.sh stamp --sha` (Task 1).
- Produces: `worktree.sh premise <n>`: fetches the default branch, makes or refreshes a detached worktree `<base>/<n>-premise_check` at its head, runs `worktrees.setup` when it creates one (as `review` does), prints `{path, head}`. The underscore is deliberate: a card's implementation worktree is `<base>/<n>-<slug>` and a slug is `[a-z0-9-]`, so no card title can collide with it. The driver removes it with the path form, `worktree.sh remove <n> <path>`; the no-path form would also remove the card's implementation worktree. (The path form also removes the card's review checkouts, which a Ready or Backlog card does not have.) Update the Invariants line in `CLAUDE.md` that says worktree removal runs only in `cleanup-done.sh`.
- Produces: `resolver.resolve` returns `Dispatch('claude', None, CLAUDE, <models.checker>, False)` for `check_premise` and (Task 8) `draft_followup`.
- Produces: `roles.command` with `dispatch.agent is None`: the argv has no `--agent` (today it would put `None` there) and carries `--tools Read,Write,Bash,Grep,Glob` placed before `--permission-mode`, because `--tools` is variadic and needs an option after it (see `board-web.py`). Permission mode, output format and `--max-turns` as for any role.
- Produces: `ROLE_ACTIONS` and `_ROLE_OF` in `driver.py` gain `check_premise -> 'checker'`; the scheduler's `_ACTION_CLASS` and `SCOPE_FREE_ACTIONS` gain `check_premise` (an action missing from `_ACTION_CLASS` goes to attention and is never admitted).
- Produces: `scripts.ALLOWED` gains `premise.sh`; `driver._FLAGS` gains `--by` and `--sha` (`--mode` is already there).
- Produces: `FLEET_BOARD_ACTOR=supervisor` in the environment that `scripts.run_argv` and `scripts.spawn_argv` build for a child (`scripts/supervisor/scripts.py`). That covers the driver's scripts, the loop's cancel-path moves (`loop.py`) and the merge lane (`merging.py`). It is not set in `os.environ`: `_launch` copies that into every role session, and a role running `tests/test-premise.sh` would then see `supervisor`. One side effect, accepted: `supervisor stuck --release` moves a card through the same runner, so that move does not stamp and the card is checked before it starts.
- Produces: `scripts/adapters/local/list.sh` rows gain `state` and `pr_url` beside `number`, `title` and `url` (existing readers take only number and title). Today state is only implied by a row's position.
- Produces: the prompt. `role_prompt` is in `driver.py` and builds `## <label>` sections from `_SECTIONS` and `_LABELS`; it renders no template and raises for an unknown role. Add a `checker` entry to both. Its inputs: card number, title, body, acceptance items (numbered), the mode, the checkout path, the scripts directory, the instructions (the text of `defaults/premise-check-prompt.md`, passed as one input the way the merger persona is), the planner persona's working rules (`skills/planner/references/persona.md`), and the open cards as `#<n> <state> <title>` lines with ` PR <url>` appended when the card has a `pr_url` (read from `board-list.sh`; `_open_cards` today gives only number and title).
- The instructions file tells the session: work only in the checkout; change no file in it; run what it needs; end with the report as its final reply, in the shape for its mode.
- Produces: report handling. As for every role, the report is the session's final reply: `finish` → `_reconcile` → `_check(run, self._file_report(c, result.report_text))`. Reuse `_check` with `--role checker --mode <mode>` (as the merger passes its mode); it already re-dispatches once and records a second rejection. Where `_apply` is called for other roles, call `CardDriver._settle_premise(c, run, parsed)`. Wrap a failure's error text as `premise check failed: <first line>; move the card to Ready to start it without a check`. The session does not post its own report; the driver posts an accepted report on the card with `board-comment.sh`, so the owner can read the verdict there.
- New rows in `driver._RULES` for the checker's rejection messages go after the rows that mirror `skills/reporting/SKILL.md`, and into the `driver_only` list of `test_rules_match_the_reporting_skill_table_cell_for_cell`. Never edit the skill.
- Produces: change detection. Before launch, keep on the `_Run` object a digest of the card's `state`, `body`, `acceptance` and `blocked_by` from `board-read.sh`. At session end read the card again; a different digest drops the verdict. (`updated_at` cannot be used: every comment and note write changes it, and `board-read.sh` does not return it.)
- Produces: note field `premise_check`: `{head, verdict, at}` for the last finished check.
- Produces: `CardDriver._settle_premise(c, run, parsed)`, the one place later tasks add verdicts. It ignores any `Out of scope:` or `Bugs found:` lines in the checker's report, so a check files no follow-ups. In this task it handles `go`: run `premise.sh stamp <n> --by check --sha <head printed by worktree.sh premise>`, write the note with `_RESET` (a settled verdict clears `action_failures`), remove the checkout. Every other verdict is a failed check with error `verdict <v> is not handled yet`.
- A Ready card that keeps failing its check is blocked by the planner's existing rule at `max_rounds`. `_do_block` already writes `_RESET` when it blocks, so the owner's move back to Ready stamps the card (Task 1) and it starts; no extra reset is needed.

- [ ] **Step 1: Write the failing tests.**

In `fixtures/supervisor/driver_cases.py` (run by `tests/test-supervisor-driver.sh`), using `board_for`, `begin` and `run_role`:

```
test_check_premise_starts_a_session_in_a_premise_worktree
    begin(b, 'check_premise').kind == 'session'; calls include ('worktree.sh', 'premise', n); no ('worktree.sh', 'create', ...);
    the argv has no '--agent' and no None, and has '--tools', 'Read,Write,Bash,Grep,Glob' before '--permission-mode'
test_the_checker_prompt_carries_the_card_and_the_board
    the prompt holds each numbered acceptance item, each open-card line with its state, the checkout path,
    the instructions text and the mode
test_go_stamps_the_commit_the_session_saw
    worktree.sh premise printed head H; report status go -> ('premise.sh', 'stamp', n, '--by', 'check', '--sha', H);
    note.premise_check == {head: H, verdict: 'go', ...}; action_failures 0; ('worktree.sh', 'remove', n, <path>)
test_an_empty_final_reply_counts_one_failure
    action_failures + 1; last_action_error starts 'premise check failed: ' and ends
    '; move the card to Ready to start it without a check'; no stamp
test_a_report_rejected_twice_counts_one_failure        parse-report.sh is called with '--mode', 'check' both times
test_the_card_changed_during_the_check_drops_the_verdict
    the second board-read returns a different acceptance -> no stamp, no move, no failure counted,
    one event 'premise verdict dropped: card changed'
test_a_new_comment_alone_does_not_drop_the_verdict
test_follow_up_lines_in_a_checker_report_file_nothing    no file-followups.sh call
test_an_unhandled_verdict_is_a_failed_check             status needs -> 'verdict needs is not handled yet'
```

In `scheduler_cases.py`: a `check_premise` row is admitted beside a `start` row of another card whose Scope overlaps it; `check_premise` is in the classified actions. In `resolver_cases.py` and `roles_cases.py`: the dispatch and argv above. In `candidates_cases.py` (it already exercises the runner): `run_argv(root, ['sh', '-c', 'printf %s "$FLEET_BOARD_ACTOR"'])` prints `supervisor`, and `os.environ.get('FLEET_BOARD_ACTOR')` is the same before and after the call. In `tests/test-board-local.sh`: a `board-list.sh` row carries the card's `state` and `pr_url`; that suite has assertions that pin whole list rows, which gain the new fields here and again in Task 8.

In `tests/test-worktree.sh`: `premise 12` prints a path ending `/12-premise_check` and the default head; a second call moves it to a newer head; setup runs on creation only; `remove 12 <that path>` deletes it and leaves `<base>/12-some-slug` in place; a path outside the base is refused.

- [ ] **Step 2: Run** `test-supervisor-driver.sh`, `test-supervisor-scheduler.sh`, `test-supervisor-resolver.sh`, `test-supervisor-roles.sh`, the suite that runs `candidates_cases.py`, `test-worktree.sh` and `test-board-local.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement.** `_do_check_premise` follows `_dispatch_merger`'s shape (resolve, build inputs, `role_prompt`, `_launch`) with no persona guard.
- [ ] **Step 4: Run** the same suites. Expected: all pass.
- [ ] **Step 5: Commit.**

### Task 5: The `needs` verdict

**Files:**
- Modify: `scripts/premise.sh` (add `add-dep`), `tests/test-premise.sh`, `scripts/supervisor/driver.py`, `scripts/supervisor/scripts.py` (only if a flag is added), `fixtures/supervisor/driver_cases.py`

**Interfaces:**
- Consumes: `CardDriver._settle_premise` (Task 4); parsed `card` (Task 3).
- Produces: `premise.sh add-dep <n> <m>`: appends `<m>` to card `<n>`'s `blocked_by` if absent, keeping the rest; refuses `<m>` equal to `<n>` or a missing card (exit 2), as the store already refuses on write.
- Produces: `CardDriver._premise_needs(c, parsed) -> Outcome`. In-flight states: `ready`, `in_progress`, `in_review`, any `review_*`, `merging`, `human_qa`.
- Produces: `CardDriver._premise_question(c, text, proposal=None)`, which Task 6 extends. In this task it moves the card to Blocked, writes the note as the other blockers do (`dict(_RESET, state='blocked', blocked_from='ready')`), and posts one comment starting `Waiting for a person: the premise check could not settle this card.` followed by `text`.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-premise.sh`: `add-dep 12 40` on `blocked_by: [7]` gives `[7, 40]`; repeating it changes nothing; `add-dep 12 12` and `add-dep 12 999` exit 2.

In `fixtures/supervisor/driver_cases.py`:

```
test_needs_adds_the_dependency_and_leaves_the_card_ready
    needs #40, #40 in_review -> ('premise.sh', 'add-dep', n, 40);
    comment == 'Premise check: needs #40, which is in_review. Added as a dependency.'; no board-move; no stamp
test_needs_a_card_already_listed_changes_nothing_and_asks
    #40 already in blocked_by -> no add-dep; question text names #40
test_needs_a_backlog_card_asks        #40 backlog -> _premise_question, text 'needs #40, which is backlog'
test_needs_a_closed_card_asks         done, wont_do
test_needs_a_missing_card_asks        text 'needs #999, which does not exist'
test_needs_itself_asks
test_needs_a_card_that_depends_on_this_one_asks
    #40.blocked_by == [n], and the two-hop case (#40 -> #41 -> n)
test_a_question_resets_the_failure_count_and_records_blocked_from_ready
```

- [ ] **Step 2: Run** `test-premise.sh` and `test-supervisor-driver.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement.** Walk `blocked_by` from #n with a visited set to find a cycle.
- [ ] **Step 4: Run** both suites. Expected: pass.
- [ ] **Step 5: Commit.**

### Task 6: `built`, `stale`, and the owner's decision

**Files:**
- Create: `scripts/premise-settle.sh`, `tests/test-premise-settle.sh`
- Modify: `scripts/supervisor/driver.py`, `scripts/supervisor/scripts.py`, `fixtures/supervisor/driver_cases.py`, `scripts/adapters/local/move.sh`, `scripts/config-defaults.json`, `tests/test-config.sh`, `hooks/gate.sh`, `hooks/gate-lex.awk` (if the lexer needs the new command), `tests/test-gate.sh`, `README.md` (the `## Gates` list)

**Interfaces:**
- Consumes: `CardDriver._premise_question` (Task 5); parsed `evidence`, `summary`, `proposal` (Task 3); `premise.sh stamp`, `fl_scope_text` (Task 1).
- Produces: card field `proposal`: `null`, or `{kind: "rewrite", scope: string, acceptance: [string, ..], summary: string, head: <40-hex>, at}` or `{kind: "close", evidence: [{item: <number>, command, output}], head, at}`.
- Produces: `premise-settle.sh propose <n> <json-file>`, the driver's only use of the script (add `premise-settle.sh` to `scripts.ALLOWED`).
- Produces: `premise-settle.sh approve <n>`: the card must be Blocked with a `rewrite` proposal whose scope yields a path. In this order: replace the body's `## Scope` section with the proposal's scope (add the section when the body has none), replace the acceptance, keep `blocked_by`, clear `proposal`, move the card to Ready, then stamp `--by approve --sha <proposal.head>`. The stamp comes after the move, because the move itself stamps `by: move`; it carries the head the session saw, so files that changed since the proposal was written still trigger a check. To test a proposed scope for paths, wrap the text under a `## Scope` heading before `fb_card_scope_paths`, which reads only under that heading.
- Produces: the default of `premise_check.enabled` becomes `true` in `scripts/config-defaults.json`. From this task every verdict is handled, so the check is safe to run everywhere. `tests/test-premise-settle.sh` starts with `unset FLEET_BOARD_ACTOR`.
- Produces: `premise-settle.sh confirm <n>`: the card must be Blocked with a `close` proposal. Adds label `fleet:closed-as-built`, clears `proposal`, moves the card to Done, and appends `{card, decision: "confirmed", at}` to `<board.dir>/premise-decisions.jsonl` (beside `usage.jsonl`, so it is per repository).
- Produces: `premise-settle.sh reject <n>`: clears `proposal` and appends `decision: "rejected"`. `move.sh` does the same when a card with a proposal leaves Blocked by a person's move (not with `FLEET_BOARD_ACTOR=supervisor`), so "move it back to Ready" is a rejection.
- Exit codes: 0 done; 1 the card is not Blocked, has no proposal of that kind (`card #<n> has no <rewrite|close> proposal to <approve|confirm>`), or the proposed scope names no path (`card #<n>: the proposed Scope names no repository path`); 2 usage; 3 card unreadable.
- Produces: gate rule G4: a Bash command in a Claude session that runs `premise-settle.sh approve`, `confirm` or `reject` is blocked with `fleet-board gate: only a person approves or confirms a premise proposal; run it in a terminal or use the board page`. `propose` is not blocked.

- [ ] **Step 1: Write the failing tests.**

`tests/test-premise-settle.sh`:

```
approve replaces Scope and acceptance, keeps blocked_by, lands in ready, proposal null, stamp by == "approve" and sha == proposal.head
approve on a body with no ## Scope adds the section
approve on a Ready card / a close proposal / no proposal -> exit 1, the exact message, card unchanged
approve of a proposal whose scope has no path -> exit 1, the exact message, card unchanged
confirm -> done, label present, proposal null, one "confirmed" line in <board.dir>/premise-decisions.jsonl
confirm on a rewrite proposal -> exit 1
reject -> proposal null, state unchanged, one "rejected" line
a person's board-move.sh <n> ready on a card with a proposal -> proposal null, one "rejected" line, stamp by move
FLEET_BOARD_ACTOR=supervisor board-move.sh of that card -> proposal kept
propose with a malformed file (acceptance not a list, kind unknown) -> exit 2, nothing written
```

`fixtures/supervisor/driver_cases.py`:

```
test_built_blocks_with_the_evidence_and_never_closes
    built, evidence for items 1 and 2 of a two-item card -> ('premise-settle.sh', 'propose', n, <file>) with kind close;
    moved to blocked, never to done; comment starts 'Waiting for a person: close as already built?' and lists
    each acceptance item's text with its command and output
test_built_missing_evidence_for_an_item_is_a_plain_question
    evidence for item 1 only -> no proposal; comment starts
    'Waiting for a person: the premise check could not settle this card.'
test_built_evidence_for_an_item_number_the_card_lacks_is_a_plain_question
test_stale_with_a_proposal_blocks_with_the_rewrite
    comment starts 'Waiting for a person: approve this rewrite?', shows the summary, then current and proposed
    Scope and acceptance; proposal kind rewrite stored
test_stale_without_a_proposal_blocks_with_the_summary
test_no_verdict_stamps_except_go
```

`tests/test-config.sh`: the default of `premise_check.enabled` is now `true`. Then run `bash plugins/fleet-board/tests/test-tick-plan.sh`, `test-stack-plan.sh` and `test-scope-reservations.sh` in Step 4: with the default on they must still print `failed: 0`, which is what Task 2's `setup_case` change is for.

`tests/test-gate.sh`: `bash …/premise-settle.sh approve 12`, `confirm 12` and `reject 12` are blocked with the G4 message (also behind `cd x &&` and with an absolute path); `propose 12 f.json` and `premise.sh show 12` are allowed; with no `.fleet-board.yml` the gate is inert.

- [ ] **Step 2: Run** the three suites. Expected: the new cases fail.
- [ ] **Step 3: Implement.** Add G4 to the README's `## Gates` residuals: a script file that calls `premise-settle.sh`, and a direct POST to the board page's premise routes (Task 7), are not seen by the gate.
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
- Page: a Blocked card with a proposal shows it at the top of the drawer. Rewrite: the summary, then current and proposed Scope and acceptance side by side, with buttons `Approve rewrite` and `Reject`. Close: each acceptance item with its command and output, with buttons `Close as built` and `Build it anyway` (a move to Ready, which rejects the proposal). The tile shows `Rewrite proposed` or `Already built?`.

- [ ] **Step 1: Write the failing tests.** In `tests/test-board-web.sh`: the three routes call the right verb; a failing verb gives 409 with the stderr text; the card and board payloads carry the new keys; a card with a malformed proposal reports `proposal: null`. In `tests/test-board-drawer-premise.sh` (DOM harness): each proposal kind renders its buttons with the exact labels; a card with no proposal renders neither; pressing a button posts to its route once and is disabled while the request is open.
- [ ] **Step 2: Run** both suites. Expected: the new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both suites. Expected: pass.
- [ ] **Step 5: Commit.**

### Task 8: Follow-ups are drafted

**Files:**
- Modify: `scripts/file-followups.sh`, `scripts/board-create.sh`, `scripts/adapters/local/create.sh`, `scripts/adapters/local/read.sh`, `scripts/adapters/local/list.sh`, `tests/test-board-local.sh`, `scripts/premise.sh`, `scripts/tick-plan.sh`, `scripts/config-defaults.json`, `scripts/config.sh`, `scripts/supervisor/driver.py`, `scripts/supervisor/state.py`, `scripts/supervisor/scheduler.py`, `scripts/supervisor/resolver.py`, `scripts/supervisor/scripts.py`, `scripts/supervisor/defaults/premise-check-prompt.md`, `tests/test-followups.sh`, `tests/test-premise.sh`, `tests/test-tick-plan-followups.sh`, `tests/test-config.sh`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/state_cases.py`, `fixtures/supervisor/scheduler_cases.py`

**Interfaces:**
- Consumes: the session, prompt and report of Tasks 3 and 4 in mode `draft`; `premise.sh stamp`, `worktree.sh premise`; `card-lint.sh`.
- Produces: config `followups.auto_ready` (`"bugs"` default, or `"none"`; refused otherwise with `followups.auto_ready must be bugs or none`) and `followups.auto_ready_cap` (non-negative integer, default 5). `followups.status` keeps its meaning.
- Produces: card field `followup`: `null`, or `{draft: "pending"|"done"|"failed", kind: "bug"|"out_of_scope", entry: <object>, from: <card number>}`. `entry` is the parsed item `file-followups.sh` receives: `{title, detail}` for an out-of-scope item, `{title, repro, expected, observed}` for a bug.
- Produces: `board-create.sh` and `create.sh` accept `--followup-file <json-file>` and store it as `followup` (`board-create.sh` refuses unknown flags, so it needs its own branch for this one). `read.sh` returns `followup`; its output is a fixed projection, so without this the driver cannot see the record. `list.sh` rows gain `followup_draft` (the `draft` value or null), so the planner finds pending cards in its one existing listing pass.
- Produces: `scripts.ALLOWED` gains `card-lint.sh`, called with `c.soft` because it exits 1 on a lint failure. `ROLE_ACTIONS`, `_ROLE_OF` (`draft_followup -> 'checker'`), the scheduler's `_ACTION_CLASS` and `SCOPE_FREE_ACTIONS` gain `draft_followup`.
- Produces: `premise.sh apply-draft <n> <json-file>`: from `{why, scope, acceptance: [..]}` writes the body as `## Why` and `## Scope` sections, replaces the acceptance and sets `followup.draft` to `done`. `premise.sh set-followup <n> <draft-value>`: sets `followup.draft`. Neither stamps.
- `file-followups.sh`, with `premise_check.enabled` true: files every new card in Backlog with `--followup-file` and `draft: "pending"`, whatever `followups.status` says, and posts neither of today's two "Filed in Backlog" comments. With it false: exactly today's behaviour, and no `followup` field. The "main is red" card `verify-main.sh` files is untouched in both cases.
- Planner: `tick-plan.sh` lists `ready in_progress in_review <stages> merging blocked` today, and a Backlog card that reached `decide` would be a `skip`. With `premise_check.enabled`, also list Backlog, but keep only rows whose `followup_draft` is `"pending"` before any per-card read, so the cost does not grow with the Backlog. Such a card plans `draft_followup` (reason `follow-up awaits a draft`); the action is scope-free and resolves like `check_premise`.
- Produces: `State.followups_auto_ready` (integer, starts at 0 each supervisor run), `State.take_auto_ready(cap) -> bool` (true and counts one when under the cap), and `followups_auto_ready: {count, cap}` in the snapshot.
- The draft prompt adds to Task 4's inputs: the `entry` object, the filing card's number, and every card on the board in every state as `#<n> <state> <title>` lines (closed ones included, since #374 duplicated #361).
- Driver, by draft verdict:
  - `duplicate` #n: #n must exist and not be the card itself, else a failed draft. Move the card to Won't do; comment `Follow-up draft: duplicate of #<n>.`
  - `fixed`: move to Won't do; comment `Follow-up draft: already fixed on the default branch.` followed by the evidence line.
  - `drafted`: run `premise.sh apply-draft`, then `card-lint.sh <n>`, then stamp `--by check --sha <head>`. Move to Ready only when all hold: `followup.kind == "bug"`; `repro.result == "failed"`; the lint passed; `followups.auto_ready == "bugs"`; `State.take_auto_ready(cap)` returns true. Otherwise the card stays in Backlog with one comment giving the first reason that failed: `Drafted; left in Backlog: <not a bug report | the repro did not fail on the default branch | no repro was run | card lint failed: <rules> | followups.auto_ready is none | this run's cap of <cap> is used>.` (A draft whose scope names no path is already rejected by `parse-report.sh`, Task 3.)
  - A failed draft (empty reply, rejected twice, bad verdict): when the card's `action_failures` reach `max_rounds`, run `premise.sh set-followup <n> failed` and post `Follow-up draft failed after <count> attempts; left as filed. A person writes the criteria and moves it to Ready.` The card stays as mechanically filed and is not planned again.

- [ ] **Step 1: Write the failing tests.**

`tests/test-followups.sh`: with the check enabled, a bug item and an out-of-scope item both land in Backlog with `followup.draft == "pending"`, the right `kind`, `from`, and `entry` equal to the input item, and no Backlog comment; with it disabled, the existing assertions hold unchanged and `.followup` is absent; an item linked to an existing card creates nothing, as today.

`tests/test-board-local.sh`: `board-read.sh` returns a card's `followup`, and a `board-list.sh` row carries `followup_draft`.

`tests/test-premise.sh`: `apply-draft` writes the Why and Scope sections and the acceptance, sets `draft` to `done` and leaves the stamp alone; a file whose acceptance is not a list exits 2; `set-followup 12 failed` sets it and `set-followup 12 nonsense` exits 2.

`tests/test-tick-plan-followups.sh` (cases enable the check): `followup-pending` -> `draft_followup`; a Backlog card with `draft` done or failed, or with no `followup`, has no row; `followup-pending` with the check disabled has no row.

`tests/test-config.sh`: the two keys, their defaults and the refusal message; a negative or non-integer cap is refused.

`fixtures/supervisor/state_cases.py`: `take_auto_ready(2)` is true, true, false; the snapshot shows `{count: 2, cap: 2}`; a new `State` starts at 0.

`fixtures/supervisor/driver_cases.py`:

```
test_the_draft_prompt_carries_the_entry_and_every_card     closed cards included
test_draft_duplicate_closes_with_a_link
test_draft_duplicate_of_itself_or_a_missing_card_is_a_failed_draft
test_draft_fixed_closes_with_the_evidence
test_drafted_bug_with_a_failing_repro_goes_to_ready
    ('premise.sh', 'apply-draft', n, <file>) carries the Why, Scope and acceptance; stamp by check; board-move to ready; count is 1
test_drafted_out_of_scope_stays_in_backlog          comment '... not a bug report.'
test_drafted_bug_whose_repro_passed_stays           '... the repro did not fail on the default branch.'
test_drafted_bug_with_no_repro_stays                '... no repro was run.'
test_drafted_bug_failing_lint_stays                 '... card lint failed: <rules>.'
test_auto_ready_none_keeps_every_draft_in_backlog   '... followups.auto_ready is none.'
test_the_cap_admits_exactly_one_of_two_drafts_finishing_together
    cap 1, two drafted bugs settled in one cycle -> one ready, the other '... this run's cap of 1 is used.'
test_cap_zero_sends_nothing_to_ready
test_a_draft_that_keeps_failing_is_marked_failed_and_left_as_filed
```

- [ ] **Step 2: Run** the suites named above. Expected: the new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the suites, then `bash plugins/fleet-board/tests/test-tick-plan.sh` (the planner now reads another column). Expected: pass.
- [ ] **Step 5: Commit.**

### Task 9: Seeing what the check did, and the docs

**Files:**
- Modify: `scripts/supervisor/driver.py`, `scripts/supervisor/state.py`, `scripts/supervisor/cli.py`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/state_cases.py`, `fixtures/supervisor/dump_real_shapes.py`, `README.md`, `skills/init/SKILL.md` (only if it lists config keys)
- Create: `tests/test-premise-docs.sh`

**Interfaces:**
- Consumes: every verdict path of Tasks 4, 5, 6 and 8.
- Produces: one event per settled verdict, text `premise #<n>: <verdict> -> <what was done>`, where the second part is one of `stamped`, `depends on #<m>`, `asked: close as already built`, `asked: approve rewrite`, `asked: could not settle`, `closed as duplicate of #<m>`, `closed as already fixed`, `drafted, to Ready`, `drafted, in Backlog`.
- Produces: snapshot key `premise: {checked, go, needs, built, stale, drafted, failed}` (counts for this run). The count of follow-ups sent to Ready stays only in Task 8's `followups_auto_ready`. `supervisor status` prints both as one line `Premise checks: <checked> run, <go> go, <needs> needs, <built> built, <stale> stale; follow-ups: <drafted> drafted, <auto_ready> of <cap> to Ready`.
- The usage ledger already records each session's role and column, so `supervisor usage` and the board's column totals include checker sessions with no change here.

- [ ] **Step 1: Write the failing tests.** Driver cases: each verdict test from earlier tasks also asserts its event text. State cases: the counts and the snapshot key. The supervisor CLI suite: the status line above. `tests/test-supervisor-ui.sh` shapes: regenerate through `dump_real_shapes.py` so the page's harness sees the new snapshot keys. `tests/test-premise-docs.sh`: the README has a `## Premise check` section naming `premise_check.enabled`, `models.checker`, `followups.auto_ready`, `followups.auto_ready_cap`, `premise-settle.sh approve`, `premise-settle.sh confirm` and `fleet:closed-as-built`.
- [ ] **Step 2: Run** the driver, state, CLI and UI suites and `test-premise-docs.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement,** and write the README section: what a stamp is, when a check runs, the four verdicts and what happens for each, how to approve, confirm or overrule (move the card to Ready), the follow-up rules and the two config keys, and how to turn it all off.
- [ ] **Step 4: Run** the same suites. Expected: pass.
- [ ] **Step 5: Commit.**

## After the last task

- Move plan card #469 to Won't do with a link to this plan.
- Confirm the shipped default of `premise_check.enabled` is `true` (Task 6 flips it) and that the repo's own `.fleet-board.yml` does not turn the check off; the design requires it on here.
- One live behavioural scenario for the check session (`behavioral-*.sh` style, against `SANDBOX_REPO`): a card whose acceptance already holds gets `built` with evidence; a card naming a moved file gets `stale` with a proposal. It costs usage, so run it only when the owner asks.
- After a week of runs, measure against the spec's "How we will know it worked": blocked reports that say the acceptance already exists or a dependency is unmerged; the share of follow-ups a person had to rewrite; `checker` session time against the implementor time those blocks used to cost; and the confirmed-to-rejected ratio in `premise-decisions.jsonl`, which decides whether closing can later go unattended.
- Tell the owner to restart the Claude app, the supervisor and the board page after the plugin updates.
