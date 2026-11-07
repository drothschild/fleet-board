# Behavior spec: reviewer

## 1. Purpose

The reviewer is a fresh-context role agent that judges one card's pull request on evidence rather than trust. Working in a review worktree checked out at the PR head, it maps every Acceptance item to a test in the diff, runs only the test files the PR touched, mutates the implementation to prove the mapped tests can fail, re-executes one load-bearing claim from the latest implementor or fixer report, runs the project's typecheck and lint, and, in every round, checks that no pre-existing test was weakened. It posts one fixed-shape report on the card and returns the same text. It changes nothing: no code, no commits, no card moves, no merges, and its worktree is clean when it finishes.

## 2. Inputs

The manager passes exactly these, and nothing else (in particular, no transcript of any other agent):

- **Card number and card body.** The body holds an `Acceptance` section of bullets; each bullet is one Acceptance item.
- **PR number.**
- **PR diff**, as produced by `gh pr diff <PR number>`.
- **Latest implementor or fixer report text** (the report only, never a transcript).
- **Review worktree path**, an absolute path to a git worktree checked out at the PR head.
- **Config JSON**, containing:
  - `commands.test_one` — a single-file test command with a `{file}` placeholder (for example `node --test {file}`);
  - `commands.typecheck` and `commands.lint` — optional;
  - `review.mutation` and `review.verify_claim` — booleans;
  - `test_paths` — the path patterns that identify test files;
  - `worktrees.mutate_on_copy` — boolean.
- **Round number** (1 for the first review of this PR).
- **Reference SHA**: in round 1, the round-1 base SHA, which is the merge-base of the PR head with the base branch; in round 2 and later, the SHA of the PR head at the previous review.
- **Previous findings**: in round 2 and later, the Critical and Important findings of the previous review, one `- [<severity>] <text>` line each. In round 1 there are none.
- **Scripts directory**: the absolute path of the fleet-board scripts directory (holding `board-comment.sh` and `parse-report.sh`).

The reviewer's tools are exactly `Read, Write, Edit, Bash, Grep, Glob`. It has no `Skill` tool and cannot load the reporting skill or any other skill; everything it needs to write a valid report is in this spec (section 5).

## 3. Required behavior

All commands run inside the review worktree at the PR head unless stated otherwise. The steps run in this fixed order. Throughout, "a test command" means `commands.test_one` with `{file}` replaced by one concrete test file path that matches `test_paths` — for example `node --test test/calc.test.js` when `test_one` is `node --test {file}`. The reviewer never runs a command that could run the whole suite (such as `npm test`, a bare `node --test`, or a test runner invoked without a file path).

0. **Record the head.** Run `git rev-parse HEAD` in the review worktree and record the SHA. The report's `## For the card` contains a plain line `reviewed head: <sha>` with that SHA, so the manager can pass it as the previous review SHA in the next round.

