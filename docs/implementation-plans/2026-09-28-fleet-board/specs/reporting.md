# Behavior spec: reporting

## Purpose

Every fleet-board role agent (implementor, reviewer, fixer) ends its work with one report in a fixed shape. The report is posted on the card and returned as the role's final reply. This spec defines that report and describes how the fleet-board manager checks it with `parse-report.sh`, quotes a rule back to a role, and handles a rejected report. The manager is the reader of this spec and of the reporting skill written from it. Role agents cannot load skills. Each role's own prompt carries the report shape, so this spec is not a role's instructions.

## Inputs

What the manager has when it handles a role's report:

- **The role's final report text.** This is the role's final reply, and the role has also posted the same text on the card as a comment.
- **The role name.** One of `implementor`, `reviewer` or `fixer`, meaning the role the manager dispatched for this report.
- **The fleet-board scripts directory.** This is where `parse-report.sh` and `board-comment.sh` live.
- **The role's original dispatch inputs.** These are the card number, the worktree, the project config, the model the role ran on and any role-specific inputs, such as the findings given to a fixer. The manager needs them for a re-dispatch.

## Required behavior

All example test commands in this spec assume `commands.test_one` is `node --test {file}` and that `test_paths` matches files such as `test/calc.test.js`. Every example is therefore one concrete test file run through `test_one`.

### How a role produces its report (what the manager can rely on)

1. The role runs `mktemp` in a Bash call and notes the absolute path it prints. It writes its report to exactly that path with the Write tool. It never puts the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command. If the Write tool refuses the file because it has not been read, it reads it once with the Read tool and writes it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path). It then checks and posts the report in ONE Bash call that names that literal path: `bash <scripts dir>/parse-report.sh --role <role> <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0. The role creates the file with `mktemp` only, never at a self-chosen path. It returns exactly the same text as its final reply. Posting a comment is the only board action a role takes: it never moves a card and never files an issue.
2. A role has exactly the tools `Read, Write, Edit, Bash, Grep, Glob` and no `Skill` tool. Everything it needs to write a valid report comes from its own prompt. If the check fails, the role fixes the file with Edit or Write and repeats the one Bash call that checks and posts it. Running the checker only reads the report and is not a board action. **Must never:** a role must never list, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory), and must never post or pass to a board script any file other than the report file it created with `mktemp` in this dispatch.

### The manager's check

3. For every role report, the manager writes the role's final report text to a temp file exactly as returned: nothing trimmed, completed or reformatted. It then runs `bash <scripts dir>/parse-report.sh --role <role> <file>`, where `<role>` is the role it dispatched. If the final reply is empty or missing, the manager checks that empty text. The checker rejects it (missing sections, `found 0` VERIFIED lines), and the manager handles it like any other rejection.
4. **Exit 0 (accepted).** The manager takes every value it acts on from the JSON the checker prints on stdout: status, findings and their severities, Out of scope and Bugs found entries, the PR number, `blocked_by` and the VERIFIED line. It never re-parses the markdown by hand. It copies the accepted `VERIFIED:` line into the card's manager note as the card's last VERIFIED line.
5. **Exit 1 (rejected).** Stdout is empty and stderr holds one `parse-report: `-prefixed line per problem. The manager re-dispatches the same role once, on the same model the rejected report came from, with the same dispatch inputs plus this text, where `<parse-report stderr>` is every stderr line quoted exactly:

   ```
   Your previous report was rejected by the manager: <parse-report stderr>. The rule: every report contains ## Status, ## Findings, ## For the card, and exactly one line of the form VERIFIED: `<command>` -> <integer> <what it counts>.
   ```

   For each stderr line, the manager also includes the Report shape rule that message enforces, quoted from the rule table below.
6. **Second rejection.** The manager checks the re-dispatched role's report the same way (item 3). If that report is also rejected (exit 1), the manager records a report error for the card in its manager note, naming the role and quoting the second run's stderr lines. The card stays in its current state. There is never a third dispatch for the same report.
7. **Nothing acts on a rejected report.** Until a report exits 0, the manager does not move the card and does not open or mark a PR because of it. It does not file Out of scope or Bugs found entries from it, and it does not copy its VERIFIED line into the note.
8. **Exit 2 (usage error).** The messages are `unknown flag: <flag>`, `unknown role: <role>`, `cannot read file: <file>` or the usage line. The fault is in the manager's own call, not in the report. The manager corrects its call (flag, role name, file path) and runs the checker again. It never re-dispatches a role because of exit 2, and never counts it as a rejection.
9. The manager never edits, completes or rewrites a role's report to make it pass. It never accepts a report the checker rejected.

### Rules for writing a valid report (enforced or relied on)

10. **Required sections.** Every report contains `## Status`, `## Findings` and `## For the card`, and exactly one `VERIFIED:` line. It also contains the role sections for its role (see Report).
11. **Findings, Out of scope and Bugs found are kept apart:**
    - **Findings** are defects in this card's own diff or in its Acceptance.
    - **Out of scope** is work worth doing that this card does not cover.
    - **Bugs found** are defects the role *observed* outside this card's diff, such as a pre-existing failing behavior it ran into. A defect caused by the card's own change is a Finding, never a Bug found, even when it shows up far from the edited lines. A defect that existed before the card, and was only discovered while working on it, is a Bug found.
