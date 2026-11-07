# Spec brief: reporting

You are writing the behavior specification for the fleet-board **reporting**. fleet-board is a Claude Code plugin: a manager moves cards (GitHub issues) across a board and dispatches three role agents (implementor, reviewer, fixer) to do the work in git worktrees. The design document describes it.

## Sections the spec must have, in this order

1. **Purpose** — one short paragraph.
2. **Inputs** — exactly what the manager passes to this role, one bullet each.
3. **Required behavior** — a numbered list. Every item is testable: it names an observable result (a commit, a file, a command run, a report line), not an intention.
4. **Must never** — a bullet list of prohibitions.
5. **Report** — the report this role produces. Reference the Report shape below and state which Status values and which role sections apply to this role. Include the Report shape verbatim in this section.
6. **Acceptance criteria this role satisfies** — the AC ids listed in this brief, each with its text as given in the acceptance criteria excerpt below.

Every requirement listed in this brief must appear in the spec. You may add behavior from the design document or the HMB process notes when it is consistent with this brief; the brief wins on any conflict. Describe behavior, not prompt wording. Cite no sources, name no third-party plugin, include no URL.

## Reporting requirements

This spec is not a role; it describes the report every role writes. Adapt the section list: Purpose; Inputs (what a role has at hand when it writes the report); Required behavior (the rules for writing a valid report); Must never; Report (the shape, verbatim); Acceptance criteria.

It must cover:
1. The report shape and every rule under it (below), including the Status values allowed per role and the role sections per role.
2. The distinction between Findings (defects in this card's own diff or Acceptance), Out of scope (work worth doing that the card does not cover) and Bugs found (a defect the role observed outside this card's diff). A bug inside the card's own diff is a Finding, never a Bug found. Each Bugs found line has all four parts; the repro is a command the role actually ran and `observed` is what it printed.
3. How to write the `VERIFIED:` line: exactly one; a real command the role ran, between backticks; `->` or `→`; then the integer that command's output showed (for example, a count of passing tests), then what that integer counts. Never an invented or estimated number.
4. That the manager checks every report with `parse-report.sh` and rejects one that violates the shape (a missing section, zero or two `VERIFIED:` lines, a `VERIFIED:` line without a backticked command and an integer, a missing reviewer section, an unknown status, a bug entry without all four parts), and re-dispatches the role once with the rule quoted.
5. That the report is written to a temp file, posted with `board-comment.sh <card number> <file>`, and is also the role's final reply.

