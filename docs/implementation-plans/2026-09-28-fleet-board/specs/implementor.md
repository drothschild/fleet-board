# Behavior spec: implementor

## 1. Purpose

The implementor takes one Ready card and turns its `## Acceptance` bullets into a draft PR, working test-first. It works in the git worktree it is given, which is already on the card's branch. It writes failing tests, commits them alone, implements the minimum needed to make them pass, and pushes. It then opens a draft PR that closes the card, or pushes to the existing PR when this is a continuation. Last, it posts one fixed-shape report on the card. If the card cannot be started, it stops before writing anything and still reports, with Status `blocked`. It never moves cards, never merges and never dispatches other agents. Its report must pass `parse-report.sh --role implementor`.

## 2. Inputs

- **Card:** the number, title and body. The body holds an `## Acceptance` section of `- ` bullets, one testable behavior per bullet.
- **Worktree path:** an absolute path to a git worktree that is already checked out on the card's branch.
- **Branch name:** the card's branch.
- **Config JSON:** the parsed project config. It includes `commands.test_one`, a command template with a `{file}` placeholder (for example `node --test {file}`), and the optional `commands.typecheck` and `commands.lint`. It also includes `test_paths`, the globs that identify test files (for example `test/**/*.test.js`).
- **Manager note:** set when this is a continuation. It may record that a PR already exists, and its number, along with the branch, round and earlier `VERIFIED:` line.
- **Scripts directory:** the absolute path of the fleet-board scripts directory. It holds `board-comment.sh` and `parse-report.sh`.

## 3. Required behavior

In every example below, `commands.test_one` is `node --test {file}` and `test_paths` is `["test/**/*.test.js"]`. The example test command is therefore `node --test test/calc.test.js`.

1. **Stays inside the worktree.** Every file it creates or edits lies under the worktree path. Every git command runs against the worktree, either as `git -C <worktree> ...` or from inside it. The one file written outside the worktree is the report temp file. It is created with `mktemp`, so it lands under `$TMPDIR` and the report never shows up as a change in the worktree.

2. **Checks that the card can start, before writing any test.** It confirms three things:
   - the worktree path exists and is a git worktree;
   - `git -C <worktree> branch --show-current` prints the given branch name;
   - the card body has an `## Acceptance` section containing at least one `- ` bullet.

   If any check fails, the implementor is **blocked before any test or PR exists**:
   - It makes no commit, no push and no PR, and it writes no file in the worktree. `git -C <worktree> status --porcelain` is left empty (when the worktree exists).
   - It posts a report by the usual route (temp file, `parse-report.sh --role implementor`, `board-comment.sh`). The report has:
     - `## Status`: `blocked`.
     - `## Findings`: one `[Important]` finding that names the block. Example: `- [Important] The card has no ## Acceptance section, so there is nothing to write a failing test against.` A missing or empty Acceptance section counts as a defect in the card's Acceptance. Other examples: the Acceptance section has no `- ` bullet; the worktree path does not exist; the worktree is on a different branch.
     - `## For the card`: what the card needs before it can start. Example: add a `## Acceptance` section with one `- ` bullet per testable behavior, then move the card back to Ready. For a worktree or branch problem, the text says the manager must recreate the worktree on the card's branch.
     - `## PR`: present, and states that no PR exists. Example: `No PR: blocked before any test was written.` It contains no `#` followed by digits. This is allowed only because Status is `blocked`.
     - `VERIFIED:` a real command the implementor ran, which printed an integer relevant to the block. The command contains no backtick character. Examples:
       - Missing Acceptance section: `gh issue view <card number> --json body --jq .body | grep -c '^## Acceptance'` prints `0`. grep exits 1 on a zero count, but the printed integer is still the result.
       - No bullets: `gh issue view <card number> --json body --jq .body | sed -n '/^## Acceptance/,/^## [^A]/p' | grep -c '^- '` prints `0`.
       - Missing worktree: `ls -d <worktree> 2>/dev/null | wc -l` prints `0`.
       - Wrong branch: `git -C <worktree> branch --show-current | grep -cx '<branch>'` prints `0`.
   - It never invents a PR number, a commit, a test file or a test command for this report.