12. **Bugs found entries.** Each Bugs found line has all four parts: title, repro, expected, observed. The repro is a command the role actually ran, between backticks. `observed` is what that command printed, not a paraphrase of what the role believes. Example: ``- parse drops trailing zero :: repro: `node --test test/parse.test.js` :: expected: ok 2 - keeps trailing zero :: observed: not ok 2 - keeps trailing zero``.
13. **The `VERIFIED:` line:**
    - There is exactly one.
    - It names a real command the role ran, between single backticks. The arrow follows, `->` or `→`, then the integer that command's output showed, then what that integer counts. Example: ``VERIFIED: `node --test test/calc.test.js` -> 3 passing tests``.
    - The integer is never invented, estimated, rounded or summed across separate runs. Counts from overlapping runs are not added together. A run that failed to execute contributes nothing, so it is never counted as passing or as a killed mutant.
    - The integer ends at whitespace or the line end, so `3abc` and `3.5` are rejected.
    - The command cannot contain a backtick. A command that would need one must be rewritten. For example, card text that holds backticks is read with `gh issue view <n> --json body --jq .body` rather than pasted.
14. **`## PR`.** For the implementor and fixer, the first `#` followed by digits in `## PR` is read as the PR number. So `## PR` contains no other `#<digits>`: no card number and no example. It holds `#<number>` unless Status is `blocked`.
15. **Blocked before any work.** An implementor that stopped before writing any test or opening a PR (for example, on a card with no Acceptance section) reports Status `blocked`. Its `## PR` states that no PR exists, with no `#<digits>` in it. Its `VERIFIED:` line counts something it actually checked, such as ``VERIFIED: `gh issue view 12 --json body --jq .body | grep -c '^## Acceptance'` -> 0 Acceptance sections``.
16. **Blocked by.** A `Blocked by: #N` line in `## For the card` is read into `blocked_by` in the checker's JSON. The manager uses it as the card's blocker.
17. **Line rules and With `--role` rules.** Every Line rule and every With `--role` rule in the Report section holds. `parse-report.sh --role <role>` rejects any violation, printing one `parse-report: ` stderr line per problem.

### Rule table

Every rejection message, the Report shape rule it enforces, and one valid form. When re-dispatching (item 5), the manager quotes the "Rule" cell for each stderr line.

