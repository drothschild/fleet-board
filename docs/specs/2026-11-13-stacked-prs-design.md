# Stacked pull requests

Date: 2026-11-13. Status: approved by the owner 2026-11-13.

## Intent

A card that depends on another card waits until that card is done. A chain of four cards
therefore runs one at a time, and each one sits idle through the previous card's whole review,
human QA and merge.

The owner wants ordered work to ship as stacked pull requests: a dependent card starts as soon
as its dependency has a pull request in review, builds on that branch, and lands after it. This
is also a feature a comparable product advertises, and fleet-board is a portfolio piece, so the
result has to be visible on GitHub as a real stack: each PR shows only its own change.

## Words

- **Parent**: the card a stacked card depends on. **Child**: the stacked card.
- **Default branch**: `origin/HEAD`, else `origin/main` (the rule `worktree.sh` uses today).
- **Stacked**: a child whose PR base is its parent's branch, not the default branch.
- **Landing**: the step after the parent merges that moves the child onto the default branch.

## Goals

- With stacking on, a Ready card with exactly one unmet dependency starts when that dependency
  is in review (or later) with an open PR.
- The child's branch starts from the parent's branch, and its PR targets the parent's branch.
- The reviewer of a child sees only the child's change.
- When the parent's branch moves, the child follows it by a merge.
- A child never merges before its parent. PRs land in dependency order, each as its own squash
  commit on the default branch.
- Chains of any length work: a child can itself be a parent.

## Non-goals

- Starting a child while the parent is still in progress with no PR.
- Stacking on more than one parent. A card with two or more unmet dependencies waits as it does
  today until one is left.
- Stacking across repositories. A dependency outside this board is not checked today and is not
  stacked on.
- Running cards with overlapping scope that are not parent and child. Scope reservations stay.
- Predicting conflicts between unrelated in-flight branches.
- Merging a whole stack in one step, or any merge method other than the existing squash.

## Anti-goals

- A child PR must never be merged into its parent's branch. That would put the child's change
  into the parent's PR after the parent was reviewed.
- No rebase and no force-push, anywhere. The repository rule stands.
- With stacking off (the default), nothing behaves differently from today.
- A stacked child must never be rebuilt, retargeted or closed automatically because its parent
  was abandoned. That case stops and asks for a person.
- No change that lets unreviewed code count as reviewed. Every new "already reviewed" rule must
  fail closed.

## Constraints

- Bash 3.2, BSD and GNU tools, jq, the system git on macOS (do not assume git 2.40 or later
  without checking and falling back). Python 3 standard library in the supervisor.
- Merges are `gh pr merge --squash --match-head-commit` in `merge-reviewed.sh`.
- The manager note validates every field that can steer a shell command. Any new field that
  holds a branch name or a sha gets the same validation as `branch` and `last_review.sha`.
- Per-card network calls in `tick-plan.sh` are a cost on every plan. A new `gh` call is made
  only for cards that are stacked, not for every card.
- Plugin changes bump both manifests (see the repository `CLAUDE.md`).

## How it works today

- `deps.sh check` reports a dependency as unmet unless its card is `done`. `tick-plan.sh`
  plans `wait` for a Ready card with any unmet dependency. Only Ready cards are gated.
- `worktree.sh create <n> <branch> <path>` makes a new branch from the default branch.
- The implementor opens the PR with `gh pr create --draft --head <branch>`, so the base is the
  default branch.
- `update-branch.sh` merges `origin/<the PR's baseRefName>` into the branch. It is planned only
  when the PR reads `CONFLICTING` or a version is not above the base.
- `worktree.sh review` reports `base` as `merge-base origin/main <head>`; the reviewer's diff
  itself comes from `gh pr diff`, which is already relative to the PR's base.
- `review-drift.sh` counts a commit after the reviewed sha as reviewed only when it is a clean
  merge whose second parent is on the default branch (plus the version-only cases).
- The scheduler holds a `start` whose declared scope overlaps an open card's scope or PR files.

## Approaches

**A. Stack once the parent is in review. Chosen by the owner.** The child starts when the
parent has an open PR in review, branches from the parent's branch and targets it on GitHub.
After the parent merges, the child is retargeted to the default branch. GitHub shows each PR as
its own change. It touches the dependency gate, the scheduler, worktree creation, the
implementor, the review base, review drift and the merge gate.

**B. Stack as soon as the parent is in progress.** Same mechanics, earlier start. Rejected: the
parent's branch is still being written and may not be pushed, so the child would redo work each
time the parent shifts.

