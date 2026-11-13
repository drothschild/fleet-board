# fleet-board

[![tests](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml/badge.svg)](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml)

Turns a local card board into a work queue for a fleet of Claude Code agents. Cards are files in your repo, shown on a board page; each carries acceptance criteria and is marked ready by hand. A supervisor you start yourself (`scripts/supervisor.sh`) moves every open card along: an implementor writes a failing test first and opens a draft PR, a reviewer checks it on evidence (an Acceptance-to-test map, mutation testing, one re-run claim), optional extra review stages (security, UX, whatever you configure) check it again with their own agent or a model from another provider, and a fixer addresses what the review found. Each role works in its own git worktree. Finished cards land in Human QA or as a PR ready for review; merging stays manual unless you set `merge.policy: auto`. A hook keeps agents from releasing Human QA, merging when they shouldn't, or starting a card without acceptance criteria.

## Install

Tell Claude Code "Go to https://github.com/drothschild/fleet-board and follow the install directions", or run:

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

Requires Claude Code 2.1.x, `git`, `jq` (both ship with macOS 15 and later) and `gh`, logged in with the `repo` scope (the PRs live on GitHub). The board page and the supervisor need `python3` 3.9 or later (standard library only). `/fleet-board:init` checks that these tools are on `PATH` and checks the `gh` scopes, printing the command that adds a missing one.

## Adding fleet-board to an existing project

Check these first. Each one stopped a real card when fleet-board was adopted on an existing app.

- **`main` is green.** A test that already fails shows up as noise in every card that touches it.
- **Setup works in a fresh worktree.** The `worktrees.setup` command (`npm ci`, `uv sync`, ...) must succeed in a brand-new worktree of `main`, not just in an existing checkout:

  ```bash
  git worktree add /tmp/fb-check origin/HEAD && (cd /tmp/fb-check && npm ci); git worktree remove --force /tmp/fb-check
  ```

  A lockfile out of sync with its manifest, or a dependency on a relative path outside the repo (`file:../lib.tgz`), breaks here.
