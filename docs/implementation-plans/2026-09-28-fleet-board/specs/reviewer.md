# Behavior spec: reviewer

## 1. Purpose

The reviewer is a fresh-context role agent that judges one card's pull request on evidence rather than trust. Working in a review worktree checked out at the PR head, it maps every Acceptance item to a test in the diff, runs only the test files the PR touched, mutates the implementation to prove the mapped tests can fail, re-executes one load-bearing claim from the latest implementor or fixer report, runs the project's typecheck and lint, and, from round 2 on, checks that no pre-existing test was weakened. It posts one fixed-shape report on the card and returns the same text. It changes nothing: no code, no commits, no card moves, no merges, and its worktree is clean when it finishes.

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
- **Reference SHA**: in round 1, the round-1 base SHA; in round 2 and later, the SHA of the PR head at the previous review.
- **Scripts directory**: the absolute path of the fleet-board scripts directory (holding `board-comment.sh` and `parse-report.sh`).

The reviewer's tools are exactly `Read, Write, Edit, Bash, Grep, Glob`. It has no `Skill` tool and cannot load the reporting skill or any other skill; everything it needs to write a valid report is in this spec (section 5).

## 3. Required behavior

All commands run inside the review worktree at the PR head unless stated otherwise. The steps run in this fixed order. Throughout, "a test command" means `commands.test_one` with `{file}` replaced by one concrete test file path that matches `test_paths` — for example `node --test test/calc.test.js` when `test_one` is `node --test {file}`. The reviewer never runs a command that could run the whole suite (such as `npm test`, a bare `node --test`, or a test runner invoked without a file path).

0. **Record the head.** Run `git rev-parse HEAD` in the review worktree and record the SHA. The report's `## For the card` contains a plain line `reviewed head: <sha>` with that SHA, so the manager can pass it as the previous review SHA in the next round.

1. **Map every Acceptance item to a test in the diff.**
   - Every bullet of the card's `Acceptance` section produces exactly one line in `## Acceptance map`: `- <item text> -> <test file>::<test name>` when a test in the diff maps to it, or `- <item text> -> UNMAPPED` when none does.
   - An item maps to a test in the diff when that test **exercises the item's behavior**: it calls the code under the item's inputs or scenario. A test that calls `subtract(5, 2)` maps to "subtract(5, 2) returns 3" even if its only assertion is `typeof subtract(5, 2) === 'number'`. Whether the assertion actually pins the behavior is judged by the mutation step (step 3), not by the map: a weak mapped test lets its mutant survive, and the survivor is the `[Critical]` finding.
   - An item is `UNMAPPED` only when no test in the diff exercises it at all. So with `review.mutation` on, a weak test gets a mutant, never an `UNMAPPED` line that skips mutation. The reviewer may additionally note a weak assertion in `## For the card` or as a `[Minor]` finding, but never instead of the mutant.
   - Every `UNMAPPED` item produces one `[Important]` finding naming the item, e.g. `- [Important] Acceptance item "subtract(2, 5) returns -3" has no test in the diff`.

2. **Run only the test files the PR touched.**
   - The touched test files are the files in the PR diff that match `test_paths` and still exist at HEAD (the reviewer may list them with `git diff --name-only <reference SHA>..HEAD -- <test_paths>` in round 1, or from the PR diff).
   - Each touched test file is run once through its test command, one file per invocation. No other test command is run in this step.
   - A touched test file that fails at the unmutated PR head is a defect in the diff and produces an `[Important]` finding naming the file and quoting the failure.

3. **Mutation** (`review.mutation`).
   - **When `review.mutation` is false:** no mutant is made, and `## Mutation` contains exactly the line `skipped: review.mutation is off`.
   - **When `review.mutation` is true:** for every mapped Acceptance item (UNMAPPED items get no mutant), the reviewer makes exactly one mutant: a small change in the **implementation code** that the mapped test covers, chosen so that it breaks that item's behavior (for example flipping an operator, changing a constant, or removing a branch). Test files are never mutated.
     - It runs the mapped test's file through its test command and expects red.
     - It restores the mutated file with `git checkout -- <file>`, then re-runs the same test command and confirms it is green again before making the next mutant.
     - It classifies the mutant as exactly one of: **killed** (the mapped test went red), **survived** (the mapped test stayed green), or **invalid** (the mutant did not compile or run, so the test result says nothing about the assertion). If the mapped test was already red on the unmutated code, no meaningful mutant is possible and the item is counted invalid; the red test is already a step-2 finding.
     - Each survivor produces one `[Critical]` finding naming the item, the file mutated, the change made and the test that stayed green.
     - `## Mutation` contains exactly one line, `killed: <n> survived: <n> invalid: <n>`, where the three counts sum to the number of mapped Acceptance items. A per-mutant account (item, file, change, command, outcome) goes in `## For the card` as plain, non-list lines (for example `mutant 1: src/calc.js "a - b" to "a + b"; node --test test/calc.test.js went red; killed`).
     - **When `worktrees.mutate_on_copy` is true:** the reviewer copies the review worktree to a temporary directory, makes and runs every mutant in the copy, restores each mutant there with `git checkout -- <file>`, and removes the copy afterwards. The review worktree itself is never mutated.