| Rejection message (after `parse-report: `) | Rule it enforces | Valid form |
|---|---|---|
| `missing section: ## Status` | Every report contains `## Status`. | `## Status` followed by `done` |
| `missing section: ## Findings` | Every report contains `## Findings`. | `## Findings` followed by `- none` |
| `missing section: ## For the card` | Every report contains `## For the card`. | `## For the card` followed by a line of free text |
| `unknown status: <word>` | `## Status` is one word: `done`, `blocked`, `clean` or `findings`. | `blocked` |
| `role <role> does not allow status: <word>` | `done` and `blocked` are for the implementor and fixer; `clean` and `findings` are for the reviewer. | `clean` (reviewer) |
| `expected exactly one VERIFIED: line, found <N>` | There is exactly one `VERIFIED:` line. | `` VERIFIED: `node --test test/calc.test.js` -> 3 passing tests `` |
| `VERIFIED line needs a backticked command and an integer after ->` | The command sits between backticks, the arrow is `->` or `→`, and the first token after the arrow is an integer ending at whitespace or the line end. | `` VERIFIED: `node --test test/calc.test.js` → 3 passing tests `` |
| `bug entry needs title, repro, expected, observed` | Each Bugs found line has all four parts. | `` - parse drops trailing zero :: repro: `node --test test/parse.test.js` :: expected: ok 2 :: observed: not ok 2 `` |
| `role <role> requires ## <section>` | Role sections: implementor `## PR`; fixer `## PR` and `## Resolutions`; reviewer `## Acceptance map`, `## Mutation` and `## Claim check`. | `## Resolutions` (fixer) |
| `duplicate section: ## <heading>` | Any heading appears at most once. | a single `## Findings` heading |
| `## Status must be one line, extra line: <line>` | `## Status` holds exactly one non-blank line. | `findings` |
| `malformed finding line: <line>` | Every non-blank `## Findings` line is `- [Critical] <text>`, `- [Important] <text>` or `- [Minor] <text>`, with that exact spelling and one space after `-`, or exactly `- none`. | `- [Important] add() returns NaN for empty input` |
| `## Findings needs "- none" or at least one "- [Critical\|Important\|Minor] <text>" line` | `## Findings` needs one of the two forms. | `- none` |
| `## Findings mixes "- none" with findings` | `## Findings` uses one of the two forms, never both. | `- [Minor] typo in the error text` (with no `- none` line) |
| `empty sub-list: Out of scope:` | An `Out of scope:` header needs at least one entry. | `Out of scope:` directly followed by `- Subtraction :: calc has no subtract()` |
| `empty sub-list: Bugs found:` | A `Bugs found:` header needs at least one entry. | `Bugs found:` directly followed by a four-part bug line |
| `stray list line in ## For the card (sub-list entries follow their header or the previous entry directly, unindented): <line>` | Entries are unindented `- ` lines directly under the header or the previous entry. A blank or text line ends the list. A `- ` line after that blank line, or an indented `  - ` line inside a list, is an error. | `- Subtraction :: calc has no subtract()` on the line right after `Out of scope:` |
| `bug repro must be a backticked command: <title>` | A bug's repro is backticked. | ``repro: `node --test test/parse.test.js` `` |
| `out of scope entry needs <title> :: <detail>: <entry>` | An Out of scope entry needs ` :: ` with a non-empty title and detail. | `- Subtraction :: calc has no subtract()` |
| `malformed ## Acceptance map line: <line>` | Acceptance map lines are split on the last ` -> `; the test is `<file>::<test name>` or `UNMAPPED`. | `- adds two numbers -> test/calc.test.js::adds two numbers` |
| `malformed ## Mutation line: <line>` | Mutation is exactly one line: `killed: <n> survived: <n> invalid: <n>` or `skipped: review.mutation is off`. | `killed: 2 survived: 0 invalid: 0` |
| `## Mutation needs exactly one "killed: <n> survived: <n> invalid: <n>" or "skipped: review.mutation is off" line` | Mutation is exactly one line of the two forms. | `skipped: review.mutation is off` |
| `## Claim check command must be one backticked command: <value>` | The Claim check `command:` holds one backticked command. | ``command: `node --test test/calc.test.js` `` |
| `## Claim check matches must be yes or no: <value>` | The Claim check `matches:` is `yes` or `no`. | `matches: no` |
| `malformed ## Claim check line: <line>` | Claim check holds only the lines `claim:`, `command:`, `result:` and `matches:`, or only the skipped line. | `result: 3 passing tests` |
| `## Claim check needs one each of claim:, command:, result: and matches:, or only "skipped: review.verify_claim is off"` | Claim check has each of the four keys once, or only the skipped line. | `skipped: review.verify_claim is off` |
| `malformed ## Resolutions line (want - <finding> :: fixed \| not fixed: <why>): <line>` | One line per input finding. The finding and its outcome are split at the first ` :: ` followed by `fixed` or `not fixed: <why>`, and `<why>` is non-empty. | `- [Minor] rename helper :: not fixed: the rename reaches files outside this card` |
| `role <role> requires a PR number (#<n>) in ## PR unless status is blocked` | The implementor's and fixer's `## PR` holds `#<number>` unless Status is `blocked`. | `Draft PR #7 opened.` |
| `status clean needs zero Critical and Important findings, found <n>` | The reviewer's `clean` means zero Critical and zero Important findings. | `clean` with Findings `- none` |
| `status findings needs at least one Critical or Important finding` | The reviewer's `findings` means at least one Critical or Important finding. | `findings` with `- [Critical] mutant in add() survived test/calc.test.js::adds two numbers` |
| `role reviewer requires at least one ## Acceptance map entry` | The reviewer's Acceptance map has at least one entry. | `- rejects empty input -> UNMAPPED` |
| `role fixer requires at least one ## Resolutions entry` | The fixer's Resolutions has at least one entry. | `- [Important] add() ignores negatives :: fixed` |

