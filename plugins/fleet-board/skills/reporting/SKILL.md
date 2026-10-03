---
name: reporting
description: Use when the fleet-board manager checks a role report (implementor, reviewer or fixer) with parse-report.sh, quotes a report rule to a role, or re-dispatches a role whose report parse-report.sh rejected. Gives the manager the check-and-re-dispatch method (exit 0 accept from the JSON, exit 1 re-dispatch once with the stderr quoted exactly, exit 2 fix its own call), the exact report shape with its line rules and per-role rules, every parse-report.sh rejection message paired with the rule to quote, and the role-specific points.
user-invocable: false
---

# Reporting (manager side)

## Principle

Every role agent (implementor, reviewer, fixer) ends with one report in a fixed shape. It posts the report on the card and returns the same text as its final reply. `parse-report.sh --role <role>` is the enforced definition of that shape. You, the manager, run the checker on the report text exactly as the role returned it. You act only on reports the checker accepts, and only on the values in its JSON. When the checker rejects a report you re-dispatch the same role once, quoting the checker's stderr exactly along with the rule each line enforces. You never repair a report yourself. Role agents have no `Skill` tool and cannot load this skill. Each role's own prompt carries the report shape, so this skill is for you alone.

## Method

Before you start, have these to hand: the role's final report text, the role name you dispatched (`implementor`, `reviewer` or `fixer`), the fleet-board scripts directory (where `parse-report.sh` and `board-comment.sh` live), and the role's original dispatch inputs (card number, worktree, project config, the model the role ran on, and any role-specific inputs such as the findings given to a fixer).

In every example below, `commands.test_one` is `node --test {file}` and one concrete test file such as `test/calc.test.js` is the target.

1. **Know what a role does.** A role runs `mktemp` in a Bash call and notes the absolute path it prints. It writes its report to exactly that path with the Write tool. It never puts the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command. If the Write tool refuses the file because it has not been read, it reads it once with the Read tool and writes it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path). It then checks and posts the report in ONE Bash call that names that literal path: `bash <scripts dir>/parse-report.sh --role <role> <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0. The role creates the file with `mktemp` only, never at a self-chosen path. It returns exactly the same text as its final reply. Posting that comment is its only board action: it never moves a card and never files an issue. A role has exactly the tools `Read, Write, Edit, Bash, Grep, Glob` and no `Skill` tool. If the check fails, the role fixes the file with Edit or Write and repeats the one Bash call that checks and posts it. Running the checker only reads the report, so it is not a board action. **Must never:** a role must never list, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory), and must never post or pass to a board script any file other than the report file it created with `mktemp` in this dispatch.
2. **Write the report to a temp file exactly as returned.** Don't trim, complete or reformat anything. If the final reply is empty or missing, write and check that empty text. The checker rejects it (missing sections, `found 0` VERIFIED lines), and you handle it like any other rejection.
3. **Run the checker with the dispatched role:** `bash <scripts dir>/parse-report.sh --role <role> <file>`. `<role>` is always the role you dispatched for this report. Never pass a different role and never leave out `--role`.
4. **Exit 0 (accepted).** Take every value you act on from the JSON on stdout: status, findings and their severities, Out of scope and Bugs found entries, the PR number, `blocked_by` and the VERIFIED line. Don't re-parse the markdown by hand. Copy the accepted `VERIFIED:` line into the card's manager note as the card's last VERIFIED line. Use `blocked_by`, which comes from a `Blocked by: #N` line in `## For the card`, as the card's blocker. Out of scope entries become Backlog cards. Bugs found entries become `bug`-labelled Backlog cards, deduplicated against open issues. File them only from accepted reports.
5. **Exit 1 (rejected).** Stdout is empty and stderr has one `parse-report: `-prefixed line per problem. Re-dispatch the same role once, on the same model the rejected report came from, with the same dispatch inputs plus this text. Replace `<parse-report stderr>` with every stderr line, quoted exactly:

   ```
   Your previous report was rejected by the manager: <parse-report stderr>. The rule: every report contains ## Status, ## Findings, ## For the card, and exactly one line of the form VERIFIED: `<command>` -> <integer> <what it counts>.
   ```

   For each stderr line, also add the rule that message enforces, quoted from the "Rule it enforces" cell of the rule table below. Quote the stderr lines exactly and don't paraphrase them. Don't tell the role to use, load or follow this skill.
