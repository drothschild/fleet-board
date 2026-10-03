# Behavior spec: `status` skill

## 1. Purpose

`status` shows the user where every fleet-board card stands. It prints the board one state at a time, flags done cards whose worktrees were left on disk, and ends with the absolute path of the headless wrapper. The README can then point users to `/fleet-board:status` to find the wrapper without writing down an install path. The skill is read-only: it reports on the board and never changes it.

## 2. Trigger

Requirements for the frontmatter `description`:

- It starts with "Use when" and states the trigger condition before the capability.
- It names the plugin as "fleet-board" and refers to "the board" and "the fleet".
- It triggers on plain-English requests as well as the slash command. That includes asking where cards stand, what the fleet is doing, "board status", "show the board", "what's in Human QA", "what's blocked", "what's in review", and asking to list all cards, including backlog, done or won't-do cards.
- It says the skill is read-only and prints the board.
- It says what the skill is **not** for:
  - advancing, processing or working the board (that is `tick`, or `run` to keep going);
  - setup (that is `init`);
  - questions about how fleet-board works (its gate hook, hooks, config keys, design or setup). Those are answered without running a skill.
- It is at most 900 characters.

Proposed description:

> Use when the user wants to know where fleet-board cards stand or what the fleet is doing: "board status", "show the board", "what's in Human QA", "what's blocked", "what's in review", "what is the fleet doing", or a request to list all cards on the board, including backlog, done or won't-do. Prints the board read-only, one section per state with each card's review round, PR and models, flags done cards whose worktrees were left behind, and shows the absolute path of the headless wrapper. Not for advancing, processing or working the board (use tick, or run to keep going), not for setting fleet-board up (use init), and not for questions about how fleet-board works (its gate hook, hooks, config keys or design), which are answered without running a skill.

## 3. Inputs

- **The user's request.** From it the skill decides only one thing: whether the user asked for everything. "Everything" means all cards or all states, including backlog, done or won't-do cards.
- **The skill's base directory.** The Skill tool announces it when the skill loads. All plugin scripts are located at `<base directory>/../../scripts/`, using the real announced directory. The skill never guesses or writes down an install path.
- **The current repository.** This is the user's repository, where every script runs. Its root is `git rev-parse --show-toplevel`. It may or may not contain `.fleet-board.yml`.

Scripts the skill uses (the paths below abbreviate `<base directory>/../../scripts/` as `scripts/`):

- `scripts/status.sh [--all]` prints one section per state: `ready`, `in_progress`, `in_review`, `human_qa`, `blocked`, plus `backlog`, `done` and `wont_do` with `--all`. Each card takes one line: `#<n> <title> · round <r> · PR #<pr> · <implementor>/<reviewer>`. An empty section shows `(none)`. Exit codes:
  - 0: the board was printed.
  - 1: a column or a card's note could not be read. Whatever could be printed is still printed.
  - 2: usage error.
  - 3: no `.fleet-board.yml`.
- `scripts/board-list.sh done` prints a JSON array of done cards, each with a `number`.
- `scripts/config.sh worktrees.dir` prints the worktrees directory, relative to the repository root. `config.sh` exit codes:
  - 0: ok.
  - 2: usage error.
  - 3: no `.fleet-board.yml`.
  - 4: YAML outside the supported subset.
  - 5: invalid values.

## 4. Required behavior

