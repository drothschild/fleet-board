# Config details

The [README](../README.md#config) has the full key table. This page covers the rest.

`config.sh` reads `.fleet-board.yml`, merges it over `scripts/config-defaults.json`, and validates it. A map is merged key by key; a list replaces the default list whole.

The default `test_paths` are `test/**`, `tests/**`, `__tests__/**`, `**/*.test.*`, `**/*.spec.*`, `**/*_test.*` and `**/test_*`.

When `models.implementor` and `models.reviewer` are the same, every tick warns that the reviewer shares the writer's blind spots.

## `merge.policy`

Under `human`, the gate blocks every `gh pr merge`, and clean PRs wait to be merged by hand. Under `auto`, the manager merges a PR whose review is clean, whose checks are green, and whose card doesn't need Human QA. `auto` is not supported headless: Claude Code's safety classifier blocks unattended merges ("Merge Without Review"). Merges stay human by default. `auto` works only where merges are explicitly allowed in the user's own Claude Code settings.

## `board.states`

Canonical states are `backlog`, `ready`, `in_progress`, `in_review`, `human_qa`, `blocked`, `done` and `wont_do`. On the labels board each defaults to `fleet:<state>`. On a Projects board they default to `Backlog`, `Ready`, `In Progress`, `In Review`, `Human QA`, `Blocked`, `Done` and `Won't Do`. Map only the ones that differ, for example a Projects board that keeps its existing column names:

```yaml
board:
  backend: github-projects
  repo: user/myProject
  project_number: 1
  states: { in_progress: "In progress", in_review: "In review", human_qa: "Human QA", wont_do: "Won't Do" }
```

## Finding the file

`config.sh` uses `$FLEET_BOARD_CONFIG` when set, then `.fleet-board.yml` at the git root, then the one in the main checkout (for a linked worktree). Its exit codes: 3 no config, 4 the file is not valid YAML or `yq` is missing, 5 an invalid value.

## How the board works in detail

**One writer per card.** `gh issue edit` sends label additions and removals as separate mutations, so two writers on one issue can leave it with the wrong labels.

**One step per tick.** Each tick, `tick-plan.sh` reads the Ready, In Progress, In Review and Blocked columns and picks exactly one action per card. The manager carries out those actions, dispatching up to `limits.concurrency` role agents at once, and prints the tick report.

**The manager note.** The manager keeps no state between ticks. Everything it needs to resume a card lives in one comment on that card, starting `<!-- fleet-board:manager-note -->`, with a JSON block holding the branch, worktree, PR, review round, models and failure counts. Leave it alone unless the tick report asks for a `note.sh reset-failures` command.

**Worktree cleanup.** The manager moves a finished card to Done but never removes its worktrees, because Claude Code's safety classifier blocks that deletion in unattended sessions. The headless wrapper runs `cleanup-done.sh` after each successful tick. When ticking interactively, `/fleet-board:status` lists done cards that still have worktree directories and prints the exact command to remove them.

**Follow-ups.** A role that notices work outside its card reports it under `Out of scope:` or `Bugs found:`. The manager files each item as a Backlog card. A bug gets the `bug` label and a body with repro, expected and observed. An item whose title matches an open issue is linked to it with a comment instead of being filed again. Roles never create cards themselves.

**Checking `main`.** After a PR merges, the next tick checks `main`: the typecheck and the PR's test files, in a separate `main-check` worktree. If `main` is red, it files a `[P0] main is red after #<pr>` card in Backlog.
