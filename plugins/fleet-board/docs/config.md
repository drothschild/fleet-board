# Config details

The [README](../README.md#config) has the full key table. This page covers the rest.

`config.sh` reads `.fleet-board.yml`, merges it over `scripts/config-defaults.json`, and validates it. A map is merged key by key; a list replaces the default list whole.

The default `test_paths` are `test/**`, `tests/**`, `__tests__/**`, `**/*.test.*`, `**/*.spec.*`, `**/*_test.*` and `**/test_*`.

When `models.implementor` and `models.reviewer` are the same, every plan warns that the reviewer shares the writer's blind spots.

## `commands.preflight`

Unset by default. A command that checks the environment works, for example that a generated client is current or a service answers. `tick-plan.sh` runs it once per plan, from the repo root, before planning. When it exits non-zero, the plan holds every card (no start, review, fix or other action), so the supervisor admits nothing, and the plan carries one warning, `preflight failed: <command> (exit <n>)`, followed by the last 20 lines of the output. No card's state or `action_failures` changes. When it exits 0 the plan is the same as with the key unset. Merge plans (`tick-plan.sh --settle-merge`, run by `merge-reviewed.sh`) never run it.

Recipes: `test -n "$OPENAI_API_KEY"` holds the board while a provider key is unset, and `review-stages.sh setup` (nothing to create on the local store) exits 0.

## `merge.policy`

Under `human`, the gate blocks every `gh pr merge`, and clean PRs wait to be merged by hand. Under `auto`, the supervisor merges a PR whose review is clean, whose checks are green, and whose card doesn't need Human QA: the card moves to `merging` and `scripts/merge-reviewed.sh` merges it outside any Claude session (see [overnight.md](overnight.md#merges-under-mergepolicy-auto)). Merges stay human by default (`human`).

## `merge.ignore_checks`

A list of dated, reasoned exceptions for checks that should not hold up a merge. Each entry has a `name` (a case-sensitive shell glob: `*` is any run of characters, `?` one character), a `reason`, and an `until` date (`YYYY-MM-DD`, valid through that day, UTC). A red check whose name matches an unexpired entry counts as green. An entry that also says `pending: true` covers a matching check that is still running, so the supervisor merges without waiting for it to finish; without it, a pending check is never green. A `pending: true` entry also covers a red check of the same name: it means "don't wait for this check, whatever it says". A check with no name or context is never covered by any entry.

Each check is judged by one of three explicit sets, and a check in none of them is never green, whatever the entries say:

- **passed:** a check run whose conclusion is `SUCCESS`, `NEUTRAL` or `SKIPPED`; a status context in state `SUCCESS`.
- **red:** a check run whose conclusion is `FAILURE`, `CANCELLED`, `TIMED_OUT`, `ACTION_REQUIRED`, `STARTUP_FAILURE` or `STALE`; a status context in state `FAILURE` or `ERROR`. Any entry covers these, so an entry without `pending` also covers `STARTUP_FAILURE` and `STALE`.
- **pending:** a check run whose status is `QUEUED`, `IN_PROGRESS`, `WAITING`, `PENDING` or `REQUESTED` and that has no conclusion yet; a status context in state `PENDING` or `EXPECTED`. Only a `pending: true` entry covers these.

A completed check run with no conclusion, or any state fleet-board does not know, always blocks the merge. An expired entry counts for nothing and the planner warns about it. The planner, `merge-reviewed.sh` and the gate share one rule (`scripts/ignore-checks.jq`), and each merge records the checks it went past on the card's note, each with the `state` it was in (`red` or `pending`).

```yaml
merge:
  policy: auto
  ignore_checks:
    - name: "*"
      reason: "CI is asynchronous feedback for this repository"
      until: 2026-12-31
      pending: true
```

`gh pr merge` still refuses a merge while a check that branch protection marks as required is failing or pending, and fleet-board never uses `--admin`. On a branch with a merge queue, gh queues the PR instead of refusing it; `merge-reviewed.sh` then finds the PR still open, treats it as possibly queued, and stops until the remote state resolves.

## `after_merge.allow` and the `## After merge` section

A card body may hold a `## After merge` section (heading in any case, ending at the next heading) with one command per `-` bullet, for example `- git tag v1.2.3` and `- git push origin v1.2.3`. After the card's PR merges, the supervisor runs `after-merge.sh run <body-file>`, which runs the commands in order and prints the outcome. Release steps no agent can do by hand need no Human QA step this way.

`after_merge.allow` in `.fleet-board.yml` is a list of command prefixes; only a command that starts with one of them (as whole words) runs. A missing key means no command is allowed.

```yaml
after_merge:
  allow: ["git tag", "git push origin"]
```

The supervisor records each command's exit status in the card's note. A command with no matching prefix is not run; the card moves to Blocked and the comment names the command and the missing `after_merge.allow` entry. A command holding `;`, `&`, `|`, a backtick, `$`, `<`, `>` or a newline is treated the same, so an allowed prefix cannot chain another command. A command that exits non-zero moves the card to Blocked, with the command and its exit status in the comment. Execution stops at the first refusal or failure. When every command succeeds the card moves to Done with no Human QA step.

## `board.states`

Canonical states are `backlog`, `ready`, `in_progress`, `in_review`, `human_qa`, `blocked`, `done` and `wont_do`. The board is always local, so a card's state is stored in its file; the names the page shows default to `Backlog`, `Ready`, `In Progress`, `In Review`, `Human QA`, `Blocked`, `Done` and `Won't Do`, and `Review: <stage>` for a review stage. Map only the ones that differ:

```yaml
board:
  repo: user/myProject
  states: { in_progress: "In progress", in_review: "In review", human_qa: "Human QA", wont_do: "Won't Do" }
```

`board.backend`, `board.project_number` and `board.project_owner` are no longer settings: `config.sh` exits 5 naming each one it finds. Delete them from `.fleet-board.yml`. To bring an existing GitHub board over, see [Moving an existing GitHub board](../README.md#moving-an-existing-github-board).

## `followups.status`

Cards a fleet run files (out-of-scope items, bugs, and the P0 "main is red" card) are created in the `ready` column by default, with an `acceptance` field drafted from the finding, so the supervisor can pick them up. Set `followups.status: backlog` to have a person triage them first; any other value is rejected by `config.sh` (`followups.status must be ready or backlog`). The Acceptance command is the first backticked span with a non-blank character; spans are paired single backticks, so a detail with an odd number of backticks or a double backtick has none. An out-of-scope item with no such span, or whose detail holds the words `no testable check` (even beside a backticked path, and even when quoted), gives no testable bullet; it is filed in Backlog regardless, with a comment saying why. Roles are told to write the check command before any other backticked text; a backticked file path written first is taken as the command, and invisible characters inside a span are not checked. A follow-up whose detail says "depends on this card" carries a `blocked_by` entry naming the spawning card. Before filing, an open card, or one closed in the last 30 days, with the same title (case-insensitive) suppresses the new card; the printed entry has `"existing": true` and `"matched": "open"` or `"closed"`.

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
      timeout: 600                    # seconds; default 600
      max_output_tokens: 16000        # default 16000
      max_diff_bytes: 400000          # default 400000
```

A stage is the state `review_<name>`, in config order between `in_review` and `human_qa`. Its column is named `Review: <name>` by default; `board.states.review_<name>` renames it; a `review_` key naming no stage is rejected.

**Routing.** A stage applies to a card when the card carries the stage's label, or when a file the PR changes matches one of its `paths` globs (the rule `needs-human-qa.sh` uses). `review-stages.sh route <card> <pr>` adds each missing label and never removes one. It runs when the card moves from In Progress to In Review, before the move, so a failure leaves the card in In Progress and the next plan retries. A person can add a label before a stage begins to force a visit; a stage already reviewed is not visited again. When `gh` lists fewer files than the PR changes, every stage is routed, with a warning.

**Re-matching.** Routing adds labels once, but a fixer's commit or a later push can touch a stage's `paths` after it. So at every clean, current review (in In Review or a stage column) `tick-plan.sh` runs `review-stages.sh match <pr>`, which reads the PR's files now and adds no label, and counts each stage those files match as routed. The next stage is the first one in config order that is routed, is not the current column and is not in the note's `reviewed_stages`; it can be a stage before the current column that was never visited. The trade-off: removing a label skips a stage only when its `paths` do not match the PR's current files. A stage whose globs match cannot be skipped that way; a label-only stage (empty `paths`) still can. A failed `match` skips the card for that plan (`lookup failed: review-stages.sh match <pr>`).

**Setup.** After adding or changing stages, run `bash <scripts>/review-stages.sh setup` (`init.sh` prints this command when it finishes; it does not run it). On the local store there is nothing to create (routing labels are added to a card when it is routed), so it exits 0.

**Flow.** A card whose evidence review is clean moves to the first routed stage (`advance_stage`) and is reviewed there next. Critical or Important findings go to the fixer and the same stage re-reviews, up to the stage's `max_rounds`; then the card is Blocked. A clean stage moves the card to the next routed stage, then to Human QA, a ready PR or a merge exactly as before.

**Advisory.** An `advisory: true` stage posts its report and its findings are read as clean: its findings never send the card to a fixer or block it. A provider stage fails closed even when advisory: a diff over `max_diff_bytes` or with no text hunks (`stage-review.sh` exit 7) blocks the card, and repeated provider failures (exits 1, 3 and 6 count as report errors) block it under the `action_failures` rule like any other stage.

**Trade-off.** A finding is fixed and re-reviewed in its own stage only. Earlier stages are not re-run, so a later stage's fix is not seen again by the evidence reviewer or by an earlier stage. The reviewed-heads rule still applies: a PR is merged only at a head some reviewer saw, so a fix that lands after the last review is reviewed again before it merges.

**A provider stage** takes `model`, `timeout`, `max_output_tokens` and `max_diff_bytes` (below) in place of `agent`, and the supervisor runs it with `stage-review.sh` instead of dispatching an agent. It sends the card body, the stage's `brief`, the round, the previous round's Critical and Important findings, the latest implementor or fixer report and the PR diff (the prompt is `scripts/providers/stage-review-prompt.md`) to that provider, and nothing else from the repo: it has no tools and no worktree, so it runs no tests.

## `models.reviewer`

A model string selects the Claude evidence reviewer and defaults to `opus`. To run
evidence review through a command provider, configure it as follows.

```yaml
models:
  reviewer: { provider: codex, model: gpt-6-astra, timeout: 1500 }
  escalation: opus
```

The provider must define a `review_command`. Set an escalation model. The timeout is an integer from 1 to 1500 seconds and
defaults to 1500. Both attempts share this timeout. The Codex preset restricts
writes to the scratch clone, where the runner sets the provider's `TMPDIR`. A reviewer-local `mktemp` wrapper routes bare `mktemp` and `mktemp -d` to explicit templates there, because macOS otherwise prefers Darwin's shared temp directory. Explicit arguments are passed through unchanged. On macOS, a reviewer-local `ps` adapter supports only `-o lstart= -p PID` (either option order), reading the real start time through `libproc`. This avoids executing the system setuid binary; the adapter does not alter sandbox policy. macOS may allow this basic start-time metadata query for processes outside the sandbox as well. Other `ps` queries fail explicitly.
The Codex preset enables the command network proxy, permits local listeners and localhost HTTP requests, and supplies no public-domain allow rules. Proxy ports are ephemeral so concurrent reviews do not collide. Scratch write restrictions and shared-temp exclusions remain enabled. This requires a Codex CLI supporting `features.network_proxy` (validated with 0.167.0). Custom review commands must provide equivalent isolation. With this form,
each agent review stage must set its own model.

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
```

Built-in presets are `openai`, `gemini`, `openrouter`, `ollama` and `codex` (a command provider, below); their values are in `scripts/providers/presets.json`. A `providers.<name>` entry is merged over the preset key by key, so `providers.openai.api_key_env: WORK_OPENAI` keeps the preset's `base_url`. The merged output holds an entry for every provider named by a stage or the evidence reviewer, or defined in the file. A provider the file defines that no stage uses prints a warning on stderr and changes nothing else.

| Key | Rule |
|---|---|
| provider name | matches `^[a-z][a-z0-9_-]*$` |
| `base_url` | an https address, or an http address whose host is `localhost`, `127.0.0.1` or `[::1]` with an optional numeric port; no userinfo (`user@`) in either (`base_url must not contain userinfo`). `chat.sh` repeats both checks before any request |
| `api_key_env` | the name of an environment variable, matching `^[A-Z_][A-Z0-9_]*$`; `null` only for a loopback `base_url` |
| `max_tokens_param` | `max_tokens` or `max_completion_tokens`; ignored when `command` is set |
| `command` | optional string run with `sh -c` instead of an HTTP call, with `{model}` replaced by the stage's `model`. Needs `base_url` and `api_key_env` to be null (`providers.<name> sets both command and base_url`, `providers.<name>.api_key_env must be null when command is set`, both exit 5) |
| `review_command` | optional command for evidence review in a scratch clone. Requires `{dir}` and supports `{model}`. Exclusive with `base_url`. Sandbox bypass flags and `danger-full-access` are forbidden. |

If a stage's `api_key_env` variable is unset or empty, `tick-plan.sh` warns once (`stage <name>: <ENV> is not set; provider reviews will fail`) and plans that stage's `review_stage` as `wait` with the reason `stage <name>: <ENV> is not set`, so the card is not failed on every plan; a card entering the stage still moves, and its review waits until the variable is set. To make the whole plan hold instead, add a preflight check (see [`commands.preflight`](#commandspreflight)): `test -n "$OPENAI_API_KEY"`, and for stage labels `review-stages.sh setup`.

Config never holds a key. `api_key`, `key`, `token` and `secret` under a provider are rejected, and the message does not repeat the value.

A provider stage also takes `model` (required) and three positive integers: `timeout` (seconds, default `600`), `max_output_tokens` (default `16000`) and `max_diff_bytes` (default `400000`). An agent stage has `provider: null`, and defaults `model` to `models.reviewer` when it is a string. Tokens are the only unit: nothing is priced, and an old `price` key on a stage or on `models.reviewer` is ignored.

**A command provider** (an entry with `command`, such as the `codex` preset) runs a local program instead of calling an HTTP API. `chat.sh` joins the prompt's system and user text, system first, and writes it to the command's stdin with the repo root as the working directory. Stdout is the reply; a non-zero exit or an empty stdout is a provider failure (exit 1, the command's stderr on stderr), and the stage's `timeout` applies to the command. The reply carries no token counts, so `stage-review.sh` records `input_tokens` and `output_tokens` as `null` (unknown, never 0) in the ledger. The model id must match `^[A-Za-z0-9][A-Za-z0-9._:/-]*$`, since it is placed into the command line. The `codex` preset is `codex exec --skip-git-repo-check -s read-only -m {model}`: it reviews under the Codex CLI's own login (a ChatGPT subscription, no API key) and needs `codex` on `PATH`.

```yaml
providers:
  codex: {}                      # or omit; the preset is built in
review:
  stages:
    - name: second-opinion
      provider: codex
      model: gpt-6-astra
```

**Data egress.** A provider stage sends the card body, the stage's `brief`, the round, the previous round's Critical and Important findings, the latest implementor or fixer report and the PR diff (the prompt is `scripts/providers/stage-review-prompt.md`) to that provider. A command provider sends the same card, findings, report and diff to the program it runs, and whatever that program forwards (the `codex` preset sends them to OpenAI through the Codex CLI). A Codex evidence reviewer can read the whole repository and sends what it reads to OpenAI through the Codex CLI. Use a provider only for repos whose code and cards you may send to it.

## `limits`

The supervisor reads `limits.concurrency`, `max_hours`, `max_tokens`, `max_tokens_per_card`, `max_turns`, `rate_limit_max_wait` and `rate_limit_margin` (see [overnight.md](overnight.md#limits)). `max_tokens` and `max_tokens_per_card` count input, output and cache-write tokens; cache reads are shown in the ledger and on the board but not counted. `config.sh` exits 5 when `rate_limit_max_wait` or `rate_limit_margin` is not a non-negative number.

| Key | Default | Meaning |
|---|---|---|
| `limits.rate_limit_max_wait` | `3600` | seconds: a GitHub rate limit whose reset is further away than this pauses the supervisor |
| `limits.rate_limit_margin` | `5` | seconds added after the reset time before new work starts |

`limits.max_cost_usd`, `limits.tick_interval`, `limits.min_tick_gap`, `limits.max_consecutive_failures` and `models.manager` belonged to the tick system, which is gone: `config.sh` exits 5 naming each one it finds. Delete them from `.fleet-board.yml`.

## `board.dir` and `board.port`

`board.dir` is where the cards live: `<board.dir>/cards/<n>.json`, the `next` counter, and the `active/` markers. The default is `.fleet-board`. It is relative to the repo root, so it cannot be absolute or contain `..`; `config.sh` exits 5 for either.

`board.port` is the port the board page listens on, on `127.0.0.1`. The default is `8765`. It must be an integer from 1024 to 65535. `board-web.sh --port N` overrides it for one run.

## Finding the file

`config.sh` uses `$FLEET_BOARD_CONFIG` when set, then `.fleet-board.yml` at the git root, then the one in the main checkout (for a linked worktree). Its exit codes: 3 no config, 4 the file is not valid YAML or uses YAML outside the supported subset, 5 an invalid value.

## YAML subset

`config.sh` parses the file with a bundled jq script (`scripts/yaml.jq`), so nothing beyond `jq` is needed. It reads block and flow maps and lists, plain, single- and double-quoted strings, `|` and `>` block strings, and `#` comments. It rejects anchors, aliases and tags, tabs used for indentation, duplicate keys, more than one document, and maps inside a block list item, naming the line.

## How the board works in detail

**One writer per card.** Every card write takes a per-card lock and rewrites the file whole, so two writers on one card never leave it half-written. The page's edit and the agents' comments change disjoint fields (`edit.sh` never touches `comments` or `state`).

**One step at a time.** The supervisor asks `tick-plan.sh --candidates` for the next action of each open card, admits what fits (`limits.concurrency`, `supervisor.provider_concurrency`, scope reservations), and runs each one: a role session, a provider review, or a script. When an action ends it plans again.

**Conflicting PRs.** An open PR on an In Progress or In Review card whose `gh pr view --json mergeable` answer is `CONFLICTING` gets the action `update_branch` from `tick-plan.sh` (reason `PR #<pr> has merge conflicts with its base branch`) instead of `start_review`, `review`, `fix` or any other action. The lookup is best effort: a failed or unreadable answer reads as unknown and plans nothing. `scripts/update-branch.sh <n> <pr> <branch> <worktree>` carries the action out: it fetches `origin`, merges `origin/<base>` into the branch with a merge commit and pushes with a plain `git push`; it never rebases and never force-pushes. A clean merge leaves the card in its column and adds `last_update` (`sha`, `base`, `changed`) to the manager note. It leaves the note's `last_review` as it is: a clean merge of the base needs no new review, and the next plan has a `review` only when a commit after `last_review` is not a clean merge (see Reviewed heads). A merge that conflicts is aborted and not pushed; the script comments with the conflicted files, leaves the card where it is, adds `conflicted_files` (every file, test files included) to the manager note, counts the conflict toward `action_failures` and exits 1. It never resolves a conflict itself: a note with `conflicted_files` plans the action `fix` from `tick-plan.sh`, with one finding `merge conflict in <file>` per file, so the fixer re-runs the merge of the base, resolves every conflict and commits a merge commit (never a rebase or a force-push). In a conflict region of a test file the fixer keeps every test and assertion from both sides; when both cannot be kept, or a touched test fails after resolving, it reports `blocked`, pushes nothing, and the card moves to Blocked with the conflicted files named. A resolved merge resets `last_review`, so the next plan has a `review`: a merge with conflict resolution never skips review.

**The manager note.** The supervisor keeps no card state of its own. Everything it needs to resume a card lives in one comment on that card, starting `<!-- fleet-board:manager-note -->`, with a JSON block holding the branch, worktree, PR, review round, models and failure counts. Leave it alone unless a card was blocked for no progress: then `note.sh reset-failures <n>` clears the count.

**Reviewed heads.** A PR is merged only at a head a reviewer saw. When an In Review PR's head has moved past the note's `last_review.sha`, `tick-plan.sh` plans `review` instead of `merge` (or `mark_ready`, `to_human_qa`), unless every commit since is a merge of the base branch whose tree equals the tree `git merge-tree --write-tree` produces for the commit's two parents. That is a clean merge of main: it skips re-review. A merge that needed conflict resolution, carries extra changes, or any non-merge commit does not. `scripts/review-drift.sh <reviewed-sha> <head-sha>` makes the call (`reviewed` or `unreviewed`); it needs the commits in the local checkout, tries one `git fetch origin`, and reads any failure as `unreviewed`. Under `merge.policy: auto`, gate G2 refuses `gh pr merge` on a `fleet/<n>-*` PR when the same check fails.

**Accepting a change.** When a card is Blocked for something a person has looked at and accepted (an unreviewed merge of `main`, a test edit a fixer may not touch), run `bash <scripts>/accept.sh <n>` (the scripts directory is the plugin's `scripts/`). In one `note.sh merge` it sets the note's `action_failures` to 0 and `last_action_error` to null, moves the reviewed-sha baseline (`last_review.sha`) to the PR's current head, clears the previous review's findings and what the block left in the note (`blocked_findings`, `blocking_pr`, `blocked_from`), and records `accepted` (`login`, `at`, `sha`) in the note. After that the PR is reviewed again from that sha: the commits and test edits up to it are not flagged, and an open finding that a test was weakened is forgiven. Every other check runs again and raises whatever is still wrong. A commit pushed later is flagged again. The exception is an Acceptance item the reviewer maps with `CHECKED` that says no test was weakened: that check reads the whole PR, so it raises the accepted edit again and the fixer may restore the test. Remove that item from the card before you accept such an edit. The command exits 1 with a message, and leaves the note unchanged, when the card is not Blocked, the note names no PR, or the PR head cannot be read. An `accepted` entry counts only when its `login` is the authenticated `gh` login; otherwise the plan reviews the PR head instead of fixing. After the note write it moves the card out of Blocked, to the state in the note's `blocked_from` (`ready`, `in_progress` or `in_review`; `in_review` when the note has none). A card still in round 0 goes to `in_progress` instead of `in_review`, so the plan starts a review rather than treating the PR as clean. A card returned to `ready` is started again, so the implementor runs before the next review. If the note write fails the card is not moved; if the move fails `accept.sh` exits 3 with the reason, the note stays written, and you move the card by hand.

**Dependencies.** A card's `blocked_by` field lists the card numbers on this board that must be Done first. Set it in the page's drawer, with `board-create.sh` or `edit.sh` (a blocker that is a missing card, or the card itself, is refused with exit 2; `edit.sh` checks only the refs the edit adds, so a stale ref already stored never blocks a save), or by a `## Depends on` section in a body you give `board-create.sh`, which is split into the field (`- #22` per bullet; a dependency in another repo cannot be a blocker and stays in the body as prose with a warning). A blocker is met when its card is in `done`. A `wont_do` blocker counts as unmet and adds the warning `#<n> depends on <ref>, which was closed as not planned`. A blocker in another repo is outside this board: it is not looked up and adds a warning. A card file that cannot be read skips the card for that plan with the reason `lookup failed: <command>`, like every other lookup in `tick-plan.sh`.

Only a Ready card with acceptance items is gated, and only at the start: `tick-plan.sh` plans `wait` with the reason `waits for <ref> (<state>)[, <ref> (...)]` and lists the refs in the card's `waiting_on`. The card stays in Ready and does not count towards the plan's `dispatchable`. In Progress, In Review and Blocked cards are never gated. On a `wait` the supervisor posts `Waiting for <refs>` once and records the refs in the note's `deps_commented`; it posts again only when the unmet set differs. Nothing promotes a card from Backlog: when the blocker finishes, the supervisor starts the card if a person has already moved it to Ready. `deps.sh parse-card` and `deps.sh check` are the two halves; `/fleet-board:status` runs them to show the reason.

**Card fields.** A card holds `acceptance` (a list of testable bullets), `blocked_by` (card numbers) and `pr_url` beside its prose `body`. `pr_url` follows the manager note's `pr` (`pr_url_source: note`); a URL a person sets in the drawer is kept until a note names a different PR. Existing stores gain the fields with `migrate-card-fields.sh`.

**Worktree cleanup.** The supervisor moves a finished card to Done but never removes its worktrees, because Claude Code's safety classifier blocks that deletion in unattended sessions. `/fleet-board:status` lists done cards that still have worktree directories and prints the exact command to remove them (`cleanup-done.sh`, run from the repo root outside any Claude session).

**Follow-ups.** A role that notices work outside its card reports it under `Out of scope:` or `Bugs found:`. The supervisor files each item as a card in the `followups.status` column (default `ready`, or Backlog when the item has no testable check). A bug gets the `bug` label and a body with repro, expected and observed. An item whose title matches an open card is linked to it with a comment instead of being filed again. Roles never create cards themselves.

**Checking `main`.** After a PR merges, the supervisor checks `main`: the typecheck and the PR's test files, in a separate `main-check` worktree. If `main` is red, it files a `[P0] main is red after #<pr>` card in the `followups.status` column (default `ready`).