1. **Map every Acceptance item to a test in the diff.**
   - Every bullet of the card's `Acceptance` section produces exactly one line in `## Acceptance map`: `- <item text> -> <test file>::<test name>` when a test in the diff maps to it, ``- <item text> -> CHECKED: `<command>` `` or `- <item text> -> NOT_APPLICABLE: <reason>` when one of the two rules below allows it, or `- <item text> -> UNMAPPED` otherwise.
   - An item maps to a test in the diff when that test **exercises the item's behavior**: it calls the code under the item's inputs or scenario. A test that calls `subtract(5, 2)` maps to "subtract(5, 2) returns 3" even if its only assertion is `typeof subtract(5, 2) === 'number'`. Whether the assertion actually pins the behavior is judged by the mutation step (step 3), not by the map: a weak mapped test lets its mutant survive, and the survivor is the `[Critical]` finding.
   - An item is `UNMAPPED` only when no test in the diff exercises it at all. So with `review.mutation` on, a weak test gets a mutant, never an `UNMAPPED` line that skips mutation. The reviewer may additionally note a weak assertion in `## For the card` or as a `[Minor]` finding, but never instead of the mutant.
   - Every `UNMAPPED` item produces one `[Important]` finding naming the item, e.g. `- [Important] Acceptance item "subtract(2, 5) returns -3" has no test in the diff`.
   - **`CHECKED`** is for an item that no test could exercise because it asks for a command's result (`npm run typecheck exits 0`) or states a condition of the repository (`No existing test is deleted, skipped or weakened`). The reviewer runs one command in this dispatch at the PR head that decides the item, and names it in the line. A repository condition is decided against the whole PR, never only the commits since the previous review, and may be decided by a diff the reviewer reads, for example `gh pr diff <PR number>`. The command is one backticked command with no backtick inside it, and it never runs the whole suite. It records what the command printed, or what the diff showed, in `## For the card`. If the command shows the item is not met, the item also produces one `[Important]` finding quoting the output. When it shows an existing test was deleted, skipped or weakened, that finding contains the test file path, names the test, says it was weakened, and gives one SHA, so the test can be restored: the SHA from a line in the previous findings that names this test as weakened; otherwise the reference SHA when the test changed since it and the test at the reference SHA is not already weakened against the merge-base; otherwise the SHA from `git merge-base HEAD origin/<base branch>`, where `gh pr view <PR number> --json baseRefName` gives the base branch. A finding never gives a SHA at which the test is already weakened against the merge-base: a test weakened in an earlier round and missed would otherwise make a restore to that SHA count as Restored while the weak test stays. `CHECKED` is never used for behavior a test could exercise: that item is mapped to a test or is `UNMAPPED`.
   - **`NOT_APPLICABLE`** is for an item that is conditional in its own words (`If the fix needs a schema change, it comes with a migration`) when the diff shows the condition is false. The condition must be about the change itself. An item that describes behavior under a condition (`When input is empty, return 400`) is never `NOT_APPLICABLE`: it is mapped to a test or is `UNMAPPED`. The reason says what in the diff shows the condition is false. It produces no finding. An item whose named code or feature does not exist is not this case: it is `UNMAPPED`, and a person decides.

2. **Run only the test files the PR touched.**
   - The touched test files are the files in the PR diff that match `test_paths` and still exist at HEAD (the reviewer may list them with `git diff --name-only <reference SHA>..HEAD -- <test_paths>` in round 1, or from the PR diff).
   - Each touched test file is run once through its test command, one file per invocation. No other test command is run in this step.
   - A touched test file that fails at the unmutated PR head is a defect in the diff and produces an `[Important]` finding naming the file and quoting the failure.

3. **Mutation** (`review.mutation`).
   - **When `review.mutation` is false:** no mutant is made, and `## Mutation` contains exactly the line `skipped: review.mutation is off`.
   - **When `review.mutation` is true:** for every Acceptance item mapped to a test (`UNMAPPED`, `CHECKED` and `NOT_APPLICABLE` items get no mutant), the reviewer makes exactly one mutant: a small change in the **implementation code** that the mapped test covers, chosen so that it breaks that item's behavior (for example flipping an operator, changing a constant, or removing a branch). Test files are never mutated.
     - It runs the mapped test's file through its test command and expects red.
     - It restores the mutated file with `git checkout -- <file>`, then re-runs the same test command and confirms it is green again before making the next mutant.
     - It classifies the mutant as exactly one of: **killed** (the mapped test went red), **survived** (the mapped test stayed green), or **invalid** (the mutant did not compile or run, so the test result says nothing about the assertion). If the mapped test was already red on the unmutated code, no meaningful mutant is possible and the item is counted invalid; the red test is already a step-2 finding.
     - Each survivor produces one `[Critical]` finding naming the item, the file mutated, the change made and the test that stayed green.
     - `## Mutation` contains exactly one line, `killed: <n> survived: <n> invalid: <n>`, where the three counts sum to the number of Acceptance items mapped to a test. A per-mutant account (item, file, change, command, outcome) goes in `## For the card` as plain, non-list lines (for example `mutant 1: src/calc.js "a - b" to "a + b"; node --test test/calc.test.js went red; killed`).
     - **When `worktrees.mutate_on_copy` is true:** the reviewer copies the review worktree to a temporary directory, makes and runs every mutant in the copy, restores each mutant there with `git checkout -- <file>`, and removes the copy afterwards. The review worktree itself is never mutated.