6. **Check the re-dispatched report the same way** (steps 2–3). If it exits 0, go to step 4. If it is rejected again (exit 1), record a report error for the card in your manager note. Name the role and quote the second run's stderr lines. The card stays in its current state. There is never a third dispatch for the same report.
7. **Nothing acts on a rejected report.** Until a report exits 0, don't move the card and don't open or mark a PR because of it. Don't file its Out of scope or Bugs found entries, and don't copy its VERIFIED line into the note.
8. **Exit 2 (usage error).** The messages are `unknown flag: <flag>`, `unknown role: <role>`, `cannot read file: <file>` or the usage line. The fault is in your call, not in the report. Correct the flag, role name or file path and run the checker again. Never re-dispatch a role because of exit 2, and never count it as a rejection.
9. **Never repair or overrule.** Never edit, complete or rewrite a role's report to make it pass, and never accept a report the checker rejected.
10. **Judge content with the report rules.** A report must meet all of these (the checker enforces the shape; the manager relies on the rest):
    - **Required sections:** `## Status`, `## Findings`, `## For the card`, exactly one `VERIFIED:` line, and the role sections for its role.
    - **Findings, Out of scope and Bugs found stay apart.** Findings are defects in this card's own diff or in its Acceptance. Out of scope is work worth doing that this card does not cover. Bugs found are defects the role *observed* outside this card's diff, such as a pre-existing failing behavior it ran into. A defect caused by the card's own change is a Finding, never a Bug found, even when it shows up far from the edited lines. A defect that existed before the card and was only discovered while working on it is a Bug found.
    - **Bugs found entries** have all four parts: title, repro, expected, observed. The repro is a command the role actually ran, between backticks. `observed` is what that command printed, not a paraphrase. Example: ``- parse drops trailing zero :: repro: `node --test test/parse.test.js` :: expected: ok 2 - keeps trailing zero :: observed: not ok 2 - keeps trailing zero``.
    - **The `VERIFIED:` line.** There is exactly one. It names a real command the role ran, between single backticks, then the arrow (`->` or `→`), then the integer that command's output showed, then what that integer counts. Example: ``VERIFIED: `node --test test/calc.test.js` -> 3 passing tests``. The integer is never invented, estimated, rounded or summed across separate runs. Counts from overlapping runs are not added together. A run that failed to execute contributes nothing, so it never counts as passing or as a killed mutant. The integer ends at whitespace or the line end, so `3abc` and `3.5` are rejected. The command cannot contain a backtick, so a command that would need one must be rewritten. For example, card text that holds backticks is read with `gh issue view <n> --json body --jq .body` instead of being pasted.
    - **`## PR`** (implementor and fixer): the first `#` followed by digits is read as the PR number. It holds `#<number>` unless Status is `blocked`, and it contains no other `#<digits>`: no card number and no example.
    - **Blocked before any work.** An implementor that stopped before writing any test or opening a PR (for example, on a card with no Acceptance section) reports Status `blocked`. Its `## PR` says that no PR exists, with no `#<digits>` in it. Its `VERIFIED:` line counts something it actually checked, such as ``VERIFIED: `gh issue view 12 --json body --jq .body | grep -c '^## Acceptance'` -> 0 Acceptance sections``.
    - **Blocked by:** a `Blocked by: #N` line in `## For the card` becomes `blocked_by` in the JSON.
    - **Every Line rule and every With `--role` rule** in the reference holds. The checker rejects each violation with one `parse-report: ` stderr line.

## Reference

### Report shape (exact)

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

- **Status values by role:** `done` and `blocked` are for the implementor and fixer. `clean` and `findings` are for the reviewer.
- **The `VERIFIED:` line:** exactly one. The command sits between backticks, the arrow is `->` or `→`, and the first token after the arrow is an integer.
- **Role sections:**
  - **implementor and fixer:** `## PR` containing `#<number>`.
  - **fixer:** also `## Resolutions`, with one line per input finding: `- <finding> :: fixed | not fixed: <why>`.
  - **reviewer:** `## Acceptance map`, `## Mutation` and `## Claim check`:
    - **Acceptance map:** each line is `- <item text> -> <test file>::<test name>` or `- <item text> -> UNMAPPED`.
    - **Mutation:** either `killed: <n> survived: <n> invalid: <n>` or `skipped: review.mutation is off`.
    - **Claim check:** either the lines `claim: <text>`, ``command: `<cmd>` ``, `result: <observed>` and `matches: yes|no`, or `skipped: review.verify_claim is off`.

### Line rules

