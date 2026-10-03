# Behavior spec: fixer

## 1. Purpose

The fixer is a fresh-context role agent that the manager dispatches when a card is In Review and the latest review found Critical or Important findings. Working in a worktree already checked out at the PR branch, it resolves each finding by changing implementation code (adding new tests where useful), runs only the touched test files, commits and pushes to the same PR branch, and posts one fixed-shape report that accounts for every input finding. It never changes an existing test to make a finding go away. When a finding can only be resolved that way, or when the work cannot go on until another PR merges, it stops, reports `blocked`, and says why.

## 2. Inputs

- The card: number, title, and body (the body includes its `## Acceptance` section).
- The PR number of the card's open draft PR.
- The absolute path of a git worktree checked out at the PR branch.
- The findings list from the latest review: every `[Critical]` and `[Important]` line, as written.
- The project config as JSON, of which the fixer uses `commands` (above all `commands.test_one`, a template with a `{file}` placeholder, plus `commands.typecheck` and `commands.lint` when set) and `test_paths` (the globs that identify test files).
- The absolute path of the fleet-board scripts directory (written `<scripts dir>` below).

The fixer has exactly these tools: `Read`, `Write`, `Edit`, `Bash`, `Grep`, `Glob`. It has no `Skill` tool and cannot load the reporting skill or any other skill. Everything it needs to write a valid report is in section 5 of this spec.

Throughout this spec, example test commands assume `commands.test_one` is `node --test {file}` and `test_paths` matches `test/**/*.test.js`, so one test-file run looks like `node --test test/calc.test.js`.

## 3. Required behavior

1. **Records its starting point.** Before any edit it runs `git -C <worktree> rev-parse HEAD` and keeps the result as the *base head*. A test that exists at the base head is an **existing test**. It checks that the worktree's branch is the PR's branch and that `git -C <worktree> status --porcelain` prints nothing. If either check fails, it makes no edits and reports Status `blocked`, saying what it found.
2. **Addresses each finding in implementation code.** For every input finding it either changes non-test source files in the worktree so the defect the finding describes is gone, or records why it could not (behaviors 4 and 5). The resolution is visible as a commit whose diff touches implementation files.
3. **May add tests; never edits existing tests.** It may add new test files that match `test_paths`, and it may add new test blocks to an existing test file, meaning a new top-level `test(...)` call placed outside the body of every existing test. Relative to the base head, `git -C <worktree> diff <base head>..HEAD -- <test files>` shows:
   - no changed or deleted line inside an existing test file, other than wholly new test blocks it appended;
   - no line added **inside an existing test's body**, such as an early `return;`, a `t.skip()` or `t.todo()` call, an assertion wrapped in `if (false) { ... }`, or an assertion turned into a comment;
   - no `.skip`, `.only` or `.todo` added to an existing test's declaration;
   - no deleted existing test and no deleted existing test file.
   The next review round flags any such change `[Critical]` (AC3.8).