**C. Branch from the parent but target the default branch.** The child's PR stays a draft until
the parent lands. No retargeting and no merge-gate change. Rejected: GitHub shows the parent's
change inside the child's PR until the parent merges, so it is not a visible stack.

## Design

### 1. Switch

A config key `stacking.enabled`, default `false`, in `config-defaults.json` and
`docs/config.md`. Every rule below applies only when it is `true`.

### 2. When a child may start

A Ready card may start stacked when all of these hold:

- it has acceptance criteria and passes card lint, as today;
- exactly one of its dependencies is unmet;
- that dependency is on this board, is not in a dependency cycle, and its card is in
  `in_review`, a `review_<stage>` state, `human_qa` or `merging`;
- that card's note holds a valid `branch` and `pr`, and the PR is open.

Otherwise the card waits exactly as it does today. The parent's branch and card number are
recorded in the child's note when it starts (below), and the plan row for the start carries
them so the driver does not look them up a second time.

### 3. Scope

A child's start is not held by the scope of the cards below it in its own stack (its parent,
the parent's parent, and so on). It is still checked against every other card, including a
sibling stacked on the same parent. The child reserves its own scope as any start does.

### 4. Starting the child

- `worktree.sh create` gains an optional start point. For a stacked start it is
  `origin/<parent branch>`, after the fetch the script already does. The existing rules for an
  existing local or remote branch are unchanged, so a resumed child is not re-based.
- The child's note records `stack: {parent: <card n>, base: <parent branch>}`.
- The implementor opens its PR as it does today. Before the first review the supervisor
  retargets it with `gh pr edit <pr> --base <parent branch>`. (Changed while planning: agent
  files are clean-room and are not hand-edited, and a script step is deterministic.)

### 5. Following the parent

`tick-plan.sh` plans `update_branch` for a stacked child, in `in_progress` or review, whose
branch does not contain the head of `origin/<parent branch>`. `update-branch.sh` already merges
the PR's `baseRefName`, so the script needs no change for this. A conflict goes to the fixer by
the existing path.

`review-drift.sh` counts a clean merge whose second parent is on the child's recorded parent
branch as reviewed, in the same way it counts a clean merge of the default branch. The parent's
commits are reviewed in the parent's own PR.

### 6. Reviewing the child

`worktree.sh review` computes `base` against the PR's base branch, not `origin/main`. Review
stages, the blast-radius and documentation reviewers, and evidence review all use the PR's base
for a stacked child. `gh pr diff` already does.

A stacked child is reviewed as any card is, every review stage included. It stops there until
it has landed (section 7).

### 7. Holding the child after review

While a card's note has `stack` set, `tick-plan.sh` plans none of `mark_ready`, `to_human_qa`
or `merge` for it. Its row is `wait` with the reason "waits for #<parent> to merge". So:

- **The PR stays a draft until the child has landed.** GitHub will not merge a draft, which
  is what protects the anti-goal under `merge.policy: human`, where a person merges in GitHub
  and no script of ours is in the way.
- **Human QA happens after landing**, on the head that will actually merge. Landing pushes a
  new head, the gate forbids moving a card out of `human_qa`, and a normal plan does not plan
  `human_qa` cards at all, so a child that entered human QA while stacked could never land.

Two more checks back this up: `merge-reviewed.sh` refuses, before any `gh pr merge`, a PR whose
`baseRefName` is not the default branch, and the gate hook refuses the same command. Merging a
child into its parent's branch is the one mistake that cannot be undone cleanly.

Stacking works under both merge policies. Under `human` the stack advances as fast as the person
merges each parent.

### 8. Landing

When a stacked child's parent card is `done` and the parent's PR is merged, the plan gives the
child a new action, `land`, which the driver runs as a script step (no agent). `land` runs in
any state from `in_progress` through review, with or without a PR. In order:

1. Fetch, then check two things. If either fails, nothing is changed.
   - The parent's merge commit on the default branch is an ancestor of the fetched default
     head. If not (a stale fetch, or the parent was merged into some other base), wait. Without
     this the merge in step 3 would silently remove the parent's change.
   - Every parent-branch commit the child has merged in is an ancestor of the parent PR's
     final head (the head that was merged). If the child followed commits that never merged,
     hold the card for attention: landing would turn them into the child's own, unreviewed.