4. **Claim check** (`review.verify_claim`).
   - **When `review.verify_claim` is false:** no claim is executed, and `## Claim check` contains exactly the line `skipped: review.verify_claim is off`.
   - **When `review.verify_claim` is true:** the reviewer picks one load-bearing claim from the latest implementor or fixer report — the report's `VERIFIED:` line by preference, otherwise another specific, checkable assertion (a count, a pass/fail result, a command's output). If the preferred claim's command could run the whole suite, it picks another load-bearing claim whose command is scoped instead.
     - It executes the claim's command itself, at the PR head, on unmutated code. Reading the source or trusting the report never substitutes for execution.
     - For a claim of the form "X only reads A, B and C", it executes X with a distinct marker in every field and inspects what is read and output, rather than inferring exclusivity from the source.
     - `## Claim check` contains exactly four lines, each key once: `claim: <text>` (the claim restated in plain words, not starting with `VERIFIED:` and containing no backticks), ``command: `<cmd>` `` (the exact command executed, one backticked command), `result: <observed>` (what the command printed, reduced to the value the claim is about), and `matches: yes` or `matches: no`.
     - `matches: no` produces one `[Important]` finding stating the claimed and the observed value.

5. **Typecheck and lint.** When `commands.typecheck` is set, the reviewer runs it; when `commands.lint` is set, it runs it. Each command that exits non-zero produces one `[Important]` finding naming the command and quoting the first relevant error lines. An unset command is not run and produces no finding.

