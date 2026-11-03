---
name: status
description: Use when the user runs /fleet-board:status or asks in plain English where fleet-board cards stand or what the fleet is doing, such as "board status", "show the board", "what's in Human QA", "what's blocked", "what's in review", "what is the fleet doing", or asks to list all cards on the board, including backlog, done or won't-do cards. Prints the board read-only, one section per state with each card's review round, PR and models, flags done cards whose worktrees were left behind, and shows the absolute path of the headless wrapper. Not for advancing, processing or working the board (use tick, or run to keep going), not for setup (use init), and not for questions about how fleet-board works (its gate hook, hooks, config keys, design or setup), which are answered without running a skill.
user-invocable: true
---

# fleet-board status

## Principle

This skill shows the user where every fleet-board card stands, and it only reports. It runs `status.sh` once, passes the board through verbatim, answers any specific question from that output alone, points out done cards whose worktrees were left on disk, and always ends with the absolute path of the headless wrapper. It never changes the board, the worktrees, the config, or any file. When it finds something the user may want to act on, it names the command and leaves running it to the user.

## Locating the scripts

The plugin's scripts are at `<base directory>/../../scripts/`, where `<base directory>` is this skill's base directory as announced by the Skill tool when the skill loaded. Substitute the real announced directory every time. Never guess, hardcode or write down an install path. Every path comes from the announced base directory.

Resolve the absolute scripts directory once with:

```bash
cd "<base directory>/../../scripts" && pwd
```

Call the result `<scripts dir>`. Run every command below from the user's repository (the current repository, root given by `git rev-parse --show-toplevel`), not from the scripts directory.

## Method

1. **Locate scripts.** Resolve `<scripts dir>` with `cd "<base directory>/../../scripts" && pwd` as described above. Command lines below use that directory, or the equivalent `<base directory>/../../scripts/` path.

2. **Decide `--all`.** Pass `--all` only if the user asked for all cards or all states, including backlog, done or won't-do cards. A request that names only active states ("what's in Human QA", "what's blocked", "what's in review", "board status", "show the board") does **not** get `--all`.

3. **Run the board.** In the user's repository, run exactly once:

   ```bash
   bash "<base directory>/../../scripts/status.sh"          # default
   bash "<base directory>/../../scripts/status.sh" --all    # only when step 2 calls for it
   ```

   Capture stdout, stderr and the exit code separately. Do not run `status.sh` a second time.

4. **Exit 0.** Print `status.sh`'s stdout verbatim. Do not reformat, reorder, summarize, drop or add card lines.

5. **Exit 1.** Print `status.sh`'s stdout verbatim, then its stderr, then one line saying the board could not be read completely.

6. **Exit 3.** Print no board. Tell the user that fleet-board is not set up in this repository and to run `/fleet-board:init`. Do not create `.fleet-board.yml` and do not run `init`. Skip the leftover-worktree check (step 9) and go straight to step 10.

7. **Exit 2 or any other non-zero code.** Print `status.sh`'s stdout and stderr, then a line saying the board could not be printed.

8. **Answer from the output.** If the user asked a specific question about where cards stand ("what's in Human QA", "what's blocked", "what's in review", "what is the fleet doing"), answer it from the `status.sh` output just printed, for example by naming the cards in the relevant section or saying that section is `(none)`. Never answer from memory, from earlier output in the conversation, or by guessing. The verbatim board output still appears above the answer.

9. **Check for leftover worktrees of done cards.** Run this after the board output (and any answer) and before the `Headless wrapper:` line, whenever `status.sh` did not exit 3. It is read-only.
   1. In the user's repository, run `bash "<base directory>/../../scripts/board-list.sh" done` and collect each card's `number`. If `board-list.sh` exits non-zero or its output is not a JSON array, skip the rest of the check silently.
   2. Run `bash "<base directory>/../../scripts/config.sh" worktrees.dir`. If `config.sh` exits non-zero (2, 3, 4, 5 or anything else), skip the check silently. Otherwise resolve the printed value against the repository root from `git rev-parse --show-toplevel`.
   3. If the resolved directory does not exist, print nothing for this check.
   4. List the directory's entries. Done card `<n>` has leftovers when some entry's name starts with `<n>-`. The dash is part of the prefix: for card `12`, an entry `12-foo` counts and `123-foo` does not.
   5. If one or more done cards have leftovers, print one line naming them in ascending order, for example `Done cards with worktrees left: #12, #15`. Then print the exact removal command, `bash <scripts dir>/cleanup-done.sh`, using the absolute directory resolved in step 1, and suggest running it from the repository root. Do not run it.
   6. If no done card has leftovers, print nothing for this check.

10. **Headless wrapper line.** In every case (exit 0, 1, 2, 3 or anything else), the last line of output is:

    ```
    Headless wrapper: <scripts dir>/fleet-board-run.sh
    ```

    with `<scripts dir>` the absolute directory from `cd "<base directory>/../../scripts" && pwd`. Do not check whether `fleet-board-run.sh` exists. Nothing follows this line.

## Output

Print the following, in order:

1. **Board block.**
   - On exit 0: `status.sh`'s stdout verbatim.
   - On exit 1: `status.sh`'s stdout verbatim, then its stderr, then one line saying the board could not be read completely.
   - On exit 3: instead of a board, a message that fleet-board is not set up here and that the user should run `/fleet-board:init`.
   - On exit 2 or any other failure: `status.sh`'s stdout and stderr and a line saying the board could not be printed.
2. **Answer (optional).** If the user asked a specific question about card state, a short answer drawn from the board block.
3. **Leftover block (only when leftovers exist).** Two lines, for example:

   ```
   Done cards with worktrees left: #12, #15
   To remove them, run from the repository root: bash /abs/path/to/scripts/cleanup-done.sh
   ```

4. **Final line, always:**

   ```
   Headless wrapper: /abs/path/to/scripts/fleet-board-run.sh
   ```

Example (exit 0, no `--all`, no leftovers). `status.sh` owns its section headers and card lines, so their exact look here is only illustrative; pass them through unchanged:

```
ready
(none)
in_progress
(none)
in_review
#19 Handle negative input · round 2 · PR #30 · sonnet/opus
human_qa
(none)
blocked
(none)
Headless wrapper: /abs/path/to/scripts/fleet-board-run.sh
```

## What not to do

- Do not move a card, write or replace a manager note, post a comment, edit a label, or change any board field.
- Do not dispatch any agent (manager, implementor, reviewer or fixer), and do not run a tick or a run.
- Do not run `cleanup-done.sh`, or remove, prune or modify any worktree, directory or file. Only name the command for the user to run.
- Do not create, edit or overwrite `.fleet-board.yml`, and do not run `init` on the user's behalf.
- Do not answer a question about card state from memory, from earlier output, or by guessing instead of from the `status.sh` output of this invocation.
- Do not reformat, summarize or trim `status.sh`'s output in place of printing it verbatim.
- Do not pass `--all` when the user did not ask for all cards or states.
- Do not guess, hardcode or write down an install path. Every path comes from the announced base directory.
- Do not omit the `Headless wrapper:` line, and do not print anything after it.
- Do not print anything for the leftover check when there are no leftovers, when the worktrees directory is missing, or when `board-list.sh` fails.
