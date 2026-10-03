# Spec brief: reviewer

You are writing the behavior specification for the fleet-board **reviewer**. fleet-board is a Claude Code plugin: a manager moves cards (GitHub issues) across a board and dispatches three role agents (implementor, reviewer, fixer) to do the work in git worktrees. The design document describes it.

## Sections the spec must have, in this order

1. **Purpose** — one short paragraph.
2. **Inputs** — exactly what the manager passes to this role, one bullet each.
3. **Required behavior** — a numbered list. Every item is testable: it names an observable result (a commit, a file, a command run, a report line), not an intention.
4. **Must never** — a bullet list of prohibitions.
5. **Report** — the report this role produces. Reference the Report shape below and state which Status values and which role sections apply to this role. Include the Report shape verbatim in this section.
6. **Acceptance criteria this role satisfies** — the AC ids listed in this brief, each with its text as given in the acceptance criteria excerpt below.

Every requirement listed in this brief must appear in the spec. You may add behavior from the design document or the HMB process notes when it is consistent with this brief; the brief wins on any conflict. Describe behavior, not prompt wording. Cite no sources, name no third-party plugin, include no URL.

## Reviewer requirements

**Inputs** (what the manager passes):
- card number and body (the body holds an `Acceptance` section of bullets)
- PR number
- the PR diff (from `gh pr diff`)
- the latest implementor or fixer report text only, never a transcript
- a review worktree path checked out at the PR head
- the config JSON: `commands` (`test_one` with a `{file}` placeholder; optional `typecheck`, `lint`), `review` (`mutation`, `verify_claim`), `test_paths`, `worktrees.mutate_on_copy`
- the round number
- the round-1 base SHA, or in later rounds the previous review SHA
- the absolute path of the fleet-board scripts directory

**Method, in this fixed order:**
1. Map every Acceptance item to a test in the diff. An unmapped item is an `[Important]` finding.
2. Run only the test files the PR touched, through `test_one`.
3. If `review.mutation` is true, make one mutant per Acceptance item, in the implementation code the mapped test covers.
   - Run the mapped test, and expect red.
   - Restore with `git checkout -- <file>`.
   - Classify each mutant: killed (the test goes red); survived (the test stays green) — a survivor is `[Critical]`; invalid (the mutant does not compile or run).
   - If `worktrees.mutate_on_copy` is true, copy the worktree to a temp dir and mutate the copy.
   - If `review.mutation` is false, write `skipped: review.mutation is off`.
4. If `review.verify_claim` is true, pick one load-bearing claim from the report (the `VERIFIED:` line by preference).
   - Execute its command.
   - Record `claim`, `command`, `result` and `matches`.
   - A mismatch is `[Important]`.
   - If `review.verify_claim` is false, write `skipped: review.verify_claim is off`.
5. Run `commands.typecheck` and `commands.lint` when they are set. A failure is `[Important]`.
6. In round 2 and later, inspect `git diff <previous-review-sha>..HEAD -- <test_paths>`. Any modified or deleted line in a test that existed at the previous review is `[Critical]`, quoting the file and the change. Adding new tests is fine.
7. Status is `clean` when there are zero Critical and zero Important findings, and `findings` otherwise.
8. Post the report with `bash <scripts dir>/board-comment.sh <card number> <file>`. The final reply is the same report text.
9. A defect observed outside the PR's diff while running tests or the claim goes under `Bugs found:` with its repro. A defect in the diff is a Finding.

**Must never:**
- edit code, commit, push, move cards, or merge
- leave a mutation in place: mutations are reverted before the report is posted, and `git status --porcelain` in the review worktree must be empty at the end

**AC ids:** fleet-board.AC3.4, fleet-board.AC3.5, fleet-board.AC3.6, fleet-board.AC3.7, fleet-board.AC3.8, fleet-board.AC5.3.

## Report shape (verbatim; the single source of truth)

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

## Enforcement: `parse-report.sh` error messages (Revision 2)