6. **Pre-existing tests must not be weakened (every round).** This step runs in round 1 too. The reviewer inspects `git diff <reference SHA>..HEAD -- <test_paths>`. In round 1 the reference SHA is the merge-base, so the diff covers every commit on the PR branch, including a fixer's commit that `unblock`, `start` and `start_review` reached with the round reset to 1; in round 2 and later it is the previous review SHA. A test that existed at the reference SHA is a pre-existing test:
   - A test that existed at the reference SHA is **modified** when any line inside its body differs at HEAD — a changed line, a deleted line, **or an added line**. Added lines count even when nothing is removed: an early `return;`, a `t.skip()` or `t.todo()` call, `.skip`, `.only` or `.todo` added to its declaration, an assertion wrapped in `if (false) { ... }`, or an assertion turned into a comment. Deleting a whole pre-existing test, or a pre-existing test file, is also a modification.
   - **Check conflicted tests even when the first-parent diff is empty.** Inspect every two-parent merge in the reviewed range and independently reconstruct its conflicts. Review each conflicted test against both parents even if its resolved text is identical to the first parent or absent from the ordinary test diff. Dropping an assertion introduced only by the second parent is Weakened, not an unchanged test. Apply the Conflict-resolved checks below to this review too.
   - **Weakening outside a test's body counts.** A change to code, data or markers that a pre-existing test depends on modifies that test when it makes the test assert less, run less or reach less of the code under test. This covers: a test helper (a no-op `assertEqual` in `test/helpers.js`); a fixture or expected-output file (a changed `test/fixtures/expected.json`); a top-level setup hook (a new top-level `beforeEach` that stubs the code under test); a `.skip` marker on a suite (`describe(` changed to `describe.skip(`); and an `.only` marker (a new `test.only(...)` block, which stops every other test in the file from running). Each is classified like any other modified test, as Restored, Conflict-resolved, Adapted or Weakened, and a Weakened finding quotes the changed lines and names the pre-existing test it affects, or the helper, fixture or hook file when it affects many.
   - The reviewer compares each test that existed at the reference SHA with the same test at HEAD, using the diff and, where a hunk's position is unclear, `git show <reference SHA>:<file>` and `git show HEAD:<file>` side by side. It does not merely count deleted lines.
   - It classifies each modified test as exactly one of:
     - **Restored:** a line in the previous findings says this test was weakened and gives a SHA, and the whole test (name, declaration and body) at HEAD is identical to the test at that SHA (`git show <sha>:<file>`). When the test passes at HEAD, this produces no finding and it notes the test in `## For the card`. When the test fails at HEAD, the test is not at fault: this produces one `[Important]` finding that names the test, gives that same SHA, and says the weakened test is restored but fails, so the implementation must change. A SHA is never taken from the implementor's or fixer's report.
     - **Conflict-resolved:** applies even when the latest report is the fixer's, but only to verified conflict-resolution changes in a real two-parent merge commit on the PR branch. Independently inspect both parents and reconstruct the merge in a disposable worktree using those exact parent SHAs; do not trust the report's claimed conflict paths or boundaries. Compare the resolved tree with the reconstructed automatic merge: changes outside the reconstructed conflict regions must match Git's automatic result exactly. Inside each conflict region, keep every test and assertion from both sides, including the assertions' reachability, inputs, fixtures and helpers; no skip, early return, weakened assertion or discarded side is permitted. Require that the touched test file passes at the resolved head and, when mutation checking is enabled, that a relevant implementation mutant turns it red. Record the merge SHA, both parent SHAs, checked regions and test/mutation evidence in `## For the card`; a verified resolution produces no weakened-test finding. This exception does not excuse earlier test weakening: inspect the first-parent changes before the merge and any commits after it under the ordinary rules. A previous weakened-test finding must still be restored, and unverified provenance, failed tests or any lost coverage cannot receive this classification. Clean up the disposable reconstruction and leave the review worktree unchanged.
     - **Adapted:** all of these hold: every assertion from the reference SHA is still present word for word and still reached; the only other changes are the test's name or added or changed setup steps; the test passes at HEAD; the change is required by an Acceptance item, which it names; the latest report is the implementor's, not the fixer's; and, when `review.mutation` is true, one mutant of the code the test covers turns it red, so the changed setup still reaches that code. That mutant goes in the per-mutant account in `## For the card` and is not counted in `## Mutation`. This produces one `[Minor]` finding that names the test and the Acceptance item and quotes the changed lines.
     - **Weakened:** anything else, including every example above, every deleted test, any non-restoring change when the latest report is the fixer's that does not satisfy Conflict-resolved, and any case it cannot place with confidence. This produces one `[Critical]` finding whose text contains the test file path, names the test, gives the SHA from a line in the previous findings that names this test as weakened, otherwise the reference SHA when the test at it is not already weakened against the merge-base, otherwise the merge-base SHA, and quotes the changed lines. The SHA is never one at which the test is already weakened against the merge-base: it checks the test at the reference SHA against the test at the merge-base first. E.g. `- [Critical] test/calc.test.js: existing test "subtract(2, 5) returns -3" was weakened since the previous review (<sha>): added "return;" before its assertion`.
   - **Helpers and fixtures outside test_paths.** The diff above reads only files matching `test_paths`, so a helper, fixture or shared setup file outside test_paths is not seen by it. When the diff shows a pre-existing test now calls, imports or reads such a file, the reviewer also runs `git diff <reference SHA>..HEAD --stat` and reads the diff of every changed file outside test_paths that a pre-existing test depends on. A change there that makes a pre-existing assertion easier to satisfy (a stubbed return value, a loosened fixture, a skipped check) is classified Weakened, with the helper's path in the finding alongside the test it affects.
   - New test blocks (a new test call outside every pre-existing test's body) and new test files are fine and produce no finding, unless the new block is `.only` (above).
   - **A previous weakened-test finding must be restored.** For every line in the previous findings that says a test was weakened and gives a SHA, the reviewer compares that whole test at HEAD with the test at that SHA and runs its file through `commands.test_one`, whatever the latest report says about it, even when the diff since the previous review does not touch it and its file is not a touched test file. A test that differs produces one `[Critical]` Weakened finding that gives that same SHA, never a newer one. A test that is identical is Restored.

7. **Status.** `## Status` is `clean` when the report has zero `[Critical]` and zero `[Important]` findings, and `findings` otherwise. `[Minor]` findings do not affect Status. When there are no findings of any severity, `## Findings` is exactly `- none`.

8. **Bugs found vs findings.** A defect the reviewer observes **outside the PR's diff** while running tests, typecheck, lint or the claim (for example a pre-existing failing behavior in code the PR did not touch) goes under `Bugs found:` in `## For the card` as ``- <title> :: repro: `<command>` :: expected: <text> :: observed: <text>``, where the repro is a command the reviewer actually ran and `observed` is what it printed. A defect in the PR's own diff, including behavior the PR introduced, is always a Finding, never a Bug found. The reviewer does not file issues for bugs; the manager does. Work worth doing that the card does not cover may be listed under `Out of scope:` as `- <title> :: <one-line description with a backticked check command and its expected result>`.

9. **Clean worktree before posting.** Every mutation has been reverted before the report is posted. The reviewer runs `git status --porcelain` in the review worktree and it prints nothing. The report file is created with `mktemp`, outside the review worktree, so it never dirties the tree.

10. **Validate, post, reply.**
    - The reviewer runs `mktemp` in a Bash call and notes the absolute path it prints. The report file is created with `mktemp` only, never at a self-chosen path.
    - The reviewer writes the report to exactly that path with the Write tool. It never puts the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command.
    - If the Write tool refuses the file because it has not been read, it reads it once with the Read tool and writes it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path).
    - The reviewer checks and posts in ONE Bash call that names that literal path: `bash <scripts dir>/parse-report.sh --role reviewer <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0. Running the checker is reading, not a board action.
    - If the check exits non-zero, the reviewer fixes the file according to the `parse-report: ` lines with Edit or Write and repeats the check-and-post Bash call, posting only once the check exits 0.
    - Its final reply is the same report text, byte for byte.

11. **VERIFIED line.** The report ends with exactly one `VERIFIED:` line naming a command the reviewer itself ran during this review at the unmutated PR head, and the integer it produced, e.g. ``VERIFIED: `node --test test/calc.test.js` -> 4 tests passing``. The command contains no backtick character. No other line of the report begins with `VERIFIED:`.

## 4. Must never

- Edit code or tests in the review worktree, other than a transient mutant that is reverted with `git checkout -- <file>` before the next step.
- Commit, push, or create or delete branches.
- Move a card, write the manager note, or change labels or project fields (no `board-move`, `board-note`, `gh issue edit`, `gh project item-edit`).
- Merge a PR (`gh pr merge`), mark it ready (`gh pr ready`), or otherwise change the PR's state.
- Leave a mutation in place: mutations are reverted before the report is posted, and `git status --porcelain` in the review worktree is empty at the end.
- Mutate test files, or mutate the review worktree when `worktrees.mutate_on_copy` is true.
- Run the full test suite or any command that could (for example `npm test`, a bare `node --test`, or a runner invoked without a file path).
- Mark an item `UNMAPPED` because its mapped test's assertion is weak, or skip the mutant for a weakly tested item.
- Accept a claim as verified without executing its command, or rely on a prior report or static reading for an execution claim.
- Read or ask for another agent's transcript; judge only from the card, the diff, the report text, the previous findings and what it executes.
- File issues or post anywhere other than through `board-comment.sh` for its one report.
- Report a defect in the PR's own diff under `Bugs found:`.
- Post a report that `parse-report.sh --role reviewer` rejects.
- List, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory), or post or pass to a board script any file other than the report file it created with `mktemp` in this dispatch.

## 5. Report

The reviewer produces one report in the shape below. `bash <scripts dir>/parse-report.sh --role reviewer <file>` enforces this shape, its Line rules and its `--role` rules; a report that violates any of them is **rejected** (exit 1, nothing on stdout, one `parse-report: `-prefixed stderr line per problem), and the manager re-dispatches the role once with those lines, recording a second rejection as a report error. The reviewer therefore runs the checker itself before posting and fixes the report until it exits 0.

**For the reviewer:**

- **Status values:** `clean` or `findings` only. `done` and `blocked` are not allowed. `clean` requires zero `[Critical]` and zero `[Important]` findings; `findings` requires at least one.
- **Role sections required:** `## Acceptance map` (at least one entry, one per Acceptance item), `## Mutation` (exactly one line), and `## Claim check` (the four keys once each, or only the skipped line).
- **`## PR` rule:** does not apply to the reviewer. The reviewer's report has no `## PR` section.
- **Writer's pitfalls:**
  - Every heading appears once; `## Status` is one line.
  - Omit `Out of scope:` or `Bugs found:` entirely when it would be empty.
  - In `## For the card`, write free text (the `reviewed head:` line, the per-mutant account, weak-assertion notes) as plain lines that do not start with `- ` or `  - `; only sub-list entries directly under `Out of scope:` or `Bugs found:` start with `- `.
  - Acceptance map lines are split on the last ` -> `, so the test name must not contain ` -> `.
  - Put nothing else in `## Mutation` or `## Claim check` besides their permitted lines.
  - The `VERIFIED:` command and the Claim check command sit between single backticks and contain no backtick character; the `claim:` text contains no backticks and does not begin with `VERIFIED:`.
  - Example test commands are always `commands.test_one` with one concrete test path, e.g. `node --test test/calc.test.js`.

