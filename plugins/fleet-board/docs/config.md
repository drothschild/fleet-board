# Config details

The [README](../README.md#config) has the full key table. This page covers the rest.

`config.sh` reads `.fleet-board.yml`, merges it over `scripts/config-defaults.json`, and validates it. A map is merged key by key; a list replaces the default list whole.

The default `test_paths` are `test/**`, `tests/**`, `__tests__/**`, `**/*.test.*`, `**/*.spec.*`, `**/*_test.*` and `**/test_*`.

When `models.implementor` and `models.reviewer` are the same, every tick warns that the reviewer shares the writer's blind spots.

## `commands.preflight`

Unset by default. A command that checks the environment works, for example that a generated client is current or a service answers. `tick-plan.sh` runs it once per tick, from the repo root, before planning. When it exits non-zero, the plan holds every card (no start, review, fix or other action), `dispatchable` is false so the loop stops, and the plan carries one warning, `preflight failed: <command> (exit <n>)`, followed by the last 20 lines of the output. No card's state or `action_failures` changes. When it exits 0 the plan is the same as with the key unset. Settle plans never run it.

## `merge.policy`

Under `human`, the gate blocks every `gh pr merge`, and clean PRs wait to be merged by hand. Under `auto`, the manager merges a PR whose review is clean, whose checks are green, and whose card doesn't need Human QA. Headless runs merge too: `scripts/merge-reviewed.sh` runs after each tick, outside any Claude session, and merges the same PRs (see [overnight.md](overnight.md#merges-under-mergepolicy-auto)). Merges stay human by default (`human`).

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

## `followups.status`

Cards a fleet run files (out-of-scope items, bugs, and the P0 "main is red" card) are created in the `ready` column by default, with a `## Acceptance` section drafted from the finding, so the next tick can pick them up. Set `followups.status: backlog` to have a person triage them first; any other value is rejected by `config.sh` (`followups.status must be ready or backlog`). The Acceptance command is the first backticked span with a non-blank character; spans are paired single backticks, so a detail with an odd number of backticks or a double backtick has none. An out-of-scope item with no such span, or whose detail holds the words `no testable check` (even beside a backticked path, and even when quoted), gives no testable bullet; it is filed in Backlog regardless, with a comment saying why. Roles are told to write the check command before any other backticked text; a backticked file path written first is taken as the command, and invisible characters inside a span are not checked. A follow-up whose detail says "depends on this card" carries `## Depends on` naming the spawning card. Before filing, an open card, or one closed in the last 30 days, with the same title (case-insensitive) suppresses the new card; the printed entry has `"existing": true` and `"matched": "open"` or `"closed"`.

## `review.stages`

Empty by default, so every existing config keeps its behavior. Each entry adds a board column after In Review, with its own reviewer, for checks the evidence reviewer does not make (security, UX, compliance). A stage names either an `agent` (a Claude subagent) or a `provider` (see [`providers`](#providers)); it sets exactly one.

```yaml
review:
  max_rounds: 3
  stages:
    - name: security                  # required; ^[a-z][a-z0-9_]*$; unique
      agent: acme:security-reviewer   # an agent, or provider (below), not both
      model: opus                     # default: models.reviewer
      paths: ["src/auth/**", "**/*.sql"]  # default []: routed by label only
      label: needs-security-review    # default: needs-<name>-review
      advisory: false                 # default false
      max_rounds: 2                   # default: review.max_rounds
      brief: "Focus on authz, secrets, injection."  # optional; passed verbatim
    - name: compliance
      provider: openai                # instead of agent
      model: <model id, passed verbatim>
      price: { input: 1.25, output: 10 }   # USD per million tokens; required
      timeout: 600                    # seconds
      max_output_tokens: 16000
      max_diff_bytes: 400000
```

A stage is the state `review_<name>`, in config order between `in_review` and `human_qa`. On the labels backend its column is the label `fleet:review_<name>`; on Projects it is the Status option `Review: <name>`. `board.states.review_<name>` renames it; a `review_` key naming no stage is rejected.

**Routing.** A stage applies to a card when the card carries the stage's label, or when a file the PR changes matches one of its `paths` globs (the rule `needs-human-qa.sh` uses). `review-stages.sh route <card> <pr>` adds each missing label and never removes one. It runs when the card moves from In Progress to In Review, before the move, so a failure leaves the card in In Progress and the next tick retries. A person can add a label before a stage begins to force a visit; a stage already reviewed is not visited again. When `gh` lists fewer files than the PR changes, every stage is routed, with a warning.

**Re-matching.** Routing adds labels once, but a fixer's commit or a later push can touch a stage's `paths` after it. So at every clean, current review (in In Review or a stage column) `tick-plan.sh` runs `review-stages.sh match <pr>`, which reads the PR's files now and adds no label, and counts each stage those files match as routed. The next stage is the first one in config order that is routed, is not the current column and is not in the note's `reviewed_stages`; it can be a stage before the current column that was never visited. The trade-off: removing a label skips a stage only when its `paths` do not match the PR's current files. A stage whose globs match cannot be skipped that way; a label-only stage (empty `paths`) still can. A failed `match` skips the card for the tick (`lookup failed: review-stages.sh match <pr>`).

**Setup.** After adding or changing stages, run `bash <scripts>/review-stages.sh setup` (`init.sh` prints this command when it finishes; it does not run it). It creates each stage's routing label on both backends and its state label on the labels backend. On Projects it checks the Status field has a column for each stage and exits 1 naming the missing ones; add them by hand, or map the stage onto an existing column with `board.states`.

**Flow.** A card whose evidence review is clean moves to the first routed stage (`advance_stage`) and is reviewed there in the same tick. Critical or Important findings go to the fixer and the same stage re-reviews, up to the stage's `max_rounds`; then the card is Blocked. A clean stage moves the card to the next routed stage, then to Human QA, a ready PR or a merge exactly as before.

**Advisory.** An `advisory: true` stage posts its report and its findings are read as clean: it never fixes and never blocks the card.

**Trade-off.** A finding is fixed and re-reviewed in its own stage only. Earlier stages are not re-run, so a later stage's fix is not seen again by the evidence reviewer or by an earlier stage. The reviewed-heads rule still applies: a PR is merged only at a head some reviewer saw, so a fix that lands after the last review is reviewed again before it merges.

**A provider stage** takes `model`, `price`, `timeout`, `max_output_tokens` and `max_diff_bytes` (below) in place of `agent`, and the manager runs it with `stage-review.sh` instead of dispatching an agent. It sends the card body and the PR diff to that provider, and only those: it has no tools and no worktree, so it runs no tests.

## `providers`

A review stage names either an `agent` (a Claude subagent) or a `provider` (a model reached over an OpenAI-compatible chat API). A stage sets exactly one; `config.sh` exits 5 with `review.stages[<i>] must set exactly one of agent and provider` otherwise.

```yaml
providers:                       # optional; a preset name needs no entry
  corp:
    base_url: <an https address>
    api_key_env: CORP_LLM_KEY
    max_tokens_param: max_tokens # or max_completion_tokens (the default)
review:
  stages:
    - name: security
      provider: openai
      model: <model id, passed verbatim>
      price: { input: 1.25, output: 10 }   # USD per million tokens
```

Built-in presets are `openai`, `gemini`, `openrouter` and `ollama`; their values are in `scripts/providers/presets.json`. A `providers.<name>` entry is merged over the preset key by key, so `providers.openai.api_key_env: WORK_OPENAI` keeps the preset's `base_url`. The merged output holds an entry for every provider a stage names or the file defines. A provider the file defines that no stage uses prints a warning on stderr and changes nothing else.

| Key | Rule |
|---|---|
| provider name | matches `^[a-z][a-z0-9_-]*$` |
| `base_url` | an https address, or an http address whose host is `localhost`, `127.0.0.1` or `[::1]` with an optional numeric port; no userinfo (`user@`) in either (`base_url must not contain userinfo`). `chat.sh` repeats both checks before any request |
| `api_key_env` | the name of an environment variable, matching `^[A-Z_][A-Z0-9_]*$`; `null` only for a loopback `base_url` |
| `max_tokens_param` | `max_tokens` or `max_completion_tokens` |

Config never holds a key. `api_key`, `key`, `token` and `secret` under a provider are rejected, and the message does not repeat the value.

A provider stage also takes `model` (required), `price` with non-negative `input` and `output` (required, so the cost ceiling never counts unpriced spend as zero), and three positive integers: `timeout` (seconds, default `600`), `max_output_tokens` (default `16000`) and `max_diff_bytes` (default `400000`). An agent stage has `provider: null` and `price: null`, and keeps `model` defaulting to `models.reviewer`.

**Data egress.** A provider stage sends the card body and the PR diff to that provider. Use a provider only for repos whose code you may send to it.

## `limits` for the headless wrapper

`fleet-board-run.sh` reads `limits.max_hours`, `max_cost_usd`, `tick_interval`, `max_consecutive_failures` and `max_turns` (see [overnight.md](overnight.md)). Three more keys deal with the GitHub quota. `config.sh` exits 5 when any of them is not a non-negative number.

| Key | Default | Meaning |
|---|---|---|
| `limits.rate_limit_max_wait` | `3600` | total seconds a run may spend waiting for rate limits to reset; a wait that would pass it stops the run (`rate-limit-wait-cap`, exit 1) |
| `limits.rate_limit_margin` | `5` | seconds added after the reset time before the next tick |
| `limits.min_tick_gap` | `0` | minimum seconds between tick starts across runs sharing one token (the whole-second part is used); `0` is off |

## Finding the file

`config.sh` uses `$FLEET_BOARD_CONFIG` when set, then `.fleet-board.yml` at the git root, then the one in the main checkout (for a linked worktree). Its exit codes: 3 no config, 4 the file is not valid YAML or uses YAML outside the supported subset, 5 an invalid value.

## YAML subset

`config.sh` parses the file with a bundled jq script (`scripts/yaml.jq`), so nothing beyond `jq` is needed. It reads block and flow maps and lists, plain, single- and double-quoted strings, `|` and `>` block strings, and `#` comments. It rejects anchors, aliases and tags, tabs used for indentation, duplicate keys, more than one document, and maps inside a block list item, naming the line.

## How the board works in detail

**One writer per card.** `gh issue edit` sends label additions and removals as separate mutations, so two writers on one issue can leave it with the wrong labels.

**One step per tick.** Each tick, `tick-plan.sh` reads the Ready, In Progress, In Review and Blocked columns and picks exactly one action per card. The manager carries out those actions, dispatching up to `limits.concurrency` role agents at once, and prints the tick report.

**Conflicting PRs.** An open PR on an In Progress or In Review card whose `gh pr view --json mergeable` answer is `CONFLICTING` gets the action `update_branch` from `tick-plan.sh` (reason `PR #<pr> has merge conflicts with its base branch`) instead of `start_review`, `review`, `fix` or any other action for that tick. The lookup is best effort: a failed or unreadable answer reads as unknown and plans nothing. `scripts/update-branch.sh <n> <pr> <branch> <worktree>` carries the action out: it fetches `origin`, merges `origin/<base>` into the branch with a merge commit and pushes with a plain `git push`; it never rebases and never force-pushes. A clean merge leaves the card in its column and adds `last_update` (`sha`, `base`, `changed`) to the manager note. It leaves the note's `last_review` as it is: a clean merge of the base needs no new review, and the next tick plans a `review` only when a commit after `last_review` is not a clean merge (see Reviewed heads). A merge that needs a manual resolution is aborted and not pushed; the script comments with the conflicted files and moves the card to Blocked. It never resolves a conflict itself.

**The manager note.** The manager keeps no state between ticks. Everything it needs to resume a card lives in one comment on that card, starting `<!-- fleet-board:manager-note -->`, with a JSON block holding the branch, worktree, PR, review round, models and failure counts. Leave it alone unless the tick report asks for a `note.sh reset-failures` command.

**Reviewed heads.** A PR is merged only at a head a reviewer saw. When an In Review PR's head has moved past the note's `last_review.sha`, `tick-plan.sh` plans `review` instead of `merge` (or `mark_ready`, `to_human_qa`), unless every commit since is a merge of the base branch whose tree equals the tree `git merge-tree --write-tree` produces for the commit's two parents. That is a clean merge of main: it skips re-review. A merge that needed conflict resolution, carries extra changes, or any non-merge commit does not. `scripts/review-drift.sh <reviewed-sha> <head-sha>` makes the call (`reviewed` or `unreviewed`); it needs the commits in the local checkout, tries one `git fetch origin`, and reads any failure as `unreviewed`. Under `merge.policy: auto`, gate G2 refuses `gh pr merge` on a `fleet/<n>-*` PR when the same check fails.

**Accepting a change.** When a card is Blocked for something a person has looked at and accepted (an unreviewed merge of `main`, a test edit a fixer may not touch), run `bash <scripts>/accept.sh <n>` (the scripts directory is the plugin's `scripts/`). In one `note.sh merge` it sets the note's `action_failures` to 0 and `last_action_error` to null, moves the reviewed-sha baseline (`last_review.sha`) to the PR's current head, clears the previous review's findings and what the block left in the note (`blocked_findings`, `blocking_pr`, `blocked_from`), and records `accepted` (`login`, `at`, `sha`) in the note. After that the next tick reviews the PR again from that sha: the commits and test edits up to it are not flagged, and an open finding that a test was weakened is forgiven. Every other check runs again and raises whatever is still wrong. A commit pushed later is flagged again. The exception is an Acceptance item the reviewer maps with `CHECKED` that says no test was weakened: that check reads the whole PR, so it raises the accepted edit again and the fixer may restore the test. Remove that item from the card before you accept such an edit. The command exits 1 with a message, and leaves the note unchanged, when the card is not Blocked, the note names no PR, or the PR head cannot be read. An `accepted` entry counts only when its `login` is the authenticated `gh` login; otherwise the plan reviews the PR head instead of fixing. After the note write it moves the card out of Blocked, to the state in the note's `blocked_from` (`ready`, `in_progress` or `in_review`; `in_review` when the note has none). A card still in round 0 goes to `in_progress` instead of `in_review`, so the plan starts a review rather than treating the PR as clean. A card returned to `ready` is started again, so the implementor runs before the next review. If the note write fails the card is not moved; if the move fails `accept.sh` exits 3 with the reason, the note stays written, and you move the card by hand.

**Dependencies.** A card body may hold a `## Depends on` section (heading in any case, ending at the next heading) with one bullet per dependency: `- #22` (an issue in `board.repo`) or `- owner/repo#22`. Blank lines are ignored; any other line in the section is ignored with the tick warning `#<n>: unrecognized dependency line: <line>`. A dependency is met when its issue is closed with state reason completed, or, on the Projects backend, when it is an item on the board's project with Status equal to the Done column, in `board.repo` or any other repo. On the labels backend every dependency is judged by its issue state only. The issue is read with `gh issue view <N> --repo <owner/repo> --json state,stateReason`, and the Status through the Projects adapter. Closed as not planned, or Status Won't Do, counts as unmet and adds the warning `#<n> depends on <ref>, which was closed as not planned`. A dependency closed any other way (as a duplicate, say) is unmet too, without the warning. A failed lookup skips the card for that tick with the reason `lookup failed: <command>`, like every other lookup in `tick-plan.sh`.

Only a Ready card with an `## Acceptance` section is gated, and only at the start: `tick-plan.sh` plans `wait` with the reason `waits for <ref> (<state or column>)[, <ref> (...)]` and lists the refs in the card's `waiting_on`. The card stays in Ready and does not count towards the plan's `dispatchable`. In Progress, In Review and Blocked cards are never gated. On a `wait` the manager posts `Waiting for <refs>` once and records the refs in the note's `deps_commented`; it posts again only when the unmet set differs. Nothing promotes a card from Backlog: when the dependency finishes, the next tick starts the card if a person has already moved it to Ready. `deps.sh parse` and `deps.sh check` are the two halves; `/fleet-board:status` runs them to show the reason.

**Worktree cleanup.** The manager moves a finished card to Done but never removes its worktrees, because Claude Code's safety classifier blocks that deletion in unattended sessions. The headless wrapper runs `cleanup-done.sh` after each successful tick. When ticking interactively, `/fleet-board:status` lists done cards that still have worktree directories and prints the exact command to remove them.

**Follow-ups.** A role that notices work outside its card reports it under `Out of scope:` or `Bugs found:`. The manager files each item as a card in the `followups.status` column (default `ready`, or Backlog when the item has no testable check). A bug gets the `bug` label and a body with repro, expected and observed. An item whose title matches an open issue is linked to it with a comment instead of being filed again. Roles never create cards themselves.

**Checking `main`.** After a PR merges, the next tick checks `main`: the typecheck and the PR's test files, in a separate `main-check` worktree. If `main` is red, it files a `[P0] main is red after #<pr>` card in the `followups.status` column (default `ready`).
