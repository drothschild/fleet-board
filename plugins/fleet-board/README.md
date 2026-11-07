# fleet-board

[![tests](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml/badge.svg)](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml)

Turns a GitHub issue board into a work queue for a fleet of Claude Code agents. Cards are written with an `## Acceptance` section and marked ready by hand. Each tick, a manager agent moves every open card one step: an implementor writes a failing test first and opens a draft PR, a reviewer checks it on evidence (an Acceptance-to-test map, mutation testing, one re-run claim), optional extra review stages (security, UX, whatever you configure) check it again with their own agent or a model from another provider, and a fixer addresses what the review found. Each role works in its own git worktree. Finished cards land in Human QA or as a PR ready for review; merging stays manual. A hook keeps agents from releasing Human QA, merging when they shouldn't, or starting a card without acceptance criteria.

## Install

Tell Claude Code "Go to https://github.com/drothschild/fleet-board and follow the install directions", or run:

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

Requires Claude Code 2.1.x, `git`, `jq` (both ship with macOS 15 and later) and `gh`, logged in with the `repo` scope (plus `project` for a Projects board). The local board page and the headless run wrapper need `python3` 3.9 or later (standard library only). `/fleet-board:init` checks that these tools are on `PATH` and checks the `gh` scopes, printing the command that adds a missing one.

## Adding fleet-board to an existing project

Check these first. Each one stopped a real card when fleet-board was adopted on an existing app.

- **`main` is green.** A test that already fails shows up as noise in every card that touches it.
- **Setup works in a fresh worktree.** The `worktrees.setup` command (`npm ci`, `uv sync`, ...) must succeed in a brand-new worktree of `main`, not just in an existing checkout:

  ```bash
  git worktree add /tmp/fb-check origin/HEAD && (cd /tmp/fb-check && npm ci); git worktree remove --force /tmp/fb-check
  ```

  A lockfile out of sync with its manifest, or a dependency on a relative path outside the repo (`file:../lib.tgz`), breaks here.