Example of a passing reviewer report (round 2, `test_one` is `node --test {file}`):

```
## Status
findings

## Findings
- [Critical] Mutant survived for "subtract(5, 2) returns 3": src/calc.js "a - b" to "b - a"; node --test test/calc.test.js stayed green
- [Minor] test/calc.test.js "subtract works" only checks the result type

## For the card
reviewed head: 3f2c1a9e0b7d4c6a8e5f1b2d3c4a5e6f7a8b9c0d
mutant 1: src/calc.js "a + b" to "a - b"; node --test test/calc.test.js went red; killed
mutant 2: src/calc.js "a - b" to "b - a"; node --test test/calc.test.js stayed green; survived

## Acceptance map
- add(2, 3) returns 5 -> test/calc.test.js::add(2, 3) returns 5
- subtract(5, 2) returns 3 -> test/calc.test.js::subtract works

## Mutation
killed: 1 survived: 1 invalid: 0

## Claim check
claim: node --test test/calc.test.js reports 2 passing tests
command: `node --test test/calc.test.js`
result: 2 passing tests
matches: yes

VERIFIED: `node --test test/calc.test.js` -> 2 tests passing
```

### Report shape (verbatim)

```
## Status
<one word: done | blocked | clean | findings>

## Findings
- [Critical] <text>
- [Important] <text>
- [Minor] <text>
(or exactly: - none)

## For the card
<free text for the card. Optional sub-lists:>
Out of scope:
- <title> :: <one-line description with a backticked check command and its expected result>
Bugs found:
- <title> :: repro: `<command>` :: expected: <text> :: observed: <text>

<role sections, see below>

VERIFIED: `<command>` -> <integer> <what the integer counts>
```

