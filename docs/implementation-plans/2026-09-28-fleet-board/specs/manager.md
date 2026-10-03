# Behavior spec: manager

## Purpose

The manager runs one tick of fleet-board. It reads the board through the tick plan, moves every listed card forward exactly one step, writes the result back to the card and its manager note, and returns a tick report as its final message. The manager keeps no state of its own; the board is the only state. Everything a later tick needs is in each card's manager note. The manager never relies on memory of an earlier tick and never reads a role agent's transcript. It sees only the role agents' final reports. The tick skill dispatches the manager, and the manager dispatches the role agents (implementor, reviewer, fixer), which work in git worktrees.

## Inputs

What the tick skill passes to the manager:

- **The scripts dir:** the absolute path of the fleet-board `scripts/` directory, written `<scripts>` below.
- **The repo root:** an absolute path, the output of `git rev-parse --show-toplevel` in the user's repo.
- **The config JSON:** the parsed `.fleet-board.yml` merged with defaults. It holds `board.repo`, `commands`, `test_paths`, `human_qa_paths`, `merge.policy`, `review`, `models`, `limits` and `worktrees`. `R` below means `board.repo`.
- **The tick start time:** in ISO 8601.

All examples below use the repo root `/work/toy`, the scripts dir `/plugins/fleet-board/scripts` and the repo `acme/toy`.

## Required behavior

Steps 1, 1a, 2, 3, 4 and 5 are the tick procedure, run in that order. Step 0 holds standing rules that apply to every step.

### 0. Standing rules

0.1. **Tools.** The manager has exactly these tools: `Agent`, `Skill`, `Read`, `Write`, `Bash`, `Grep` and `Glob`. It uses `Write` only for the files in its temp directory (0.9): report files, note-patch files, follow-up files and comment files.

0.2. **Skills.** The only skill the manager invokes is `fleet-board:reporting`, which holds the report-checking rules. It never invokes any other skill.

0.3. **Agents.** Every Agent call has `subagent_type` set to `fleet-board:implementor`, `fleet-board:reviewer` or `fleet-board:fixer`. The manager never dispatches a general-purpose agent, any other built-in agent, another manager, or any other agent.

0.4. **Dispatch parameters.** Every Agent call explicitly passes all three of these:
   - `subagent_type`, as in 0.3.
   - `model`, taken from the tick plan card's `models`: `models.implementor` for the implementor, `models.reviewer` for the reviewer, `models.fixer` for the fixer. The model never comes from the session, the agent file's frontmatter or anywhere else.
   - `run_in_background: false`. This parameter is never left out: when it is missing, the runtime may run the agent in the background anyway, and the tick can then end with the dispatch still unreconciled.

0.5. **Waiting for dispatches.** Role agents run in the foreground. The manager waits for every dispatched agent's final report before it reconciles that report or writes the tick report. It never uses a background option of the Agent tool, and never ends the tick while a dispatch is still running.

0.6. **Where scripts run.** Every fleet-board script finds the config through the git toplevel of its working directory. So every script call runs from the repo root, one Bash call per command, with the repo root and scripts dir written out literally. Example: `cd /work/toy && bash /plugins/fleet-board/scripts/board-move.sh 12 in_review`.

0.7. **Literal values in gated commands.** A PreToolUse gate hook checks every Bash call made by the manager or any role agent. It blocks, with exit 2 and one stderr line, any command it cannot read. So in every `board-move.sh`, `gh pr ready` and `gh pr merge` command, the card number, PR number and state are written as literal values, never as a shell variable or a `$(...)` substitution. Examples: `board-move.sh 12 in_review`, `gh pr merge 34 --repo acme/toy --squash`.

0.8. **Gate blocks.** Besides unreadable commands, the gate blocks:
   - any move out of `human_qa`;
   - `gh pr merge` under `merge.policy: human`, on a draft PR, without an explicit PR number, with `--admin`, or when checks are not green;
   - a move to `ready` for a card without `## Acceptance`.

   The manager never retries a blocked command in another form. It records the block as the action's result, adds a warning (the gate's stderr line) to the tick report, and counts the action as one that made no progress (2.C).

0.9. **gh calls.** Every `gh` call names the repo explicitly with `--repo <board.repo>`.

0.10. **Temp files.** At the start of the tick the manager creates one temp directory with `mktemp -d`, outside the repo and outside every worktree. It writes all its report, note-patch, follow-up and comment files there with the `Write` tool.
   - A temp file's content never goes inside a Bash command: no heredoc, `echo`, `printf` or `cat`. The gate reads Bash command text and blocks content that quotes a gated command.
   - The manager writes each file with the `Write` tool, then passes only its path to the script.
   - If the `Write` tool refuses a file because it has not been read (an existing file, for example one just made by `mktemp`), the manager reads it once and writes it again.

0.11. **Note reads and writes.**
   - `note.*` means the card's note as printed by `note.sh get N`, read after the plan. The plan does not carry `last_review`, `implementor_attempts` or the other note fields.
   - Every note change is `note.sh merge <n> <patch-file>`. The patch file holds a JSON object with only the keys being changed.
   - The manager never runs `note.sh put`.
   - The manager never runs `note.sh reset-failures`. A person runs it after moving a skipped card by hand. The manager resets the counter itself, inside its own merges.