The usage errors `unknown flag: <flag>`, `unknown role: <role>`, `cannot read file: <file>` and the usage line exit 2. They have no rule to quote because they are never sent to a role (item 8).

## Must never

The manager must never:

- Edit, complete, trim or rewrite a role's report, whether to make it pass or for any other reason.
- Accept a report that `parse-report.sh --role <role>` rejected, or act on one: move the card, mark a PR, file an Out of scope or Bugs found card, or record its VERIFIED line.
- Re-dispatch more than once for one rejected report, or dispatch a third time after a second rejection.
- Re-dispatch a role because the checker exited 2.
- Paraphrase a rejection instead of quoting the `parse-report: ` stderr lines exactly.
- Re-parse report markdown by hand when the checker's JSON is available.
- Check a report with a role other than the one it dispatched, or without `--role`.
- Ask a role to use, load or follow the reporting skill. Roles have no `Skill` tool and cannot load skills.
- Give or quote an example command that could run the whole suite, such as `npm test` or a bare `node --test`. Examples are `commands.test_one` with one concrete test file, such as `node --test test/calc.test.js`.

A report itself must never:

- Contain an invented, estimated or summed `VERIFIED:` integer.
- Contain a `VERIFIED:` command holding a backtick.
- List a defect in the card's own diff under Bugs found.
- Give a bug repro that the role did not actually run.

## Report

This is the report every role writes. `parse-report.sh --role <role>` enforces the shape, its Line rules and its With `--role` rules, as described below. A report that violates any of them is rejected: the checker exits 1, prints nothing on stdout and prints one `parse-report: `-prefixed stderr line per problem.

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

`scripts/parse-report.sh [--role implementor|reviewer|fixer] <file>` is the enforced definition of the Report shape. Each message below appears after `parse-report: ` (`<...>` is filled in from the report):

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

### Role-specific points the manager must know

