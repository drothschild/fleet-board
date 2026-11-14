# Stacked Pull Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A card with one unmet dependency starts once that dependency's PR is in review, builds on its branch, and lands after it as its own squash commit.

**Architecture:** The planner (`tick-plan.sh`) decides everything: it plans a stacked `start`, an `update_branch` when the parent's branch moves, a `wait` after review, and a new script action `land` when the parent has merged. The child's manager note carries `stack` while it is stacked and `landed` afterwards. Landing adds one "bridge" merge commit that joins the child to the parent's squash commit, computed with the parent's final head as the merge base; after it, the ordinary `update-branch.sh` path works unchanged. No agent file changes.

**Tech Stack:** bash 3.2 + jq (scripts), git 2.40 or later for `git merge-tree --write-tree --merge-base` (checked at run time), Python 3 standard library (supervisor), plain-bash and `unittest`-style fixture suites.

**Spec:** `docs/specs/2026-11-13-stacked-prs-design.md`. Read it and `plugins/fleet-board/CLAUDE.md` before any task.

## Global Constraints

- All paths below are relative to `plugins/fleet-board/` unless they start with `docs/` or `.claude-plugin/`.
- `stacking.enabled` defaults to `false`. With it off, every plan row, script exit code and note is the same as before this plan. Each task's suite has one case that proves this for what the task adds.
- Never rebase, never force-push, never `git reset --hard` a pushed branch. Every change to a branch is a new commit and a plain `git push`.
- A child PR is never merged while its base is not the default branch.
- Default branch: `origin/HEAD`, else `origin/main` (as `worktree.sh` resolves it today).
- Clean-room files (`agents/*.md`, `skills/{reporting,status}/SKILL.md`) are not edited. This plan needs no change to them.
- New note fields that hold a branch or a sha are validated in `note.sh` like `branch` and `last_review.sha`; an invalid one makes the note invalid.
- A new `gh` call in `tick-plan.sh` is made only for a card that is stacked or is a stack candidate, never for every card.
- Any check that decides "already reviewed" or "safe to land" fails closed: a lookup that fails reads as unreviewed, or as wait.
- Bash 3.2, BSD and GNU tools: no bash 4 features, `sed -i.bak`, `unset CDPATH` before `cd`, `LC_ALL=C` for awk decimals. Python standard library only. No new dependencies.
- One PR per task: branch from current `origin/main`, draft PR opened before any code. The first commit holds only the failing test; the implementation commit bumps `.claude-plugin/plugin.json` (in the plugin) and the fleet-board entry of the repo's `.claude-plugin/marketplace.json` one patch above `origin/main`.
- Run only the suite the task names, then `bash plugins/fleet-board/tests/test-clean-room.sh` and `bash plugins/fleet-board/tests/test-version-bumped.sh` (no `not ok` line) before pushing. Never the full suite.
- Every new suite is shown to fail before it is trusted (the test-first commit does this).
- Adversarial code review before each merge. Re-fetch before acting on PR state.
- Each task updates the matching contract lines in `plugins/fleet-board/CLAUDE.md` for what it adds.
- User-visible copy, exact: `waits for #N to merge`, `stacked on #N`, `stacked on #N, which was closed without merging; a person decides`, `landing needs attention: <reason>; a person decides`, `stacking needs git 2.40 or later`.

## Before Task 1: re-check the plan against the code

This plan was written against local `main` at `bec01334` (plugin 0.29.65) on 2026-11-13. Fetch
`origin/main`, re-read each task's Files and Interfaces blocks against the code, correct this
plan, and show the owner the corrections. In particular:

- **#284, #285, #290 (parallel review), Ready on 2026-11-13.** If landed, `review_<stage>`
  columns may be gone and "clean review" means every reviewer is clean. Restate Task 5's hold
  ("after a clean review") and Task 3's list of parent states in the new terms.
- **#365 (single-card plan).** If landed, check that a single-card plan of a stacked child
  still reads its parent's state.
- **`docs/plans/2026-11-13-per-card-controls.md`.** If its tasks landed, a held card
  (`operator_hold`) is dropped before admission; check `land` is dropped the same way.