3. **Resumes from the manager note on a continuation.** When the manager note records a PR, the implementor confirms it with `gh pr view <number> --json number,headRefName,isDraft,state` and treats that PR as the card's PR.
   - It reads `git -C <worktree> log` to see which commits already exist on the branch. It does not redo committed work.
   - It never rewrites or reorders existing commits.

   When the note records no PR, the implementor runs `gh pr list --head <branch> --json number` before opening one. If that returns a PR, the implementor reuses it and does not open a second one.

4. **Writes a test first for each Acceptance item.** Every `- ` bullet under `## Acceptance` gets at least one test before any implementation code is written.
   - Each test lives in a file whose path matches a `test_paths` glob.
   - Each test's name echoes its bullet's text closely enough that a reviewer can map the bullet to that test by name. The reviewer's map uses the form `<test file>::<test name>`.

5. **Runs only the new test files, and confirms they fail.** It runs each new or changed test file on its own through `commands.test_one`, with `{file}` replaced by that file's path. Example: `node --test test/calc.test.js`.
   - It confirms that the run fails.
   - The failure must come from the missing behavior, not from a typo, a syntax error or a broken import path in the test itself. A test that errors for its own reasons is fixed and re-run; that run is not counted as a failing test.
   - A test that passes before any implementation exists does not test the new behavior. It is rewritten until it fails against the current code.
   - If an item's behavior genuinely already exists, the implementor keeps that item's passing test and says so under `## For the card`. At least one new test must still fail for the first commit to be a test-first commit. If no new test can fail, the implementor makes no commit. It reports `blocked` with an `[Important]` finding that the Acceptance describes behavior that already exists, and `## PR` states that no PR exists.

6. **Commits the test files alone as the first commit.** The first commit the implementor adds to the branch contains only test files. `git -C <worktree> show --name-only --format= <that commit>` lists only paths that match `test_paths`, and none of them is implementation code, a fixture used as implementation, or config. The commit message says it adds failing tests, for example `test: failing tests for <card title>`.

7. **Implements the minimum, re-runs only those test files, and commits.** It writes the least code that makes the new tests pass, then re-runs only the same test files through `commands.test_one`, one file per run, and sees them pass.
   - It commits the implementation as a separate commit, after the test commit.
   - It does not weaken, skip or delete a test from the first commit to get green. If a test itself was wrong, the fix goes in its own commit and `## For the card` says what changed and why.
   - When done, `git -C <worktree> status --porcelain` is empty: all work is committed.

8. **Runs typecheck and lint when they are set.** When `commands.typecheck` or `commands.lint` is set, it runs that command in the worktree.
   - A failure caused by the card's own diff is fixed, re-checked and committed.
   - A failure in files the card did not touch, which the implementor did not cause, is reported under `Bugs found:`. It is not fixed as part of the card.
   - When either command is unset, `## For the card` says it was skipped because it is not configured.

9. **Pushes and opens a draft PR, or reuses the existing one.** It pushes the branch with `git -C <worktree> push -u origin <branch>`, never with force.
   - When no PR exists, it runs `gh pr create --draft --head <branch>` with a title taken from the card. The PR body contains the line `Closes #<card number>`.
   - When the manager note (or step 3's check) shows a PR already exists, it only pushes to that PR's branch and opens no new PR.
   - `gh pr view <number> --json isDraft` reports `true` afterwards.

10. **Records measured evidence in the report.**
    - `## For the card` names each test file it wrote, the test-first commit SHA, the implementation commit SHA, and the pushed head SHA.
    - It gives before and after results as the command plus the number it printed. Example: `node --test test/calc.test.js` had 2 failing before implementation and 2 passing after.
    - Every number comes from a command run in this session, against the exact head reported. Counts from overlapping runs are not added together. Runs that errored for setup reasons are not counted as passes or failures.
    - These statements are load-bearing claims that the reviewer may re-execute, so each must be reproducible by the stated command.

11. **Writes, checks and posts the report, and replies with the same text.**
    - It runs `mktemp` in a Bash call and notes the absolute path it prints. The file lands under `$TMPDIR`, outside the worktree. The file is created with `mktemp` only, never at a self-chosen path.
    - It writes the report to exactly that path with the Write tool. It never puts the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command.
    - If the Write tool refuses the file because it has not been read, it reads it once with the Read tool and writes it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path).
    - It checks and posts in ONE Bash call that names that literal path: `bash <scripts dir>/parse-report.sh --role implementor <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0. Running the checker only reads the file; it is not a board action.
    - If `parse-report.sh` fails, it fixes the file with Edit or Write and repeats that check-and-post Bash call, posting only on exit 0.
    - Its final reply is exactly the posted report text.

12. **Lists out-of-scope discoveries.** Work worth doing that this card does not cover goes under `Out of scope:` in `## For the card`, one `- <title> :: <one-line description>` entry per item. Such work is neither done silently in this card nor left unmentioned. The manager turns each entry into a card.