2. Make sure the child's branch contains the parent PR's final head. Merge it in if it does
   not. A conflict here holds the card for attention (the parent's branch may already be
   deleted, so the fixer's plain merge of the base cannot be used).
3. Merge the parent's squash commit into the child **with the parent's final head as the merge
   base**, and commit the result as an ordinary merge commit with two parents (the child's
   head and the squash commit). This is the "bridge". Then push, as `update-branch.sh` does.
   After the bridge, git's own merge base with the default branch is the squash, so the rest
   of the default branch is merged by the existing `update-branch.sh`, unchanged.
4. Retarget the PR, if there is one: `gh pr edit <pr> --base <default branch>`. Idempotent. A
   child with no PR yet skips this, and its implementor is given the default branch as base.
5. Clear `stack` from the child's note and record `landed: {parent, parent_head, sha}`.

The retarget comes after the push so that a failed or conflicted step 3 leaves the PR as it was.

**A conflict in step 3** means the default branch changed lines the child also changed, in a
commit the parent never merged. Scope reservations make this rare. Nothing is pushed and the
card is held for attention with the files named. (Changed while planning: the first draft gave
the fixer a special landing mode, which needs the clean-room fixer re-authored. With the bridge,
every later conflict with the default branch is an ordinary one the fixer already handles.)

Step 3 is the centre of this design. The parent was squash-merged, so the default branch does
not contain the parent's commits and git's own merge base is the old default-branch commit. A
plain `git merge origin/main` then conflicts on every line the parent changed and the child
changed again, which is the usual case for dependent work. Using the parent's final head as the
base gives the same result a `rebase --onto` would, without rewriting history: "theirs" is what
the default branch changed since the parent, "ours" is the child's own change.

After landing, the child is an ordinary card: version raising, conflict handling and merge
planning run as they do today. Version raising runs as part of landing too, since the base
changed.

`review-drift.sh` counts the landing merge as reviewed when: its second parent is on the default
branch, the child's note records the landing with that parent head, and the commit's tree equals
the tree the same explicit-base merge produces (with the existing version-only allowance). A
landing merge that needed conflict resolution is unreviewed and goes back to review.

### 9. When the parent does not land

- **Parent is closed as won't-do, or its PR is closed without merging:** the child is held
  with an attention reason naming the parent. Nothing is retargeted or rebuilt. The owner
  decides: re-point the dependency, land the child by hand, or close it.
- **Parent is blocked:** the child keeps following and can be reviewed; its merge stays held.
- **Parent's branch is deleted before landing** (GitHub's auto-delete on merge): expected.
  Landing reads the parent's final head from the pull ref, not the branch. GitHub may have
  retargeted the child's PR already; step 2 is then a no-op.

### 10. What the owner sees

- `status` and the board page show, on a stacked child, "stacked on #<parent>" and the hold
  reason while it waits to merge.
- The README gains a short section on stacking, with the config key.

## Order of work

The first card proves the landing merge on a fixture, before anything depends on it: a local
git repository where a parent is squash-merged and the child (a) edited lines the parent also
edited, (b) had merged a later parent commit, (c) meets an unrelated change on the default
branch. The suite must show the plain merge conflicting and the explicit-base merge producing
the right tree, on the system git.

After that, roughly: the start rule and scope exemption; worktree start point and the
implementor's base; following and review base; the merge hold; landing and its review-drift
rule; status, board page and docs. Each is one card, and after the first they can themselves be
run as a stack.

## Left to the builder

- How to do the explicit-base merge: `git merge-tree --write-tree --merge-base` where the
  installed git has it, `git read-tree -m` with `git merge-index` otherwise, or one method that
  works everywhere. The fixture decides.
- The exact names of the note fields and the plan action, and where the parent's final head is
  read from (the parent's note, `gh pr view`, or the fetched pull ref), as long as a value that
  cannot be validated fails closed.
- How the scheduler learns a card's stack ancestors for the scope exemption.

## My calls, not the owner's

These were proposed and not objected to, or filled in while writing. Check them:

- The config key name `stacking.enabled`, default off.
- A parent in `human_qa` or `merging` counts as "in review" for starting a child.
- A child's PR stays a draft, and the child stays out of human QA, until it has landed. This
  replaces an earlier idea that only the merge would be held; the reviewer of this document
  showed that a child in human QA could never land.
- No limit on stack depth beyond `limits.concurrency`.
- A draft PR plus two script checks against merging into a non-default base.
- A landing merge that resolved cleanly does not need another review.
- Landing waits when the parent's merge commit is not yet on the fetched default branch, and
  asks for attention when the child followed parent commits that never merged.
- A conflict in the bridge, or while merging the parent's final head, stops for a person.
- The supervisor retargets the PR; no agent file changes.
- A child with no PR yet still lands; its implementor then opens the PR against the default
  branch.