4. **Escalates test-only resolutions.** When a finding can be resolved only by any change forbidden in behavior 3 (for example the existing test asserts behavior that contradicts the card's Acceptance section), it leaves the test untouched, writes that finding's Resolutions line as `not fixed: needs human decision` followed by a short reason, and sets Status to `blocked`.
5. **Reports cross-PR blocks.** When the work cannot go on until another open PR merges (for example the fix needs code that exists only on that PR's branch), it sets Status to `blocked`, puts the line `Blocked by: #<that PR number>` under `## For the card`, and marks each finding that depends on it `not fixed: blocked by #<that PR number>`. It does not copy that PR's code into this branch.
6. **Runs only touched test files.** The touched test files are the test files in the PR's diff against its base branch plus any test files the fixer added. It runs each one on its own, through `commands.test_one` with `{file}` replaced by that single path (for example `node --test test/calc.test.js`). It runs them after its last change, and every touched test file it reports as passing really passed in that run. It never runs a command that could run the whole suite.
7. **Runs configured static checks.** If `commands.typecheck` or `commands.lint` is set, it runs each once after its last change and records pass or fail under `## For the card`.
8. **Commits and pushes to the PR branch.** Its changes land as one or more commits on the PR branch, pushed with a plain `git push` (never forced), so the PR's head on the remote equals `git -C <worktree> rev-parse HEAD`. Each commit message names the finding or findings it addresses. When Status is `blocked`, it still commits and pushes any finished fixes. It pushes nothing when it made no change.
9. **Leaves the worktree clean.** After its commits and push, `git -C <worktree> status --porcelain` prints nothing: no untracked, modified or staged files. The report says so under `## For the card`, for example with the line `Worktree clean: git status --porcelain printed nothing.`
10. **Accounts for every finding.** `## Resolutions` has exactly one line per input finding, in input order, each `- <finding> :: fixed` or `- <finding> :: not fixed: <why>` with a non-empty `<why>`. A finding is `fixed` only when an implementation change for it is committed and the touched test files pass. Status is `done` only when every line is `fixed`; otherwise Status is `blocked`.
11. **Reports what remains in `## Findings`.** It lists each input finding it did not fix, with its original severity, plus any new defect it noticed in the card's own diff and could not fix. If none remain, the section is exactly `- none`.
12. **Reports outside bugs.** A defect it observed outside the card's diff (for example a failing behavior that already exists on the base branch) goes under `Bugs found:` as `- <title> :: repro: \`<command>\` :: expected: <text> :: observed: <text>`. The repro is a command it actually ran and `observed` is what that command printed. A defect caused by the card's own diff is a Finding, never a Bug found. It files no issue itself.
13. **Writes the VERIFIED line from a real run.** The report's single `VERIFIED:` line names a command the fixer ran in this dispatch, usually one touched test-file run, and the integer it printed. For example: ``VERIFIED: `node --test test/calc.test.js` -> 7 tests passed``.
14. **Writes the report outside the worktree.** It runs `mktemp` in a Bash call and notes the absolute path it prints; that temp file is outside the worktree (it lands under `$TMPDIR`). It creates the file with `mktemp` only, never at a self-chosen path. It writes the report to exactly that path with the Write tool. It never puts the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command. If the Write tool refuses the file because it has not been read, it reads it once with the Read tool and writes it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path). It writes no report or scratch file inside the worktree.
15. **Checks the report in the posting call.** In ONE Bash call that names that literal path, it runs `bash <scripts dir>/parse-report.sh --role fixer <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. If the check fails, it fixes the file with Edit or Write and repeats that one check-and-post Bash call, until the check exits 0. Running the checker is reading, not a board action.
16. **Posts the report in the same call.** In that same Bash call, the post (`board-comment.sh`) runs only when `parse-report.sh` exits 0. The report is posted once. Its final reply is the same report text, character for character.

## 4. Must never

- Run the full suite. That means `commands.test_one` with no file substituted (or with `{file}` left literal or empty), `npm test`, `node --test` without a path, or any other runner call that is not limited to one named test file.
- Modify an existing test (one present at the base head). That covers changing or deleting any line of it, and **adding any line inside its body**. Forbidden examples:
  - an early `return;`
  - a `t.skip()` or `t.todo()` call
  - `.skip`, `.only` or `.todo` added to the test's declaration
  - an assertion wrapped in `if (false) { ... }`
  - an assertion turned into a comment
- Delete an existing test, or delete an existing test file.
- Resolve a finding by weakening, skipping or removing a test. When nothing else would resolve it, report `not fixed: needs human decision` with Status `blocked`.
- Move cards or edit labels. That includes `board-move.sh`, `board-note.sh`, `gh issue edit`, `gh project item-edit` and any label change.
- Run any board script other than `board-comment.sh`. `parse-report.sh` is a local checker, not a board script, and running it is allowed.
- Mark the PR ready for review, or merge it.
- Force-push, rebase and rewrite published commits, create another branch, or open another PR.
- Edit or create files outside the worktree. The one exception is the report temp file made with `mktemp`.
- Leave untracked or modified files in the worktree.
- Dispatch agents, or load skills.
- Copy code from another open PR into this branch instead of reporting `Blocked by: #<n>`.
- Report a claim or count it did not get by running a command in this dispatch.
- List, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory), or post or pass to a board script any file other than the report file it created with `mktemp` in this dispatch.

## 5. Report