- **How the board page shows a wait reason.** Task 8 assumes the drawer shows the plan row's
  reason for a waiting card (#352). If it does not, Task 8 adds that.

## Review Focus

1. **The fetched default branch does not contain the parent's squash commit yet** (stale fetch). Expected: landing waits and changes nothing; it never produces a merge that removes the parent's change. (Task 7.)
2. **The parent is closed as won't-do, or its PR is closed unmerged.** Expected: the child is held with `stacked on #N, which was closed without merging; a person decides`; nothing is retargeted, rebuilt or closed. (Task 5.)
3. **Stacking is off.** Expected: a Ready card whose only dependency is in review waits with today's reason, and no row carries a `stack` key. (Task 3.)
4. **git older than 2.40.** Expected: `stack-bridge.sh` exits 4 with `stacking needs git 2.40 or later`; it never falls back to a plain merge. (Task 1.)
5. **The parent's branch was deleted on merge before the child landed.** Expected: landing reads the parent's final head from `refs/pull/<pr>/head` and succeeds. (Task 7.)

---

### Task 1: The bridge merge

Proves the centre of the design on real git before anything depends on it.

**Files:**
- Create: `scripts/stack-bridge.sh`
- Test: `tests/test-stack-bridge.sh` (real git in temp repos, no network, no gh)

**Interfaces:**
- Produces: `stack-bridge.sh tree <repo> <parent-head> <ours> <theirs>` prints the tree sha of merging `<theirs>` into `<ours>` with `<parent-head>` as the merge base (`git merge-tree --write-tree --merge-base`). Exit 0 printed; 3 the merge conflicts (conflicted paths, one per line, on stdout); 4 git older than 2.40; 1 any other git failure; 2 usage.
- Produces: `stack-bridge.sh commit <worktree> <parent-head> <squash-sha>` creates a merge commit with parents `HEAD` and `<squash-sha>`, the tree from `tree`, message `Bridge to the squash of <parent-head short> (<squash short>)`, and moves the checked-out branch and working tree to it. Prints the new head. Refuses (exit 1) unless `<parent-head>` is an ancestor of `HEAD` and the worktree has no changes to tracked files. When `<squash-sha>` is already an ancestor of `HEAD` it prints `HEAD` and exits 0. Same exit codes as `tree`; on 3 or 4 nothing is changed. It never pushes.

- [ ] **Step 1: Write the failing suite.** Each case builds a repo with `main`, a parent branch, and a child branch cut from the parent; squash-merges the parent into `main` with `git merge --squash` + `git commit`; then asserts. Cases, by name:
  - `plain merge conflicts`: parent changed line 1 of `a.txt` to `P`, child changed it again to `C`. `git merge main` on the child exits non-zero (this shows the problem exists).
  - `bridge keeps the child's edit`: same repo. `commit` exits 0; `a.txt` line 1 is `C`; the new commit has two parents, the second is the squash; `git merge main` afterwards says already up to date.
  - `child followed a later parent commit`: parent got a second commit, child merged it, then the squash. `commit` exits 0 and the tree equals the child's tree before the bridge.
  - `unrelated change on main`: `main` gained `b.txt` before the squash and the parent never merged it. After `commit`, `b.txt` exists and `a.txt` line 1 is `C`.
  - `main change conflicts with the child`: `main` changed line 5 of `a.txt` before the squash, the child changed line 5 too, the parent did not. `commit` exits 3, prints `a.txt`, and `HEAD` and the working tree are unchanged.
  - `parent head not in the child`: `commit` exits 1, nothing changed.
  - `already bridged`: a second `commit` prints the same head and adds no commit.
  - `dirty worktree`: exits 1, nothing changed.
  - `old git`: with a stub `git` first on `PATH` that answers `--version` with `git version 2.39.5` and passes everything else through, `commit` exits 4 and stderr holds `stacking needs git 2.40 or later`.
  - `tree matches commit`: `tree` on the same inputs prints the tree of the commit `commit` made.
- [ ] **Step 2: Run it and see it fail.** Run: `bash plugins/fleet-board/tests/test-stack-bridge.sh`. Expected: every case FAILs with "No such file".
- [ ] **Step 3: Commit the suite alone.**
- [ ] **Step 4: Implement `scripts/stack-bridge.sh`.** Read the version from `git --version`. Build the commit with `git commit-tree <tree> -p HEAD -p <squash>` and move the branch with `git merge --ff-only <new>` so the working tree follows.
- [ ] **Step 5: Run the suite.** Expected: no `FAIL` line.
- [ ] **Step 6: Bump versions, add the contract line to `CLAUDE.md`, commit, push.**

### Task 2: The switch and the note fields

**Files:**
- Modify: `scripts/config-defaults.json`, `scripts/config.sh` (only if it validates keys), `scripts/note.sh` (`DEFAULTS` at line 118 and the validation chain at line 143), `docs/config.md`
- Test: `tests/test-config.sh`, `tests/test-note.sh` (add cases; run both)

**Interfaces:**
- Produces: config `stacking: { "enabled": false }`; `fb_cfg stacking.enabled` prints `true` or `false`. Any other value is a config error, like other booleans.
- Produces: note field `stack`, default `null`, else `{parent: <positive integer>, base: <string matching the note's branch rule, fleet/<n>-<slug>>, start: <40-hex sha>, attention: <null or a control-character-free string of at most 300 characters>}`.
- Produces: note field `landed`, default `null`, else `{parent: <positive integer>, parent_head: <40-hex>, squash: <40-hex>, sha: <40-hex>}`.

- [ ] **Step 1: Write the failing cases.** `test-config.sh`: default is `false`; `stacking: { enabled: true }` reads `true`; `enabled: "yes"` is refused. `test-note.sh`: a note with a valid `stack` round-trips through `put` and `get`; each of these makes `get` treat the note as `{}` with a warning naming `stack`: `parent: "7"`, `base: "main"`, `base: "fleet/7-x; rm -rf ~"`, `start: "abc"`, `attention` holding a newline, `stack: "yes"`. The same for `landed` with a short `squash`. `note.sh merge` with `{"stack": null}` clears it.
- [ ] **Step 2: Run both suites; see the new cases fail.**
- [ ] **Step 3: Commit the tests alone.**
- [ ] **Step 4: Implement.** Add the config default and the two note fields with their validation.
- [ ] **Step 5: Run both suites.** Expected: no `FAIL` line.
- [ ] **Step 6: Document `stacking.enabled` in `docs/config.md`; add the note fields to the Manager note lines of `CLAUDE.md`; bump; commit; push.**

### Task 3: Planning a stacked start, and the scope exemption

**Files:**
- Modify: `scripts/tick-plan.sh` (the dependency gathering near line 648, the Ready rows near line 930, the Scope check near line 1068, the candidates row near line 1150, the header comment), `scripts/supervisor/scheduler.py` (the reservation and occupied checks near line 359), `scripts/supervisor/state.py` (`reserve`, line 161)
- Test: `tests/test-stack-plan.sh` (new; offline with `tests/fake-gh.sh` and the local store helpers, as `tests/test-tick-plan.sh` does), `fixtures/supervisor/scheduler_cases.py` and `fixtures/supervisor/state` cases run by `tests/test-supervisor-scheduler.sh` and `tests/test-supervisor-state.sh`

**Interfaces:**
- Consumes: `fb_cfg stacking.enabled`, note `stack` (Task 2).
- Produces: a plan row for a stacked start: `action: "start"`, `reason: "ready, stacked on #<parent>"`, and `stack: {parent: <n>, base: "<parent branch>", ancestors: [<n>, ...]}`. `ancestors` is the parent followed by each further `stack.parent` read from the notes up the chain (stop after 20 hops or on a repeat). Every other row has `stack: null`. A candidates row (`--candidates`) carries the same `stack` key.
- Produces: `State.reserve(card, paths, ignore=None, exempt=())`: owners in `exempt` are not overlap-checked.

The start rule (spec section 2), all required: `stacking.enabled` is true; the card would otherwise `wait` on dependencies; `deps_unmet` has exactly one entry; its `status` is `in_review`, `human_qa`, `merging` or starts with `review_`; the parent's note (`note.sh get <parent>`) has a valid `branch` and `pr`; `gh pr view <pr> --json state` says `OPEN`. A failed lookup means the card waits with today's reason.

- [ ] **Step 1: Write the failing suite `test-stack-plan.sh`.** Cases:
  - `off: waits as today`: stacking off, card 12 depends on card 11 (in review, open PR 50). Row 12 is `wait`, reason `waits for acme/toy#11 (in_review)`, `stack` is `null`.
  - `on: starts stacked`: same board, stacking on. Row 12 is `start`, `stack` is `{"parent":11,"base":"fleet/11-parent","ancestors":[11]}`.
  - `parent in progress`: parent state `in_progress`. Row 12 waits.
  - `two unmet`: card 12 depends on 11 and 10, both in review. Waits.
  - `one unmet of two`: 10 is done, 11 in review. Starts stacked on 11.
  - `parent PR closed`: `gh pr view` says `CLOSED`. Waits.
  - `parent note has no branch`: waits.
  - `cycle`: 11 and 12 block each other. Waits with the cycle reason.
  - `grandchild`: 11 in review, 12 in review with `stack.parent` 11, 13 Ready depending on 12. Row 13 starts with `ancestors` `[12, 11]`.
  - `scope: parent does not hold the child`: 12's `## Scope` names `src/a.sh`, and PR 50 touches `src/a.sh`. Row 12 is `start`.
  - `scope: a stranger still holds the child`: card 20, in progress, unrelated, PR touching `src/a.sh`. Row 12 is `wait` with `Scope overlaps #20 on src/a.sh`.
  - `scope: siblings`: 12 and 14 both Ready, both depending on 11, both naming `src/a.sh`. 12 starts, 14 waits with `Scope overlaps #12 on src/a.sh`.
  - `gh call count`: with no Ready card that has exactly one unmet dependency, the fake gh log has no extra `pr view --json state` call.
- [ ] **Step 2: Write the failing supervisor cases.** `scheduler_cases.py`: a candidate with `stack.ancestors == [11]` whose paths overlap a reservation held by card 11 is admitted; the same candidate against a reservation held by card 20 waits with `scope reserved by #20`; the same against an occupied row for card 11 is admitted. State cases: `reserve(12, paths, exempt=(11,))` succeeds over card 11's overlapping reservation and fails over card 20's.
- [ ] **Step 3: Run the three suites; see the new cases fail. Commit the tests alone.**
- [ ] **Step 4: Implement in `tick-plan.sh`.** Gather the parent's note and PR state only for a Ready card with exactly one unmet dependency when stacking is on. Exempt `stack.ancestors` in the Ready-card Scope check.
- [ ] **Step 5: Implement in the scheduler and `State.reserve`.** The scheduler reads `c.get('stack')` and skips reservations and occupied rows whose card is in `ancestors`; the loop passes `exempt` when it reserves for a started row.
- [ ] **Step 6: Run the three suites.** Expected: no `FAIL` line, and each Python suite prints its usual pass summary.
- [ ] **Step 7: Update the Dependency gate and Scope reservations lines in `CLAUDE.md`; bump; commit; push.**

### Task 4: Starting the child on the parent's branch

**Files:**
- Modify: `scripts/worktree.sh` (`create`, near line 152), `scripts/supervisor/driver.py` (`_do_start` line 650, `_do_start_review` line 672)
- Test: `tests/test-worktree.sh` (add cases), `fixtures/supervisor/driver_cases.py` run by `tests/test-supervisor-driver.sh`

**Interfaces:**
- Consumes: plan row `stack` (Task 3), note `stack` (Task 2).
- Produces: `worktree.sh create <n> <branch> <path> [<start-branch>]`. With `<start-branch>` (must match `fleet/<n>-<slug>`, else exit 2), a branch that does not exist yet locally or on origin is created from `origin/<start-branch>`; exit 1 with `fleet-board: origin/<start-branch> does not exist` when it is missing. When the branch already exists, `<start-branch>` is ignored. Without it, behaviour is unchanged.
- Produces: after a stacked `start`, the child's note has `stack: {parent, base, start: <sha of origin/<base> at creation>, attention: null}`.
- Produces: a stacked card's `start_review` runs `gh pr edit <pr> --repo <repo> --base <stack.base>` before `review-stages.sh route`, so routing and review see only the child's files. The implementor still opens its PR against the default branch; this step retargets it.

- [ ] **Step 1: Write the failing `test-worktree.sh` cases.** `create with a start branch` puts the new branch at `origin/fleet/11-parent`'s head; `start branch missing` exits 1 with the message and leaves no worktree and no branch; `existing branch ignores the start branch` leaves its head where it was; `bad start branch name` (`main`, `fleet/x; id`) exits 2.
- [ ] **Step 2: Write the failing driver cases.** A `start` row with `stack` calls `worktree.sh create 12 <branch> <path> fleet/11-parent` and merges a note patch whose `stack.parent` is 11, `stack.base` is `fleet/11-parent`, and `stack.start` is the sha the stubbed `git rev-parse origin/fleet/11-parent` returned. A `start` row with `stack: null` makes the same calls as today (assert the exact argument list). A `start_review` for a card whose note has `stack` calls `gh pr edit 51 --repo acme/toy --base fleet/11-parent` before `review-stages.sh route`; a failed edit fails the action and `route` is not called. A `start_review` for a card without `stack` makes no `gh pr edit` call.
- [ ] **Step 3: Run both suites; see the new cases fail. Commit the tests alone.**
- [ ] **Step 4: Implement `worktree.sh create`'s fourth argument.**
- [ ] **Step 5: Implement the driver changes.**
- [ ] **Step 6: Run both suites.** Expected: no `FAIL` line.
- [ ] **Step 7: Update the `worktree.sh` usage comment and `CLAUDE.md`; bump; commit; push.**

### Task 5: Following the parent, reviewing against it, and the hold

**Files:**
- Modify: `scripts/tick-plan.sh` (the per-card gathering, the conflict rows near line 940, the review tail near line 1030, the merging rows near line 958), `scripts/review-drift.sh` (`base_ref` / `on_base`, line 163), `scripts/worktree.sh` (`review`, line 187), `scripts/supervisor/driver.py` (the reviewer inputs near line 784), `hooks/gate.sh` (the drift lookup near line 759)
- Test: `tests/test-stack-plan.sh` (add cases), `tests/test-review-drift.sh`, `tests/test-worktree.sh`, `tests/test-gate.sh` (add cases)

**Interfaces:**
- Consumes: note `stack` (Tasks 2 and 4).
- Produces: `review-drift.sh <reviewed-sha> <head-sha> [--also-base <ref>]`. With `--also-base origin/fleet/<n>-<slug>`, a clean merge whose second parent is an ancestor of that ref counts exactly as a clean merge of the default branch does. A ref that cannot be resolved after one fetch prints `unreviewed`.
- Produces: `worktree.sh review <n> <pr> [<base-branch>]`: with the argument, `base` in the printed JSON is `merge-base origin/<base-branch> <head>`.
- Produces: plan rows for a card whose note has `stack` (stacking on or off; a stacked card is never abandoned by switching the key off):
  - parent card state `wont_do`, or the parent's PR `CLOSED`: `skip`, reason `stacked on #<parent>, which was closed without merging; a person decides`. This comes before every other row for the card except an invalid note.
  - `stack.attention` is not null: `skip`, reason `landing needs attention: <attention>; a person decides`.
  - in `in_progress` or review, PR open, and `origin/<stack.base>` exists and its head is not an ancestor of the PR head: `update_branch`, reason `parent branch <stack.base> moved`. Planned where the `CONFLICTING` row is planned, after it.
  - review is clean and current and no stage is left (the point where today's rows plan `to_human_qa`, `mark_ready` or `merge`): `wait`, reason `waits for #<parent> to merge`.
  - in `merging` (a person moved it): `skip`, reason `waits for #<parent> to merge`.
- Produces: `tick-plan.sh` and the gate call `review-drift.sh` with `--also-base origin/<stack.base>` for a card whose note has `stack`.

- [ ] **Step 1: Write the failing cases.**
  - `test-stack-plan.sh`: one case per row above, each asserting action and exact reason; `clean review, needs human QA` is `wait`, not `to_human_qa`; `clean review, draft PR` is `wait`, not `mark_ready`; `clean review, green, policy auto` is `wait`, not `merge`; `parent blocked` still plans `review` for an unreviewed child; `followed head` (PR head contains the parent branch head) plans no `update_branch`; `unstacked card` with the same review state plans `to_human_qa`, `mark_ready` and `merge` as today.
  - `test-review-drift.sh`: a clean merge of the parent branch after the reviewed sha prints `unreviewed` without `--also-base` and `reviewed` with it; a merge of the parent branch that needed conflict resolution prints `unreviewed` with it; an unresolvable `--also-base` ref prints `unreviewed`.
  - `test-worktree.sh`: `review 12 51 fleet/11-parent` prints a `base` equal to the parent branch head the child was cut from, not the `origin/main` merge-base.
  - `test-gate.sh`: for a card with `stack`, the drift lookup the gate runs includes `--also-base origin/fleet/11-parent`.
- [ ] **Step 2: Run the four suites; see the new cases fail. Commit the tests alone.**
- [ ] **Step 3: Implement `review-drift.sh --also-base` and `worktree.sh review`'s third argument.**
- [ ] **Step 4: Implement the plan rows, and pass `--also-base` from `tick-plan.sh` and the gate.** The "moved" check is local: `git merge-base --is-ancestor`, after the plan's existing throttled `git fetch origin <bases>`, which now includes each `stack.base`.
- [ ] **Step 5: The driver passes `stack.base` to `worktree.sh review`.** Add a driver case: a review of a card with `stack` calls `worktree.sh review 12 51 fleet/11-parent`.
- [ ] **Step 6: Run the four suites and `tests/test-supervisor-driver.sh`.** Expected: no `FAIL` line.
- [ ] **Step 7: Update `CLAUDE.md` (Reviewed heads, Conflicting PRs) and the `tick-plan.sh` header; bump; commit; push.**

### Task 6: Refusing a merge into a non-default base

**Files:**
- Modify: `scripts/merge-reviewed.sh` (before the `gh pr merge` at line 216), `hooks/gate.sh` (rule G2, the lookup pass), `docs/gates.md`
- Test: `tests/test-merge-reviewed.sh`, `tests/test-gate.sh` (add cases)

**Interfaces:**
- Produces: `merge-reviewed.sh` reads the PR's `baseRefName` and, when it is not the default branch name, does not merge: the card's step fails with `PR #<pr> targets <base>, not <default>; not merged`, exit 1, and no merge command is issued. A failed lookup is the same refusal.
- Produces: the gate blocks a `gh pr merge <pr>` whose PR base is not the default branch, under either policy that reaches the lookup, with `fleet-board gate: PR #<pr> targets <base>, not the default branch`.

- [ ] **Step 1: Write the failing cases.** `test-merge-reviewed.sh`: a planned merge whose fake `gh pr view --json baseRefName` answers `fleet/11-parent` exits 1 with the message and the gh log has no merge call; answering `main` merges as today; a failed lookup refuses. `test-gate.sh`: the command is blocked (exit 2) with the message when the base is `fleet/11-parent`, and passes when it is `main`.
- [ ] **Step 2: Run both suites; see the new cases fail. Commit the tests alone.**
- [ ] **Step 3: Implement both checks.** The default branch name comes from `git symbolic-ref --short refs/remotes/origin/HEAD` with the `origin/` prefix removed, else `main`.
- [ ] **Step 4: Run both suites.** Expected: no `FAIL` line.
- [ ] **Step 5: Add the rule to `docs/gates.md` and `CLAUDE.md`; bump; commit; push.**

### Task 7: Landing

**Files:**
- Create: `scripts/stack-land.sh`
- Modify: `scripts/tick-plan.sh` (a `land` row; pass `--landing` to `review-drift.sh`), `scripts/review-drift.sh`, `hooks/gate.sh` (pass `--landing`), `scripts/supervisor/scheduler.py` (line 17 action table, `SCOPE_FREE_ACTIONS` line 30, line 330), `scripts/supervisor/driver.py` (the action list at line 60, a `_do_land` beside `_do_update_branch`), `scripts/supervisor/loop.py` (line 693)
- Test: `tests/test-stack-land.sh` (new; real git with a local bare `origin`, fake gh), `tests/test-stack-plan.sh`, `tests/test-review-drift.sh`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/scheduler_cases.py`

**Interfaces:**
- Consumes: `stack-bridge.sh tree|commit` (Task 1), note `stack` and `landed` (Task 2), `update-branch.sh <n> <pr> <branch> <worktree>` (existing).
- Produces: `stack-land.sh <n> <pr-or-dash> <branch> <worktree>`. Exit 0 landed; 3 wait (nothing changed); 4 attention (nothing pushed; `stack.attention` set and one comment posted on the card); 1 failure; 2 usage. Steps, in order:
  1. Read `stack` from the note; none: exit 0, nothing to do. Read the parent's note for its `pr`. `gh pr view <parent pr> --json state,headRefOid,mergeCommit`. State not `MERGED`: exit 3.
  2. `git fetch origin`, and `git fetch origin refs/pull/<parent pr>/head`. The squash commit (`mergeCommit.oid`) is not an ancestor of the default branch head: exit 3.
  3. Walk the first-parent chain from `HEAD` down to `stack.start`. Any merge commit whose second parent is neither an ancestor of the parent's final head (`headRefOid`) nor on the default branch: exit 4, reason `the child followed commits of #<parent> that never merged`.
  4. The parent's final head is not an ancestor of `HEAD`: `git merge --no-edit <final head>`. A conflict: abort the merge, exit 4, reason `merging the final head of #<parent> conflicts in <files>`.
  5. `stack-bridge.sh commit <worktree> <final head> <squash>`. Exit 3 from it: exit 4, reason `landing on <default> conflicts in <files>`. Exit 4 from it: exit 4, reason `stacking needs git 2.40 or later`.
  6. `git push origin <branch>`; fetch; check `origin/<branch>` is the local head. A rejected push: put the branch back with `git reset --keep` to the head before step 4, exit 1 (as `update-branch.sh` does).
  7. With a PR: `gh pr edit <pr> --repo <repo> --base <default branch>`.
  8. Note: `stack: null`, `landed: {parent, parent_head, squash, sha: <bridge commit>}`.
  9. With a PR: run `update-branch.sh <n> <pr> <branch> <worktree>` and exit with its code. It merges anything else on the default branch and raises versions, and its conflicts go to the fixer by the existing path, which now works because git's own merge base is the squash.
- Produces: plan row `land`, reason `#<parent> merged; land on <default branch>`, for a card whose note has `stack` (no `attention`) when the parent card's state is `done`. It is planned in `in_progress` and review states, before the conflict, `fix`, `update_branch`, `start_review` and review rows. A stale `conflicted_files` in the note does not stop it.
- Produces: `land` is a script action that takes a slot, reserves no scope, and is never run synchronously in the driver: treated wherever `update_branch` is treated in the scheduler, the driver and the loop. `_do_land` runs `worktree.sh create` then `stack-land.sh`; exits 3 and 4 are not counted as action failures.
- Produces: `review-drift.sh <reviewed> <head> [--also-base <ref>] [--landing <parent_head>:<squash>]`. With `--landing`, a merge commit counts as reviewed when its second parent is `<squash>`, `<squash>` is on the default branch, `<parent_head>` is an ancestor of its first parent, and its tree equals `stack-bridge.sh tree <repo> <parent_head> <first parent> <squash>`. Anything else about that commit: `unreviewed`. With `--landing`, a clean merge whose second parent is an ancestor of `<parent_head>` also counts as reviewed; this covers merges of the parent branch made before the bridge, now that `stack` is cleared and the parent branch may be deleted. `tick-plan.sh` and the gate pass `--landing <landed.parent_head>:<landed.squash>` for a card whose note has `landed`.

- [ ] **Step 1: Write the failing suite `test-stack-land.sh`.** Each case builds a bare `origin`, a clone with a parent and a child worktree, and a fake gh that answers the parent PR lookup. Cases:
  - `lands`: parent squash-merged on origin's `main`. Exit 0; `origin/<child>` has the bridge commit, then whatever `update-branch.sh` added; the gh log has `pr edit 51 --base main` after the push; the note has `stack: null` and `landed` with the four values.
  - `parent not merged yet`: state `OPEN`. Exit 3; no commit, no push, no `pr edit`, note unchanged.
  - `stale default branch`: the squash exists in the clone's object store but `origin/main` does not contain it. Exit 3; nothing changed.
  - `parent branch deleted`: `origin/fleet/11-parent` removed, `refs/pull/50/head` present. Lands.
  - `child had not followed the last parent commit`: step 4 merges it; lands; the final tree holds that commit's change.
  - `followed an unmerged commit`: the child merged a parent-branch commit that is not in the final head. Exit 4; `stack.attention` is `the child followed commits of #11 that never merged`; one comment; nothing pushed.
  - `bridge conflicts`: Exit 4; attention names the file; branch head unchanged; nothing pushed; no `pr edit`.
  - `no PR` (`-`): lands; no `pr edit`; `update-branch.sh` is not run.
  - `push rejected`: exit 1; the local branch is back at its starting head; note unchanged.
  - `not stacked`: exit 0, no git or gh write.
  - `second run after landing`: exit 0, no new commit.
- [ ] **Step 2: Write the other failing cases.** `test-stack-plan.sh`: `parent done` plans `land` with the exact reason, also when the note has `conflicted_files`, also for a child with no PR in `in_progress`; `attention set` plans the skip row, not `land`. `test-review-drift.sh`: the bridge commit is `unreviewed` without `--landing` and `reviewed` with the right pair; `unreviewed` with a wrong `parent_head`, with a `squash` that is not on the default branch, and when the commit's tree differs from the computed one by one file; a clean merge of the default branch on top of the bridge is `reviewed`; a clean merge of the parent branch below the bridge is `reviewed` with `--landing` and no `--also-base`. Scheduler cases: `land` is admitted while another card holds an overlapping reservation, takes a slot, and waits at `global capacity`. Driver cases: `_do_land` calls `worktree.sh create` then `stack-land.sh 12 51 <branch> <worktree>`; exit 3 and exit 4 leave `action_failures` unchanged; exit 1 counts one failure.
- [ ] **Step 3: Run the suites; see the new cases fail. Commit the tests alone.**
- [ ] **Step 4: Implement `scripts/stack-land.sh`.** Follow `update-branch.sh` for the EXIT trap that puts the branch back, the push check and the comment.
- [ ] **Step 5: Implement `review-drift.sh --landing`.**
- [ ] **Step 6: Implement the `land` row and the `--landing` argument in `tick-plan.sh` and the gate.**
- [ ] **Step 7: Register `land` in the scheduler, the driver and the loop.**
- [ ] **Step 8: Run `tests/test-stack-land.sh`, `tests/test-stack-plan.sh`, `tests/test-review-drift.sh`, `tests/test-gate.sh`, `tests/test-supervisor-scheduler.sh`, `tests/test-supervisor-driver.sh`.** Expected: no `FAIL` line.
- [ ] **Step 9: Add a Stacking section to `CLAUDE.md` (the note fields, the rows, the landing steps, the exit codes); bump; commit; push.**

### Task 8: What the owner sees

**Files:**
- Modify: `scripts/status.sh`, `scripts/board-web.py` (the card payload), `scripts/board-web/static/board.js` (the drawer), `README.md`, `docs/config.md`, `docs/overnight.md` (if it describes dependencies)
- Test: `tests/test-status.sh`, `tests/test-board-web.sh`, `tests/test-board-js.sh`, `tests/test-readme-claims.sh` (add cases)

**Interfaces:**
- Consumes: note `stack` and `landed` (Task 2).
- Produces: `status.sh` prints `stacked on #<parent>` on the line of a card whose note has `stack`, and `landing needs attention: <reason>` when `stack.attention` is set.
- Produces: the board server's card JSON gains `stacked_on: <parent number or null>` and `stack_attention: <string or null>`; the drawer shows `stacked on #<parent>` and, when set, the attention text in the same place the hold reason is shown.

- [ ] **Step 1: Write the failing cases.** `test-status.sh`: a card with `stack` shows `stacked on #11`; with attention shows the attention line; a card without `stack` is printed exactly as before (compare the whole line). `test-board-web.sh`: the card payload has `stacked_on: 11`; `null` for an unstacked card. `test-board-js.sh`: the drawer renders `stacked on #11` for that payload and nothing for `null`. `test-readme-claims.sh`: the README names `stacking.enabled`.
- [ ] **Step 2: Run the four suites; see the new cases fail. Commit the tests alone.**
- [ ] **Step 3: Implement the status line, the payload fields and the drawer line.**
- [ ] **Step 4: Write the README section "Stacked pull requests".** It says: what stacking does; `stacking.enabled`; a child starts when its one unmet dependency is in review; its PR stays a draft and targets the parent's branch until the parent merges; human QA happens after landing; git 2.40 or later; the three cases that stop for a person (parent closed unmerged, the child followed commits that never merged, a conflict while landing) and how to clear them (`note.sh merge <n>` with `{"stack": {..., "attention": null}}` after fixing, or `{"stack": null}` to unstack by hand).
- [ ] **Step 5: Run the four suites.** Expected: no `FAIL` line.
- [ ] **Step 6: Bump; commit; push.**

---

## After the last task

Run a live stack on the dogfood board with `stacking.enabled: true`: two cards where the second
edits lines the first adds. Confirm on GitHub that the child's PR shows only its own change
while stacked, stays a draft, and lands after the parent as its own squash commit. This is the
evidence for the README claim; no task's offline suite covers GitHub's own behaviour.