- **One test file at a time.** `commands.test_one` must take a single test path in place of `{file}`, for example `npm test -- --runTestsByPath {file}` or `pytest {file}`.
- **Pick the board.** **Labels** creates eight `fleet:<state>` labels and `needs-human-qa`, and overwrites the color and description of any existing label with those names. **Projects** uses the existing board: every state needs a column (add a Blocked column first if there is none), and names that differ are mapped in [`board.states`](docs/config.md#boardstates).
- **Cards already on the board.** The manager acts on every card in Ready, In Progress, In Review and Blocked, including ones that were there before. Run `/fleet-board:status` first, and move work that should be finished by hand back to Backlog.
- **Process docs.** If `AGENTS.md` or `CLAUDE.md` has board, review or merge rules, remove them; the agents read those files and would argue with the manager. Keep the project facts.

Then run `/fleet-board:init`, get `.fleet-board.yml` onto the default branch (role worktrees branch from `origin/HEAD`), move **one** small card to Ready, and run `/fleet-board:tick` until it reaches a ready PR or Human QA.

## On a fresh repo

1. **Create a repo** with a little code and a test runner that can run one test file, and clone it.
2. **Run `/fleet-board:init`** and choose **Labels**. Confirm or edit the commands it proposes; `commands.test_one` matters most, for example `node --test {file}`.
3. **Commit and push `.fleet-board.yml`:**

   ```bash
   git add .fleet-board.yml && git commit -m "chore: add fleet-board config" && git push
   ```

4. **Write one small card**: an issue with an `## Acceptance` section of testable `- ` bullets (see [Writing a card](#writing-a-card)). Add `needs-human-qa` to check the result by hand before any PR is marked ready.
5. **Label it `fleet:ready`.**
6. **Run `/fleet-board:tick`** a few times, or `/fleet-board:run` to keep going until nothing is left. Each tick ends its report with `dispatchable: true` or `false`.
7. **Watch it move.** With a clean review:

   | After | Card | What appears |
   |---|---|---|
   | tick 1 | `fleet:in_progress` | A `fleet/<n>-<slug>` branch, a worktree, and a draft PR whose first commit holds only the failing tests |
   | tick 2 | `fleet:in_review` | The reviewer's report on the card |
   | tick 3 | `fleet:human_qa`, or a ready PR | Human QA with a "What to check" comment, or the PR marked ready for review |
   | tick 4 | unchanged | `dispatchable: false` |

   With `review.stages` configured and a PR that matches a stage, the clean In Review card goes to `fleet:review_<name>` instead of Human QA, and the stage's report appears on it in that same tick. Each stage adds at least one tick; Human QA or the ready PR follows once every stage is clean ([details](docs/config.md#reviewstages)).

8. **Release Human QA by hand** in the GitHub UI: check the change, merge the PR, and move the card to `fleet:done` (or back to `fleet:ready`). No agent can do this; the gate blocks it.

## The board

```
Backlog → Ready → In Progress → In Review → Human QA → Done
                        ↓             ↓
                     Blocked       Blocked
```

Each entry in `review.stages` adds a column after In Review. Plus Won't Do. On the labels board a card's state is a `fleet:<state>` label; on a Projects board it is the Status column.

**Who moves what.** Only a person moves cards from Backlog to Ready, and out of Human QA. The manager makes every other move. Role agents never move cards; they post reports as comments.

### Writing a card

- **`## Acceptance` lists only what a test can check**, one `- ` bullet per behavior. The reviewer maps each bullet to a test; a bullet with no test is a finding.
- **Put on-device and manual checks under `## Human QA`**, not in Acceptance. No agent can test them, so in Acceptance they only get the card blocked.
- **Hold a card until another finishes with `## Depends on`**, one bullet per dependency: `- #22` for an issue in `board.repo`, or `- owner/repo#22` for another repo. While any dependency is unmet, the card stays in Ready, `/fleet-board:status` shows what it waits for, and the manager comments `Waiting for ...` once (again only when the set of unmet dependencies changes). A dependency is met when its issue is closed as completed, or, on a Projects board, when it is an item on the board's project in the Done column (in any repo; on a labels board only the issue state counts). Closed as not planned, or Won't Do, never counts as met and adds a tick warning. You still move the card from Backlog to Ready yourself; the gate only holds a Ready card back, and never one already in progress. See [Dependencies](docs/config.md#how-the-board-works-in-detail).
- **Avoid edit conflicts with `## Scope`**: list the files a card changes as backticked paths in its `## Scope` section. A Ready card that names a path that an In progress, In review or review-stage card also names waits (the plan's reason names that card) instead of starting, so the two do not edit the same files in parallel. A card whose `## Scope` names no backticked paths starts as usual. The plan also gives `merge` to at most one card per tick, the lowest card number; the others wait for the next tick.
- **Move the whole chain to Ready; each card starts on the first tick after its dependencies are Done.** That is the safe way to set up an overnight run. Nothing promotes a Backlog card when its dependencies finish, so a card left in Backlog stays there.

**Lint command.** `/fleet-board:lint [card...]` (`scripts/lint.sh`) runs `card-lint.sh` on Ready and Backlog cards, or on the cards you name, and adds `untestable-bullet`, `dependency-cycle`, `unresolved-dependency` and `missing-file`. It exits 1 when any card fails. `/fleet-board:import-plan` runs it on its generated cards and creates nothing while one fails.

**Card lint.** Before a Ready card is dispatched, `scripts/card-lint.sh` checks its body. A failing card stays in Ready, the manager posts one comment naming the rule and the bullet (again only when the lint result changes), and no implementor runs until you fix the card. The rules:

- [`no-heading`](#card-lint-no-heading): the card has no `## Acceptance` heading.
- [`no-bullets`](#card-lint-no-bullets): the heading has no `- ` bullet under it.
- [`manual-check`](#card-lint-manual-check): an Acceptance bullet needs a person to check it.

#### Card lint: no-heading

The body needs a `## Acceptance` heading. A bold `**Acceptance**` line or `Acceptance:` is not a heading; the lint names it so you can turn it into one.

#### Card lint: no-bullets

Write one `- ` bullet per testable behavior under `## Acceptance`. One prose sentence gives the implementor nothing to map a test to.

#### Card lint: manual-check

An Acceptance bullet containing `on device`, `on a device`, `verify on`, `by hand`, `Human QA` or `simulator` (any case) can only be checked by a person. Move it under `## Human QA`; the same phrases there are not linted.

**When a card gets blocked.** The manager blocks a card, with a comment saying why, when Critical or Important findings survive `review.max_rounds` rounds, when the implementor produces no PR in that many attempts, or when that many actions in a row make no progress. From round `models.escalate_after_rounds` on, the implementor and fixer run on `models.escalation`, or on the reviewer's model when that is unset.

More on how ticks, notes, follow-ups and the `main` check work: [docs/config.md](docs/config.md#how-the-board-works-in-detail).

## Config

`.fleet-board.yml` lives at the repo root. Set only what differs from the defaults. A list (`test_paths`, `human_qa_paths`) replaces the default list.

| Key | Default | What it does |
|---|---|---|
| `board.backend` | `github-labels` | `github-labels`, `github-projects` or `local` (cards as files in the repo, see [Local board](#local-board)) |
| `board.repo` | none (required) | `owner/name` of the repo the cards live in |
| `board.project_number` | none | the Projects board number; required for `github-projects`, not used on `local` |
| `board.dir` | `.fleet-board` | `local` only: where the cards live, relative to the repo root; no `..`, not absolute ([details](docs/config.md#boarddir-and-boardport)) |
| `board.port` | `8765` | `local` only: the port of the board page, 1024 to 65535 ([details](docs/config.md#boarddir-and-boardport)) |
| `board.project_owner` | `null` | the project's owner, when it isn't the repo owner |
| `board.states` | `{}` | maps a state to a label or column name ([details](docs/config.md#boardstates)) |
| `commands.test_one` | none | runs one test file; `{file}` is replaced by its path |
| `commands.typecheck` | none | run by roles, and on `main` after a merge |
| `commands.lint` | none | run by roles |
| `commands.preflight` | none | checks the environment once per tick; a non-zero exit holds every card and warns with the last 20 lines of output |
| `commands.qa_build` | none | run before a card goes to Human QA; the last 20 lines go in its comment |
| `worktrees.dir` | `../.fleet-worktrees` | where card worktrees go, relative to the repo root |
| `worktrees.setup` | none | run once in each new worktree, such as `npm ci` |
| `worktrees.mutate_on_copy` | `false` | the reviewer mutates a copy of the worktree instead of the worktree itself |
| `test_paths` | common test globs | globs that identify test files |
| `human_qa_paths` | `[]` | a PR touching any of these globs sends its card to Human QA |
| `merge.policy` | `human` | `human` or `auto` ([details](docs/config.md#mergepolicy)) |
| `review.mutation` | `true` | the reviewer runs mutation testing against the diff |
| `review.verify_claim` | `true` | the reviewer re-runs one claim from the implementor's report |
| `review.max_rounds` | `3` | rounds, attempts and no-progress actions allowed before a card is blocked |
| `review.stages` | `[]` | extra review columns after In Review, each with its own agent or provider model, routed by path globs or a label ([details](docs/config.md#reviewstages)) |
| `review.stages[].provider` | none | runs the review stage on a model from a provider instead of a Claude `agent`; set exactly one of the two, plus `model` and `price` ([details](docs/config.md#providers)) |
| `providers` | `{}` | provider connections by name: `base_url`, `api_key_env`, `max_tokens_param`, or `command` (a local program such as `codex exec`; sends the same card, findings, report and diff to it); built-in presets `openai`, `gemini`, `openrouter`, `ollama`, `codex` need no entry ([details](docs/config.md#providers)) |
| `models.manager` / `implementor` / `reviewer` / `fixer` | `sonnet` / `sonnet` / `opus` / `sonnet` | each role's model |
| `models.escalate_after_rounds` | `2` | from this round on, implementor and fixer use `models.escalation` |
| `models.reviewer` | `opus` | Claude model string or an object with `provider`, `model`, `price` and optional `timeout` ([details](docs/config.md#modelsreviewer)) |
| `providers.<name>.review_command` | none | runs the evidence reviewer in a scratch clone. A Codex evidence reviewer can read the whole repository and sends what it reads to OpenAI through the Codex CLI. |
| `models.escalation` | unset | model for escalated implementor and fixer; defaults to the reviewer model in string form and is required in object form. Setting it equal to `models.reviewer` warns, since the writer then shares the reviewer's blind spots |
| `limits.concurrency` | `6` | role agents running at once |
| `limits.tick_interval` | `300` | seconds between ticks |
| `limits.max_hours`, `max_cost_usd`, `max_consecutive_failures`, `max_turns` | `8`, `40`, `3`, `200` | headless wrapper limits |
| `limits.rate_limit_max_wait`, `rate_limit_margin`, `min_tick_gap` | `3600`, `5`, `0` | seconds: total rate-limit wait cap, margin after a reset, minimum gap between tick starts of runs sharing a token |
| `headless.permission_mode` | `auto` | `--permission-mode` for each headless tick |

The config file is `.fleet-board.yml`, any valid YAML.

## Gates

A `PreToolUse` hook blocks any agent command that would move a card out of Human QA, merge a PR under `merge.policy: human`, or mark a card Ready without `## Acceptance`. It does nothing in repos without `.fleet-board.yml`. It is a text check, so it has blind spots and some false positives; [docs/gates.md](docs/gates.md) lists them, along with how fleet-board behaves alongside other plugins. Branch protection on GitHub remains the backstop for merges.

## Review quality

The reviewer catches 6 of 6 seeded defect classes at least 2 of 3 times (opus, `review.mutation` on), measured by a harness in `tests/eval/` on defects such as an off-by-one the tests miss, a weakened assertion and a mocked-away bug. The method, the exact commands, and the results table (measured catch rate per defect class, with and without `review.mutation`, per model, plus cost per run) are in [docs/reviewer-eval.md](docs/reviewer-eval.md).

## Running overnight

The headless wrapper runs ticks one after another until the board is settled or a limit is reached. Find its path on the last line of `/fleet-board:status`, then from the repo root:

```bash
bash <path from /fleet-board:status> --repo .
```

After each successful tick the wrapper also runs `scripts/settle.sh`, a plain shell script that starts no Claude session. It moves the cards whose next step needs no agent (for example a clean review to Human QA) right away instead of a whole tick later. It never merges and never moves a card out of Human QA. A person's interactive `/fleet-board:tick` does not run it.

Stop it gracefully with `touch .fleet-board.stop`, or at once with Ctrl-C. Under `merge.policy: auto` an overnight run merges reviewed, non-draft, green PRs itself and moves their cards to Done; under `human` (the default) it merges nothing. Stop reasons, exit codes, the run log, cost estimates and scheduling with launchd are in [docs/overnight.md](docs/overnight.md).

## Local board

`board.backend: local` keeps the cards as JSON files under `<repo>/.fleet-board/` (the `board.dir` key moves it) instead of GitHub issues. `board.repo` stays required, since the PRs still live there.

Set it up with `/fleet-board:init` and pick Local, or run `init.sh --backend local --repo OWNER/NAME`. It creates `.fleet-board/cards`, starts the card counter at 1, adds `.fleet-board/` to `.gitignore` and creates no labels. It still checks the `gh` scope `repo`. To version the board, remove that line from `.gitignore` and commit the directory.

To move an existing board, save each active card with `board-read.sh <n> > <dir>/<n>.json` while the config still names the old backend, then run `migrate-to-local.sh <dir>/*.json` from the repo root and set `board.backend: local`: cards keep their numbers, states and comments, the manager note is re-authored to the local user (`--note-author` overrides), and it refuses an existing store unless `--force`.

Open the page from the repo root with the `board-web.sh` beside the wrapper (the wrapper's path is the last line of `/fleet-board:status`):

```bash
bash <directory of that path>/board-web.sh --repo .
```

It binds `127.0.0.1` only and uses `board.port` unless you pass `--port N`. It refuses a board that is not `local`.

- **Cards.** Drag a card to another column, or click it to open the drawer and edit its title, body, labels and state. The state select in the drawer is the keyboard path. A card lights up while a role works on it.
- **Start and Stop.** Start spawns the headless wrapper in its own session, so it keeps running when you close the page. Stop writes `.fleet-board.stop`, which ends the run after the current tick. A restarted page finds a live run again, and a run started from a terminal or launchd counts too: every wrapper holds a per-repo run lock, so Start never launches a second one (see [docs/overnight.md](docs/overnight.md)). The page keeps its state under `~/.fleet-board/web/` (`FLEET_BOARD_LOG_DIR` moves it). `FLEET_BOARD_RUN` replaces the wrapper script.
- **Import.** Paste a plan. The page runs `claude -p` with `/fleet-board:import-plan <plan> --preview`, using `headless.permission_mode` and `limits.max_turns`, and shows the cards it would create. Nothing is created until you press Create, which runs `import-plan.sh` (it prints `Created #N: <title>` for each card). Dependencies in the preview show as `owner/repo#n` using `board.repo`. `FLEET_BOARD_CLAUDE` names a different `claude` binary and `FLEET_BOARD_PLUGIN_DIR` adds `--plugin-dir` to that session.
- **Who you are.** On `local` the author of a note is `FLEET_BOARD_USER`, else `$USER`. Anyone who can write the directory can write a note.
- **Rate limits.** The local board makes no GitHub calls to list columns, read cards and comments, or write notes and reports. PR calls (`gh pr view`, `gh pr list`, pushes) remain, so you can lower `limits.tick_interval` to match your CI time.

## Known issues

- **Unblocking a card re-runs the implementor.** A card moved from Blocked back to Ready goes through `start` again, so the implementor runs once more before review. Its branch and PR are reused, so no work is lost. Planned for 0.1.1.
- **Role prompts name a GitHub command on a local board.** The role prompts give `gh issue view <n> --json body` as an example for re-reading a card. On a local board that reads an unrelated GitHub issue with the same number in `board.repo`. The manager passes the card body inline, so this only happens when a role picks that example.

## Demo

[`docs/demo.cast`](docs/demo.cast) records `tests/behavioral-tick.sh --scenario ready-path` on a sandbox repo: one card goes from Ready to a PR ready for review in four ticks, with all 48 checks passing. Play it with `asciinema play docs/demo.cast`.

## Design

The tradeoffs behind this plugin are written up in [docs/design.md](../../docs/design.md).

## License

MIT
