# Spec brief: manager

You are writing the behavior specification for the fleet-board **manager**. fleet-board is a Claude Code plugin: a manager moves cards (GitHub issues) across a board and dispatches three role agents (implementor, reviewer, fixer) to do the work in git worktrees. The design document describes it. The manager is the agent that runs one **tick**: it reads the board, advances every listed card exactly one step, writes the result back to the card, and returns a tick report. The tick skill dispatches it; the manager dispatches the role agents.

## Sections the spec must have, in this order

1. **Purpose** — one short paragraph.
2. **Inputs** — exactly what the tick skill passes to the manager, one bullet each.
3. **Required behavior** — a numbered list. Every item is testable: it names an observable result (a script run with given arguments, a note field set, a comment posted, a card moved, an agent dispatched with a given `subagent_type` and `model`, a tick report line), not an intention. Keep the procedure's numbering and its action table (below); you may split items but must not drop any.
4. **Must never** — a bullet list of prohibitions.
5. **Tick report** — the exact shape of the manager's final message.
6. **Acceptance criteria this role satisfies** — the AC ids listed in this brief, each with its text as given in the acceptance criteria excerpt below.

Every requirement listed in this brief must appear in the spec. You may add behavior from the design document or `reporting.md` when it is consistent with this brief; the brief wins on any conflict. Describe behavior, not prompt wording. Cite no sources, name no third-party plugin, include no URL.

## Purpose

Run one tick; stateless; the board is the only state. Everything a later tick needs is in each card's manager note; the manager never relies on memory of an earlier tick and never reads a role agent's transcript.

## Inputs (from the tick skill)