1. **Locate scripts.** The skill resolves the absolute scripts directory by running `cd "<base directory>/../../scripts" && pwd`, with the base directory the Skill tool announced. The command lines below use that directory, or the equivalent `<base directory>/../../scripts/` path.
2. **Decide `--all`.** If the user asked for all cards or all states, including backlog, done or won't-do cards, the skill runs `status.sh` with `--all`. Otherwise it runs `status.sh` without `--all`. A request that names only active states ("what's in Human QA", "what's blocked", "board status") does not get `--all`.
3. **Run the board.** In the user's repository, the skill runs `bash "<base directory>/../../scripts/status.sh"`, adding `--all` only when step 2 calls for it. It runs `status.sh` exactly once.
4. **Exit 0.** The skill prints `status.sh`'s stdout verbatim. It does not reformat, reorder, summarize, drop or add card lines.
5. **Exit 1.** The skill prints what `status.sh` printed to stdout, verbatim, then its stderr. It then prints a line saying the board could not be read completely.
6. **Exit 3.** The skill prints no board. It tells the user that fleet-board is not set up in this repository and to run `/fleet-board:init`. It does not create `.fleet-board.yml` or run `init`. It skips the leftover-worktree check (step 9).
7. **Exit 2 or any other non-zero code.** The skill prints `status.sh`'s stdout and stderr and says the board could not be printed.
8. **Answer from the output.** If the user asked a specific question about where cards stand ("what's in Human QA", "what's blocked", "what is the fleet doing"), the skill answers from the `status.sh` output just printed, for example by naming the cards in the relevant section or saying the section is `(none)`. It never answers from memory, from earlier output in the conversation, or by guessing. The verbatim board output still appears.
9. **Check for leftover worktrees of done cards.** This check runs after the board output and before the `Headless wrapper:` line, whenever `status.sh` did not exit 3. It is read-only:
   1. In the user's repository, run `bash "<base directory>/../../scripts/board-list.sh" done` and collect each card's `number`. If `board-list.sh` exits non-zero or its output is not a JSON array, skip the rest of the check silently.
   2. Run `bash "<base directory>/../../scripts/config.sh" worktrees.dir`. Resolve the value against the repository root from `git rev-parse --show-toplevel`. If `config.sh` exits non-zero, skip the check silently.
   3. If the resolved directory does not exist, print nothing for this check.
   4. List the directory's entries. Done card `<n>` has leftovers when some entry's name starts with `<n>-`. The dash is part of the prefix, so for card `12` an entry `123-foo` does not count and `12-foo` does.
   5. If one or more done cards have leftovers, print one line naming them in ascending order, for example `Done cards with worktrees left: #12, #15`. Next, print the exact removal command, `bash <absolute scripts dir>/cleanup-done.sh`, using the directory resolved in step 1 of this list. Suggest running it from the repository root.
   6. If no done card has leftovers, print nothing for this check.
10. **Headless wrapper line.** In every case (exit 0, 1, 2, 3 or anything else), the skill's last line is `Headless wrapper: <absolute scripts dir>/fleet-board-run.sh`. The directory is resolved with `cd "<base directory>/../../scripts" && pwd`. The skill does not check that `fleet-board-run.sh` exists. Nothing follows this line.

## 5. Must never

- Move a card, write or replace a manager note, post a comment, edit a label, or change any board field.
- Dispatch any agent (manager, implementor, reviewer or fixer), or run a tick or a run.
- Run `cleanup-done.sh`, or remove, prune or modify any worktree, directory or file. It only names the command for the user to run.
- Create, edit or overwrite `.fleet-board.yml`, or run `init` on the user's behalf.
- Answer a question about card state from memory, from earlier output, or by guessing instead of from the `status.sh` output of this invocation.
- Reformat, summarize or trim `status.sh`'s output in place of printing it verbatim.
- Pass `--all` when the user did not ask for all cards or states.
- Guess, hardcode or write down an install path. Every path comes from the announced base directory.
- Omit the `Headless wrapper:` line, or print anything after it.
- Print anything for the leftover check when there are no leftovers, when the worktrees directory is missing, or when `board-list.sh` fails.
- Declare `allowed-tools` or any frontmatter key other than `name`, `description` and `user-invocable: true`.

## 6. Output

The skill prints the following, in order:

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

Example (exit 0, no `--all`, no leftovers). `status.sh` owns its section headers and card lines, so their exact look here is only illustrative; the skill passes them through unchanged:

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

## 7. Acceptance criteria

None directly (operator convenience; the design names a `status` skill).