`scripts/parse-report.sh [--role implementor|reviewer|fixer] <file>` (in the fleet-board scripts directory) is the enforced definition of the Report shape above. The manager runs it with `--role <role>` on every role report. A report that violates any rule is **rejected**: the script exits 1, prints nothing on stdout, and prints one stderr line per problem, each prefixed `parse-report: `. The manager then re-dispatches the role once with those lines and the rule quoted; a second rejected report is recorded as a report error and the card stays where it is. A spec must therefore make every report its role writes pass `parse-report.sh --role <role>`.

The complete list of rejection messages (`<...>` is filled in from the report; each appears after `parse-report: `):

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

Two consequences of the parser that a report writer must know:
- The `VERIFIED:` command sits between single backticks, so it can contain no backtick character itself (a command that would need one, such as one that pastes card text holding backticks, must be rewritten, e.g. to read the text with `gh issue view <n> --json body --jq .body`).
- In `## PR`, the first `#` followed by digits is read as the PR number, so `## PR` must contain no `#<digits>` other than the real PR number (not a card number, not an example).

## Acceptance criteria excerpt (verbatim)

### fleet-board.AC3: Role agents
- **fleet-board.AC3.1 Success:** The implementor's first commit contains a failing test and no implementation.
- **fleet-board.AC3.2 Success:** The implementor runs only the individual test file(s) it wrote, never the full suite.
- **fleet-board.AC3.3 Success:** The implementor opens a draft PR and posts a report in the fixed shape with a `VERIFIED:` line.
- **fleet-board.AC3.4 Success:** The reviewer maps each Acceptance item to a test and flags an unmapped item as Important.
- **fleet-board.AC3.5 Success:** With `review.mutation` on, the reviewer reports killed, survived, and invalid counts, and a survivor is Critical.
- **fleet-board.AC3.6 Success:** With `review.verify_claim` on, the reviewer executes one claim from the implementor's report and records the command and result.
- **fleet-board.AC3.7 Success:** With either toggle off, the reviewer skips that step and says so in the report.
- **fleet-board.AC3.8 Failure:** A fixer commit that modifies a test to dismiss a finding is flagged Critical by the next review round.
- **fleet-board.AC3.10 Success:** A bug a role agent observes outside its card's scope, reported under `Bugs found:` with a repro command and the expected and observed results, becomes a Backlog card labelled `bug` with those details, linked from the PR; a bug matching an open issue's title is not filed twice, and the existing issue is linked instead. *(Partial: this phase defines the report format and parses it. Filing is Phase 6.)*