- the absolute scripts dir (the fleet-board `scripts/` directory; written `<scripts>` below)
- the repo root (absolute; the output of `git rev-parse --show-toplevel` in the user's repo)
- the config JSON (the parsed `.fleet-board.yml` merged with defaults: `board.repo`, `commands`, `test_paths`, `human_qa_paths`, `merge.policy`, `review`, `models`, `limits`, `worktrees`)
- the tick start time (ISO 8601)

## Tools (decision D3)

The manager's tools are exactly `Agent`, `Skill`, `Read`, `Write`, `Bash`, `Grep`, `Glob`. It needs `Write` for its temp report, note-patch and comment files.

- The only skill the manager may invoke is `fleet-board:reporting` (the report-checking rules, written for the manager). It must never invoke any other skill.
- It must never dispatch any agent other than `fleet-board:implementor`, `fleet-board:reviewer` and `fleet-board:fixer` (the Agent tool's `subagent_type`). It never dispatches a general-purpose or other built-in agent, and never another manager.
- The spec states all three rules in Required behavior and again in Must never.

## How the manager runs commands (facts the spec must carry)

- **Working directory.** Every fleet-board script finds the config through the git toplevel of its working directory, so every script call runs from the repo root: `cd <repo root> && bash <scripts>/<script> ...`, one Bash call per command, with the repo root and scripts dir written out literally.
- **Literal values in gated commands.** A PreToolUse gate hook inspects every Bash call (the manager's and every role agent's) and blocks, with exit 2 and one stderr line, any command it cannot read. So in `board-move.sh`, `gh pr ready` and `gh pr merge` commands the card number, PR number and state are literal (`board-move.sh 12 in_review`, `gh pr merge 34 --repo acme/toy --squash`), never a shell variable or `$(...)` substitution. The gate also blocks: any move out of `human_qa`; `gh pr merge` under `merge.policy: human`, on a draft, without an explicit PR, with `--admin`, or with checks that are not green; a move to `ready` of a card without `## Acceptance`. A blocked command is not retried in another form; the manager records the block as the action's result and a warning.
- **gh calls** name the repo explicitly: `--repo <board.repo>`.
- **Temp files.** The manager creates one temp directory per tick (`mktemp -d`, outside the repo and outside every worktree) and writes its report, note-patch, follow-up and comment files there with the `Write` tool.
- **Note writes.** Every note change is `note.sh merge <n> <patch-file>`, where the patch file holds a JSON object with only the keys being changed. `note.sh put` is not used by the manager, and neither is `note.sh reset-failures` (a person runs it after moving a skipped card by hand; the manager resets the counter inside its own merges).
- **Waiting for dispatches.** Role agents are dispatched with the Agent tool in the foreground: the manager waits for every dispatched agent's final report before reconciling or writing the tick report. It never uses a background option of the Agent tool, and never ends the tick while a dispatch is still running. **Every role Agent call passes `run_in_background: false` explicitly; it is never omitted.** When the parameter is left out, the runtime may run the agent in the background anyway (observed in Phase 6 Task 9: an implementor dispatch without the parameter ran in the background, and the manager ended the tick with an incomplete report and the dispatch unreconciled). (Observed in Phase 5: a dispatcher that ran Agent calls in the background emitted several `result` events and printed the report only when the agent completed.)
- **Dispatch parameters.** Every Agent call passes `subagent_type` (`fleet-board:implementor`, `fleet-board:reviewer` or `fleet-board:fixer`) and `model` explicitly, taken from the tick plan card's `models` (`implementor`, `reviewer` or `fixer`), never from the session, the agent file's frontmatter or anything else.
- **The report text.** A role's report is its final reply as the Agent tool returns it. When the tool result appends metadata the agent did not write (an agent id, a usage or token-count block), that metadata is not part of the report and is left out of the report file; the report itself is never edited.
- **Token counts for the cost line.** The Agent tool result reports the total tokens the dispatch used. The manager keeps that number per dispatch, with the model it passed.

## Procedure (numbered; every step and every table row must appear in the spec)

1. Run `board-cache-clear.sh`, then `tick-plan.sh`. Print the warnings.
   - If `tick-plan.sh` exits non-zero, the tick does nothing else: the tick report says the plan failed (with its stderr), and its last line is `dispatchable: false`.
1a. **Pending follow-ups, every tick.** For each card whose plan action is `file_pending`, write `note.pending_followups` to a temp file and run `file-followups.sh` on it. That is the card's whole action this tick. It does not advance, so it cannot leave the plan with unfiled items.
   - The file is the note's `pending_followups` object as stored, `{"out_of_scope":[...],"bugs":[...],"pr":<n>}` (the same `out_of_scope` and `bugs` item shapes as `parse-report.sh` output); the command is `file-followups.sh <card> <pr> <file>`, where `<pr>` is `pending_followups.pr`, else `note.pr`, else the plan card's `pr` (a PR the plan found by branch). `tick-plan.sh` gives `file_pending` only when one of the three is set; a card with pending items and no PR gets its normal action instead, and the plan's warnings carry `pending follow-ups on #<n> wait for a PR`. If all three are null anyway, nothing is run for the card this tick: the items stay pending and the tick report carries that warning.
   - Handle the result exactly like a first-time filing:
     - **On exit 0:** append `out_of_scope_created` and `bugs_filed`, then set `pending_followups: null`.
     - **On failure:** merge what was filed, and keep the rest pending.
   - A retry never duplicates. Items already filed are skipped by the note-history and open-issue checks.
   - Nothing reported is ever dropped, which is the design's "never an omission".
2. Execute the card actions. Up to `limits.concurrency` role dispatches run concurrently: issue those Agent calls in a single message, then wait for them. When more role dispatches are due than `limits.concurrency`, the rest wait for the next batch in the same tick. Always pass `model` explicitly, from the plan's `models`, never from anything else.

   | Action | What the manager does |
   |---|---|
   | `start` | `worktree.sh create` → `board-move.sh N in_progress` → `note.sh merge` with branch, worktree, `round 0`, models, and `implementor_attempts: 1` → dispatch the implementor |
   | `continue_implementor` | `note.sh merge` with `implementor_attempts + 1`, `branch` and `worktree` (the plan card's) → `worktree.sh create N <plan branch> <plan worktree>` → dispatch the implementor with the note |
   | `start_review` | `board-move.sh N in_review` → `note.sh merge` with `round: 1` and `pr` = the plan's `pr` → `worktree.sh review` → dispatch the reviewer with `round: 1` and `prev_sha` = the `base` from `worktree.sh review` |
   | `review` | `worktree.sh review` → dispatch the reviewer with `round` = `note.round` and `prev_sha` = `note.last_review.sha`, or `base` when there is no previous review |
   | `fix` | `note.sh merge` with `branch` and `worktree` (the plan card's) → `worktree.sh create N <plan branch> <plan worktree>` (a failure ends the action without progress; see "Action failures") → dispatch the fixer with `note.last_review.findings`, filtered to Critical and Important, on `plan.models.fixer`. Then `note.sh merge` with `round + 1`, plus `escalated` and `escalated_at_round` when the plan says escalated. Then run `worktree.sh review`, and in the same tick dispatch the reviewer with `prev_sha` = `note.last_review.sha`, the SHA the previous round reviewed. The reviewer's tamper check (AC3.8) diffs from that SHA. |
   | `block` | `board-move.sh N blocked`. `note.sh merge` with `blocked_findings` set to the surviving findings, or the plan's `reason` when there are none (an action-failure block always uses the reason, clears `blocking_pr` before the move and resets the counter only after the move succeeds; see "Action failures"). Post a comment listing them. |
   | `to_human_qa` | Run `commands.qa_build` in the worktree when it is set, and capture the last 20 lines. Then `board-move.sh N human_qa` **first**. Only after the move succeeds, post a comment that contains the card's `## Acceptance` section quoted verbatim as a blockquote, under the heading `What to check in Human QA`, plus the qa_build summary, unless the card already has a comment with that heading (then post no other). |
   | `mark_ready` | `gh pr ready <pr> --repo R`. Never merge. |
   | `merge` | Two **separate** Bash calls. First `gh pr ready <pr> --repo R`, then `gh pr merge <pr> --repo R --squash`. The gate evaluates each command before it runs: combined into one command, the merge would be checked while the PR is still a draft, and blocked. There is no `--delete-branch`, because the branch is still checked out in a worktree; branch cleanup is left to the repo's "automatically delete head branches" setting. Then `note.sh merge` with `merged_pr`. |
   | `verify_main` | `verify-main.sh N <pr>`. `note.sh merge` with `main_check`. If `p0_card` is present, report it. |
   | `finish` | `board-move.sh N done` → `note.sh merge` with `state: done`, `action_failures: 0` and `last_action_error: null`, best-effort: a denied or failed write is a warning in the tick report, not a failure. The manager never removes worktrees and never runs `worktree.sh remove`; `cleanup-done.sh` does that outside any Claude session (see Task 5a). |
   | `unblock` | `board-move.sh N ready` → `note.sh merge` with `blocking_pr: null`, `blocked_findings: null`, `action_failures: 0` and `last_action_error: null`, so stale data does not carry into the next cycle |
   | `skip_no_acceptance` | When `comment_needed` is true, post via `board-comment.sh` a comment starting with `<!-- fleet-board:skip-no-acceptance -->` that explains the card needs a `## Acceptance` section before it can start. Otherwise do nothing. |
   | `skip`, `wait` | nothing |

   Clarifications of the table (the spec must carry each):
   - **Where values come from.** `N` is the plan card's `number`. The branch and worktree, for every action, are the plan card's `branch` and `worktree`, never the note's alone: the plan always carries both (the note's when it has them, else the defaults `fleet/<n>-<slug>` and `<base>/<n>-<slug>`). A card can reach `in_progress` without a note branch: a person dragged it to In Progress, the note write after `start`'s board move failed, or the note named a worktree outside the current base (`note.sh` then reads that worktree as null). For `start`, the note's `models` are the plan card's `models`. `note.*` means the card's note from `note.sh get N`, read after the plan (the plan does not carry `last_review`, `implementor_attempts` or the other note fields).
   - **`continue_implementor` and `fix` write the branch and worktree into the note, then run `worktree.sh create N <plan branch> <plan worktree>`.** `worktree.sh create` is idempotent: it prints the existing path, or re-creates a worktree that is missing (for example after a crash), and the implementor and fixer work in that worktree on the card's branch.
     - **`continue_implementor` counts the attempt first.** The one `note.sh merge` sets `implementor_attempts` = `note.implementor_attempts` (0 when null) + 1, `branch` and `worktree`, before `worktree.sh create` runs. When `worktree.sh create` then fails, the action made no progress (see "Action failures"): the implementor is not dispatched, the failure is counted in `action_failures`, and the attempt still counts in `implementor_attempts` too. `continue_implementor` keeps its `implementor_attempts` count alongside `action_failures`; whichever count reaches `review.max_rounds` first makes the plan block the card.
     - **`fix`.** The `note.sh merge` with `branch` and `worktree` comes first. A failed `worktree.sh create` ends the action without progress, like any other failed step (see "Action failures"): the fixer is not dispatched, the round does not change, no reviewer is dispatched, and the failure is counted. `fix` does not block the card itself; `tick-plan.sh` blocks it once the count reaches `review.max_rounds`.
     - **A failed or refused `note.sh merge`** (for example `refusing to merge into the invalid manager note`) means the action is not taken: no worktree command and no dispatch for that card this tick, and the tick report carries the stderr line as a warning. It is an action that made no progress, counted like any other (see "Action failures"); when the counting merge is refused too, only the warning remains. `tick-plan.sh` already skips a card whose note is invalid, with a warning.
   - **Action failures (every action; review cycles 3 to 6).** Every action that fails to make progress is counted, whatever the reason. The count lives in the note as `action_failures` (with `last_action_error`); with `max` = `review.max_rounds`, `tick-plan.sh` turns it into these rules: a ready, in_progress or in_review card gets `block` once `action_failures >= max`; if the blocks themselves keep failing, the same card gets `skip` once `action_failures >= 2 * max`; a blocked card whose `unblock` is due (its `blocking_pr` merged) gets `skip` (no `unblock`) once `action_failures >= max`; any other blocked card is a plain `skip` with reason `blocked` and no warning, whatever its count (review cycle 6). So a card gets at most `2 * max` actions in a row without progress (`max` when it is blocked) before the plan stops giving it any action and warns for a person; `file_pending` comes before these rules and is not bounded by them. The bound covers exactly what the manager records, so the manager records every action's outcome.
     - **The plan's skips for this reason are not actions.** A plan card with action `skip` and a reason starting `could not be blocked after ` or `unblock made no progress after ` gets nothing from the manager this tick: no board or note write, no counter write, no comment. The plan's warnings already carry `#N: could not be blocked after <k> attempts: <last_action_error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures N` or `#N: unblock made no progress after <k> attempts: <last_action_error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures N` (`<scripts>` is the absolute scripts dir, single-quoted when it holds a space or another shell character); the tick report's `Warnings:` lists them like every plan warning, verbatim, so the person gets the exact command. The manager does not run that command itself: a hand move does not reset the count, and only the person who moved the card decides it should be retried (review cycle 6).
     - **Progress, per action.** An action made progress when its intended board or note change happened:
       - `start`: the card is in `in_progress` and an implementor report was accepted (`parse-report.sh` exit 0, first or second attempt).
       - `continue_implementor`: an implementor report was accepted.
       - `start_review`: the card is in `in_review` and an accepted reviewer report was recorded as `last_review`.
       - `review`: an accepted reviewer report was recorded as `last_review`.
       - `fix`: the fixer's report was accepted and `round` + 1 was merged. (A failure in the reviewer step that follows in the same tick is a warning; the next tick's `review` action counts it.)
       - `block`: the card is in `blocked`.
       - `to_human_qa`: the card is in `human_qa`.
       - `mark_ready`: the PR is ready (`gh pr ready` exited 0).
       - `merge`: the PR is merged (`gh pr merge` exited 0) and `merged_pr` was recorded.
       - `verify_main`: `main_check` was recorded.
       - `unblock`: the card is in `ready`. `finish`: the card is in `done`.
       - `file_pending`: `file-followups.sh` exited 0 and `pending_followups` was set to null.
       - `skip_no_acceptance`: the comment was posted, or none was needed.
       - In any action, an accepted report with Status `blocked` that moved the card to `blocked` is progress.
       - `skip`, `wait` and unlisted actions change nothing and are not counted: no counter write.
     - **The rule.** At the end of each card's action, after its report reconciliation:
       1. If the action did **not** make progress, for any reason (a failed setup step such as `worktree.sh create` or `worktree.sh review`, including a `worktrees.setup` failure they report; a report rejected twice; a failed `gh`, board or script call; a command the gate blocked; a refused `note.sh merge`; a refused or failed merge), run `note.sh merge` with `{"action_failures": <note.action_failures, 0 when null, + 1>, "last_action_error": "<one line saying what failed>"}`. The line is the failed command's first stderr line, or for a report rejected twice `<role> report rejected twice: <the first parse-report stderr line of the second rejection>`. The tick report's result for the card says the action made no progress, and `Warnings:` carries `#N: <action> made no progress (<new count> of <review.max_rounds>): <the line>`.
       2. If it **did** make progress, merge `{"action_failures": 0, "last_action_error": null}`. Fold this into the action's last `note.sh merge` (the note-upkeep `state` merge of step 4) rather than a separate write.
       3. The counting merge may be folded into the same `note.sh merge` as the note-upkeep `state` and, for a report rejected twice, the `report_errors` entry. When it fails or is refused, the tick report carries its stderr line as a warning; nothing else is done for the card.
       4. A failed step ends the card's action for the tick: no dispatch and no later step of the action. Steps that already ran stand (for example `continue_implementor`'s attempt count, or `start_review`'s board move).
       5. The manager never blocks or skips a card itself for failures it counted; `tick-plan.sh` does, with reason `no progress after <n> attempts: <last_action_error>` (or `no error recorded`) for `block`, and the two skip reasons above.
     - **`block` for action failures** (the plan's reason starts with `no progress after `), in this order (review cycle 5):
       1. `note.sh merge` with `{"blocking_pr": null}` **first**, before the move, so no stale blocking PR can unblock the card by itself even when a later step fails. If this merge fails, the action made no progress (counted as in "The rule"); the card is not moved this tick.
       2. `board-move.sh N blocked`. If it fails, the action made no progress: count it as in "The rule" (`action_failures` + 1 and `last_action_error`). The counter is never reset before the move succeeds.
       3. Only after the move succeeds: `note.sh merge` with `blocked_findings` = `[{"severity":"Important","text":"<the plan's reason>"}]` (never the review findings), `action_failures: 0` and `last_action_error: null` (with the note-upkeep `state: blocked`), so a card a person moves back by hand gets fresh attempts instead of being blocked again on the next tick. If this merge fails, the tick report carries its stderr line as a warning.
       Only a person moves the card back. The comment (via `board-comment.sh`) says the card's action made no progress that many times, quotes the error, and says a person must fix the cause (for example remove the other worktree, switch the main checkout to another branch, restore `worktrees.dir`, fix `worktrees.setup`, or fix what makes the role's report fail) and then move the card back.
     - `unblock` and `finish` also reset both keys (see their rows).
   - **`worktree.sh review` output.** It prints `{"path":..,"copy":..|null,"sha":..,"base":..}`: `path` is the review worktree the reviewer is given, `sha` is the PR head being reviewed (it becomes `last_review.sha` when the report is accepted), and `base` is the merge-base with `origin/main` (the round-1 comparison point). If it exits non-zero, the reviewer is not dispatched and the action made no progress (see "Action failures").
   - **`fix`, step by step.** Dispatch the fixer; reconcile its report (step 3). Only when the fixer's report is accepted and its Status is `done`: `note.sh merge` with `round` + 1 (plus `escalated: true` and `escalated_at_round` = the new round when the plan card's `escalated` is true, and `models` = the plan card's `models`), run `worktree.sh review N <pr>`, and dispatch the reviewer with `round` = the new round and `prev_sha` = `note.last_review.sha`. When the fixer's report is rejected twice, or its Status is `blocked`, the round does not change and no reviewer is dispatched this tick.
   - **Surviving findings** for `block` (other than an action-failure block, above) are `note.last_review.findings` filtered to Critical and Important; `blocked_findings` is always a list of `{severity, text}`. When there are no surviving findings (an in_progress card blocked by the plan after the implementor attempt limit), it is `[{"severity":"Important","text":"<the plan's reason>"}]`. The comment is posted with `board-comment.sh`.
   - **`to_human_qa`.** The worktree is the plan card's `worktree`. The Acceptance section is read from the card body (`board-read.sh N`, `.body`): the `## Acceptance` heading line through the line before the next `## ` heading or the end of the body, each line prefixed `> `. The qa_build summary is its exit code and the last 20 lines of its output, in a fenced block; when `commands.qa_build` is unset the comment says no QA build is configured. `board-move.sh N human_qa` runs first; the comment is posted with `board-comment.sh` only after the move succeeds, so a failed move never leaves a comment behind to be posted again on the next tick. Before posting, the manager checks the card's `comments` (from `board-read.sh N`): when one already has a heading line reading `What to check in Human QA`, it posts no other. When the comment fails after the move, the card is still in `human_qa` (progress) and the tick report carries the stderr line as a warning.
   - **`verify_main`.** `<pr>` is the plan card's `pr` (the merged PR). On exit 0, merge `main_check` = `{commit, ok, results}` from its output (not `p0_card`); when `ok` is false, the tick report's result for the card names the red commit and `p0_card`. On a non-zero exit nothing is merged (`main_check` stays null, so the next tick retries) and the tick report carries a warning.
   - **`merge`.** Only when the plan says `merge`; the manager never decides to merge on its own. If `gh pr ready` or `gh pr merge` fails or is blocked, `merged_pr` is not set and the tick report carries the stderr line as a warning.
   - **`finish`.** Only two steps: `board-move.sh N done`, then the note write setting `state: done`. The note write is best-effort: when it fails or is denied, the card's table result says so and `Warnings:` carries the reason. The tick does not fail, and the write is not retried in another form. The manager removes no worktree and never runs `worktree.sh remove`. The worktrees of done cards are removed outside any Claude session by `cleanup-done.sh`, which the headless wrapper runs after each successful tick and interactive users run by hand. (Observed in Phase 6 Task 9: Claude Code's safety classifier denied `worktree.sh remove` in an unattended tick as irreversible local destruction.)
   - **Actions not listed** in the table (any other value) are treated as `skip` with a warning.

3. **Report reconciliation, for every role result:**
   1. Write the agent's final report text to a temp file.
   2. Run `parse-report.sh --role <role>`.
   3. On failure, re-dispatch the same role once, on the same model, with the same inputs plus: `Your previous report was rejected by the manager: <parse-report stderr>. The rule: every report contains ## Status, ## Findings, ## For the card, and exactly one line of the form VERIFIED: \`<command>\` -> <integer> <what it counts>.`
   4. If the second report also fails, `note.sh merge` a `report_errors` entry and leave the card where it is. The action made no progress: count it (see "Action failures"), in the same merge or the next.
   5. On success:
      - Set `last_verified`.
      - For the reviewer, set `last_review` = `{round, sha, critical, important, findings}`, where `sha` is the `sha` that `worktree.sh review` returned for this review.
      - For the implementor, set `pr`, from the report's `## PR`.
      - When any role reports Status `blocked` with a non-null `blocked_by`: `note.sh merge` with `blocking_pr` = `blocked_by`, then `board-move.sh N blocked`. The `unblock` action later fires when that PR merges.
      - Run `file-followups.sh` on a file holding this report's `out_of_scope` and `bugs`, **plus** any items already in `note.pending_followups`, so one call covers both.
        - **On exit 0:** merge its `out_of_scope_created` and `bugs_filed` output into the note (`note.sh merge` appends both), and set `pending_followups: null`.
        - **On a non-zero exit:**
          - Merge whatever entries it printed as already filed.
          - Store every item not yet filed as `pending_followups`. That is the union of the previous pending items and this report's items, deduplicated by (kind, title) with titles compared case-insensitively, minus those just filed.
          - Carry a warning in the tick report.
          - Pending items are never replaced by a later report's items. They are only added to.

   Clarifications of step 3 (the spec must carry each):
   - **Exit codes of `parse-report.sh`.** 0: accepted, and every value used afterwards comes from its JSON on stdout (never from re-reading the markdown). 1: rejected; the stderr lines (each prefixed `parse-report: `) are quoted exactly in the re-dispatch text, together with the report-shape rule each line enforces (the rule table in `reporting.md`). 2: a usage error in the manager's own call; the manager fixes its call and never re-dispatches for it. The `fleet-board:reporting` skill may be invoked here; it holds the same rules.
   - **Parsed fields used:** `status`, `findings` (`[{severity,text}]`), `counts` (`{critical,important,minor}`), `out_of_scope` (`[{title,detail}]`), `bugs` (`[{title,repro,expected,observed}]`), `blocked_by` (integer or null), `pr` (integer or null), `verified.line` (the `VERIFIED:` line, stored as `last_verified`).
   - **`last_review`** = `{"round": <the round the reviewer was given>, "sha": <worktree.sh review sha>, "critical": counts.critical, "important": counts.important, "findings": findings}`.
   - **`report_errors` entry:** `{"role", "round", "at": <ISO time>, "errors": [<the second rejection's stderr lines>]}`. The tick report's `Reports rejected:` count is the number of role reports rejected this tick (first and second attempts both count).
   - **Implementor `pr`** is merged only when the parsed `pr` is non-null.
   - **Status `blocked` with `blocked_by` null** (for example a fixer finding it can resolve only by changing a test, marked `not fixed: needs human decision`): `note.sh merge` with `blocked_findings` = the report's Critical and Important findings (or, when there are none, one entry holding the report's `for_the_card` text), `board-move.sh N blocked`, and post a comment listing them. No `blocking_pr` is set, so only a person moves the card back.
   - **The follow-up file** for `file-followups.sh <card> <pr> <file>` is a JSON object `{"out_of_scope":[...],"bugs":[...]}` (the parsed report's two lists, with the pending ones added). `<pr>` is the card's PR (`note.pr`, or the implementor's newly reported `pr`). The manager files only when a PR number is known. When there is none yet (a blocked implementor that opened no PR) and there are items to file, it stores them in `pending_followups` with `pr: null` and adds a warning; they are filed by the first reconciliation after `note.pr` is set. When both lists are empty and nothing is pending, `file-followups.sh` is not run.
   - **`file-followups.sh` exit codes:** 0 = every item filed, stdout `{"out_of_scope_created":[...],"bugs_filed":[...]}`; 1 with empty stdout = nothing filed (a search, the note or the input failed); 1 with JSON on stdout = filed partway (those entries are filed, the rest are not). Each entry is `{title, number, existing}`; `existing: true` means an open issue already had that title and was linked instead of creating a card.
   - **`pending_followups` shape** is `{"out_of_scope":[...],"bugs":[...],"pr":<n or null>}` with the same item shapes as the parsed report.

4. **Note upkeep.** After every card's actions, `note.sh merge` with `state` = the card's resulting canonical state. A fresh tick must be able to resume from the note alone.
   - For every counted action (all but `skip`, `wait` and unlisted actions), this merge also carries the action's outcome: `action_failures` + 1 and `last_action_error` when it made no progress, `action_failures: 0` and `last_action_error: null` when it did (see "Action failures"). An action whose outcome was already written in an earlier merge of the same tick is not counted twice.
   - Every dispatch also records the `models` it used (the plan card's `models`) in the note, so the note always names the models actually used.
5. **Tick report,** as the final message:
   - `## Tick report`
   - a table of card, action and result
   - `Warnings:`
   - a `Reports rejected:` count
   - a cost line: `cost_estimate_usd: <x> (estimate; subagent tokens x prices.json as_of <date>)`, summing `estimate-cost.sh --model <m> --tokens <n>` over each dispatch's reported total tokens
   - the last line exactly `dispatchable: true|false`: the plan's value, except that it is `true` when any `file_pending` filing exited 0 this tick

   Clarifications of step 5 (the spec must carry each):
   - `Warnings:` lists every plan warning (including the shared-model warning, `implementor and reviewer share model <m>; the reviewer shares the writer's blind spots`), every follow-up filing failure, every script failure or gate block, and every dispatch whose token count was missing; `Warnings: none` when there are none.
   - The cost is the sum, formatted with 4 decimals, of `estimate-cost.sh --model <model passed> --tokens <total tokens>` for every dispatch (re-dispatches included); `as_of` is the `as_of` field of `<scripts>/prices.json`. A dispatch with no reported token count adds 0 and a warning. With no dispatches the cost is `0.0000`.
   - Nothing follows the `dispatchable:` line.

## Must never

- move a card out of `human_qa`
- merge under `merge.policy: human`
- merge a draft
- move a card to `ready` itself, except `unblock`
- edit code
- read role transcripts. The manager sees only the reports.
- dispatch any agent without an explicit `model`
- run more than `limits.concurrency` role agents at once
- invoke any skill other than `fleet-board:reporting` (decision D3)
- dispatch any agent other than `fleet-board:implementor`, `fleet-board:reviewer`, `fleet-board:fixer` (decision D3)
- edit, complete or rewrite a role's report, or accept a report `parse-report.sh --role <role>` rejected
- re-dispatch a role more than once for one rejected report
- drop a reported out-of-scope item or bug: it is filed, or it stays in `pending_followups`
- run `gh pr ready` and `gh pr merge` in one Bash call, or pass `--delete-branch` or `--admin` to `gh pr merge`
- run `worktree.sh remove`, or delete any worktree or directory itself; worktree cleanup for done cards belongs to `cleanup-done.sh`, run outside Claude
- put a shell variable or `$(...)` where a card number, PR number or state belongs in a `board-move.sh`, `gh pr ready` or `gh pr merge` command
- run tests or a test suite itself (`verify-main.sh` runs the post-merge checks); never `npm test`, jest or a bare `node --test`
- write to the board except through the fleet-board scripts, `gh pr ready`, `gh pr merge`, and the manager-note script

## Example commands

Every example command in the spec uses the fleet-board scripts with literal values (for example `cd /work/toy && bash /plugins/fleet-board/scripts/board-move.sh 12 in_review`) and a repo like `acme/toy`. When a test command appears in an example (e.g. a `commands.test_one` value), it is `node --test {file}` or a single file such as `node --test test/calc.test.js`. Never give `npm test`, jest, `--runTestsByPath` or any command that could run a whole suite as an example; `npm test` and a bare `node --test` may appear only in Must never.

## What the manager passes to each role (from the role specs)

- **implementor** (`subagent_type: fleet-board:implementor`, `model` = plan `models.implementor`): the card number, title and body (from `board-read.sh N`); the worktree path (absolute) and branch; the config JSON; the manager note (`note.sh get N`) for a continuation; the absolute scripts dir.
- **reviewer** (`fleet-board:reviewer`, `model` = plan `models.reviewer`): the card number and body; the PR number; the PR diff (`gh pr diff <pr> --repo R`; when it is longer than 1500 lines, the manager writes it to a temp file and passes that file's absolute path instead, saying so); the latest implementor or fixer report text only (in the same tick, the report the fixer just returned; otherwise the newest comment on the card whose body has a `## Status` line and a line starting `VERIFIED:` and no `## Acceptance map` line); the review worktree path (`path` from `worktree.sh review`); the config JSON; the round number; the reference SHA (`prev_sha`: round 1 the `base`, later rounds `note.last_review.sha`); the absolute scripts dir.
- **fixer** (`fleet-board:fixer`, `model` = plan `models.fixer`): the card number, title and body; the PR number; the worktree path (the plan card's `worktree`, on the PR branch); the findings list (`note.last_review.findings` filtered to Critical and Important, each as the line `- [<severity>] <text>`); the config JSON; the absolute scripts dir.

## Scripts the manager calls (their actual interfaces; the spec must match them)

Board contract scripts (all under `<scripts>`; each exits 3 when the repo has no config):

- `board-cache-clear.sh` — clears the Projects backend cache; no arguments.
- `board-read.sh <n>` — JSON `{number,title,url,state,body,labels,manager_note,manager_note_id,comments}`; `comments` is `[{id,author,body,created_at}]`, oldest first.
- `board-move.sh <n> <state>` — moves the card (canonical states `backlog ready in_progress in_review human_qa blocked done wont_do`); a move to `ready` is refused for a body without `## Acceptance`; already there is a no-op.
- `board-comment.sh <n> <file>` — posts the file content verbatim as a new comment.
- `board-create.sh <title> <body-file> [--label L]...` — used by `verify-main.sh` and `file-followups.sh`, not directly by the manager.
- `parse-report.sh [--role implementor|reviewer|fixer] <file>` — see `reporting.md`.
- `status.sh` — not used by the manager.

The Phase 6 scripts, with their header documentation verbatim:

````
### note.sh
note.sh - the manager note codec: reads, writes and merges a card's note.

Usage:
  note.sh get <n>                    print the note JSON ({} when there is none)
  note.sh parse <n> < <board-read-json>
                                     the same as get, from a board-read.sh
                                     output on stdin (no board call)
  note.sh put <n> <json-file>        write the note (missing keys get defaults)
  note.sh merge <n> <json-patch>     get, merge the patch in, put
  note.sh reset-failures <n>         merge {"action_failures": 0,
                                     "last_action_error": null} (no file)

The note is a comment on the card: the marker line (added by board-note.sh),
a heading, a one-line summary, and one fenced ```json block holding the note.

get validates the note before trusting it (fields that could steer shell
commands). An invalid note prints {} and a warning on stderr:
  fleet-board: warning: ignoring invalid manager note on #<n>: <field>
A worktree that is a well-formed absolute path (no control character, no
".." segment) but lies outside the current normalized worktrees base (the
repo was re-cloned or moved, or worktrees.dir changed) does not reject the
note: get prints it with worktree null and warns
  fleet-board: warning: manager note on #<n> names a worktree outside <base>; treating it as null: <path>
put refuses to write a note that get would reject, and a worktree outside
the base.

action_failures (a non-negative integer, default 0) and last_action_error
(a string or null) count the manager's actions on the card that failed to
make progress, in a row (the manager resets them after one that did);
tick-plan.sh blocks the card at review.max_rounds, and skips it for a
person at 2 * review.max_rounds (review.max_rounds when it is blocked and
its unblock is due). A hand move does not reset them; reset-failures does.
get rejects a last_action_error holding a control character; put and
merge replace each control character in it with a space first, since it
is written from an error line and a refused write would lose the count.
The summary line shows the count and the error when action_failures > 0.
A note written before the rename holds setup_failures and last_setup_error:
get, parse, merge and put read them as action_failures and
last_action_error (the new key wins when both are present) and drop them.

reset-failures is what a person runs after moving a card that tick-plan.sh
skips on its count (its warnings end with this command): a hand move does not
reset the count, so without it the card would be skipped, or blocked again.
It behaves exactly like merge with that patch, including the refusal below.

merge: out_of_scope_created and bugs_filed append (deduplicated by title,
compared case-insensitively), report_errors appends, pending_followups is
replaced whole, and every other key is merged with jq's * operator. merge
refuses (exit 1, nothing written) when the stored note is invalid, so that
it never overwrites it with a note built from {}; replace it with put.

Exit codes:
  0 - success (get: note or {} printed)
  1 - the card could not be read or written (parse: stdin is not a card),
      the note's JSON block does not parse, put/merge was given an invalid
      note or a file that is not a JSON object, or merge (or reset-failures)
      found the stored note invalid
  2 - usage error
### tick-plan.sh
tick-plan.sh - decides one step for every card on the board (the tick plan).

Usage: tick-plan.sh        (no arguments; run inside the repo)

Lists the ready, in_progress, in_review and blocked columns, reads each card
once (board-read.sh; the manager note is parsed from that read with
note.sh parse), makes the PR lookups the decision needs, and prints:

  {"dispatchable": bool, "warnings": [..], "cards": [
    {"number", "title", "state", "action", "reason", "branch", "worktree", "pr",
     "round", "models": {"implementor","reviewer","fixer"}, "escalated",
     "needs_human_qa": bool|null, "comment_needed": bool|null}]}

branch and worktree are always set: the note's when it has them, else the
defaults fleet/<n>-<slug> and <base>/<n>-<slug> (slug from the title, "card"
when empty). A note worktree outside the current base counts as none.

Lookups per card (all through gh --repo <board.repo>):
  gh pr list --head <branch> --state open --json number
      in_progress/in_review, when note.pr is null and note.branch is set
  gh pr view <pr> --json isDraft,state,mergedAt,statusCheckRollup,headRefOid
      in_progress/in_review, when a PR is known
  needs-human-qa.sh --labels <card labels> <n> <pr>
      in_review, when the PR is open and the review is clean and current
      (last_review.round >= note.round, as in the table, and no Critical or
      Important finding); otherwise needs_human_qa is null, since the
      decision does not use it
  gh pr view <blocking_pr> --json state,mergedAt
      blocked, when note.blocking_pr is set
A failed lookup (or a failed card or note read) makes that card's action
skip, with reason "lookup failed: <command>" and a warning. It never falls
through to any other action.

A card whose manager note note.sh rejects as invalid is skipped with reason
"invalid manager note: <field>" and the warning
"#<n>: invalid manager note: <field>; fix or replace it (note.sh put)":
note.sh merge refuses to write over an invalid note, so no action could
record its effect (an attempt count, a round), and the card would loop.

The decision table itself is the single jq program below.

Pending follow-ups (note.pending_followups) hold a card in file_pending only
when a PR is known to file them against: pending_followups.pr, else note.pr,
else the PR this plan found. Without one, the card goes through the table as
usual and the plan warns "pending follow-ups on #<n> wait for a PR".
Action failures: note.action_failures is the number of the manager's
actions on the card, in a row, that failed to make progress, as the
manager records them: any action (start, continue_implementor,
start_review, review, fix, mark_ready, merge, verify_main, to_human_qa,
file_pending, block, unblock, finish, skip_no_acceptance) whose intended
board or note change did not happen, for any reason (a failed setup step,
a report rejected twice, a failed gh, board or script call, a refused
merge); an action that made progress resets it to 0. This script only
reads the count. Below, k is note.action_failures, max is
review.max_rounds and <error> is note.last_action_error, or
"no error recorded" when it is null:
  ready, in_progress, in_review, max <= k < 2*max: block, with reason
    "no progress after <k> attempts: <error>", whatever action the table
    would give. A block that fails is counted too, so k keeps rising while
    the card stays in its column.
  ready, in_progress, in_review, k >= 2*max: skip, with reason
    "could not be blocked after <k> attempts: <error>" and the warning
    "#<n>: could not be blocked after <k> attempts: <error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>".
  blocked, with note.blocking_pr set and merged (the table would give
    unblock), k >= max: skip (unblock is not tried again), with reason
    "unblock made no progress after <k> attempts: <error>" and the warning
    "#<n>: unblock made no progress after <k> attempts: <error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>".
    Any other blocked card has no unblock to fail: it gets the table's
    skip "blocked", whatever k is.
  <scripts> is this script's absolute directory, single-quoted when it
  holds a character the shell would split or expand. A hand move does not
  reset k (it lives in the note), so without the reset the card would stay
  skipped (k >= 2*max) or be blocked again (a blocked card moved to ready).
So, file_pending aside (it comes first, and is never dispatchable by
itself), the plan gives no action to a card whose recorded count is
2*max or more, or max or more when it is blocked: at most 2*max actions
in a row without progress on a card before it waits for a person. The count lives in the note, not in the column: only an
action that made progress (the manager resets it) or a person editing the
note (note.sh reset-failures) clears it. It bounds only what the manager records; a failure the
manager does not record is not counted. Order: a failed lookup, then an
invalid note (both skip), then file_pending (it only files, and pending
items are never dropped), then these rules, then the table.
An in_review card with no known PR is skipped with the warning
"#<n>: in review, but no PR is known".
A clean, current review whose human-QA answer is unknown is skipped with
the warning "human-QA need unknown for #<n>".
A note worktree outside the current base (note.sh reads it as null) adds
note.sh's warning to the plan's warnings:
"manager note on #<n> names a worktree outside <base>; treating it as null: <path>".

Exit codes:
  0 - plan printed
  1 - a column could not be listed, or the plan could not be built
  2 - usage error
### worktree.sh
worktree.sh - creates, refreshes and removes a card's git worktrees.

Usage:
  worktree.sh create <n> <branch> <path>
      Fetches origin. When <path> is already a worktree of this repo on
      <branch>, prints the path and stops (resumption). Otherwise adds a
      worktree at <path>: on the local branch when it exists, else tracking
      origin/<branch> when that exists, else a new branch from origin/HEAD
      (falling back to origin/main). Runs worktrees.setup in a worktree it
      just created, then prints the path. When the branch is already checked
      out in another worktree (for example under an old worktrees.dir, or in
      a repo that moved), it adds nothing and fails with
        fleet-board: branch <branch> is checked out at <other path>; remove that worktree (git worktree remove, or git worktree prune when its directory is gone) or restore worktrees.dir
      or, when the other checkout is the repository's main checkout,
        fleet-board: branch <branch> is checked out at <path>, the repository's main checkout; switch that checkout to another branch
  worktree.sh review <n> <pr>
      Fetches the PR head (into refs/fleet-board/pull/<pr>) and puts a
      detached worktree <base>/<n>-review on it, creating it (and running
      worktrees.setup once) or checking the new head out in it. With
      worktrees.mutate_on_copy, also refreshes <base>/<n>-review-copy, a
      cp -R of the checkout without .git. Prints
      {"path":..,"copy":..|null,"sha":<head>,"base":<merge-base origin/main head>}.
  worktree.sh remove <n> [<worktree-path>]      (never called by the manager; used by cleanup-done.sh)
      Removes <worktree-path>, which must be the card's own directory: a
      direct child of <base> named <n>-* (as given and after symlinks are
      resolved), never main-check (an empty string or "null" counts as omitted;
      omitted means every <base>/<n>-* except <n>-review and
      <n>-review-copy), then <n>-review, then <n>-review-copy, then runs
      git worktree prune. Missing paths are fine. Never deletes a branch.

<base> is the normalized worktrees directory:
  cd "$FLEET_ROOT/<worktrees.dir>" && pwd -P
Every path this script touches must resolve (symlinks followed) to a path
strictly under <base>; create also requires <path> to be a direct child.
A path outside it, or holding a "." or ".." segment, is refused before
anything is changed.

Exit codes:
  0 - done (create: path printed; review: JSON printed; remove: all removed)
  1 - refused path, git failure, setup failure, or an existing path that is
      not the expected worktree
  2 - usage error
### verify-main.sh
verify-main.sh - checks main after a card's PR merged (typecheck plus the
touched tests), and files a P0 card when main is red.

Usage: verify-main.sh <card-n> <pr>

Steps:
  1. git fetch origin.
  2. Put the detached worktree <base>/main-check on origin/main, creating it
     or checking the new commit out in it. The user's own checkout is never
     touched. worktrees.setup runs when main-check is first created, and
     again when package-lock.json, yarn.lock or pnpm-lock.yaml changed
     between its previous and new HEAD.
  3. Runs commands.typecheck in main-check, when set.
  4. For each file of `gh pr view <pr> --json files` that matches test_paths
     and exists on main, runs commands.test_one with {file} replaced by the
     path. A path outside [A-Za-z0-9._/@+-] is not substituted into a shell
     command; it is recorded as a failed result instead.
  5. Prints {"commit": <sha>, "ok": bool, "results": [{"cmd", "exit"}]}.
  6. When ok is false, files the Backlog card "[P0] main is red after #<pr>"
     and adds "p0_card": <n>. It first searches the open issues
       gh issue list --state open --search "<terms> in:title"
     (<terms> is the title with each character outside [A-Za-z0-9 _-]
     turned into a space); a row whose title equals the P0 title,
     case-insensitively, is reused (a retry never files a second card).
     Otherwise it creates the card through board-create.sh (its body names
     the commit, the failing commands, "Merged PR: #<pr>" and the card).
     A failed or unexpected search exits 1: it never files blind.
     Limits of the reuse:
     - GitHub search is eventually consistent. A new issue can take a while
       to appear in search results, so a retry within seconds of a run that
       filed the card can still file a duplicate.
     - On the github-projects backend, filing is two steps (create the
       issue, then add it to the project), so a run can leave the issue off
       the board. A reused issue is read with board-read.sh; when it is not
       an item of the project (item_id null) it is moved to backlog with
       board-move.sh, which adds it to the project. An issue already on the
       project is left in whatever column it is in. A failed read or move
       exits 1.
       On github-labels, one gh issue create files and labels the card, so
       no board check is made.
Command output goes to stderr; stdout holds only the JSON.

<base> is the normalized worktrees directory (cd <worktrees.dir> && pwd -P).

Exit codes:
  0 - verified; JSON printed (ok may be false, with the P0 card filed)
  1 - main could not be verified (fetch, worktree, setup, or PR files lookup
      failed), or main is red and the P0 card could not be searched for or
      filed; nothing is printed on stdout
  2 - usage error
### file-followups.sh
file-followups.sh - files a role report's follow-ups as Backlog cards.

Usage: file-followups.sh <card-n> <pr> <parsed-report-json-file>

The report file is parse-report.sh output; its out_of_scope items
({title, detail}) and bugs ({title, repro, expected, observed}) are filed.

  0. The input is deduplicated by (kind, title), titles compared
     case-insensitively. Items whose title is already in the card's note
     (out_of_scope_created for out-of-scope items, bugs_filed for bugs) are
     dropped: they were filed before.
  1. Pass one searches for every item before anything is written:
       gh issue list --state open --search "<terms> in:title"
     where <terms> is the title with each character outside [A-Za-z0-9 _-]
     turned into a space. A returned row matches when its title equals the
     item's title, case-insensitively. Any search failure exits 1 having
     filed nothing.
  2. Pass two files each item:
       match      gh issue comment <existing> "Also seen while working #<card> (PR #<pr>).",
                  then gh pr comment "<Known bug|Out of scope>, already tracked as #<existing>: <title>"
       out of scope, no match
                  board-create.sh "<title>" (detail + "Found while working #<card> (PR #<pr>).")
                  then gh pr comment "Out of scope, tracked as #<new>: <title>"
       bug, no match
                  board-create.sh "<title>" (## Bug/Repro/Expected/Observed body) --label bug
                  then gh pr comment "Bug found outside this card, filed as #<new>: <title>"
     An item counts as filed once its create or its existing-issue comment
     succeeds. A failed PR comment only warns on stderr:
       fleet-board: warning: PR comment failed for #<n>

Prints {"out_of_scope_created":[{title,number,existing}], "bugs_filed":[...]}.

Exit codes:
  0 - every item filed (or none to file); JSON printed
  1 - nothing filed (the note, report, or a search failed; stdout empty), or
      a create/existing-issue comment failed partway through pass two
      (stdout holds the JSON of the items filed so far)
  2 - usage error
### estimate-cost.sh
estimate-cost.sh - estimates the USD cost of token counts from prices.json.

Usage:
  estimate-cost.sh --model <alias|id> --input N --output N [--cache-write N] [--cache-read N]
  estimate-cost.sh --model <alias|id> --tokens N
  estimate-cost.sh --model-usage <json>

Prints USD with 4 decimals. Prices are USD per million tokens, read from
prices.json next to this script; an alias (opus, sonnet, ...) maps to an id.
  --tokens N       a total-token-only count (what subagent results give),
                   priced at the blended rate 0.8*input + 0.2*output
  --model-usage J  a stream-json modelUsage object, {<model>: {inputTokens,
                   outputTokens, cacheReadInputTokens,
                   cacheCreationInputTokens, costUSD}}; an entry's costUSD is
                   used when present, otherwise its tokens are priced
The result is an estimate: prices.json is a snapshot, not a bill.

Exit codes:
  0 - cost printed
  1 - unknown model (or prices.json unreadable)
  2 - usage error (bad flag, missing or non-numeric count, invalid JSON)
### needs-human-qa.sh
needs-human-qa.sh - decides whether a card's PR needs human QA.

Usage: needs-human-qa.sh [--labels <json-array>] <card-n> <pr-n>

--labels: the card's label names as a JSON array of strings (as board-read.sh
prints them), from a card read the caller already has; the card is then not
read again.

Prints true when the card carries the needs-human-qa label, or when a file
the PR changes matches a human_qa_paths glob; prints false otherwise.

Glob rule: matched with bash `case` after turning ** into *; a pattern that
starts with **/ also matches with that prefix removed, so src/components/**
matches src/components/a/b.tsx and **/*.test.* matches a.test.js.

When gh lists fewer files than the PR changes (a very large PR), the answer
is true with a warning: a file it did not list could need human QA.

Exit codes:
  0 - answer printed
  1 - the card or the PR's files could not be read (nothing printed)
  2 - usage error (including --labels that is not a JSON array of strings)
````

## From the phase plan (verbatim): Manager note schema and Tick plan

### Manager note schema (encoded by `note.sh`)

The note comment body, after the marker line that `board-note.sh` adds:

````
### fleet-board manager note
State: <state> · Round: <round> · PR: #<pr or —> · Branch: `<branch>`[ · Action failures: <n> (last: <last_action_error>)]

```json
{ ...note JSON... }
```
````

The note JSON keys all default to `null`, or `[]` for lists (the two counters default to 0). The summary line ends with ` · Action failures: <n> (last: <last_action_error>)` only when `action_failures` is above 0:

| Key | Contents |
|---|---|
| `state` | canonical state |
| `branch` | branch name |
| `worktree` | worktree path |
| `pr` | PR number |
| `round` | review round |
| `models` | `{implementor, reviewer, fixer}`, the models actually used |
| `escalated` | boolean |
| `escalated_at_round` | round at which models escalated |
| `last_verified` | the most recent `VERIFIED:` line |
| `last_review` | `{round, sha, critical, important, findings:[{severity,text}]}` |
| `blocked_findings` | surviving findings when the card was blocked |
| `blocking_pr` | the PR blocking this card |
| `merged_pr` | PR number once merged |
| `main_check` | `{commit, ok, results}` |
| `out_of_scope_created` | `[{title, number, existing}]` |
| `bugs_filed` | `[{title, number, existing}]` |
| `pending_followups` | the parsed `{out_of_scope, bugs, pr}` of a report whose filing failed, or `null` |
| `report_errors` | malformed-report records |
| `implementor_attempts` | integer, default 0. Incremented on every implementor dispatch. |
| `action_failures` | non-negative integer, default 0. The number of the manager's actions on the card, in a row, that did not make progress (review cycle 4; it replaces cycle 3's `setup_failures`). At the end of each action the manager adds 1 when the action's intended board or note change did not happen, for any reason (a failed setup step, a report rejected twice, a failed `gh`, board or script call, a refused merge), and resets it to 0 when it did. `block` for this reason, `unblock` and `finish` also reset it (the error moves into `blocked_findings`, so a card a person moves back by hand is not re-blocked on the next tick). `tick-plan.sh` blocks the card at `review.max_rounds` and skips it, with a warning for a person, at `2 * review.max_rounds` (`review.max_rounds` when it is blocked and its unblock is due; review cycles 5 and 6). A hand move does not reset it; `note.sh reset-failures <n>` does (review cycle 6). |
| `last_action_error` | string or null, default null. One line saying why the last counted action made no progress; reset to null with `action_failures`. `note.sh put` and `merge` replace each control character in it with a space. `note.sh reset-failures` sets it to null. |
| `updated_at` | ISO timestamp |

**Array keys append.** `out_of_scope_created`, `bugs_filed` and `report_errors` are append-only history. `pending_followups` is written only by the manager's filing step, as the full set of still-unfiled items. The step itself computes the union of the old pending items and the new ones, so `note.sh merge` replaces the key with that union. `note.sh merge` concatenates them (existing + patch, deduplicated by `title`, compared case-insensitively, for `out_of_scope_created` and `bugs_filed`). Every other key is replaced, using jq `*` semantics. `note.sh merge` (and `note.sh reset-failures`, which is a merge) refuses (exit 1, nothing written) when the stored note is invalid, instead of overwriting it with a note built from `{}`; `note.sh put` replaces it. (Review cycle 1.)

**Validation on read (trust boundary).** `note.sh get` rejects a note whose fields could steer shell commands. On rejection it prints `{}` and writes `fleet-board: warning: ignoring invalid manager note on #<n>: <field>` to stderr. The checks:
- `pr` is null or an integer.
- `blocking_pr` and `merged_pr` are null or integers.
- `branch` is null or matches `^fleet/[0-9]+-[a-z0-9-]{1,40}$`.
- `worktree` is null, or an absolute path with no control character and no `..` segment. It must also be equal to the normalized worktrees base or start with `"<base>/"`; a plain string prefix is not enough: `<root>/.fw2/x` must not pass for the base `<root>/.fw`.
  - **Outside the current base (review cycle 1).** A worktree that is otherwise well formed but lies outside the current base (the repo was re-cloned or moved, the note was written on another machine, or `worktrees.dir` changed) does not reject the note: `note.sh get` treats it as null and warns `fleet-board: warning: manager note on #<n> names a worktree outside <base>; treating it as null: <path>`. The note's history (`pending_followups`, `bugs_filed`, and the rest) survives. `note.sh put` still refuses to write such a worktree.
  - **Normalized base:** `mkdir -p "$FLEET_ROOT/$(fb_cfg worktrees.dir)" && cd "$FLEET_ROOT/$(fb_cfg worktrees.dir)" && pwd -P`, run in a subshell. This does not depend on `realpath`, which macOS bash 3.2 may lack.
  - `tick-plan.sh` and `worktree.sh` always emit worktree paths built from that normalized base.
- `round` is null or an integer.
- `implementor_attempts` is null or an integer.
- `action_failures` is null or a non-negative integer; `last_action_error` is null or a string with no control character (review cycles 3 and 4).
- `pending_followups` is null or an object; `pending_followups.pr` is null or an integer.

Phase 2 already restricts the note to comments by the authenticated login. This is the second layer.

### Tick plan (the output of `tick-plan.sh`)

```
{"dispatchable": bool, "warnings": [..], "cards": [
  {"number", "title", "state", "action", "reason", "branch", "worktree", "pr",
   "round", "models": {"implementor","reviewer","fixer"}, "escalated",
   "needs_human_qa": bool|null, "comment_needed": bool|null}
]}
```

**Actions,** evaluated per card in the listed state order `ready`, `in_progress`, `in_review`, `blocked`. `human_qa`, `done` and `wont_do` are never listed. This is AC1's state table.

| State | Condition | Action |
|---|---|---|
| ready, in_progress, in_review | `note.action_failures >= 2 * review.max_rounds` (after `file_pending`, before every row below) | `skip` (reason `could not be blocked after <k> attempts: <last_action_error>`; warning `#<n>: could not be blocked after <k> attempts: <last_action_error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>`) (review cycles 5 and 6) |
| ready, in_progress, in_review | `review.max_rounds <= note.action_failures < 2 * review.max_rounds` (after `file_pending`, before every row below) | `block` (reason `no progress after <k> attempts: <last_action_error>`, or `no error recorded` when it is null) |
| blocked | `note.blocking_pr` is set and merged (the table would give `unblock`) and `note.action_failures >= review.max_rounds` (after `file_pending`, before the blocked rows below); any other blocked card gets the table's `skip` (reason `blocked`), whatever the count | `skip` (reason `unblock made no progress after <k> attempts: <last_action_error>`; warning `#<n>: unblock made no progress after <k> attempts: <last_action_error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>`) (review cycles 5 and 6) |
| ready | the body has `## Acceptance` | `start` |
| ready | no Acceptance | `skip_no_acceptance`. `comment_needed` = no comment contains `<!-- fleet-board:skip-no-acceptance -->` |
| in_progress | no PR known and `implementor_attempts < review.max_rounds` | `continue_implementor` |
| in_progress | no PR known and `implementor_attempts >= review.max_rounds` | `block` (reason `implementor produced no PR after <n> attempts`) |
| in_progress | a PR exists | `start_review` (and the plan's `pr` carries the discovered number, which the manager merges into the note) |
| in_review | the PR is merged and `note.main_check` is null | `verify_main` |
| in_review | the PR is merged and `main_check` is set | `finish` (move to done) |
| in_review | `note.last_review` null, or `last_review.round < note.round` | `review` |
| in_review | `critical + important > 0` and `round < review.max_rounds` | `fix` |
| in_review | `critical + important > 0` and `round >= review.max_rounds` | `block` |
| in_review | zero Critical and Important, and `needs-human-qa.sh` says true | `to_human_qa` |
| in_review | zero, no QA need, and the PR is still a draft | `mark_ready` |
| in_review | zero, no QA need, PR not a draft, `merge.policy == auto`, and the rollup is green | `merge` |
| in_review | zero, no QA need, PR not a draft, otherwise | `wait` |
| blocked | `note.blocking_pr` is merged | `unblock` |
| blocked | otherwise | `skip` |

**"PR known"** means `note.pr` is set. When it is null but `note.branch` is set, `tick-plan.sh` also runs `gh pr list --repo R --head <branch> --state open --json number`. A hit counts as the PR. This covers an implementor whose report was rejected twice after it had already opened a PR.

**Pending follow-ups hold the card in place.**
- Any listed card whose `note.pending_followups` is non-null, and that has a PR to file them against, gets action `file_pending`, with reason `pending follow-ups`, overriding the table above. The PR is `pending_followups.pr`, else `note.pr`, else the PR the plan found by branch. The card does not advance until those items are filed, so it can never reach `human_qa` or `done`, which are never listed again, with unfiled follow-ups.
- **No PR yet (review cycle 1).** When none of the three names a PR, nothing could be filed, so holding the card would stall it forever. The card goes through the table above as usual, and the plan warns `pending follow-ups on #<n> wait for a PR`. The items are filed by the first reconciliation after the card has a PR (the manager files the pending items together with the report's).
- `file_pending` does not make the *plan* dispatchable. If GitHub keeps failing, the headless wrapper stops, and the next run retries. When a `file_pending` filing succeeds during the tick, the manager's tick report says `dispatchable: true`, because the card now has work waiting (see the manager brief, step 5).
- Cards in `in_progress`, `in_review` or `blocked` can have pending items. A report with `blocked_by` moves the card to blocked and is still filed. The override applies to every listed state, including a blocked card whose `blocking_pr` has merged: it gets `file_pending`, not `unblock`, when a PR is known.

**Action failures (review cycles 3 and 4).** Three review cycles found actions (`continue_implementor`, `fix`, `start`, a persistent `worktree.sh review` failure) whose failed setup step left the card in place and dispatchable on every tick, and cycle 4 found the same for failures that are not setup steps (a report rejected twice, a failed `gh` or board call). The bound is generic rather than per action or per failure kind: at the end of every action the manager records whether it made progress, adding 1 to `note.action_failures` when it did not and resetting it when it did, and `tick-plan.sh` turns a ready, in_progress or in_review card with `action_failures >= review.max_rounds` into `block`, whatever the table would give. It bounds exactly what the manager records. The order is: a failed lookup and an invalid note (both `skip`), then `file_pending` (it only files, and needs a PR, so pending items are never dropped), then these rules, then the table. `unblock` and `finish` reset the counter, and so does the manager's `block` for this reason, which records the error in `blocked_findings` and sets `blocking_pr` to null.

Review cycle 5 found that two actions could still keep a card dispatchable forever, because a failure of the action that is supposed to end the loop was itself unbounded. A `block` whose `board-move.sh N blocked` fails leaves the card in its column, so the count rises past `review.max_rounds` and the plan gave `block` again on every tick; and a `blocked` card was exempt, so an `unblock` that kept failing (the gate refusing the move to ready for a hand-dragged card with no `## Acceptance`, a misconfigured Ready column) was retried forever. Now, with `k = note.action_failures` and `max = review.max_rounds`: a ready, in_progress or in_review card gets `block` for `max <= k < 2*max` and `skip` with the warning `#<n>: could not be blocked after <k> attempts: <last_action_error>; fix the board and move the card by hand` for `k >= 2*max`; a blocked card gets `skip` with the warning `#<n>: unblock made no progress after <k> attempts: <last_action_error>; move the card by hand` for `k >= max`. Neither skip is dispatchable. The guarantee, bounded by what the manager records: `file_pending` aside (it comes first and is never dispatchable by itself), the plan gives no action to a card after `2*max` recorded actions in a row without progress (`max` on a blocked card); it waits for a person. The count lives in the note, not in the column, so only an action that made progress or a person editing the note clears it. A note written before the rename still holds `setup_failures` and `last_setup_error`: `note.sh` reads them as `action_failures` and `last_action_error` (the new key wins when both are present) and never writes them.

Review cycle 6 found that "move the card by hand" alone does not work, because a hand move does not reset the count: it lives in the note, not in the column. A card skipped at `2*max` stays skipped in any non-blocked column, and a blocked card skipped at `max` that a person drags back to Ready still has `action_failures >= max`, so the next plan gives `block` again. So both warnings now end with the exact command that clears it: `#<n>: could not be blocked after <k> attempts: <last_action_error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>` and `#<n>: unblock made no progress after <k> attempts: <last_action_error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures <n>`, where `<scripts>` is the absolute directory `tick-plan.sh` runs from (single-quoted when it holds a character outside `A-Za-z0-9/._+:@-`, such as a space, so the command pastes as printed). `note.sh reset-failures <n>` is `note.sh merge` with `{"action_failures": 0, "last_action_error": null}` and no patch file. Cycle 6 also narrowed the blocked-card rule to the case it bounds: it applies only when an unblock is due (`note.blocking_pr` set and merged). A blocked card with no blocking PR, or one not merged yet, has no unblock to fail; it gets the table's `skip` (reason `blocked`) and no warning, whatever its count.

**Blocked cards** with a `note.blocking_pr` get one extra lookup: `gh pr view <blocking_pr> --repo R --json state,mergedAt`. `state == "MERGED"` means `unblock`.

**Lookup failures fail closed.**
- If any `gh` lookup for a card fails (`pr list`, `pr view` of the card's PR, or `pr view` of its blocking PR), that card's action is `skip`, with `reason: "lookup failed: <command>"` and a warning line.
- A failed lookup never falls through to `continue_implementor`, `unblock` or any other action.
- Failed-lookup skips count as not dispatchable.

**Invalid notes (review cycle 1).** A card whose manager note `note.sh` rejects as invalid gets `skip`, with reason `invalid manager note: <field>` and the warning `#<n>: invalid manager note: <field>; fix or replace it (note.sh put)`. `note.sh merge` refuses to write over an invalid note, so no action could record its effect, and the card would loop. An in_review card with no known PR also warns: `#<n>: in review, but no PR is known`.

**PR lookups** use a single call per card: `gh pr view <pr> --repo R --json isDraft,state,mergedAt,statusCheckRollup,headRefOid`. `statusCheckRollup` feeds the `merge` rule, using the same green definition as gate G2e: every entry's `(.conclusion // .state)` is in SUCCESS, NEUTRAL or SKIPPED, and an empty rollup is green.

**Models.** Start from the config `models`. When `round >= models.escalate_after_rounds`, `implementor` and `fixer` become `models.escalation`, or `models.reviewer` when that is null, and `escalated` is true. The reviewer model never changes. (AC6.2)

**Warnings.** When the configured `models.implementor == models.reviewer`, add: `implementor and reviewer share model <m>; the reviewer shares the writer's blind spots`. (AC6.3)

**Dispatchable.** `dispatchable` is true when any card has an action other than `skip`, `wait` and `file_pending`, or has `skip_no_acceptance` with `comment_needed` true.

**Branch and worktree names.**
- The branch is `fleet/<n>-<slug>`. The slug is the title lowercased, with each non-`[a-z0-9]` run turned into `-`, the ends trimmed, and cut to 40 characters. Trim any trailing `-` again after the cut. If the result is empty, the slug is `card`.
- The worktree is `<normalized worktrees base>/<n>-<slug>`.
- When the note already names a branch or worktree, the note wins. That is what makes resumption stable.
- Every plan card carries a branch and worktree, so the manager takes them from the plan card for `start`, `continue_implementor` and `fix`, never from the note alone: a card dragged to In Progress by hand, or whose note write failed after `start` moved it, has no note branch (review cycle 1).

## Report checking

The report every role writes, the rejection messages of `parse-report.sh`, the rule each message enforces, and the manager-side check-and-re-dispatch method are in `reporting.md` (an input file). The spec follows it for step 3 and does not restate the whole report shape; it names `reporting.md` rules where it relies on them.

## AC ids

AC1.1 to AC1.7, AC3.9, AC3.10, AC4.7, AC4.8, AC5.4, AC6.1 to AC6.4.

## Acceptance criteria excerpt (verbatim)

### fleet-board.AC1: A tick advances every card one step
- **fleet-board.AC1.1 Success:** A Ready card with `## Acceptance` gets a worktree, a branch, an implementor dispatch, and moves to In Progress in one tick.
- **fleet-board.AC1.2 Success:** An In Progress card with a draft PR moves to In Review and gets a reviewer dispatch.
- **fleet-board.AC1.3 Success:** A card with zero Critical/Important findings and a `needs-human-qa` label or a diff matching `human_qa_paths` moves to Human QA with a comment quoting its Acceptance section.
- **fleet-board.AC1.4 Success:** A card with zero findings and no human-QA need has its PR marked ready-for-review; with `merge.policy: human` no merge happens.
- **fleet-board.AC1.5 Success:** The manager note after each tick is sufficient for a fresh tick to resume without re-reading transcripts (branch, PR, round, models).
- **fleet-board.AC1.6 Failure:** A Ready card without `## Acceptance` is skipped and receives exactly one explanatory comment across repeated ticks.
- **fleet-board.AC1.7 Failure:** At `review.max_rounds` the card moves to Blocked and the surviving findings are in the note.

### fleet-board.AC3: Role agents
- **fleet-board.AC3.9 Success:** Out-of-scope findings become new Backlog cards linked from the PR.
- **fleet-board.AC3.10 Success:** A bug a role agent observes outside its card's scope, reported under `Bugs found:` with a repro command and the expected and observed results, becomes a Backlog card labelled `bug` with those details, linked from the PR; a bug matching an open issue's title is not filed twice, and the existing issue is linked instead. *(Completed here. Phase 5 defines and parses the format, and Phase 3 creates the label.)*

### fleet-board.AC4: Gates
- **fleet-board.AC4.7 Success:** After a merge, the next tick verifies `main` (typecheck plus touched tests) and records the commit in the note.
- **fleet-board.AC4.8 Success:** A red `main` opens a P0 Backlog card linked to the merged PR.

### fleet-board.AC5: Clean-room and reporting
- **fleet-board.AC5.4 Failure:** A report missing the `VERIFIED:` line is rejected by the manager, which re-dispatches once with the rule quoted. *(Completed here. The detection came from Phase 5.)*

### fleet-board.AC6: Models, manager report, and headless run
- **fleet-board.AC6.1 Success:** Each role runs on the model named in config; none inherits the session model.
- **fleet-board.AC6.2 Success:** After `escalate_after_rounds` failed rounds, implementor and fixer run on the escalation model (`models.escalation`, default the reviewer's model) and the note records the switch.
- **fleet-board.AC6.3 Success:** The tick report warns when implementor and reviewer share a model.
- **fleet-board.AC6.4 Success:** The tick report ends with a stop signal (`dispatchable: true|false`) and a cost estimate labelled as an estimate.

## Revision 9 requirements (Phase 8, 2026-09-30: per-dispatch report paths; these win over anything above)

**Withdrawn 2026-09-30: the r9 re-author drifted and was reverted; the manager stays at Revision 8.**

**Why (observed live).** A role wrote its report to a temp file it made with `mktemp`, then ran `parse-report.sh` and `board-comment.sh` in later Bash calls. Shell state does not persist between Bash calls, so the path was lost. The role guessed it by listing the system temp directory sorted by time and took the newest file, which belonged to another process running at the same time (a manager note for a card in a different repo), and posted that file on its card.

- **A report file path per dispatch.** For every role dispatch (implementor, reviewer, fixer, including the one re-dispatch after a rejected report), the manager chooses a report file path unique to that dispatch, inside the tick's own temp directory (the one it creates once per tick with `mktemp -d`; see "Temp files"): `<tick dir>/report-<card>-<role>-<attempt>.md`, with `<attempt>` 1 for the first dispatch of that role for that card in this tick and 2 for the re-dispatch. Two dispatches never share a path.
- **Passed in the prompt.** The dispatch prompt contains the line `Report file: <absolute path>` with the path written out literally (for example `Report file: /tmp/tmp.Ab12/report-12-implementor-1.md`). Add it to each role's inputs under "What the manager passes to each role", and to the re-dispatch text in step 3.
- **The manager does not create the file**, and does not read, write or delete it. The role creates it, posts it with `board-comment.sh`, and returns the same text as its final reply.
- **No change to report reading.** The manager reads the role's report from the role's final reply, exactly as before, and writes that text to its own check file for `parse-report.sh`. Its own check file's name differs from every `Report file:` path it hands out (for example `<tick dir>/check-<card>-<role>-<attempt>.md`).
- **Must never** additionally includes: dispatch a role without a `Report file:` line; give two dispatches the same report path; put a report path outside the tick's temp directory.

## Revision 9b requirements (Phase 8, 2026-10-02: temp files written with the Write tool only; these win over anything above)

**Why (observed live).** In a live run on the Revision 8 manager, the manager wrote role reports and other temp files with Bash heredocs (`cat > $T/rev1.md <<'EOF' ...`) although "Temp files" says to write them with the `Write` tool. The PreToolUse gate (`hooks/gate.sh`) lexes the whole Bash command text, heredoc body included, as commands, so a role report or a comment quoting a card's Acceptance that mentions a gated command (`gh pr merge`, `gh issue edit`, `board-move.sh N <state>`) is blocked at the manager's check or post step (code review finding I1; the roles were fixed in Revision C).

This is a minimal in-place edit, not a re-author (the Revision 9 re-author above drifted and was withdrawn).

- **"Temp files" (rule 0.10).** Keep the existing text and add: the file's content never goes inside a Bash command (no heredoc, `echo`, `printf` or `cat`), because the gate reads Bash command text and blocks content that quotes a gated command; write each file with the `Write` tool, then pass only its path to the script. If the `Write` tool refuses a file because it has not been read (an existing file, for example one just made by `mktemp`), read it once and write again.
- **Must never** (optional) additionally includes: put a temp file's content inside a Bash command (heredoc, `echo`, `printf` or `cat`) instead of writing it with the `Write` tool.
- Nothing else changes.