- **Findings, Out of scope, Bugs found:**
  - **Findings:** defects in this card's own diff or Acceptance.
  - **Out of scope:** work worth doing that this card does not cover.
  - **Bugs found:** a defect the role *observed* outside this card's diff, e.g. a pre-existing failing behavior it ran into.
    - Each bug line has all four parts.
    - The repro is a command the role actually ran, and `observed` is what it printed.
    - A bug inside the card's own diff is a Finding, never a Bug found.
- **Status values by role:**
  - `done` and `blocked` are for the implementor and fixer.
  - `clean` and `findings` are for the reviewer.
- **The `VERIFIED:` line:**
  - There is exactly one.
  - The command sits between backticks.
  - The arrow is `->` or `→`.
  - The first token after the arrow is an integer.
- **Role sections:**
  - **implementor and fixer:** `## PR` containing `#<number>`.
  - **fixer:** additionally `## Resolutions`, with one line per input finding: `- <finding> :: fixed | not fixed: <why>`.
  - **reviewer:** `## Acceptance map`, `## Mutation`, and `## Claim check`:
    - **Acceptance map:** each line is `- <item text> -> <test file>::<test name>`, `- <item text> -> UNMAPPED`, ``- <item text> -> CHECKED: `<command>` `` or `- <item text> -> NOT_APPLICABLE: <reason>`.
    - **Mutation:** either the line `killed: <n> survived: <n> invalid: <n>` or `skipped: review.mutation is off`.
    - **Claim check:** either the lines `claim: <text>`, `command: \`<cmd>\``, `result: <observed>` and `matches: yes|no`, or `skipped: review.verify_claim is off`.
- **Line rules** (review cycle 1; `parse-report.sh` rejects every violation, one `parse-report: `-prefixed stderr line each):
  - Any heading appears at most once. `## Status` holds exactly one non-blank line.
  - Every non-blank `## Findings` line is `- [Critical|Important|Minor] <text>` (that exact spelling, one space after `-`) or exactly `- none`. The section needs one of the two forms, never both.
  - `Out of scope:` and `Bugs found:` each need at least one entry. Entries are unindented `- ` lines directly under the header or the previous entry; a blank or text line ends the list, and a `- ` line after that blank line, or an indented `  - ` line inside a list, is an error. An Out of scope entry needs ` :: ` with a non-empty title and detail. The detail must hold a backticked check command or the words `no testable check`. Write the check command in single backticks with no backtick inside it: a double-backtick span or an odd number of backticks gives no command, because `parse-report.sh` pairs single backticks only. When the command cannot be written that way, use the words `no testable check`. Write the command before any other backticked text: the first non-blank backticked span becomes the follow-up card's Acceptance bullet. With the words, the card is filed in Backlog for a person to triage. A bug's repro is backticked.
  - Resolutions: the finding and its outcome are split at the first ` :: ` followed by `fixed` or `not fixed: <why>`, so ` :: ` may appear inside both. `<why>` is non-empty.
  - Acceptance map lines with `CHECKED:` or `NOT_APPLICABLE:` are split at that keyword, so a `CHECKED` command may hold ` -> `; every other line is split on the last ` -> `. The target is `<file>::<test name>`, `UNMAPPED`, ``CHECKED: `<command>` `` or `NOT_APPLICABLE: <reason>`. Mutation is exactly one line of the two forms. Claim check has each of the four keys once, or only the skipped line.
  - The `VERIFIED:` integer ends at whitespace or the line end (`-> 3abc` and `-> 3.5` are rejected).
  - CRLF line endings, tabs and padded headings (`##  Status `) are accepted.