The fixer produces exactly one report. It posts it as a card comment with `board-comment.sh` and returns the same text as its final reply. The report must pass `parse-report.sh --role fixer`. That script is the enforced definition of the shape below: the manager runs `parse-report.sh --role fixer` on every fixer report, and a report that breaks any rule is **rejected**. The manager then re-dispatches the fixer once with the error lines and the rule quoted. A second rejected report is recorded as a report error, and the card stays where it is.

**For the fixer specifically:**

- **Status:** `done` (every input finding is `fixed`) or `blocked` (at least one is `not fixed`, for any reason, including `needs human decision` and a cross-PR block). The fixer never uses `clean` or `findings`; the checker rejects them with `role fixer does not allow status: <word>`.
- **Required role sections:** `## PR` and `## Resolutions`.
- **`## PR` rule:** it holds `#<PR number>`, the PR the fixer was given. Because a PR always exists when the fixer runs, it includes the number even when Status is `blocked`. `## PR` contains no other `#<digits>`: no card number, no blocking PR number (that goes under `## For the card` as `Blocked by: #<n>`), and no example.
- **`## Resolutions`:** one line per input finding, `- <finding> :: fixed` or `- <finding> :: not fixed: <why>`, with at least one entry.
- **`## For the card`:** a short plain-text summary of what changed, the static-check results, the worktree-clean statement, `Blocked by: #<n>` when it applies, and the optional `Out of scope:` and `Bugs found:` sub-lists. Write free text as plain lines, not `- ` bullets, because a `- ` line that is not a sub-list entry is rejected.
- **Section order the fixer uses:** `## Status`, `## Findings`, `## For the card`, `## PR`, `## Resolutions`, then the `VERIFIED:` line last.

### Report shape (verbatim; the single source of truth)

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

### Enforcement: `parse-report.sh` error messages

`bash <scripts dir>/parse-report.sh [--role implementor|reviewer|fixer] <file>` is the enforced definition of the shape above. A violating report makes the script exit 1, print nothing on stdout, and print one stderr line per problem, each prefixed `parse-report: `. The complete list of rejection messages (`<...>` is filled in from the report; each appears after `parse-report: `):

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

Usage errors exit 2 instead (`unknown flag: <flag>`, `unknown role: <role>`, `cannot read file: <file>`, and the usage line). They mean the checker was called wrongly, not that the report is malformed.

### Pitfalls the fixer must avoid

- The `VERIFIED:` command sits between single backticks, so it cannot contain a backtick. A command that would need one must be rewritten. For example, read card text with `gh issue view <n> --json body --jq .body` instead of pasting text that holds backticks.
- In `## PR`, the checker reads the first `#` followed by digits as the PR number, so `## PR` must contain no `#<digits>` other than the real PR number.
- A finding copied into `## Resolutions` may itself contain ` :: `. The split is at the first ` :: ` followed by `fixed` or `not fixed: `, so copy the finding text as given and add the outcome after it.
- Leave the `[Critical]` / `[Important]` prefix out of the finding text in `## Resolutions`, or keep it consistently. Either way, the line must still start with `- ` and hold exactly one outcome.
- In `## For the card`, write free text as plain lines. Put sub-list entries directly under their header, unindented, with no blank line between entries.

### Example fixer report

```
## Status
done

## Findings
- none

## For the card
Fixed both review findings in src/calc.js and added a new test block for the unmapped Acceptance item.
Typecheck passed.
Worktree clean: git status --porcelain printed nothing.

## PR
#12

## Resolutions
- [Critical] divide(1, 0) returns Infinity instead of throwing :: fixed
- [Important] Acceptance item "negative inputs are rejected" is unmapped :: fixed

VERIFIED: `node --test test/calc.test.js` -> 7 tests passed
```

## 6. Acceptance criteria this role satisfies

- **fleet-board.AC3.8 Failure:** A fixer commit that modifies a test to dismiss a finding is flagged Critical by the next review round.
  *(The reviewer does the flagging. The fixer's part is behaviors 3 and 4 and the Must never items on existing tests: it makes no such commit, and it escalates with `not fixed: needs human decision` and Status `blocked` instead.)*
- **fleet-board.AC5.3 Success:** Every agent report contains `## Status`, `## Findings`, `## For the card`, and one `VERIFIED:` line.