13. **Lists bugs it observed outside the card's diff.** A defect the implementor ran into outside its own diff goes under `Bugs found:`, as `- <title> :: repro: `<command>` :: expected: <text> :: observed: <text>`. Examples: a pre-existing failing behavior, or a lint error in an untouched file.
    - The repro is a command it actually ran.
    - `observed` is that command's real output.
    - A failure caused by the card's own change is never a Bug found. If still unresolved, it is a Finding. Filing the bugs is the manager's job.

14. **Ends the report with one honest `VERIFIED:` line.** For a `done` report, the line is the final `commands.test_one` run on a new test file, with the integer that run printed. Example: ``VERIFIED: `node --test test/calc.test.js` -> 2 tests passed``. The command is one the implementor ran in this session, contains no backtick, and the integer is what it printed.

15. **Chooses Status by outcome.**
    - `done`: every Acceptance item has a test that passes, the commits are pushed, and a draft PR exists. `## PR` contains that PR's `#<number>`.
    - `blocked`: the card could not be started (step 2), or no failing test could be written (step 5), or the tests cannot be made to pass, or the push or PR creation failed.
    - A `blocked` report after a PR exists still names it as `#<number>` in `## PR`. A `blocked` report with no PR states that no PR exists and contains no `#<digits>` in `## PR`.
    - `## Findings` is `- none` when the implementor knows of no defect in its own diff or in the card's Acceptance. Otherwise it lists each one with a severity. Example: `- [Minor] The Acceptance bullet "handles bad input" is ambiguous; implemented as throwing a TypeError.`

## 4. Must never

- Run the full suite. Prohibited: `commands.test_one` without a file (with `{file}` left empty or unreplaced), `npm test`, `node --test` without a path, or any other runner call not scoped to one named test file.
- Move cards or edit labels. No `board-move.sh`, no `gh issue edit`, no `gh project item-edit`, and no other state change on the board.
- Touch any board script other than `board-comment.sh`. `board-move.sh`, `board-note.sh`, `board-list.sh` and `board-read.sh` are not run. `parse-report.sh` is a checker, not a board script, and may be run on the implementor's own report.
- Mark the PR ready (`gh pr ready`) or merge it (`gh pr merge`).
- Edit files outside the worktree. The only exception is the report temp file in the system temp directory.
- Dispatch agents.
- Invent a PR number, test command, test result or `VERIFIED:` integer.
- Put a `#<digits>` in `## PR` when no PR exists.
- Commit implementation code in the first commit, or commit tests and implementation together.
- Force-push, amend or rewrite commits already on the branch.
- Weaken, skip or delete a test to make it pass.
- File issues or bug cards itself (`gh issue create`). Bugs and out-of-scope work are only reported.
- Open a second PR for a card that already has one.
- List, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory). Never post or pass to a board script any file other than the report file it created with `mktemp` in this dispatch.

## 5. Report

The implementor produces one report per dispatch. It posts the report on the card through `board-comment.sh` and returns the same text as its final reply.

**This role's rules:**
- **Status values:** `done` or `blocked`. The values `clean` and `findings` are the reviewer's and are rejected for this role.
- **Role section:** `## PR`. It contains `#<number>`, the real PR number, unless Status is `blocked` and no PR exists. In that case it states that no PR exists and contains no `#` followed by digits.
- `## PR` must contain no other `#<digits>`: not the card number and not an example. The parser reads the first `#` followed by digits as the PR number. `Closes #<card number>` goes in the PR body, never in `## PR`.
- `## Findings`, `Out of scope:`, `Bugs found:` and the `VERIFIED:` line follow the shape and line rules below.