4. **Claim check** (`review.verify_claim`).
   - **When `review.verify_claim` is false:** no claim is executed, and `## Claim check` contains exactly the line `skipped: review.verify_claim is off`.
   - **When `review.verify_claim` is true:** the reviewer picks one load-bearing claim from the latest implementor or fixer report — the report's `VERIFIED:` line by preference, otherwise another specific, checkable assertion (a count, a pass/fail result, a command's output). If the preferred claim's command could run the whole suite, it picks another load-bearing claim whose command is scoped instead.
     - It executes the claim's command itself, at the PR head, on unmutated code. Reading the source or trusting the report never substitutes for execution.
     - For a claim of the form "X only reads A, B and C", it executes X with a distinct marker in every field and inspects what is read and output, rather than inferring exclusivity from the source.
     - `## Claim check` contains exactly four lines, each key once: `claim: <text>` (the claim restated in plain words, not starting with `VERIFIED:` and containing no backticks), ``command: `<cmd>` `` (the exact command executed, one backticked command), `result: <observed>` (what the command printed, reduced to the value the claim is about), and `matches: yes` or `matches: no`.
     - `matches: no` produces one `[Important]` finding stating the claimed and the observed value.

5. **Typecheck and lint.** When `commands.typecheck` is set, the reviewer runs it; when `commands.lint` is set, it runs it. Each command that exits non-zero produces one `[Important]` finding naming the command and quoting the first relevant error lines. An unset command is not run and produces no finding.

6. **Pre-existing tests must not be modified (round 2 and later).** In round 1 this step does nothing. In round 2 and later, the reviewer inspects `git diff <previous-review-sha>..HEAD -- <test_paths>`:
   - A test that existed at the previous review SHA is **modified** when any line inside its body differs at HEAD — a changed line, a deleted line, **or an added line**. Added lines count even when nothing is removed: an early `return;`, a `t.skip()` or `t.todo()` call, `.skip`, `.only` or `.todo` added to its declaration, an assertion wrapped in `if (false) { ... }`, or an assertion turned into a comment. Deleting a whole pre-existing test, or a pre-existing test file, is also a modification.
   - The reviewer compares each test that existed at the previous review SHA with the same test at HEAD, using the diff and, where a hunk's position is unclear, `git show <previous-review-sha>:<file>` and `git show HEAD:<file>` side by side. It does not merely count deleted lines.
   - Every such modification produces one `[Critical]` finding whose text contains the test file path, names the test, and quotes the changed lines, e.g. `- [Critical] test/calc.test.js: existing test "subtract(2, 5) returns -3" was modified since the previous review: added "return;" before its assertion`.
   - New test blocks (a new test call outside every pre-existing test's body) and new test files are fine and produce no finding.

7. **Status.** `## Status` is `clean` when the report has zero `[Critical]` and zero `[Important]` findings, and `findings` otherwise. `[Minor]` findings do not affect Status. When there are no findings of any severity, `## Findings` is exactly `- none`.

8. **Bugs found vs findings.** A defect the reviewer observes **outside the PR's diff** while running tests, typecheck, lint or the claim (for example a pre-existing failing behavior in code the PR did not touch) goes under `Bugs found:` in `## For the card` as ``- <title> :: repro: `<command>` :: expected: <text> :: observed: <text>``, where the repro is a command the reviewer actually ran and `observed` is what it printed. A defect in the PR's own diff, including behavior the PR introduced, is always a Finding, never a Bug found. The reviewer does not file issues for bugs; the manager does. Work worth doing that the card does not cover may be listed under `Out of scope:` as `- <title> :: <one-line description>`.

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
- Read or ask for another agent's transcript; judge only from the card, the diff, the report text and what it executes.
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
- <title> :: <one-line description>
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
    - **Acceptance map:** each line is `- <item text> -> <test file>::<test name>` or `- <item text> -> UNMAPPED`.
    - **Mutation:** either the line `killed: <n> survived: <n> invalid: <n>` or `skipped: review.mutation is off`.
    - **Claim check:** either the lines `claim: <text>`, `command: \`<cmd>\``, `result: <observed>` and `matches: yes|no`, or `skipped: review.verify_claim is off`.
- **Line rules** (review cycle 1; `parse-report.sh` rejects every violation, one `parse-report: `-prefixed stderr line each):
  - Any heading appears at most once. `## Status` holds exactly one non-blank line.
  - Every non-blank `## Findings` line is `- [Critical|Important|Minor] <text>` (that exact spelling, one space after `-`) or exactly `- none`. The section needs one of the two forms, never both.
  - `Out of scope:` and `Bugs found:` each need at least one entry. Entries are unindented `- ` lines directly under the header or the previous entry; a blank or text line ends the list, and a `- ` line after that blank line, or an indented `  - ` line inside a list, is an error. An Out of scope entry needs ` :: ` with a non-empty title and detail. A bug's repro is backticked.
  - Resolutions: the finding and its outcome are split at the first ` :: ` followed by `fixed` or `not fixed: <why>`, so ` :: ` may appear inside both. `<why>` is non-empty.
  - Acceptance map lines are split on the last ` -> `; the test is `<file>::<test name>` or `UNMAPPED`. Mutation is exactly one line of the two forms. Claim check has each of the four keys once, or only the skipped line.
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

- **fleet-board.AC3.4 Success:** The reviewer maps each Acceptance item to a test and flags an unmapped item as Important.
- **fleet-board.AC3.5 Success:** With `review.mutation` on, the reviewer reports killed, survived, and invalid counts, and a survivor is Critical.
- **fleet-board.AC3.6 Success:** With `review.verify_claim` on, the reviewer executes one claim from the implementor's report and records the command and result.
- **fleet-board.AC3.7 Success:** With either toggle off, the reviewer skips that step and says so in the report.
- **fleet-board.AC3.8 Failure:** A fixer commit that modifies a test to dismiss a finding is flagged Critical by the next review round.
- **fleet-board.AC5.3 Success:** Every agent report contains `## Status`, `## Findings`, `## For the card`, and one `VERIFIED:` line.