**AC ids:** fleet-board.AC5.3, fleet-board.AC5.4 (detection side), fleet-board.AC3.10 (report format side).

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
- **Audience (decision D2).** The role agents do **not** have the `Skill` tool, so no role can load the reporting skill; each role's own prompt carries the report shape. The reporting spec, and the skill authored from it, are for the **fleet-board manager** (Phase 6): the skill is used when the manager checks a role report with `parse-report.sh`, quotes a rule to a role, or re-dispatches a role whose report was rejected. Rewrite the spec for that consumer:
  - **Purpose:** the report every role writes, and how the manager checks it and handles a rejected one.
  - **Inputs:** what the manager has at hand: the role's final report text (also posted on the card), the role name (`implementor`, `reviewer` or `fixer`), the fleet-board scripts directory, and the role's original dispatch inputs (for a re-dispatch).
  - **Required behavior** (the manager's, each testable):
    1. Write the role's final report text to a temp file and run `bash <scripts dir>/parse-report.sh --role <role> <file>`.
    2. Exit 0: use the JSON on stdout (never re-parse the markdown by hand).
    3. Exit 1: re-dispatch the same role once, on the same model, with the same inputs plus the text `Your previous report was rejected by the manager: <parse-report stderr>. The rule: every report contains ## Status, ## Findings, ## For the card, and exactly one line of the form VERIFIED: \`<command>\` -> <integer> <what it counts>.`, and for each stderr line the Report shape rule it enforces, quoted from the list below.
    4. If the second report is also rejected, record a report error for the card and leave the card where it is; never a third dispatch for the same report.
    5. Exit 2 is a usage error in the manager's own call, not a bad report; fix the call, never re-dispatch for it.
    6. The manager never edits, completes or rewrites a role's report to make it pass, and never accepts a report the checker rejected.
  - A **rule table**: every rejection message in the list above, paired with the Report shape rule it enforces and one line showing a valid form, so the manager can quote the rule for any message.
  - The Report shape, its Line rules and With `--role` rules, and the error list, verbatim, plus the role-specific points a manager must know: Status values per role; `## PR` holds `#<number>` unless Status is `blocked`; a blocked implementor that stopped before any test or PR (e.g. a card without `## Acceptance`) has a `## PR` stating that no PR exists and a `VERIFIED:` line counting something it checked (e.g. `-> 0` Acceptance sections); a `Blocked by: #N` line in `## For the card` gives `blocked_by`; the Findings / Out of scope / Bugs found distinction.
  - **Must never** (the manager's): edit a role's report; accept a report `parse-report.sh --role <role>` rejected; re-dispatch more than once for one rejected report; paraphrase a rejection instead of quoting the stderr lines; ask a role to use the reporting skill (roles cannot load skills).
- The previous brief text that addressed "a role agent writing its report" is superseded by this item wherever they conflict. Keep the AC ids.
- **Example commands** (added in Revision 2 after the first Revision 2 run gave `npm test -- --runTestsByPath ...` examples). Every example test command anywhere in the spec (the example `VERIFIED:` lines, repro commands, claim-check commands, rule-table examples) is `commands.test_one` with `{file}` replaced by one concrete test path that matches `test_paths`, for example `node --test test/calc.test.js` when `test_one` is `node --test {file}`. Never give `npm test`, jest, `--runTestsByPath`, or any other command that could run the whole suite as an example. `npm test` and a bare `node --test` may appear only where the spec lists them as prohibited full-suite commands.

## Revision 3 requirements (Phase 8, 2026-09-30: per-dispatch report file; these win over anything above, including Revision 2)

**Supersedes the earlier Revision 3 text** (2026-09-30, Phase 8 Revision B). The earlier version of this section had the manager pass a `Report file:` path to every dispatch. That manager change was withdrawn (the manager stays at Revision 8), so no `Report file:` line is given and the rule below is role-side only.

**Why (observed live).** A role wrote its report to a temp file made with `mktemp`, then ran `parse-report.sh` and `board-comment.sh` in later Bash calls. Shell state does not persist between Bash calls, so the path was lost; the role guessed it by listing the system temp directory sorted by time and posted another process's file on its card.

- **One call.** The role writes its report to a temp file and runs `bash <scripts dir>/parse-report.sh --role <role> <file>` and `bash <scripts dir>/board-comment.sh <card number> <file>` on it in ONE Bash call, so the path is never lost between calls. If `parse-report.sh` fails, the role fixes the report and repeats the whole write+check+post sequence as one call again, posting only on exit 0. Equivalent acceptable form: create the file with `mktemp` and keep its literal path in the same Bash command as the check and the post.
- **Must never** additionally includes: list, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp dir), or read, post or pass to any script a file it did not write in this dispatch, other than the inputs the dispatch names.
- This applies where the spec describes the role side (the role's temp file). The manager's side is unchanged.
- Everything else is unchanged.

## Revision 3b requirements (Phase 8 Revision B3, 2026-09-30: report file from `mktemp` only; these win over Revision 3)

**User decision.** Revision 3 says the role writes its report to "a temp file" and offers `mktemp` only as an "equivalent acceptable form", which allows a hand-picked, non-unique name; two concurrent roles could collide on it. The fixer got the same rule in Revision B2.

- **The role-side item (item 1 in the spec and the skill).** The role creates the report file with `mktemp` (so it lands under `$TMPDIR`), and keeps its literal path in the same Bash call as the check and the post. The `mktemp` form is the only form: the "equivalent form" sentence becomes the rule. The manager's side (its own temp file for checking a returned report) is unchanged.
- Everything else is unchanged.

## Revision 3c requirements (Phase 8 Revision C, 2026-10-02: report body written with the Write tool; Must-never scoped to temp files; these win over Revisions 3 and 3b)

**Why (code review I1 and M4).** Revision 3 had the role build the report inside a Bash heredoc (`f=$(mktemp) && cat > "$f" <<'EOF' ... EOF && parse-report ... && board-comment ...`). The PreToolUse gate (`hooks/gate.sh`) reads the whole Bash command text, the heredoc body included, as commands, so a report quoting a gated command (a finding that mentions `gh pr merge`, `gh issue edit` or `board-move.sh N <state>`) is blocked with exit 2 and cannot be posted (I1). The Must-never sentence "Never read, post, or pass to any script a file you did not write in this dispatch, other than the inputs the dispatch names" literally forbids normal work such as reading the worktree's source (M4).

- **The report file procedure** (wherever the spec or skill says how the report is created, written, checked and posted):
  - (a) Run `mktemp` in a Bash call and note the absolute path it prints.
  - (b) Write the report to exactly that path with the Write tool. Never put the report text inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks a report that quotes a gated command.
  - (c) Check and post in ONE Bash call naming that literal path: `bash <scripts dir>/parse-report.sh --role <role> <path> && bash <scripts dir>/board-comment.sh <card number> <path>`. The post runs only when the check exits 0.
  - (d) If the check fails, fix the file with Edit or Write and repeat (c).
  - `mktemp` only; no self-chosen path. Every heredoc example is removed.
- **The temp-directory Must-never item** becomes: "Never list, glob, search or sort any temp directory (for example `ls -t $TMPDIR`, `/var/folders/...`, or `find` in a temp directory), and never post or pass to a board script any file other than the report file you created with `mktemp` in this dispatch." The "did not write in this dispatch" wording is removed.
- Everything else is unchanged: the report templates, the frontmatter, the other Must-never items and every other line.

## Revision 3d requirements (Phase 8 Revision C2, 2026-10-02: read once, then write, when the Write tool refuses the mktemp file; these win over Revisions 3, 3b and 3c)

**Why (code review cycle 2, Minor 1).** Revision 3c has the role run `mktemp`, then write the report to that path with the Write tool. In Claude Code the Write tool refuses an existing file that has not been read ("File has not been read yet"), and `mktemp` creates the file, so a role may hit that refusal and fall back to a heredoc (blocked by the gate when the report quotes a gated command) or to a self-chosen path. The manager got the recovery instruction in its Revision 9b; the roles did not.

- **The report file procedure** (in the spec or skill): right after the step that writes the report with the Write tool, add exactly one sentence, in the file's own voice: if the Write tool refuses the file because it has not been read, read it once with the Read tool and write it again (still never a heredoc, `echo`, `printf` or `cat`, and never a different path).
- The sentence appears once per file, after step (b) only; the check-and-post step, any Enforcement paragraph and the Must-never list do not repeat it.
- Everything else is unchanged and byte-identical: the report templates, the frontmatter, the Must-never items and every other line.

## Revision 11 requirements (2026-11-01, Out of scope entries carry a check command)

An `Out of scope:` entry is `- <title> :: <detail>` and the detail must hold a backticked
check command (what a person runs to see the work is done, with its expected result) or the
words `no testable check`. The command is written before any other backticked text, because
the first non-blank backticked span becomes the follow-up card's Acceptance bullet. With the
words `no testable check` the follow-up card is filed in Backlog for a person to triage.
`parse-report.sh` rejects an entry with neither, with the message
`out of scope entry needs a backticked check command or the words no testable check: <entry>`.
The shape lines, the entry rule, the rejection-message list and every example Out of scope
entry say so; examples always carry a check command.

## Revision 12 requirements (2026-11-01, Acceptance items no test can map to)

An `## Acceptance map` line may also be ``- <item> -> CHECKED: `<command>` `` or
`- <item> -> NOT_APPLICABLE: <reason>`. `parse-report.sh` accepts both and rejects a `CHECKED`
with no single backticked command and a `NOT_APPLICABLE` with no reason, using the existing
`malformed ## Acceptance map line: <line>` message. The shape lines and the split rule say so.

## Revision 16 requirements (2026-11-03, single backticks for the check command)

The check command in an `Out of scope:` entry is written in single backticks with no backtick
inside it. A markdown double-backtick span, or an odd number of backticks, gives no command,
because `parse-report.sh` pairs single backticks only, and the rejection then reads as if no
command were present. When the command cannot be written that way, the entry uses the words
`no testable check`. The entry rule says so.

## Revision 17 requirements (2026-11-06, PR #174: review stages and provider stages)

A new report role, `stage-reviewer`, for a review stage's report: the report of the stage's own agent, or the `report_file` that `stage-review.sh` printed for a provider-backed stage. `parse-report.sh --role stage-reviewer` requires `## Status` (`clean` or `findings`), `## Findings`, `## For the card` and exactly one `VERIFIED:` line, with the same line rules, and no `## Acceptance map`, `## Mutation` or `## Claim check`. The spec text is in `specs/reporting.md`; write each item where the spec puts it. Nothing else in the file changes.

1. The role list (Purpose, and the Inputs role name) names `stage-reviewer` and what it is for.
2. A provider-backed stage is never re-dispatched: `stage-review.sh` already re-asked its model once.
3. Rule table row `role <role> does not allow status: <word>`: `clean` and `findings` are for the reviewer and the stage-reviewer.
4. Rule table row `role <role> requires ## <section>`: the stage-reviewer has no role sections, so this message never names it.
5. Rows `status clean needs ...` and `status findings needs ...`: they hold for the stage-reviewer as for the reviewer.
6. Report section: Status values by role, Role sections (stage-reviewer: none), and the With `--role` rule name the stage-reviewer; the rejection-messages usage line reads `[--role implementor|reviewer|fixer|stage-reviewer]`.
7. Role-specific table: a `stage-reviewer` row (`clean`/`findings`, no role sections, no `## PR` rule).

## Revision 22 requirements (2026-11-06, card fields and the local board; these win over anything above)

Cards now carry first-class fields, and the board is the local card store. `board-read.sh <n>`
prints the card as JSON with `acceptance` (an array of strings), `blocked_by` (card numbers on
this board) and `pr_url`. A card's acceptance items are its `acceptance` field, not a
`## Acceptance` section of the body. Change only what the items below name; keep the frontmatter
and every other line unchanged. The `Blocked by: #N` report line and the checker's `blocked_by`
JSON field are unchanged.

1. The backtick rule's example: card text that holds backticks is read with
   `board-read.sh <n> | jq -r '.body'` rather than pasted (in place of `gh issue view <n>
   --json body --jq .body`).
2. Blocked before any work: the example cause is a card with no acceptance items (in place of
   "no Acceptance section"), and the VERIFIED example is
   ``VERIFIED: `board-read.sh 12 | jq '.acceptance | length'` -> 0 acceptance items``.
3. The role-specific point on a blocked implementor: "a card without acceptance items", and its
   VERIFIED line counts `-> 0` acceptance items (in place of Acceptance sections).
4. Bugs found become `bug`-labelled Backlog cards deduplicated against open cards on this board
   (in place of "open issues").
5. The blocked implementor example report: the For-the-card line is
   `Stopped before writing a test: the card has no acceptance items.` and the VERIFIED line is
   ``VERIFIED: `board-read.sh 12 | jq '.acceptance | length'` -> 0 acceptance items``.