| Role | Status values | Role sections | `## PR` rule |
|---|---|---|---|
| implementor | `done`, `blocked` | `## PR` | Holds `#<number>` unless Status is `blocked` |
| fixer | `done`, `blocked` | `## PR`, `## Resolutions` (at least one entry, one per input finding) | Holds `#<number>` unless Status is `blocked` |
| reviewer | `clean` (zero Critical and Important), `findings` (at least one Critical or Important) | `## Acceptance map` (at least one entry), `## Mutation`, `## Claim check` | none |

- In `## PR`, the first `#<digits>` is the PR number. Any other `#<digits>` there (a card number, an example) would be read as the PR.
- A blocked implementor that stopped before any test or PR (for example, on a card without an Acceptance section) has a `## PR` stating that no PR exists. Its `VERIFIED:` line counts something it checked, such as `-> 0` Acceptance sections.
- A `Blocked by: #N` line in `## For the card` gives `blocked_by`.
- Findings are defects in this card's diff or Acceptance. Out of scope is uncovered work, which becomes a Backlog card. Bugs found are defects observed outside the diff, which become `bug`-labelled Backlog cards, deduplicated against open issues. Filing these cards is the manager's job in Phase 6, and it happens only from accepted reports.

### Example reports that pass

Implementor, `--role implementor`:

```
## Status
done

## Findings
- none

## For the card
Added add() with one test per Acceptance item.
Out of scope:
- Subtraction :: calc has no subtract() yet

## PR
Draft PR #7 opened from branch fleet/card-12.

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
```

Implementor blocked before any work, `--role implementor`:

```
## Status
blocked

## Findings
- none

## For the card
Stopped before writing a test: the card body has no Acceptance section.

## PR
No PR exists; work stopped before the first commit.

VERIFIED: `gh issue view 12 --json body --jq .body | grep -c '^## Acceptance'` -> 0 Acceptance sections
```

Reviewer, `--role reviewer`:

```
## Status
clean

## Findings
- none

## For the card
Every Acceptance item maps to a test; every mutant was killed.

## Acceptance map
- adds two numbers -> test/calc.test.js::adds two numbers
- rejects empty input -> test/calc.test.js::rejects empty input

## Mutation
killed: 2 survived: 0 invalid: 0

## Claim check
claim: 3 tests pass in test/calc.test.js
command: `node --test test/calc.test.js`
result: pass 3
matches: yes

VERIFIED: `node --test test/calc.test.js` -> 3 passing tests
```

Fixer, `--role fixer`:

```
## Status
done

## Findings
- none

## For the card
Fixed the negative-input finding; the rename is left for its own card.
Bugs found:
- parse drops trailing zero :: repro: `node --test test/parse.test.js` :: expected: ok 2 - keeps trailing zero :: observed: not ok 2 - keeps trailing zero

## PR
Pushed to PR #7.

## Resolutions
- [Important] add() ignores negative input :: fixed
- [Minor] rename helper :: not fixed: the rename reaches files outside this card

VERIFIED: `node --test test/calc.test.js` -> 4 passing tests
```

## Acceptance criteria this role satisfies

- **fleet-board.AC5.3 Success:** Every agent report contains `## Status`, `## Findings`, `## For the card`, and one `VERIFIED:` line.
- **fleet-board.AC5.4 Failure (detection side):** A report missing the `VERIFIED:` line is rejected by the manager, which re-dispatches once with the rule quoted. *(Partial: this phase builds and tests the detection in `parse-report.sh`. The re-dispatch is the manager's behavior and is completed in Phase 6.)*
- **fleet-board.AC3.10 Success (report format side):** A bug a role agent observes outside its card's scope, reported under `Bugs found:` with a repro command and the expected and observed results, becomes a Backlog card labelled `bug` with those details, linked from the PR; a bug matching an open issue's title is not filed twice, and the existing issue is linked instead. *(Partial: this phase defines the report format and parses it. Filing is Phase 6.)*