0.12. **The report text.** A role's report is its final reply as the Agent tool returns it. If the tool result appends metadata the agent did not write (an agent id, a usage or token-count block), that metadata is not part of the report and is left out of the report file. The report itself is never edited.

0.13. **Token counts.** For every dispatch, including re-dispatches, the manager keeps the total token count the Agent tool result reports, together with the model it passed. These counts feed the cost line (5.4).

0.14. **Stateless.** Every decision comes from the tick plan, from `note.sh get N`, from `board-read.sh N`, or from outputs of scripts and dispatches in this tick. Nothing comes from an earlier tick's conversation or from a role's transcript.

0.15. **What each role is given.**
   - **implementor** (`subagent_type: fleet-board:implementor`, `model` = the plan card's `models.implementor`):
     - the card number, title and body, from `board-read.sh N`;
     - the absolute worktree path and the branch (the plan card's);
     - the config JSON;
     - the manager note (`note.sh get N`) for a continuation;
     - the absolute scripts dir.
   - **reviewer** (`fleet-board:reviewer`, `model` = the plan card's `models.reviewer`):
     - the card number and body;
     - the PR number;
     - the PR diff, from `gh pr diff <pr> --repo R`. When the diff is longer than 1500 lines, the manager writes it to a file in the temp directory and passes that file's absolute path instead, saying so.
     - Only the latest implementor or fixer report text. In the tick where the fixer just ran, this is the report the fixer returned. Otherwise it is the newest comment on the card whose body has a `## Status` line and a line starting `VERIFIED:`, and has no `## Acceptance map` line.
     - the review worktree path (`path` from `worktree.sh review`);
     - the config JSON;
     - the round number;
     - the reference SHA `prev_sha`: in round 1 this is the `base` from `worktree.sh review`, in later rounds `note.last_review.sha`;
     - the absolute scripts dir.
   - **fixer** (`fleet-board:fixer`, `model` = the plan card's `models.fixer`):
     - the card number, title and body;
     - the PR number;
     - the worktree path (the plan card's `worktree`, on the PR branch);
     - the findings list: `note.last_review.findings` filtered to Critical and Important, each written as the line `- [<severity>] <text>`;
     - the config JSON;
     - the absolute scripts dir.

### 1. Plan

1.1. The manager runs `cd <repo root> && bash <scripts>/board-cache-clear.sh`, then `cd <repo root> && bash <scripts>/tick-plan.sh`. If `board-cache-clear.sh` fails, its stderr line becomes a tick report warning and the tick continues.

1.2. When `tick-plan.sh` exits 0, every string in the plan's `warnings` array appears verbatim under the tick report's `Warnings:`.

1.3. When `tick-plan.sh` exits non-zero, the tick does nothing else: no board write, no note write, no dispatch. The tick report says the plan failed and quotes its stderr, and its last line is `dispatchable: false`.

1.4. The plan is JSON of the form `{"dispatchable", "warnings", "cards": [{"number", "title", "state", "action", "reason", "branch", "worktree", "pr", "round", "models", "escalated", "needs_human_qa", "comment_needed"}]}`. Each card gets exactly the action the plan gives it. The manager never picks another action.

### 1a. Pending follow-ups (every tick)

1a.1. For each plan card whose action is `file_pending`, the manager writes the note's `pending_followups` object, as stored, to a file in the temp directory: `{"out_of_scope":[...],"bugs":[...],"pr":<n>}`. The item shapes are the same as in `parse-report.sh` output. It then runs `file-followups.sh <card> <pr> <file>`, where `<pr>` is the first non-null of `pending_followups.pr`, `note.pr` and the plan card's `pr` (a PR the plan found by branch). This is the card's whole action for the tick, and the card does not advance. So a card can never leave the plan with unfiled items.

1a.2. `tick-plan.sh` gives `file_pending` only when one of those three PR sources is set. A card with pending items and no PR gets its normal action instead, and the plan's warnings carry `pending follow-ups on #<n> wait for a PR`. If all three are null anyway, the manager runs nothing for the card this tick. The items stay pending, and the tick report carries the warning `pending follow-ups on #<n> wait for a PR`.

1a.3. The result is handled exactly like a first-time filing (3.6):
   - **Exit 0:** one `note.sh merge` appends `out_of_scope_created` and `bugs_filed` from the output, and sets `pending_followups: null`.
   - **Exit 1 with JSON on stdout:** the printed entries are merged, and the rest stay in `pending_followups` (the stored set minus what was filed). A warning is added.
   - **Exit 1 with empty stdout:** nothing is merged except the failure count (2.C), `pending_followups` is unchanged, and a warning is added.

1a.4. A retry never files an item twice. Items already filed are skipped by `file-followups.sh`'s note-history and open-issue checks. Nothing reported is ever dropped: every item is filed or stays in `pending_followups`.

1a.5. When any `file_pending` filing exits 0 in this tick, the tick report's last line is `dispatchable: true` (5.5).

### 2. Card actions

2.1. **Concurrency.** Up to `limits.concurrency` role dispatches run at once. The manager issues those Agent calls in a single message and waits for all of them (0.5). When more role dispatches are due than `limits.concurrency` allows, the rest wait for the next batch in the same tick. A re-dispatch (3.3) and the reviewer dispatch that follows a fix count against the same limit. The manager never has more than `limits.concurrency` role agents running.

2.2. **Action table.** For plan card number `N` (the plan card's `number`), the manager does this:

| Action | What the manager does |
|---|---|
| `start` | `worktree.sh create N <plan branch> <plan worktree>` → `board-move.sh N in_progress` → `note.sh merge` with `branch`, `worktree`, `round: 0`, `models` (the plan card's) and `implementor_attempts: 1` → dispatch the implementor |
| `continue_implementor` | `note.sh merge` with `implementor_attempts` = `note.implementor_attempts` (0 when null) + 1, plus `branch` and `worktree` (the plan card's) → `worktree.sh create N <plan branch> <plan worktree>` → dispatch the implementor with the note |
| `start_review` | `board-move.sh N in_review` → `note.sh merge` with `round: 1` and `pr` = the plan card's `pr` → `worktree.sh review N <pr>` → dispatch the reviewer with `round: 1` and `prev_sha` = the `base` from `worktree.sh review` |
| `review` | `worktree.sh review N <pr>` → dispatch the reviewer with `round` = `note.round` and `prev_sha` = `note.last_review.sha`, or `base` when there is no previous review |
| `fix` | `note.sh merge` with `branch` and `worktree` (the plan card's) → `worktree.sh create N <plan branch> <plan worktree>` → dispatch the fixer, on `models.fixer`, with `note.last_review.findings` filtered to Critical and Important → only when the fixer's report is accepted with Status `done`: `note.sh merge` with `round` + 1 (plus `escalated` and `escalated_at_round` when the plan says escalated) → `worktree.sh review N <pr>` → dispatch the reviewer in the same tick, with `prev_sha` = `note.last_review.sha` (the SHA the previous round reviewed; the reviewer's tamper check diffs from it) |
| `block` | `board-move.sh N blocked` → `note.sh merge` with `blocked_findings` = the surviving findings, or the plan's `reason` when there are none → post a comment listing them. An action-failure block uses its own order (2.D). |
| `to_human_qa` | run `commands.qa_build` in the worktree when it is set, keeping the last 20 lines → `board-move.sh N human_qa` **first** → only after the move succeeds, post a comment headed `What to check in Human QA` that quotes the card's `## Acceptance` section verbatim as a blockquote and includes the qa_build summary. If the card already has a comment with that heading, post nothing. |
| `mark_ready` | `gh pr ready <pr> --repo R`. Never merge. |
| `merge` | Two **separate** Bash calls: `gh pr ready <pr> --repo R`, then `gh pr merge <pr> --repo R --squash` → `note.sh merge` with `merged_pr` |
| `verify_main` | `verify-main.sh N <pr>` → `note.sh merge` with `main_check`. If `p0_card` is present, report it. |
| `finish` | `board-move.sh N done` → `note.sh merge` with `state: done`, `action_failures: 0` and `last_action_error: null` (best-effort) |
| `unblock` | `board-move.sh N ready` → `note.sh merge` with `blocking_pr: null`, `blocked_findings: null`, `action_failures: 0` and `last_action_error: null`, so stale data does not carry into the next cycle |
| `skip_no_acceptance` | When `comment_needed` is true, post with `board-comment.sh` a comment that starts with `<!-- fleet-board:skip-no-acceptance -->` and explains that the card needs a `## Acceptance` section before it can start. Otherwise do nothing. |
| `skip`, `wait` | nothing |

Every script in the table runs as `cd <repo root> && bash <scripts>/<script> ...` (0.6). Every comment is written to a temp file and posted with `board-comment.sh N <file>`.

2.3. **Where values come from.**
   - `N` is the plan card's `number`.
   - For every action, the branch and worktree are the plan card's `branch` and `worktree`, never the note's alone. The plan always has both: the note's values when the note has them, otherwise the defaults `fleet/<n>-<slug>` and `<base>/<n>-<slug>`. A card can reach `in_progress` with no branch in its note in three ways: a person dragged it to In Progress; the note write after `start`'s board move failed; or the note named a worktree outside the current base, which `note.sh` reads as null.
   - For `start`, the note's `models` are the plan card's `models`.
   - `<pr>` for `start_review`, `review`, `fix`, `mark_ready`, `merge` and `verify_main` is the plan card's `pr`, or `note.pr` when the plan's is null.

2.4. **`start`.** The dispatched implementor gets the inputs in 0.15. When its report is accepted, reconciliation runs as in step 3. Progress means the card is in `in_progress` and an implementor report was accepted, on the first or second attempt.

2.5. **`continue_implementor` and `fix` write the branch and worktree into the note, then run `worktree.sh create N <plan branch> <plan worktree>`.** `worktree.sh create` is idempotent. It prints the existing path, or re-creates a missing worktree (for example after a crash). The implementor and fixer work in that worktree on the card's branch.
   - **`continue_implementor` counts the attempt first.** A single `note.sh merge` sets `implementor_attempts` (`note.implementor_attempts`, 0 when null, + 1), `branch` and `worktree`. This happens before `worktree.sh create` runs. If `worktree.sh create` then fails, the action made no progress (2.C): the implementor is not dispatched, the failure is added to `action_failures`, and the attempt still counts in `implementor_attempts`. The two counts are kept side by side, and whichever reaches `review.max_rounds` first makes the plan block the card.
   - **`fix`.** The `note.sh merge` with `branch` and `worktree` comes first. A failed `worktree.sh create` ends the action without progress, like any failed step: no fixer dispatch, no round change, no reviewer dispatch, and the failure is counted. `fix` never blocks the card itself; `tick-plan.sh` blocks it once the count reaches `review.max_rounds`.
   - **A failed or refused `note.sh merge`** (for example `refusing to merge into the invalid manager note`) means the action is not taken. That card gets no worktree command and no dispatch this tick, and the tick report carries the stderr line as a warning. The action made no progress and is counted like any other (2.C). If the counting merge is refused too, only the warning remains. `tick-plan.sh` already skips any card whose note is invalid, with a warning.

2.6. **`worktree.sh review` output.** It prints `{"path":..,"copy":..|null,"sha":..,"base":..}`:
   - `path` is the review worktree the reviewer is given.
   - `sha` is the PR head being reviewed. It becomes `last_review.sha` when the report is accepted.
   - `base` is the merge-base with `origin/main`, the comparison point for round 1.

   If `worktree.sh review` exits non-zero, the reviewer is not dispatched and the action made no progress (2.C).

2.7. **`start_review`.** The board move and the note merge (`round: 1`, `pr` = the plan's `pr`) run before `worktree.sh review`. Steps that already ran stand even if a later step fails. Progress means the card is in `in_review` and an accepted reviewer report was recorded as `last_review`.

2.8. **`review`.** Progress means an accepted reviewer report was recorded as `last_review`.

2.9. **`fix`, step by step.**
   1. `note.sh merge` with the plan card's `branch` and `worktree`.
   2. `worktree.sh create N <plan branch> <plan worktree>`.
   3. Dispatch the fixer on `models.fixer`, with the findings list in 0.15.
   4. Reconcile its report (step 3).
   5. Only when the fixer's report is accepted and its Status is `done`: `note.sh merge` with `round` = `note.round` + 1, `models` = the plan card's `models`, and, when the plan card's `escalated` is true, `escalated: true` and `escalated_at_round` = the new round.
   6. `worktree.sh review N <pr>`.
   7. Dispatch the reviewer with `round` = the new round, `prev_sha` = `note.last_review.sha`, and the fixer's report as the latest report.

   If the fixer's report is rejected twice, or its Status is `blocked`, the round stays the same and no reviewer is dispatched this tick. Progress means the fixer's report was accepted and `round` + 1 was merged. A failure in the reviewer step that follows in the same tick is a warning, and the next tick's `review` action counts it.

2.10. **Surviving findings** for a `block` that is not an action-failure block:
   - They are `note.last_review.findings` filtered to Critical and Important.
   - `blocked_findings` is always a list of `{severity, text}`.
   - When there are no surviving findings (for example an in_progress card the plan blocked after the implementor attempt limit), `blocked_findings` is `[{"severity":"Important","text":"<the plan's reason>"}]`.
   - The comment lists each entry and is posted with `board-comment.sh`. Progress means the card is in `blocked`.

2.11. **`to_human_qa`.**
   - The worktree is the plan card's `worktree`. `commands.qa_build`, when set, runs in that worktree. The summary is its exit code and the last 20 lines of its output, in a fenced block. When `commands.qa_build` is unset, the comment says that no QA build is configured.
   - The Acceptance section is read from the card body (`.body` from `board-read.sh N`). It runs from the `## Acceptance` heading line up to the line before the next `## ` heading, or to the end of the body. Each line is prefixed with `> `.
   - `board-move.sh N human_qa` runs first. The comment is posted with `board-comment.sh` only after the move succeeds, so a failed move never leaves behind a comment that the next tick would post again.
   - Before posting, the manager checks the card's `comments` (from `board-read.sh N`). If any comment already has a heading line reading `What to check in Human QA`, it posts nothing.
   - If the comment fails after the move, the card is still in `human_qa`, which counts as progress, and the tick report carries the stderr line as a warning. Progress means the card is in `human_qa`.

2.12. **`mark_ready`.** Runs `gh pr ready <pr> --repo R` and never merges. Progress means `gh pr ready` exited 0.

2.13. **`merge`.**
   - Runs only when the plan says `merge`. The manager never decides to merge on its own.
   - `gh pr ready <pr> --repo R` and `gh pr merge <pr> --repo R --squash` are two separate Bash calls, in that order. The gate checks each command before it runs, so a combined command would be checked while the PR is still a draft, and blocked.
   - The command has no `--delete-branch`, because the branch is still checked out in a worktree. Branch cleanup is left to the repo's "automatically delete head branches" setting. There is never an `--admin`.
   - If `gh pr ready` or `gh pr merge` fails or is blocked, `merged_pr` is not set and the tick report carries the stderr line as a warning.
   - Progress means `gh pr merge` exited 0 and `merged_pr` was recorded.

2.14. **`verify_main`.**
   - `<pr>` is the plan card's `pr`, the merged PR.
   - On exit 0, the manager merges `main_check` = `{commit, ok, results}` from the output. `p0_card` is not included in `main_check`.
   - When `ok` is false, the card's result in the tick report names the red commit and the `p0_card` number.
   - On a non-zero exit nothing is merged. `main_check` stays null, so the next tick retries, and the tick report carries a warning.
   - Progress means `main_check` was recorded.

2.15. **`finish`.** Only two steps: `board-move.sh N done`, then the note write setting `state: done`, `action_failures: 0` and `last_action_error: null`.
   - The note write is best-effort. If it fails or is denied, the card's result in the tick report says so and `Warnings:` gives the reason. The tick does not fail, and the write is not retried in another form.
   - The manager removes no worktree and never runs `worktree.sh remove`. `cleanup-done.sh` removes the worktrees of done cards outside any Claude session: the headless wrapper runs it after each successful tick, and interactive users run it by hand. An unattended session may deny worktree removal as irreversible local destruction.
   - Progress means the card is in `done`.

2.16. **`unblock`.** Progress means the card is in `ready`. The note merge clears `blocking_pr` and `blocked_findings` and resets both failure keys.

2.17. **`skip_no_acceptance`.** At most one explanatory comment per card, ever: the plan sets `comment_needed` to false once a comment with the marker exists. Progress means the comment was posted, or none was needed.

2.18. **Unlisted actions.** Any action value not in the table is treated as `skip`, and the tick report carries a warning naming the card and the value.

#### 2.C. Action failures

2.C.1. Every action that fails to make progress is counted, whatever the reason. The count is stored in the note as `action_failures`, with `last_action_error`. With `max` = `review.max_rounds`, `tick-plan.sh` turns the count into these rules:
   - a ready, in_progress or in_review card gets `block` once `action_failures >= max`;
   - if the blocks themselves keep failing, the card gets `skip` once `action_failures >= 2 * max`;
   - a blocked card whose `unblock` is due (its `blocking_pr` merged) gets `skip` instead of `unblock` once `action_failures >= max`;
   - any other blocked card gets a plain `skip` with reason `blocked` and no warning, whatever its count.

   So a card gets at most `2 * max` actions in a row without progress (`max` when it is blocked) before the plan stops giving it actions and warns a person. `file_pending` comes before these rules and is not limited by them. The limit covers exactly what the manager records, so the manager records the outcome of every counted action.

2.C.2. **Skips for this reason are not actions.** A plan card with action `skip` and a reason starting with `could not be blocked after ` or `unblock made no progress after ` gets nothing from the manager this tick: no board write, no note write, no counter write, no comment. The plan's warnings already carry one of these lines, with `<scripts>` the absolute scripts dir, single-quoted when it holds a space or another shell character:
   - `#N: could not be blocked after <k> attempts: <last_action_error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures N`
   - `#N: unblock made no progress after <k> attempts: <last_action_error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures N`

   The tick report's `Warnings:` lists them verbatim, like every plan warning, so the person gets the exact command. The manager never runs that command itself. A hand move does not reset the count, and only the person who moved the card decides that it should be retried.

2.C.3. **Progress, per action.** An action made progress when its intended board or note change happened:
   - `start`: the card is in `in_progress` and an implementor report was accepted (`parse-report.sh` exit 0, first or second attempt).
   - `continue_implementor`: an implementor report was accepted.
   - `start_review`: the card is in `in_review` and an accepted reviewer report was recorded as `last_review`.
   - `review`: an accepted reviewer report was recorded as `last_review`.
   - `fix`: the fixer's report was accepted and `round` + 1 was merged.
   - `block`: the card is in `blocked`.
   - `to_human_qa`: the card is in `human_qa`.
   - `mark_ready`: `gh pr ready` exited 0.
   - `merge`: `gh pr merge` exited 0 and `merged_pr` was recorded.
   - `verify_main`: `main_check` was recorded.
   - `unblock`: the card is in `ready`.
   - `finish`: the card is in `done`.
   - `file_pending`: `file-followups.sh` exited 0 and `pending_followups` was set to null.
   - `skip_no_acceptance`: the comment was posted, or none was needed.
   - Any action: an accepted report with Status `blocked` that moved the card to `blocked` is progress.
   - `skip`, `wait` and unlisted actions change nothing and are not counted. The manager writes no counter for them.

2.C.4. **The rule.** At the end of each card's action, after its report reconciliation:
   1. **No progress.** If the action made no progress, for any reason, the manager runs `note.sh merge` with `{"action_failures": <note.action_failures, 0 when null, + 1>, "last_action_error": "<one line saying what failed>"}`. Reasons include a failed setup step such as `worktree.sh create` or `worktree.sh review` (including a `worktrees.setup` failure they report), a report rejected twice, a failed `gh`, board or script call, a command the gate blocked, a refused `note.sh merge`, and a refused or failed merge.
      - The line is the failed command's first stderr line. For a report rejected twice, it is `<role> report rejected twice: <the first parse-report stderr line of the second rejection>`.
      - The card's result in the tick report says the action made no progress.
      - `Warnings:` carries `#N: <action> made no progress (<new count> of <review.max_rounds>): <the line>`.
   2. **Progress.** If the action made progress, the manager merges `{"action_failures": 0, "last_action_error": null}`. This is folded into the action's last `note.sh merge` (the note-upkeep `state` merge of step 4) rather than written separately.
   3. **Folding.** The counting merge may be folded into the same `note.sh merge` as the note-upkeep `state`, and, for a report rejected twice, the `report_errors` entry. If that merge fails or is refused, the tick report carries its stderr line as a warning, and nothing else is done for the card.
   4. **A failed step ends the action.** After a failed step there is no dispatch and no later step of that action for the rest of the tick. Steps that already ran stand, for example `continue_implementor`'s attempt count or `start_review`'s board move.
   5. **The plan decides blocks.** The manager never blocks or skips a card on its own for failures it counted. `tick-plan.sh` does that: `block` with reason `no progress after <n> attempts: <last_action_error>` (or `no error recorded`), and the two skip reasons in 2.C.2.

#### 2.D. `block` for action failures

When the plan's reason starts with `no progress after `, the manager runs these steps in this order:

2.D.1. First, before the move, `note.sh merge` with `{"blocking_pr": null}`. This ensures no stale blocking PR can unblock the card by itself, even if a later step fails. If this merge fails, the action made no progress and is counted as in 2.C.4. The card is not moved this tick.

2.D.2. Then `board-move.sh N blocked`. If the move fails, the action made no progress and is counted as in 2.C.4 (`action_failures` + 1 and `last_action_error`). The counter is never reset before the move succeeds.

2.D.3. Only after the move succeeds, `note.sh merge` with:
   - `blocked_findings` = `[{"severity":"Important","text":"<the plan's reason>"}]`, never the review findings;
   - `action_failures: 0` and `last_action_error: null`;
   - the note-upkeep `state: blocked`.

   This lets a card a person moves back by hand start with fresh attempts instead of being blocked again on the next tick. If this merge fails, the tick report carries its stderr line as a warning.

2.D.4. A comment posted with `board-comment.sh`:
   - says how many times the card's action made no progress;
   - quotes the error;
   - says a person must fix the cause and then move the card back. Examples of causes to fix: remove the other worktree, switch the main checkout to another branch, restore `worktrees.dir`, fix `worktrees.setup`, or fix what makes the role's report fail.

   Only a person moves the card back.

2.D.5. `unblock` and `finish` also reset both keys (2.2).

### 3. Report reconciliation (for every role result)

3.1. The manager writes the agent's final report text, exactly as returned and without appended tool metadata (0.12), to a file in the temp directory.

3.2. It runs `cd <repo root> && bash <scripts>/parse-report.sh --role <role> <file>`, where `<role>` is the role it dispatched.

3.3. **Exit 1 (rejected).** The manager re-dispatches the same role once, with the same `subagent_type`, the same model, `run_in_background: false` and the same inputs, plus this text:

   ```
   Your previous report was rejected by the manager: <parse-report stderr>. The rule: every report contains ## Status, ## Findings, ## For the card, and exactly one line of the form VERIFIED: `<command>` -> <integer> <what it counts>.
   ```

   `<parse-report stderr>` is every `parse-report: `-prefixed stderr line, quoted exactly. Each line is followed by the report-shape rule it enforces, quoted from the rule table in `reporting.md`. The manager may invoke `fleet-board:reporting` to look up those rules.

3.4. **Second rejection.** If the re-dispatched report is also rejected:
   - `note.sh merge` appends a `report_errors` entry `{"role", "round", "at": <ISO time>, "errors": [<the second rejection's stderr lines>]}`;
   - the card stays where it is;
   - there is never a third dispatch for the same report;
   - the action made no progress and is counted (2.C.4), in the same merge or the next.

   Nothing acts on a rejected report: no card move, no PR change, no follow-up filing, no `last_verified`.

3.5. **Exit 2 (usage error).** The error is in the manager's own call. The manager fixes the call (flag, role name, file path) and runs the checker again. It never re-dispatches for exit 2, and exit 2 does not count as a rejection.

3.6. **Exit 0 (accepted).** Every value used afterwards comes from the checker's JSON on stdout, never from re-reading the markdown. The fields used are `status`, `findings` (`[{severity,text}]`), `counts` (`{critical,important,minor}`), `out_of_scope` (`[{title,detail}]`), `bugs` (`[{title,repro,expected,observed}]`), `blocked_by` (an integer or null), `pr` (an integer or null) and `verified.line`. Then, in this order:
   1. **`last_verified`** = `verified.line`.
   2. **Reviewer:** `last_review` = `{"round": <the round the reviewer was given>, "sha": <the sha worktree.sh review returned for this review>, "critical": counts.critical, "important": counts.important, "findings": findings}`.
   3. **Implementor:** `pr` = the parsed `pr`, merged only when it is non-null.
   4. **Status `blocked` with a non-null `blocked_by`** (any role): `note.sh merge` with `blocking_pr` = `blocked_by`, then `board-move.sh N blocked`. The `unblock` action fires later, when that PR merges.
   5. **Status `blocked` with `blocked_by` null** (for example a fixer that could resolve a finding only by changing a test, marked `not fixed: needs human decision`):
      - `note.sh merge` with `blocked_findings` = the report's Critical and Important findings, or, when there are none, one entry holding the report's `for_the_card` text;
      - `board-move.sh N blocked`;
      - a comment listing them.

      No `blocking_pr` is set, so only a person moves the card back.
   6. **Follow-ups.** When this report's `out_of_scope` or `bugs` is non-empty, or `note.pending_followups` holds items, the manager writes the follow-up file `{"out_of_scope":[...],"bugs":[...]}`. It holds this report's two lists plus the pending ones, deduplicated by (kind, title) with titles compared case-insensitively. It then runs `file-followups.sh N <pr> <file>`, one call covering both. `<pr>` is `note.pr`, or the implementor's newly reported `pr`.
      - **No PR known yet** (for example a blocked implementor that opened no PR), with items to file: `file-followups.sh` is not run. The items are stored in `pending_followups` with `pr: null`, and a warning is added. The first reconciliation after `note.pr` is set files them.
      - **Nothing to file** (both lists empty and nothing pending): `file-followups.sh` is not run.
      - **Exit 0** (stdout `{"out_of_scope_created":[...],"bugs_filed":[...]}`, each entry `{title, number, existing}`; `existing: true` means an open issue already had that title and was linked instead of a new card being created): `note.sh merge` appends both lists and sets `pending_followups: null`.
      - **Exit 1 with JSON on stdout** (filed partway) or **exit 1 with empty stdout** (nothing filed):
        - the manager merges whatever entries were printed as filed;
        - it stores as `pending_followups` every item not yet filed: the union of the previous pending items and this report's items, deduplicated by (kind, title) with titles compared case-insensitively, minus those just filed, with `pr` set;
        - it adds a warning.

        Pending items are never replaced by a later report's items; they are only added to.

3.7. **`pending_followups` shape** is `{"out_of_scope":[...],"bugs":[...],"pr":<n or null>}`, with the same item shapes as the parsed report.

3.8. **Rejection count.** Every rejected role report in this tick, first or second attempt, adds 1 to the tick report's `Reports rejected:` count.

### 4. Note upkeep

4.1. After every card's action, `note.sh merge` sets `state` to the card's resulting canonical state. A fresh tick can resume every card from its note alone: branch, worktree, PR, round, models, last review, attempt and failure counts, and pending follow-ups.

4.2. For every counted action (everything except `skip`, `wait` and unlisted actions), this merge also records the action's outcome: `action_failures` + 1 and `last_action_error` when it made no progress, or `action_failures: 0` and `last_action_error: null` when it did (2.C). An outcome already written by an earlier merge in the same tick is not counted twice.

4.3. Every dispatch records in the note the `models` it used (the plan card's `models`), so the note always names the models actually used. When the plan card's `escalated` is true, the note records `escalated: true` and `escalated_at_round`, which records the switch of implementor and fixer to the reviewer's model.

4.4. Cards with a `skip` whose reason starts with `could not be blocked after ` or `unblock made no progress after `, and cards with `skip` or `wait`, get no note write (2.C.2).

### 5. Tick report

5.1. The final message is the tick report, in the shape given under **Tick report** below.

5.2. The table has one row per plan card. The row gives the card, the action taken and the result, including "made no progress" results, a red `main` with its commit and `p0_card`, and a best-effort note write that failed.

5.3. `Warnings:` lists each of these, one per line; when there are none, the line is `Warnings: none`:
   - every plan warning verbatim, including the shared-model warning `implementor and reviewer share model <m>; the reviewer shares the writer's blind spots` and the reset-command skip warnings;
   - every follow-up filing failure;
   - every script failure or gate block;
   - every no-progress line from 2.C.4;
   - every dispatch whose token count was missing.

5.4. The cost is the sum of `estimate-cost.sh --model <model passed> --tokens <total tokens>` over every dispatch, re-dispatches included, formatted with 4 decimals.
   - `as_of` is the `as_of` field of `<scripts>/prices.json`.
   - A dispatch with no reported token count adds 0 and a warning.
   - With no dispatches the cost is `0.0000`.

5.5. The last line is exactly `dispatchable: true` or `dispatchable: false`. The value is the plan's `dispatchable`, except that it is `true` when any `file_pending` filing exited 0 this tick. Nothing follows this line.

## Must never

- Move a card out of `human_qa`.
- Merge under `merge.policy: human`.
- Merge a draft PR.
- Merge when the plan did not say `merge`.
- Move a card to `ready`, except in `unblock`.
- Edit code.
- Run tests or a test suite itself. `verify-main.sh` runs the post-merge checks. Never `npm test`, jest or a bare `node --test`.
- Read role transcripts. The manager sees only the reports.
- Rely on memory of an earlier tick instead of the plan, the note and the board.
- Dispatch any agent without an explicit `model`, or with a model taken from anywhere other than the plan card's `models`.
- Leave out `run_in_background: false` on an Agent call, run a role agent in the background, or end the tick while a dispatch is still running.
- Run more than `limits.concurrency` role agents at once.
- Invoke any skill other than `fleet-board:reporting`.
- Dispatch any agent other than `fleet-board:implementor`, `fleet-board:reviewer` and `fleet-board:fixer`. That rules out a general-purpose agent, any other built-in agent and another manager.
- Edit, complete, trim or rewrite a role's report, or accept or act on a report that `parse-report.sh --role <role>` rejected.
- Re-dispatch a role more than once for one rejected report, or re-dispatch because the checker exited 2.
- Paraphrase a rejection instead of quoting the `parse-report: ` lines exactly.
- Drop a reported out-of-scope item or bug. Every item is filed or stays in `pending_followups`, and pending items are never replaced, only added to.
- Run `gh pr ready` and `gh pr merge` in one Bash call, or pass `--delete-branch` or `--admin` to `gh pr merge`.
- Run `worktree.sh remove`, or delete any worktree or directory itself. Worktree cleanup for done cards belongs to `cleanup-done.sh`, run outside Claude.
- Put a shell variable or `$(...)` where a card number, PR number or state belongs in a `board-move.sh`, `gh pr ready` or `gh pr merge` command.
- Retry a command the gate blocked in another form.
- Run a fleet-board script from any directory other than the repo root, or run a `gh` command without `--repo <board.repo>`.
- Run `note.sh put` or `note.sh reset-failures`, or write a note other than through `note.sh merge`.
- Reset `action_failures` before an action-failure block's move to `blocked` has succeeded.
- Block or skip a card on its own for failures it counted, or take any action on a plan card skipped as `could not be blocked after ` or `unblock made no progress after `.
- Post the Human QA comment before the move to `human_qa` succeeds, or post a second comment headed `What to check in Human QA`.
- Write temp files inside the repo or inside any worktree.
- Put a temp file's content inside a Bash command (heredoc, `echo`, `printf` or `cat`) instead of writing it with the Write tool.
- Write to the board except through the fleet-board scripts, `gh pr ready`, `gh pr merge` and the manager-note script.
- Give an example command that could run a whole suite. Example test commands are `commands.test_one` with one concrete file, such as `node --test test/calc.test.js`.

## Tick report

The manager's final message has exactly this shape, and nothing follows the last line:

````
## Tick report

| Card | Action | Result |
|---|---|---|
| #<n> | <action> | <result> |

Warnings:
- <warning>
Reports rejected: <count>
cost_estimate_usd: <x.xxxx> (estimate; subagent tokens x prices.json as_of <date>)
dispatchable: <true|false>
````

- There is one table row per plan card.
- When there are no warnings, the `Warnings:` block is the single line `Warnings: none`.
- `<count>` is the number of role reports rejected this tick, first and second attempts both counted.
- `<x.xxxx>` has 4 decimals. `<date>` is `as_of` from `<scripts>/prices.json`.

Example:

````
## Tick report

| Card | Action | Result |
|---|---|---|
| #12 | start | moved to in_progress; implementor reported draft PR #34 |
| #15 | review | round 2 reviewed: 0 Critical, 1 Important |
| #18 | skip | could not be blocked after 6 attempts |

Warnings:
- implementor and reviewer share model sonnet; the reviewer shares the writer's blind spots
- #18: could not be blocked after 6 attempts: board-move failed; fix the board, move the card by hand, then run: bash /plugins/fleet-board/scripts/note.sh reset-failures 18
Reports rejected: 0
cost_estimate_usd: 0.4210 (estimate; subagent tokens x prices.json as_of 2026-09-01)
dispatchable: true
````

When `tick-plan.sh` exits non-zero, the report has the same shape:
- the table is replaced by the line `Plan failed: <tick-plan.sh stderr>`;
- `Warnings:` carries the stderr;
- `Reports rejected: 0`;
- the cost is `0.0000`;
- the last line is `dispatchable: false`.

## Acceptance criteria this role satisfies

- **fleet-board.AC1.1 Success:** A Ready card with `## Acceptance` gets a worktree, a branch, an implementor dispatch, and moves to In Progress in one tick.
- **fleet-board.AC1.2 Success:** An In Progress card with a draft PR moves to In Review and gets a reviewer dispatch.
- **fleet-board.AC1.3 Success:** A card with zero Critical/Important findings and a `needs-human-qa` label or a diff matching `human_qa_paths` moves to Human QA with a comment quoting its Acceptance section.
- **fleet-board.AC1.4 Success:** A card with zero findings and no human-QA need has its PR marked ready-for-review; with `merge.policy: human` no merge happens.
- **fleet-board.AC1.5 Success:** The manager note after each tick is sufficient for a fresh tick to resume without re-reading transcripts (branch, PR, round, models).
- **fleet-board.AC1.6 Failure:** A Ready card without `## Acceptance` is skipped and receives exactly one explanatory comment across repeated ticks.
- **fleet-board.AC1.7 Failure:** At `review.max_rounds` the card moves to Blocked and the surviving findings are in the note.
- **fleet-board.AC3.9 Success:** Out-of-scope findings become new Backlog cards linked from the PR.
- **fleet-board.AC3.10 Success:** A bug a role agent observes outside its card's scope, reported under `Bugs found:` with a repro command and the expected and observed results, becomes a Backlog card labelled `bug` with those details, linked from the PR; a bug matching an open issue's title is not filed twice, and the existing issue is linked instead.
- **fleet-board.AC4.7 Success:** After a merge, the next tick verifies `main` (typecheck plus touched tests) and records the commit in the note.
- **fleet-board.AC4.8 Success:** A red `main` opens a P0 Backlog card linked to the merged PR.
- **fleet-board.AC5.4 Failure:** A report missing the `VERIFIED:` line is rejected by the manager, which re-dispatches once with the rule quoted.
- **fleet-board.AC6.1 Success:** Each role runs on the model named in config; none inherits the session model.
- **fleet-board.AC6.2 Success:** After `escalate_after_rounds` failed rounds, implementor and fixer run on the reviewer's model and the note records the switch.
- **fleet-board.AC6.3 Success:** The tick report warns when implementor and reviewer share a model.
- **fleet-board.AC6.4 Success:** The tick report ends with a stop signal (`dispatchable: true|false`) and a cost estimate labelled as an estimate.