### fleet-board.AC5: Clean-room and reporting
- **fleet-board.AC5.1 Success:** `grep -ri <the forbidden plugin name> plugins/fleet-board` finds nothing.
- **fleet-board.AC5.2 Success:** Each role agent has a behavior spec committed under the implementation plan, and the agent file cites no external source.
- **fleet-board.AC5.3 Success:** Every agent report contains `## Status`, `## Findings`, `## For the card`, and one `VERIFIED:` line.
- **fleet-board.AC5.4 Failure:** A report missing the `VERIFIED:` line is rejected by the manager, which re-dispatches once with the rule quoted. *(Partial: this phase builds and tests the detection in `parse-report.sh`. The re-dispatch is the manager's behavior and is completed in Phase 6.)*

## Revision 2 requirements (review cycle 1; these win over anything above, including Revision 1)

- **Report shape.** The Report shape section above is the current one, with its Line rules and With `--role` rules, and the error-message list after it is complete. The spec's Report section includes both verbatim, states that `parse-report.sh --role <role>` enforces them and that a violating report is rejected, and states the Status values, role sections and `## PR` rule for this role.
- **No Skill tool (decision D2).** Role agents have exactly the tools `Read, Write, Edit, Bash, Grep, Glob`; none has the `Skill` tool, so a role cannot load the reporting skill or any other skill. Everything a role needs to write a valid report (the shape, the line rules, the `--role` rules and the pitfalls above) must be in the role's own spec, so that the agent prompt authored from it carries it. A role may run `bash <scripts dir>/parse-report.sh --role <role> <report file>` itself before posting, and must fix its report until that exits 0; running the checker is reading, not a board action.
- **What "modifying an existing test" means (review finding I5).** In round 2 and later (method step 6), a test that existed at the previous review SHA is "modified" when **any** line inside its body differs at HEAD: a changed line, a deleted line, **or an added line** inside the existing test's body. Added lines count even when nothing is removed, for example an early `return;`, a `t.skip()` / `t.todo()` call, `.skip` / `.only` / `.todo` added to its declaration, an assertion wrapped in `if (false) { ... }`, or an assertion turned into a comment. Deleting a whole pre-existing test, or a pre-existing test file, is also a modification. Only new test blocks (a new `test(...)` call outside every pre-existing test's body) and new test files are fine.
  - The reviewer checks this by comparing each test that existed at the previous review SHA with the same test at HEAD (from `git diff <previous-review-sha>..HEAD -- <test_paths>` and, where the hunk position is unclear, `git show <sha>:<file>` for both sides), not only by counting deleted lines.
  - Every such hunk is a `[Critical]` finding that names the test file and quotes the changed lines, e.g. `- [Critical] test/calc.test.js: existing test "subtract(2, 5) returns -3" was modified since the previous review: added "return;" before its assertion`. The finding text contains the test file path.
- **Example commands** (added in Revision 2 after the first Revision 2 run gave `npm test -- --runTestsByPath ...` examples). Every example test command anywhere in the spec (the example `VERIFIED:` lines, repro commands, claim-check commands, rule-table examples) is `commands.test_one` with `{file}` replaced by one concrete test path that matches `test_paths`, for example `node --test test/calc.test.js` when `test_one` is `node --test {file}`. Never give `npm test`, jest, `--runTestsByPath`, or any other command that could run the whole suite as an example. `npm test` and a bare `node --test` may appear only where the spec lists them as prohibited full-suite commands.
- **Mapping a weak test (added after live run review-survivor-20260928-182015).** An Acceptance item maps to a test in the diff when that test **exercises the item's behavior**: it calls the code under the item's inputs or scenario (e.g. a test that calls `subtract(5, 2)` maps to "subtract(5, 2) returns 3"), even when its assertion is weak (e.g. it only checks `typeof subtract(5, 2) === 'number'`). Whether the assertion actually pins the behavior is judged by the mutation step, not by the map: a weak mapped test lets a mutant survive, and the survivor is the `[Critical]` finding (AC3.5). An item is `UNMAPPED` only when no test in the diff exercises it at all. So with `review.mutation` on, a weak test gets a mutant, never an `UNMAPPED` line that skips mutation. The reviewer may also note the weak assertion under `## For the card` or as a `[Minor]` finding, but never instead of the mutant. Do not write the rule "a test whose name matches but whose assertions do not check the item does not count as a mapping".

## Revision 3 requirements (Phase 8, 2026-09-30: per-dispatch report file; these win over anything above, including Revisions 1 and 2)

**Supersedes the earlier Revision 3 text** (2026-09-30, Phase 8 Revision B). The earlier version of this section had the manager pass a `Report file:` path to every dispatch. That manager change was withdrawn (the manager stays at Revision 8), so no `Report file:` line is given and the rule below is role-side only.

**Why (observed live).** A role wrote its report to a temp file made with `mktemp`, then ran `parse-report.sh` and `board-comment.sh` in later Bash calls. Shell state does not persist between Bash calls, so the path was lost; the role guessed it by listing the system temp directory sorted by time and posted another process's file on its card.

