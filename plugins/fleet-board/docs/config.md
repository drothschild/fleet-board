# Config details

The [README](../README.md#config) has the full key table. This page covers the rest.

`config.sh` reads `.fleet-board.yml`, merges it over `scripts/config-defaults.json`, and validates it. A map is merged key by key; a list replaces the default list whole.

The default `test_paths` are `test/**`, `tests/**`, `__tests__/**`, `**/*.test.*`, `**/*.spec.*`, `**/*_test.*` and `**/test_*`.

When `models.implementor` and `models.reviewer` are the same, every tick warns that the reviewer shares the writer's blind spots.

## `merge.policy`

Under `human`, the gate blocks every `gh pr merge`, and clean PRs wait to be merged by hand. Under `auto`, the manager merges a PR whose review is clean, whose checks are green, and whose card doesn't need Human QA. `auto` is not supported headless: Claude Code's safety classifier blocks unattended merges ("Merge Without Review"). Merges stay human by default. `auto` works only where merges are explicitly allowed in the user's own Claude Code settings.

## `after_merge.allow` and the `## After merge` section

A card body may hold a `## After merge` section (heading in any case, ending at the next heading) with one command per `-` bullet, for example `- git tag v1.2.3` and `- git push origin v1.2.3`. After the card's PR merges, the manager runs `after-merge.sh run <body-file>`, which runs the commands in order and prints the outcome. Release steps no agent can do by hand need no Human QA step this way.

`after_merge.allow` in `.fleet-board.yml` is a list of command prefixes; only a command that starts with one of them (as whole words) runs. A missing key means no command is allowed.

```yaml
after_merge:
  allow: ["git tag", "git push origin"]
```

The manager records each command's exit status in the card's note. A command with no matching prefix is not run; the card moves to Blocked and the comment names the command and the missing `after_merge.allow` entry. A command holding `;`, `&`, `|`, a backtick, `$`, `<`, `>` or a newline is treated the same, so an allowed prefix cannot chain another command. A command that exits non-zero moves the card to Blocked, with the command and its exit status in the comment. Execution stops at the first refusal or failure. When every command succeeds the card moves to Done with no Human QA step.

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

`config.sh` uses `$FLEET_BOARD_CONFIG` when set, then `.fleet-board.yml` at the git root, then the one in the main checkout (for a linked worktree). Its exit codes: 3 no config, 4 the file is not valid YAML or uses YAML outside the supported subset, 5 an invalid value.

## YAML subset

`config.sh` parses the file with a bundled jq script (`scripts/yaml.jq`), so nothing beyond `jq` is needed. It reads block and flow maps and lists, plain, single- and double-quoted strings, `|` and `>` block strings, and `#` comments. It rejects anchors, aliases and tags, tabs used for indentation, duplicate keys, more than one document, and maps inside a block list item, naming the line.

## How the board works in detail

**One writer per card.** `gh issue edit` sends label additions and removals as separate mutations, so two writers on one issue can leave it with the wrong labels.

**One step per tick.** Each tick, `tick-plan.sh` reads the Ready, In Progress, In Review and Blocked columns and picks exactly one action per card. The manager carries out those actions, dispatching up to `limits.concurrency` role agents at once, and prints the tick report.

**The manager note.** The manager keeps no state between ticks. Everything it needs to resume a card lives in one comment on that card, starting `<!-- fleet-board:manager-note -->`, with a JSON block holding the branch, worktree, PR, review round, models and failure counts. Leave it alone unless the tick report asks for a `note.sh reset-failures` command.

**Dependencies.** A card body may hold a `## Depends on` section (heading in any case, ending at the next heading) with one bullet per dependency: `- #22` (an issue in `board.repo`) or `- owner/repo#22`. Blank lines are ignored; any other line in the section is ignored with the tick warning `#<n>: unrecognized dependency line: <line>`. A dependency is met when its issue is closed with state reason completed, or, on the Projects backend, when it is an item on the board's project with Status equal to the Done column, in `board.repo` or any other repo. On the labels backend every dependency is judged by its issue state only. The issue is read with `gh issue view <N> --repo <owner/repo> --json state,stateReason`, and the Status through the Projects adapter. Closed as not planned, or Status Won't Do, counts as unmet and adds the warning `#<n> depends on <ref>, which was closed as not planned`. A dependency closed any other way (as a duplicate, say) is unmet too, without the warning. A failed lookup skips the card for that tick with the reason `lookup failed: <command>`, like every other lookup in `tick-plan.sh`.

Only a Ready card with an `## Acceptance` section is gated, and only at the start: `tick-plan.sh` plans `wait` with the reason `waits for <ref> (<state or column>)[, <ref> (...)]` and lists the refs in the card's `waiting_on`. The card stays in Ready and does not count towards the plan's `dispatchable`. In Progress, In Review and Blocked cards are never gated. On a `wait` the manager posts `Waiting for <refs>` once and records the refs in the note's `deps_commented`; it posts again only when the unmet set differs. Nothing promotes a card from Backlog: when the dependency finishes, the next tick starts the card if a person has already moved it to Ready. `deps.sh parse` and `deps.sh check` are the two halves; `/fleet-board:status` runs them to show the reason.

**Worktree cleanup.** The manager moves a finished card to Done but never removes its worktrees, because Claude Code's safety classifier blocks that deletion in unattended sessions. The headless wrapper runs `cleanup-done.sh` after each successful tick. When ticking interactively, `/fleet-board:status` lists done cards that still have worktree directories and prints the exact command to remove them.

**Follow-ups.** A role that notices work outside its card reports it under `Out of scope:` or `Bugs found:`. The manager files each item as a Backlog card. A bug gets the `bug` label and a body with repro, expected and observed. An item whose title matches an open issue is linked to it with a comment instead of being filed again. Roles never create cards themselves.

**Checking `main`.** After a PR merges, the next tick checks `main`: the typecheck and the PR's test files, in a separate `main-check` worktree. If `main` is red, it files a `[P0] main is red after #<pr>` card in Backlog.