- **One test file at a time.** `commands.test_one` must take a single test path in place of `{file}`, for example `npm test -- --runTestsByPath {file}` or `pytest {file}`.
- **Existing GitHub board.** If the project already runs on a fleet-board issue board, copy it over once with [`import-github.sh`](#moving-an-existing-github-board); the board itself is always local.
- **Cards already on the board.** The supervisor acts on every card in Ready, In Progress, In Review and Blocked, including ones that were there before. Run `/fleet-board:status` first, and move work that should be finished by hand back to Backlog.
- **Process docs.** If `AGENTS.md` or `CLAUDE.md` has board, review or merge rules, remove them; the agents read those files and would argue with their role specs. Keep the project facts.

Then run `/fleet-board:init`, get `.fleet-board.yml` onto the default branch (role worktrees branch from `origin/HEAD`), move **one** small card to Ready, and start the supervisor (see [Running the supervisor](#running-the-supervisor)) until the card reaches a ready PR or Human QA.

## On a fresh repo

1. **Create a repo** with a little code and a test runner that can run one test file, and clone it.
2. **Run `/fleet-board:init`.** It creates the local card store. Confirm or edit the commands it proposes; `commands.test_one` matters most, for example `node --test {file}`.
3. **Commit and push `.fleet-board.yml`:**

   ```bash
   git add .fleet-board.yml && git commit -m "chore: add fleet-board config" && git push
   ```

4. **Write one small card** on the board page (see [Local board](#local-board)): a title, a body, and testable acceptance items (see [Writing a card](#writing-a-card)). Add the `needs-human-qa` label to check the result by hand before any PR is marked ready.
5. **Move it to Ready.**
6. **Start the supervisor**: press Start on the board page, or run `fleet-board supervisor start --detach` (see [Running the supervisor](#running-the-supervisor)).
7. **Watch it move.** With a clean review:

   | Step | Card | What appears |
   |---|---|---|
   | implement | In Progress | A `fleet/<n>-<slug>` branch, a worktree, and a draft PR whose first commit holds only the failing tests |
   | review | In Review | The reviewer's report on the card |
   | hand-off | Human QA, or a ready PR | Human QA with a "What to check" comment, or the PR marked ready for review |

   With `review.stages` configured and a PR that matches a stage, the clean In Review card goes to `Review: <name>` instead of Human QA, and the stage's report appears on it next. Human QA or the ready PR follows once every stage is clean ([details](docs/config.md#reviewstages)). Under `merge.policy: auto` a clean, green PR that needs no Human QA goes to `merging` and is merged instead.

8. **Release Human QA by hand** on the board page: check the change, merge the PR, and move the card to Done (or back to Ready). No agent can do this; the gate blocks it.

## The board

```
Backlog → Ready → In Progress → In Review → Human QA → Done
                        ↓             ↓   ↘ Merging ↗
                     Blocked       Blocked
```

Each entry in `review.stages` adds a column after In Review. Merging is used only under `merge.policy: auto`. Plus Won't Do. A card's state is a field in its file.

**Who moves what.** Only a person moves cards from Backlog to Ready, and out of Human QA. The supervisor makes every other move. Role agents never move cards; they post reports as comments.

### Writing a card

- **Acceptance lists only what a test can check**, one item per behavior, in the card's `acceptance` field (the drawer's Acceptance list). The reviewer maps each item to a test; an item with no test is a finding.
- **Put on-device and manual checks under `## Human QA`** in the body, not in Acceptance. No agent can test them, so in Acceptance they only get the card blocked.
- **Hold a card until another finishes with Blocked by**: the card's `blocked_by` field lists card numbers on this board (the drawer's Blocked by chips; `#22` in the add box). While any blocker is not Done, the card stays in Ready, `/fleet-board:status` shows what it waits for, and the supervisor comments `Waiting for ...` once (again only when the set of unmet blockers changes). A blocker is met when its card is Done. A Won't Do blocker never counts as met and adds a plan warning. A blocker must be a card on this board: a card that names itself or a card that does not exist is refused, and a dependency in another repo has no home (multi-repo plans go into one board). You still move the card from Backlog to Ready yourself; the gate only holds a Ready card back, and never one already in progress. See [Dependencies](docs/config.md#how-the-board-works-in-detail).
- **Avoid edit conflicts with `## Scope`**: list the files a card changes as backticked paths in its `## Scope` section. A Ready card that names a path that an In progress, In review or review-stage card also names waits (the plan's reason names that card) instead of starting, so the two do not edit the same files in parallel. A card whose `## Scope` names no backticked paths starts as usual. Merges run one at a time, lowest card number first; the others wait their turn.
- **Move the whole chain to Ready; each card starts once its dependencies are Done.** That is the safe way to set up an overnight run. Nothing promotes a Backlog card when its dependencies finish, so a card left in Backlog stays there.

**Lint command.** `/fleet-board:lint [card...]` (`scripts/lint.sh`) runs `card-lint.sh` on Ready and Backlog cards, or on the cards you name, and adds `untestable-bullet`, `dependency-cycle`, `unresolved-dependency` and `missing-file`. It exits 1 when any card fails. `/fleet-board:import-plan` runs it on its generated cards and creates nothing while one fails.

**Card lint.** Before a Ready card is dispatched, `scripts/card-lint.sh` checks its acceptance items. A failing card stays in Ready, the supervisor posts one comment naming the rule and the item (again only when the lint result changes), and no implementor runs until you fix the card. The rules:

- [`no-heading`](#card-lint-no-heading): a body has no `## Acceptance` heading.
- [`no-bullets`](#card-lint-no-bullets): the heading has no `- ` bullet under it.
- [`manual-check`](#card-lint-manual-check): an acceptance item needs a person to check it.
- [`empty-acceptance`](#card-lint-empty-acceptance): a card whose `acceptance` field has no items. It replaces `no-heading` and `no-bullets` for a stored card, since the field has no heading.

#### Card lint: no-heading

Applies to a body, such as the ones `import-plan` generates before they are split into card fields: it needs a `## Acceptance` heading. A bold `**Acceptance**` line or `Acceptance:` is not a heading; the lint names it so you can turn it into one. On a stored card the same mistake shows as `empty-acceptance`: add at least one item to the card's acceptance list.

#### Card lint: no-bullets

Write one `- ` bullet per testable behavior under `## Acceptance` (in a stored card, one list item each). One prose sentence gives the implementor nothing to map a test to.

#### Card lint: empty-acceptance

A stored card's `acceptance` field is empty or missing. Add at least one testable item in the drawer's Acceptance list (or with `board-create.sh --acceptance-file`). A body with a `## Acceptance` section is split into the field when the card is created or edited, so pasting one in works too.

#### Card lint: manual-check

An acceptance item containing `on device`, `on a device`, `verify on`, `by hand`, `Human QA` or `simulator` (any case) can only be checked by a person. Move it under `## Human QA` in the body; the same phrases there are not linted.

**When a card gets blocked.** The supervisor blocks a card, with a comment saying why, when Critical or Important findings survive `review.max_rounds` rounds, when the implementor produces no PR in that many attempts, or when that many actions in a row make no progress. From round `models.escalate_after_rounds` on, the implementor and fixer run on `models.escalation`, or on the reviewer's model when that is unset.

More on how planning, notes, follow-ups and the `main` check work: [docs/config.md](docs/config.md#how-the-board-works-in-detail).

## Config

`.fleet-board.yml` lives at the repo root. Set only what differs from the defaults. A list (`test_paths`, `human_qa_paths`) replaces the default list.

| Key | Default | What it does |
|---|---|---|
| `board.repo` | none (required) | `owner/name` of the repo the PRs live in |
| `board.dir` | `.fleet-board` | where the cards live, relative to the repo root; no `..`, not absolute ([details](docs/config.md#boarddir-and-boardport)) |
| `board.port` | `8765` | the port of the board page, 1024 to 65535 ([details](docs/config.md#boarddir-and-boardport)) |
| `board.states` | `{}` | maps a state to the name the board shows ([details](docs/config.md#boardstates)) |
| `commands.test_one` | none | runs one test file; `{file}` is replaced by its path |
| `commands.typecheck` | none | run by roles, and on `main` after a merge |
| `commands.lint` | none | run by roles |
| `commands.preflight` | none | checks the environment before each plan; a non-zero exit holds every card and warns with the last 20 lines of output |
| `commands.qa_build` | none | run before a card goes to Human QA; the last 20 lines go in its comment |
| `worktrees.dir` | `../.fleet-worktrees` | where card worktrees go, relative to the repo root |
| `worktrees.setup` | none | run once in each new worktree, such as `npm ci` |
| `worktrees.mutate_on_copy` | `false` | the reviewer mutates a copy of the worktree instead of the worktree itself |
| `test_paths` | common test globs | globs that identify test files |
| `human_qa_paths` | `[]` | a PR touching any of these globs sends its card to Human QA |
| `merge.policy` | `human` | `human` or `auto` ([details](docs/config.md#mergepolicy)) |
| `merge.persona` / `merge.persona_append` | `null` / `null` | the merger's instructions: a path relative to the repo root (default `.fleet-board/merger.md` when present), and text added after it ([details](#merger-and-deploys)) |
| `merge.ignore_checks` | `[]` | red checks treated as green, each with `name`, `reason` and `until` ([details](docs/config.md#mergepersona-mergepersona_append-and-mergeignore_checks)) |
| `review.mutation` | `true` | the reviewer runs mutation testing against the diff |
| `review.verify_claim` | `true` | the reviewer re-runs one claim from the implementor's report |
| `review.max_rounds` | `3` | rounds, attempts and no-progress actions allowed before a card is blocked |
| `review.stages` | `[]` | extra review columns after In Review, each with its own agent or provider model, routed by path globs or a label ([details](docs/config.md#reviewstages)) |
| `review.stages[].provider` | none | runs the review stage on a model from a provider instead of a Claude `agent`; set exactly one of the two, plus `model` ([details](docs/config.md#providers)) |
| `providers` | `{}` | provider connections by name: `base_url`, `api_key_env`, `max_tokens_param`, or `command` (a local program such as `codex exec`; sends the same card, findings, report and diff to it); built-in presets `openai`, `gemini`, `openrouter`, `ollama`, `codex` need no entry ([details](docs/config.md#providers)) |
| `models.implementor` / `reviewer` / `fixer` / `merger` | `sonnet` / `opus` / `sonnet` / `sonnet` | each role's model |
| `models.escalate_after_rounds` | `2` | from this round on, implementor and fixer use `models.escalation` |
| `models.reviewer` | `opus` | Claude model string or an object with `provider`, `model` and optional `timeout` ([details](docs/config.md#modelsreviewer)) |
| `providers.<name>.review_command` | none | runs the evidence reviewer in a scratch clone. A Codex evidence reviewer can read the whole repository and sends what it reads to OpenAI through the Codex CLI. |
| `models.escalation` | unset | model for escalated implementor and fixer; defaults to the reviewer model in string form and is required in object form. Setting it equal to `models.reviewer` warns, since the writer then shares the reviewer's blind spots |
| `limits.concurrency` | `6` | role sessions running at once |
| `limits.max_hours`, `max_tokens`, `max_tokens_per_card`, `max_turns` | `8`, `20000000`, none, `200` | supervisor limits: hours before it drains and exits, run tokens before admissions pause, tokens per card, `--max-turns` per session; both token limits count input, output and cache-write tokens, and cache reads are shown but not counted ([details](docs/overnight.md#limits)) |
| `limits.rate_limit_max_wait`, `rate_limit_margin` | `3600`, `5` | seconds: the longest rate-limit wait before the supervisor pauses, margin after a reset |
| `headless.permission_mode` | `auto` | `--permission-mode` for each role session |
| `supervisor.*` | see [config.md](docs/config.md#supervisor) | the reconcile interval, timeouts, retry backoff, aging, per-provider concurrency, `scope_ignore` (paths left out of scope overlap) and `version_files` (JSON files whose version conflicts are resolved and kept above the base) |

The config file is `.fleet-board.yml`, any valid YAML. `board.backend`, `board.project_number` and `board.project_owner` are gone, and so are the tick system's `limits.max_cost_usd`, `limits.tick_interval`, `limits.min_tick_gap`, `limits.max_consecutive_failures` and `models.manager`: `config.sh` exits 5 on any of them (see [Upgrading](#upgrading-from-an-earlier-version)). Tokens are the only unit; an old `price` key is ignored.

## Merger and deploys

Under `merge.policy: auto` the supervisor merges a reviewed PR, runs the card's `## After merge` steps, then runs the **merger**: a role that follows a persona to do project-specific work after a merge, such as a deploy, and to judge a refused merge. It never merges and never moves a card.

The persona is chosen like this:

- `merge.persona: null` (the default) uses `.fleet-board/merger.md` in the board directory when it exists, else the plugin's default.
- `merge.persona: <relative path>` uses that file; a missing file is an attention.
- `merge.persona_append: "<text>"` is added after the chosen persona.

A persona for a repo that deploys after each merge and squash-merges (so the PR's head commit never reaches `main`):

```markdown
# Merger persona

After a merge:
1. Run `gh pr view <pr> --json state,mergeCommit` and confirm the state is MERGED. Take the merge commit from `mergeCommit.oid`.
2. Fetch `origin` and confirm that merge commit is an ancestor of `origin/main`. Never check the PR's head commit: a squash merge never puts it on `main`.
3. Deploy from a fresh detached worktree of that commit with `deploy/deploy.sh`, then check the health URL answers 200.
4. Remove the worktree. Report `attention` if any step fails.
```

On a refused merge the merger can ask for a retry (the supervisor holds the card until the retry time; a second refusal after a retry is an attention) or report `attention` when a person must decide. On attention the card stays in Merging and nothing else runs for it.

**Clearing an attention.** Fix the cause, then write a file holding `{"merger": null}` and run:

```bash
bash <scripts dir>/note.sh merge <n> <file>
```

Add `"merge_refusal": null` and `"merge_retry": null` to the file to let the card try the merge again. Moving the card by hand to another column also clears the records.

`merge.ignore_checks` lists red checks to treat as green, each with a `reason` and an `until` date; see [docs/config.md](docs/config.md#mergepersona-mergepersona_append-and-mergeignore_checks). A check GitHub requires still blocks the merge while it is red.

## Gates

A `PreToolUse` hook blocks any agent command that would move a card out of Human QA, merge a PR under `merge.policy: human`, or mark a card Ready without acceptance items. It does nothing in repos without `.fleet-board.yml`. It is a text check, so it has blind spots and some false positives; [docs/gates.md](docs/gates.md) lists them, along with how fleet-board behaves alongside other plugins. Branch protection on GitHub remains the backstop for merges.

## Review quality

The reviewer catches 6 of 6 seeded defect classes at least 2 of 3 times (opus, `review.mutation` on), measured by a harness in `tests/eval/` on defects such as an off-by-one the tests miss, a weakened assertion and a mocked-away bug. The method, the exact commands, and the results table (measured catch rate per defect class, with and without `review.mutation`, per model, plus cost per run) are in [docs/reviewer-eval.md](docs/reviewer-eval.md).

## Running the supervisor

The supervisor dispatches the board's work until you stop it. Run it from anywhere in the repo; it runs from the repo root (the main checkout, even from a worktree):

```bash
fleet-board supervisor start --detach   # or Start on the board page
fleet-board supervisor status
fleet-board supervisor stop             # finish running sessions, then exit
```

`fleet-board` is a small launcher that `/fleet-board:init` puts in `~/.local/bin` (`FLEET_BOARD_BIN_DIR` moves it; `scripts/install-cli.sh` installs or refreshes it on its own). It runs the plugin's newest installed version that has the script it needs, so plugin updates never break it, and `fleet-board path` prints the plugin directory it uses. When that version ships a newer launcher, the copy runs it instead. `FLEET_BOARD_PLUGIN_ROOT` points it at another copy, such as a checkout of this repository, or pins a version; when a per-project install record names a different version, the launcher says so on stderr.

Before it starts, it checks for cards a crashed run left behind and refuses to start (exit 4) until you resolve them (`stuck`, `stuck --release N`). It stops on its own after `limits.max_hours`, pauses admissions at `limits.max_tokens` (cache reads are shown but not counted), and counts tokens only. Under `merge.policy: auto` it merges reviewed, non-draft, green PRs that need no Human QA, one at a time, and moves their cards to Done; under `human` (the default) it merges nothing. Pause, resume, limits, the startup check and scheduling are in [docs/overnight.md](docs/overnight.md).

## Local board

The board is always local: cards are JSON files under `<repo>/.fleet-board/`, which `/fleet-board:init` creates (`init.sh --repo OWNER/NAME`). It starts the card counter at 1, adds `.fleet-board/` to `.gitignore` and checks the `gh` scope `repo`, since `board.repo` is where the PRs live. To version the board, remove that line from `.gitignore` and commit the directory.

**Card fields.** A card has a title, a prose `body`, `labels`, a `state` and three fields that used to be body sections:

| Field | Holds | Used by |
|---|---|---|
| `acceptance` | a list of testable items | the Ready gate, card lint, the implementor and reviewer |
| `blocked_by` | card numbers on this board | the dependency gate, `/fleet-board:status`, the card face |
| `pr_url` | the card's PR | the card face and drawer |

`board-read.sh <n>` prints them next to the prose body. `pr_url` follows the manager note's `pr`: when the note records a PR, the card gets its URL; a URL you set yourself in the drawer is kept until a note names a different PR. A body you give `board-create.sh` or import with `## Acceptance` and `## Depends on` sections is split into the fields, so plans written the old way still import.

Open the page from anywhere in the repo:

```bash
fleet-board board
```

It binds `127.0.0.1` only and uses `board.port` unless you pass `--port N`.

- **Cards.** Drag a card to another column, or click it to open the drawer and edit its title, body, labels, state, Acceptance list, Blocked by chips and PR link. The state select in the drawer is the keyboard path. A card shows `blocked by #n` in amber while a blocker is open, and its PR link. A card lights up while a role works on it.
- **Start and Stop.** The board page's Start, Pause, Resume and Stop drive the command-line supervisor (`fleet-board supervisor`, which runs `scripts/supervisor.sh`). Start launches one in the background, the same as `fleet-board supervisor start --detach`, or resumes a paused one; Stop offers Drain and Cancel. A supervisor started from a terminal shows up too. The token strip shows tokens for this run, all time, and the planner. A card's drawer breaks its tokens down by column and action. Cards a crashed run left behind get a red border and a STUCK label, with a line that says how to resolve each (`fleet-board supervisor stuck --release N`). A banner gives the count, and Start stays disabled until they are resolved. The page keeps its state under `~/.fleet-board/web/` (`FLEET_BOARD_LOG_DIR` moves it).
- **Import.** Paste a plan. The page runs `claude -p` with `/fleet-board:import-plan <plan> --preview`, using `headless.permission_mode` and `limits.max_turns`, and shows the cards it would create. Nothing is created until you press Create, which runs `import-plan.sh` (it prints `Created #N: <title>` for each card). `FLEET_BOARD_CLAUDE` names a different `claude` binary and `FLEET_BOARD_PLUGIN_DIR` adds `--plugin-dir` to that session.
- **Who you are.** The author of a note is `FLEET_BOARD_USER`, else `$USER`. Anyone who can write the directory can write a note.
- **Rate limits.** The board makes no GitHub calls to list columns, read cards and comments, or write notes and reports. PR calls (`gh pr view`, `gh pr list`, pushes) remain; a GitHub rate limit holds new work until it resets (`limits.rate_limit_max_wait`).

**Migrating a store.** A store made before the fields existed keeps them in the body. Run `migrate-card-fields.sh` from the repo root (`--dry-run` first to see the cards it would change): it moves each card's `## Acceptance` and `## Depends on` sections into the fields, takes `pr_url` from the manager note, and prints one line per changed card. A dependency that is not a card on this board stays in the body as a prose line, with a warning. It is safe to run again.

### Upgrading from an earlier version

Do the steps in this order. On 0.15.x and earlier a missing `backend` key defaults to `github-labels`, so deleting the key before updating would quietly switch a local board to GitHub labels.

0. Stop a running supervisor first (`fleet-board supervisor stop`, and wait for it to exit). Between the update and the migration every unmigrated card reads `acceptance: []`, so a live run would see no acceptance on any card.
1. Update the plugin (`/plugin marketplace update fleet-board`, then update or reinstall it) and start a new session.
2. Delete `backend:` (and `project_number:` and `project_owner:` if set) from `.fleet-board.yml`. `config.sh` exits 5 naming the key until you do.
3. Run `migrate-card-fields.sh` on the local store. If your cards are GitHub issues (`backend: github-labels`, `github-projects`, or no `backend` key: the old default was labels), skip this step and follow "Moving an existing GitHub board" below instead.
4. From 0.26.0 the tick system is gone: the `tick` and `run` skills, the headless tick wrapper, the manager agent and the `.fleet-board.stop` file. Delete `limits.max_cost_usd`, `limits.tick_interval`, `limits.min_tick_gap`, `limits.max_consecutive_failures` and `models.manager` from `.fleet-board.yml` (`config.sh` exits 5 naming each), and run the supervisor instead.
5. From 0.27.0 `scripts/settle.sh` and `tick-plan.sh --settle` are gone (the supervisor plans those steps itself), and `limits.max_tokens` and `limits.max_tokens_per_card` no longer count cache reads, so the same limit lets a run go further. Lower them if you set them with cache reads in mind.

### Moving an existing GitHub board

A repo whose cards are still GitHub issues (`fleet:<state>` labels, or a Projects board) is copied once into the local store with `scripts/import-github.sh`, run from the repo root (the scripts directory is in the last line of `/fleet-board:status`). It is read-only: every `gh` call is a GET or a list, and nothing is written to GitHub.

First, run `/fleet-board:init` (or write `.fleet-board.yml` by hand) so the local store exists, and make sure the config no longer has `backend`, `project_number` or `project_owner`: the importer loads the config and `config.sh` exits 5 on them. Note the project number from the old config before you delete it. `init.sh` adds `.fleet-board/` to `.gitignore`; if you wrote the config by hand, add that line yourself, or remove it later if you want to version the board.

```bash
bash <scripts directory>/import-github.sh --repo OWNER/NAME --dry-run
```

- `--repo OWNER/NAME` names the repo whose issues are imported (required). It must be the same as `board.repo` (case-insensitive); otherwise the import exits 2.
- `--project N` imports a Projects board instead of labels, reading each item's Status column; `N` is the `project_number` from the old config; `--owner LOGIN` names the project's owner when it is not the repo owner.
- `--dry-run` prints one line per card and writes nothing; run it first.
- `--force` imports into a store that already has cards, overwriting the imported numbers and leaving other cards. A card that is in Human QA in the store is kept as it is, with a warning. Without it the import refuses a non-empty store.

Each card keeps its issue number, title, dates, labels (without the `fleet:<state>` ones), comments and manager note (re-authored to the local login). Acceptance and dependencies are split into the fields; a dependency on an issue that is not imported, or in another repo, stays in the body as prose with a warning. An issue with no state label, or not on the project, is not a card and is skipped with a warning; a Projects column that maps to no state stops the run (map it in `board.states`, or add the review stage).

## Known issues

- **Unblocking a card re-runs the implementor.** A card moved from Blocked back to Ready goes through `start` again, so the implementor runs once more before review. Its branch and PR are reused, so no work is lost. Planned for 0.1.1.

## Design

The tradeoffs behind this plugin are written up in [docs/design.md](../../docs/design.md).

## License

MIT