- Any heading appears at most once. `## Status` holds exactly one non-blank line.
- Every non-blank `## Findings` line is `- [Critical] <text>`, `- [Important] <text>` or `- [Minor] <text>` (that exact spelling, one space after `-`), or exactly `- none`. The section needs one of the two forms, never both.
- `Out of scope:` and `Bugs found:` each need at least one entry. Entries are unindented `- ` lines directly under the header or the previous entry. A blank or text line ends the list. A `- ` line after that blank line, or an indented `  - ` line inside a list, is an error. An Out of scope entry needs ` :: ` with a non-empty title and detail. A bug's repro is backticked.
- Resolutions: the finding and its outcome are split at the first ` :: ` followed by `fixed` or `not fixed: <why>`, so ` :: ` may appear inside both. `<why>` is non-empty.
- Acceptance map lines are split on the last ` -> `. The test is `<file>::<test name>` or `UNMAPPED`. Mutation is exactly one line of the two forms. Claim check has each of the four keys once, or only the skipped line.
- The `VERIFIED:` integer ends at whitespace or the line end (`-> 3abc` and `-> 3.5` are rejected).
- CRLF line endings, tabs and padded headings (`##  Status `) are accepted.

### With `--role` rules

- The role's sections are required.
- Status must be one of the role's two values.
- The implementor's and fixer's `## PR` holds `#<number>` unless Status is `blocked`, because no PR may exist yet.
- The reviewer's `clean` means zero Critical and zero Important findings. `findings` means at least one Critical or Important finding.
- The reviewer's Acceptance map and the fixer's Resolutions each have at least one entry.

### Rejection messages (complete)

Exit 1. Each message comes after `parse-report: `, with `<...>` filled in from the report:

- `missing section: ## Status`
- `missing section: ## Findings`
- `missing section: ## For the card`
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
- `empty sub-list: Out of scope:`
- `empty sub-list: Bugs found:`
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

Usage errors exit 2 instead: `unknown flag: <flag>`, `unknown role: <role>`, `cannot read file: <file>` and the usage line. They mean your call was wrong, not that the report is malformed. They have no rule to quote because they never go to a role.

### Rule table

When you re-dispatch, quote the "Rule it enforces" cell for each stderr line. (Inside the table, `\|` stands for a literal `|` in the message.)

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

### Role-specific points

| Role | Status values | Role sections | `## PR` rule |
|---|---|---|---|
| implementor | `done`, `blocked` | `## PR` | Holds `#<number>` unless Status is `blocked` |
| fixer | `done`, `blocked` | `## PR`, `## Resolutions` (at least one entry, one per input finding) | Holds `#<number>` unless Status is `blocked` |
| reviewer | `clean` (zero Critical and Important), `findings` (at least one Critical or Important) | `## Acceptance map` (at least one entry), `## Mutation`, `## Claim check` | none |

- In `## PR`, the first `#<digits>` is the PR number. Any other `#<digits>` there, such as a card number or an example, would be read as the PR.
- A blocked implementor that stopped before any test or PR (for example, on a card without an Acceptance section) has a `## PR` saying that no PR exists. Its `VERIFIED:` line counts something it checked, such as `-> 0` Acceptance sections.
- A `Blocked by: #N` line in `## For the card` gives `blocked_by`.
- Findings are defects in this card's diff or Acceptance. Out of scope is uncovered work and becomes a Backlog card. Bugs found are defects observed outside the diff and become `bug`-labelled Backlog cards, deduplicated against open issues. Filing these cards is your job, and it happens only from accepted reports.

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

## What not to do

You must never:

- Edit, complete, trim or rewrite a role's report, whether to make it pass or for any other reason.
- Accept a report that `parse-report.sh --role <role>` rejected, or act on one: move the card, mark a PR, file an Out of scope or Bugs found card, or record its VERIFIED line.
- Re-dispatch more than once for one rejected report, or dispatch a third time after a second rejection.
- Re-dispatch a role because the checker exited 2.
- Paraphrase a rejection instead of quoting the `parse-report: ` stderr lines exactly.
- Re-parse report markdown by hand when the checker's JSON is available.
- Check a report with a role other than the one you dispatched, or without `--role`.
- Ask a role to use, load or follow the reporting skill. Roles have no `Skill` tool and cannot load skills.
- Give or quote an example command that could run the whole suite, such as `npm test`, `jest` or a bare `node --test`. Examples are `commands.test_one` with one concrete test file, such as `node --test test/calc.test.js`.

A report must never:

- Contain an invented, estimated or summed `VERIFIED:` integer.
- Contain a `VERIFIED:` command holding a backtick.
- List a defect in the card's own diff under Bugs found.
- Give a bug repro that the role did not actually run.