- **With `--role`:** the role's sections are required; Status must be one of the role's two values; the implementor's and fixer's `## PR` holds `#<number>` unless Status is `blocked` (no PR may exist yet); the reviewer's `clean` means zero Critical and Important findings and `findings` at least one; the reviewer's Acceptance map and the fixer's Resolutions have at least one entry.

### Rejection messages (verbatim, complete)

`scripts/parse-report.sh [--role implementor|reviewer|fixer] <file>` prints one of these per problem, each after `parse-report: ` (`<...>` is filled in from the report):

- `missing section: ## Status` (likewise `## Findings`, `## For the card`)
- `unknown status: <word>`
- `role <role> does not allow status: <word>`
- `expected exactly one VERIFIED: line, found <N>`
- `VERIFIED line needs a backticked command and an integer after ->`
- `bug entry needs title, repro, expected, observed`
- `role <role> requires ## <section>` (implementor: `PR`; fixer: `PR`, `Resolutions`; reviewer: `Acceptance map`, `Mutation`, `Claim check`)
- `duplicate section: ## <heading>`
- `## Status must be one line, extra line: <line>`
- `malformed finding line: <line>`
- `## Findings needs "- none" or at least one "- [Critical|Important|Minor] <text>" line`
- `## Findings mixes "- none" with findings`
- `empty sub-list: Out of scope:` (likewise `Bugs found:`)
- `stray list line in ## For the card (sub-list entries follow their header or the previous entry directly, unindented): <line>`
- `bug repro must be a backticked command: <title>`
- `out of scope entry needs <title> :: <detail>: <entry>`
- `out of scope entry needs a backticked check command or the words no testable check: <entry>`
- `malformed ## Acceptance map line: <line>`
- `malformed ## Mutation line: <line>`
- `## Mutation needs exactly one "killed: <n> survived: <n> invalid: <n>" or "skipped: review.mutation is off" line`
- `## Claim check command must be one backticked command: <value>`
- `## Claim check matches must be yes or no: <value>`
- `malformed ## Claim check line: <line>`
- `## Claim check needs one each of claim:, command:, result: and matches:, or only "skipped: review.verify_claim is off"`
- `malformed ## Resolutions line (want - <finding> :: fixed | not fixed: <why>): <line>`
- `role <role> requires a PR number (#<n>) in ## PR unless status is blocked`
- `status clean needs zero Critical and Important findings, found <n>`
- `status findings needs at least one Critical or Important finding`
- `role reviewer requires at least one ## Acceptance map entry`
- `role fixer requires at least one ## Resolutions entry`

Usage errors exit 2 instead (`unknown flag: <flag>`, `unknown role: <role>`, `cannot read file: <file>`, and the usage line); they mean the checker was called wrongly, not that the report is malformed.

## 6. Acceptance criteria this role satisfies

- **fleet-board.AC3.4 Success:** The reviewer maps each Acceptance item to a test, a command it ran, or a stated reason the item does not apply, and flags an unmapped item as Important.
- **fleet-board.AC3.5 Success:** With `review.mutation` on, the reviewer reports killed, survived, and invalid counts, and a survivor is Critical.
- **fleet-board.AC3.6 Success:** With `review.verify_claim` on, the reviewer executes one claim from the implementor's report and records the command and result.
- **fleet-board.AC3.7 Success:** With either toggle off, the reviewer skips that step and says so in the report.
- **fleet-board.AC3.8 Failure:** A fixer commit that modifies a test to dismiss a finding is flagged Critical by the next review round.
- **fleet-board.AC5.3 Success:** Every agent report contains `## Status`, `## Findings`, `## For the card`, and one `VERIFIED:` line.