**Enforcement:** `parse-report.sh --role implementor` enforces the Report shape, the Line rules and the `--role` rules below. A report that breaks any rule is rejected: exit 1, nothing on stdout, and one `parse-report: `-prefixed stderr line per problem. The manager then re-dispatches the role once, with those lines and the rule quoted. A second rejected report is recorded as a report error, and the card stays where it is. So the implementor writes the report with the Write tool to the path `mktemp` printed, then checks and posts it in ONE Bash call that names that literal path: `bash <scripts dir>/parse-report.sh --role implementor <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0. If the check fails, it fixes the file with Edit or Write and repeats that check-and-post call.

The role agent has only `Read, Write, Edit, Bash, Grep, Glob` and no `Skill` tool, so it cannot load a reporting skill. Everything it needs to write a valid report is in this section.

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

`scripts/parse-report.sh [--role implementor|reviewer|fixer] <file>` (in the fleet-board scripts directory) is the enforced definition of the Report shape above. The complete list of rejection messages (`<...>` is filled in from the report; each appears after `parse-report: `):

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

### Pitfalls for the report writer

- The `VERIFIED:` command sits between single backticks, so it cannot contain a backtick itself. A command that would need one must be rewritten. For example, a command that pastes card text containing backticks should instead read the text with `gh issue view <n> --json body --jq .body`.
- In `## PR`, the first `#` followed by digits is read as the PR number. So `## PR` must contain no `#<digits>` except the real PR number: not the card number, not an example.
- In `## For the card`, free text must not start a line with `- ` unless that line is an entry directly under `Out of scope:` or `Bugs found:`. Otherwise it is a stray list line. Put free text before the sub-lists, and do not leave a blank line between a sub-list header and its entries.
- Each heading appears once. Do not repeat `## Findings` or `## PR`.
- A `Bugs found:` entry needs all four parts, with the repro in backticks. An `Out of scope:` entry needs ` :: ` with text on both sides. Leave out a sub-list header entirely when it has no entries.

### Template A: normal report (Status `done`)

```
## Status
done

## Findings
- none

## For the card
Tests for both Acceptance items are in test/calc.test.js. Test-first commit 3f2a1c9, implementation commit 8b7d0e4, pushed head 8b7d0e4.
`node --test test/calc.test.js`: 2 failing before implementation, 2 passing after. Typecheck passed; lint passed.
Out of scope:
- Divide by zero :: calc defines no behavior for divide(1, 0)
Bugs found:
- Lint error in untouched file :: repro: `npm run lint` :: expected: 0 problems :: observed: src/legacy.js 4:7 error 'tmp' is assigned a value but never used

## PR
Draft PR #12 on branch fleet/add-calc.

VERIFIED: `node --test test/calc.test.js` -> 2 tests passed
```

Leave out `Out of scope:` and `Bugs found:` when there is nothing to list. The numbers, SHAs, PR number and outputs shown above are placeholders. A real report carries only values the implementor observed.

### Template B: blocked before any test or PR exists

```
## Status
blocked

## Findings
- [Important] The card has no ## Acceptance section, so there is nothing to write a failing test against.

## For the card
Add a ## Acceptance section with one bullet per testable behavior, then move the card back to Ready. No test, commit, push or PR was made, and the worktree is unchanged.

## PR
No PR: blocked before any test was written.

VERIFIED: `gh issue view 7 --json body --jq .body | grep -c '^## Acceptance'` -> 0 Acceptance sections in the card body
```

For the other block causes, the finding names that cause, and the `VERIFIED:` line uses the matching command from Required behavior step 2.

## 6. Acceptance criteria this role satisfies

- **fleet-board.AC3.1 Success:** The implementor's first commit contains a failing test and no implementation.
- **fleet-board.AC3.2 Success:** The implementor runs only the individual test file(s) it wrote, never the full suite.
- **fleet-board.AC3.3 Success:** The implementor opens a draft PR and posts a report in the fixed shape with a `VERIFIED:` line.
- **fleet-board.AC3.10 Success:** A bug a role agent observes outside its card's scope, reported under `Bugs found:` with a repro command and the expected and observed results, becomes a Backlog card labelled `bug` with those details, linked from the PR; a bug matching an open issue's title is not filed twice, and the existing issue is linked instead. *(Partial: this phase defines the report format and parses it. Filing is Phase 6.)* This role covers the reporting side only: the `Bugs found:` format. Filing is the manager's job.
- **fleet-board.AC5.3 Success:** Every agent report contains `## Status`, `## Findings`, `## For the card`, and one `VERIFIED:` line.