- **One call.** The role writes its report to a temp file and runs `bash <scripts dir>/parse-report.sh --role reviewer <file>` and `bash <scripts dir>/board-comment.sh <card number> <file>` on it in ONE Bash call, so the path is never lost between calls. If `parse-report.sh` fails, the role fixes the report and repeats the whole write+check+post sequence as one call again, posting only on exit 0. Equivalent acceptable form: create the file with `mktemp` and keep its literal path in the same Bash command as the check and the post.
- **Must never** additionally includes: list, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp dir), or read, post or pass to any script a file it did not write in this dispatch, other than the inputs the dispatch names.
- Everything else is unchanged.

## Revision 3b requirements (Phase 8 Revision B3, 2026-09-30: report file from `mktemp` only; these win over Revision 3)

**User decision.** Revision 3 says the role writes its report to "a temp file" and offers `mktemp` only as an "equivalent acceptable form", which allows a hand-picked, non-unique name; two concurrent roles could collide on it. The fixer got the same rule in Revision B2.

- **Behavior 9 and the one-call bullet of behavior 10 (steps 10 and 11 in the agent).** The report file is created with `mktemp` (so it lands under `$TMPDIR`), and its literal path is kept in the same Bash call as the check and the post. The `mktemp` form is the only form: the "equally acceptable form" sentence becomes the rule, and "for example to a file created with `mktemp`" no longer leaves room for another path.
- Everything else is unchanged.

## Revision 3c requirements (Phase 8 Revision C, 2026-10-02: report body written with the Write tool; Must-never scoped to temp files; these win over Revisions 3 and 3b)

**Why (code review I1 and M4).** Revision 3 had the role build the report inside a Bash heredoc (`f=$(mktemp) && cat > "$f" <<'EOF' ... EOF && parse-report ... && board-comment ...`). The PreToolUse gate (`hooks/gate.sh`) reads the whole Bash command text, the heredoc body included, as commands, so a report quoting a gated command (a finding that mentions `gh pr merge`, `gh issue edit` or `board-move.sh N <state>`) is blocked with exit 2 and cannot be posted (I1). The Must-never sentence "Never read, post, or pass to any script a file you did not write in this dispatch, other than the inputs the dispatch names" literally forbids normal work such as reading the worktree's source (M4).

- **The report file procedure** (wherever the spec or agent says how the report is created, written, checked and posted):
  - (a) Run `mktemp` in a Bash call and note the absolute path it prints.
  - (b) Write the report to exactly that path with the Write tool. Never put the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command.
  - (c) Check and post in ONE Bash call naming that literal path: `bash <scripts dir>/parse-report.sh --role reviewer <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0.
  - (d) If the check fails, fix the file with Edit or Write and repeat (c).
  - `mktemp` only; no self-chosen path. Every heredoc example is removed.
- **The temp-directory Must-never item** becomes: "Never list, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory), and never post or pass to a board script any file other than the report file you created with `mktemp` in this dispatch." The "did not write in this dispatch" wording is removed.
- Everything else is unchanged: the report templates, the frontmatter, the other Must-never items and every other line.

## Revision 3d requirements (Phase 8 Revision C2, 2026-10-02: read once, then write, when the Write tool refuses the mktemp file; these win over Revisions 3, 3b and 3c)

**Why (code review cycle 2, Minor 1).** Revision 3c has the role run `mktemp`, then write the report to that path with the Write tool. In Claude Code the Write tool refuses an existing file that has not been read ("File has not been read yet"), and `mktemp` creates the file, so a role may hit that refusal and fall back to a heredoc (blocked by the gate when the report quotes a gated command) or to a self-chosen path. The manager got the recovery instruction in its Revision 9b; the roles did not.

- **The report file procedure** (in the spec or agent): right after the step that writes the report with the Write tool, add exactly one sentence, in the file's own voice: if the Write tool refuses the file because it has not been read, read it once with the Read tool and write it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path).
- The sentence appears once per file, after step (b) only; the check-and-post step, any Enforcement paragraph and the Must-never list do not repeat it.
- Everything else is unchanged and byte-identical: the report templates, the frontmatter, the Must-never items and every other line.
