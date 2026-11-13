# fleet-board

[![tests](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml/badge.svg)](https://github.com/drothschild/fleet-board/actions/workflows/tests.yml)

fleet-board is a Claude Code plugin that runs a team of AI coding agents from a kanban board.

You write cards on a local board page. Each card has a title and a list of testable acceptance items. A supervisor you
start from the command line works through the board. For each card it:

- has one agent, in its own git worktree and branch, write failing tests first, then make them pass and open a pull
  request;
- has a second agent review that PR on evidence;
- has a third agent fix what the review found.

Optionally, it also merges the PR and runs your deploy. You decide what goes on the board and what needs your eyes. The
agents do the rest, and hooks stop them from skipping a step.

## What it does

- **A board in your repo.** Cards are small files under `.fleet-board/`, kept out of git, and shown on a local web page.
  Columns:

  ```
  Backlog → Ready → In Progress → In Review → [review stages] → Merging → Done
                        ↘ Blocked      ↘ Blocked               ↘ Human QA → Done
  ```

  Human QA is where a card waits for you to check it by hand. Merging is used only with `merge.policy: auto`. You move
  cards from Backlog to Ready, and out of Human QA. Everything else moves on its own.
- **Extra review stages.** You can add your own stages after the main review, such as security, UX or performance. Each
  stage runs its own agent or a model from another provider, and can be limited to the files it cares about.
- **Follow-up cards.** When an agent working on one card finds a bug or work outside that card, the supervisor files
  it as a new card, in Ready by default so the fleet picks it up. Set `followups.status: backlog` to triage them
  yourself first. A follow-up that matches an open card is added to that card as a comment instead.
- **Evidence-based review.** The reviewer does not take the implementor's word for anything. It:
  - maps every acceptance item to a test;
  - breaks the code on purpose (mutation testing) to prove the tests catch it;
  - re-runs one of the implementor's claims itself;
  - checks that no existing test was weakened.

  Findings go to a fixer. Review and fix rounds repeat until the review is clean or the card is blocked. Each blocked
  card gets a comment saying why.
- **Optional merges and deploys.** With `merge.policy: auto`, a card with a clean review, green checks, a non-draft PR
  and no Human QA need is merged for you, one at a time per repository.

  After the merge, a **merger** agent follows a short persona file you can write in plain English. A typical persona says to
  deploy the API and the web client, then check that the health URL answers.

  The merger can retry a refused merge once, send a merge conflict back for a fix, or stop and wait for you. It never
  loosens a merge rule. The only way to merge past a known-flaky check is a dated entry in your config.
- **A supervisor.** One `fleet-board supervisor start` process per repository runs the board:
  - it plans each card's next step and runs several cards at once, up to the limits you set;
  - it keeps two cards from editing the same files at the same time;
  - it backs off when a provider is rate-limited.

  Stop it, and it either finishes the work in flight or cancels it cleanly.
- **Crash recovery.** If a run dies part-way through, the next `start` lists every card left half done and
  refuses to start until each one is resolved. The board page shows those cards with a red border and a **STUCK**
  label. One command returns a card to its last stable column, without touching its branch or pull request.
- **Token accounting.** Every agent session's tokens go into a ledger in your repo. The board page shows:
  - tokens for this run, all time, and the planning chat, each counted separately;
  - a total at the top of each column;
  - for each card, a breakdown by column and by action.

  A token budget pauses the supervisor when it is reached. Cache reads are shown but don't count toward the budget.
- **Guardrails enforced by hooks.** A hook checks every shell command an agent runs. It blocks:
  - moving a card out of Human QA;
  - any merge under `merge.policy: human`;
  - merging a draft PR, a PR with red or pending checks, or one with unreviewed commits;
  - moving a card to Ready without acceptance items.

  It is a text check with known blind spots ([docs/gates.md](plugins/fleet-board/docs/gates.md)); keep branch
  protection on as the backstop. Agents are also told never to force-push or rewrite history.
- **Planning help.** A chat on the board page drafts cards with you. `/fleet-board:import-plan` turns a written plan
  into PR-sized cards. It works out the dependencies between them and shows you a preview before it creates anything.

## Install

Tell Claude Code:

> Go to https://github.com/drothschild/fleet-board and follow the install directions.

Claude does the rest. The one step it can't do for you is logging in to GitHub, if you have never run `gh auth login`.

To install by hand instead, run these in Claude Code and start a new session:

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

**Requirements:**
- Claude Code 2.1 or later.
- `git` (from the Xcode Command Line Tools on macOS) and `jq` (ships with macOS 15 and later).
- `python3` 3.9 or later. It needs only the standard library.
- `gh`, logged in with the `repo` scope. The pull requests live on GitHub.

### Install directions for Claude

Follow these steps in order, running each command with your shell tool. fleet-board needs only `git`, `jq`, `python3`
and `gh`; do not install anything else.

1. **Check the tools.** Run `git --version`, `jq --version`, `python3 --version` and `gh --version`. For each one missing:
   - with Homebrew (`command -v brew` succeeds), run `brew install <tool>` yourself;
   - otherwise give the user the install command for their system (for example `sudo apt-get install -y <tool>`),
     since it needs their password, and wait for them.
2. **Install the plugin:**

   ```bash
   claude plugin marketplace add drothschild/fleet-board
   claude plugin install fleet-board@fleet-board
   ```

   If the marketplace is already added, run `claude plugin marketplace update fleet-board` and continue.
3. **Put the `fleet-board` command on the PATH.** Run the plugin's installer, which copies a small launcher to
   `~/.local/bin/fleet-board`:

   <!-- install-cli-command -->
   ```bash
   jq -r '.plugins["fleet-board@fleet-board"] // [] | if type == "array" then . else [.] end | map(select(.version and .installPath)) | sort_by((.version | tostring | split("-")[0] | split(".") | (. + ["0", "0", "0"])[:3] | map(tonumber? // 0)) + [if (.version | tostring | contains("-")) then 0 else 1 end]) | reverse | .[].installPath' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" 2>/dev/null | (while IFS= read -r p; do [ -f "$p/scripts/install-cli.sh" ] && exec bash "$p/scripts/install-cli.sh"; done; echo "fleet-board is not installed; run /plugin install fleet-board@fleet-board" >&2; exit 1)
   ```
   <!-- /install-cli-command -->

   It runs `scripts/install-cli.sh` from the newest installed version (a prerelease such as `0.27.1-beta` sorts below
   `0.27.1`).

   If it prints an `export PATH=...` line, add that line to the user's shell profile (`~/.zshrc` or `~/.bashrc`).
4. **Check the GitHub login.** Run `gh auth status`. If it reports no login, ask the user to run `gh auth login` in a
   terminal and choose the browser login. It is interactive, so do not run it yourself. `/fleet-board:init` checks the
   scopes later.
5. **Finish.** Tell the user three things:
   - fleet-board is installed;
   - it loads in a **new** Claude Code session;
   - the next step is to open that session in the repository they want to manage and run `/fleet-board:init`.

## Set up a repository

In a Claude Code session opened in your repository:

1. **Run `/fleet-board:init`.** It creates `.fleet-board.yml` and the local card store, and checks your tools and GitHub
   scopes. Confirm the commands it proposes. The one that matters most is `commands.test_one`, which runs a single test
   file, for example `npx vitest run {file}` or `pytest {file}`.
2. **Commit and push `.fleet-board.yml`** to your default branch. Agents work in worktrees cut from it.
3. **Check that `main` is green**, and that `worktrees.setup` (`npm ci`, `uv sync`, ...) works in a fresh worktree. A
   test that already fails, or a setup that only works in your own checkout, will trip every card.

To merge automatically, set `merge.policy: auto`. To deploy after a merge, write `.fleet-board/merger.md`; the next
section shows how.

## Run it

`/fleet-board:init` also installs the `fleet-board` command in `~/.local/bin` (`FLEET_BOARD_BIN_DIR` moves it). It runs
the plugin's newest installed version, so plugin updates never break it. To pin one version, or to run a checkout of
this repository, set `FLEET_BOARD_PLUGIN_ROOT` to that plugin directory; `fleet-board path` prints the one in use.

**Already set up?** If the repository was set up before the command existed, re-run `/fleet-board:init` (it installs the
command even when it refuses the existing config), or install it from a terminal:

<!-- install-cli-command -->
```bash
jq -r '.plugins["fleet-board@fleet-board"] // [] | if type == "array" then . else [.] end | map(select(.version and .installPath)) | sort_by((.version | tostring | split("-")[0] | split(".") | (. + ["0", "0", "0"])[:3] | map(tonumber? // 0)) + [if (.version | tostring | contains("-")) then 0 else 1 end]) | reverse | .[].installPath' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" 2>/dev/null | (while IFS= read -r p; do [ -f "$p/scripts/install-cli.sh" ] && exec bash "$p/scripts/install-cli.sh"; done; echo "fleet-board is not installed; run /plugin install fleet-board@fleet-board" >&2; exit 1)
```
<!-- /install-cli-command -->

**1. Open the board page.** In a terminal in your repository:

```bash
fleet-board board
```

The page is served at http://127.0.0.1:8765 (`board.port`); keep this command running.

**2. Write a card.** Give it a title, a short body and testable acceptance items, one behavior per item. For example:

> **Bump the API version**
> Bump the API package version from 0.0.0 to 0.1.0.
> - `node -p "require('./apps/server/package.json').version"` prints `0.1.0`

Put checks that need a person ("looks right on a phone") under a `## Human QA` heading in the body, not in the
acceptance list, and add the `needs-human-qa` label so the card stops in Human QA before its PR is merged.
Move the card to **Ready**.

**3. Start the supervisor.** Press **Start** on the board page, or run it from a terminal anywhere in the repository (it
runs from the repo root, in the main checkout even from a worktree):

```bash
fleet-board supervisor start            # in the foreground; Ctrl-C cancels cleanly
fleet-board supervisor start --detach   # in the background, logging to ~/.fleet-board/runs/supervisor.log
```

**4. Watch it move.** The card goes to In Progress, then In Review. By default (`merge.policy: human`) it then waits
for you: in Human QA if it needs a person, otherwise in In Review with its PR marked ready. Merge the PR and the card
moves to Done. Under `merge.policy: auto` it goes through Merging to Done instead. Its drawer shows each agent's report
and the tokens it used.

**5. Control it.**

| Command | What it does |
|---|---|
| `fleet-board supervisor status` | what's running, and on which cards |
| `fleet-board supervisor pause` / `resume` | stop starting new work / start again |
| `fleet-board supervisor stop --drain` | finish the work in flight, then exit |
| `fleet-board supervisor stop --cancel` | end every agent session after a short grace period (a merge in progress finishes), return each card to its column, then exit |
| `fleet-board supervisor usage [--card N]` | tokens for this run and all time, or one card's breakdown |
| `fleet-board supervisor stuck [--release N]` | list the cards a crashed run left half done, or return one to its column |

The board page has the same Start, Pause, Resume and Stop buttons.

### Deploying after a merge

`.fleet-board/merger.md` is plain English. It lists the steps the merger runs after a merge and how it should judge a
refused merge. For example:

```markdown
## After a merge
1. Fetch `origin`, and check the PR's merge commit is on `main`.
2. In a fresh detached worktree of `origin/main`, run `deploy/deploy.sh`.
3. Check that `curl -fsS https://example.internal/api/health` prints `{"ok":true}`.
Stop at the first failure and report `attention`.

## When a merge is refused
A conflict: report `fix`. A pending check: report `retry`. Anything else: report `attention`.
```

When an after-merge step fails, the card waits in Merging with the merger's report until you decide. If `main` fails
its check after a merge, the supervisor pauses. To skip a known flaky check until a date, add an entry to `merge.ignore_checks` in `.fleet-board.yml` with a reason; the persona can't
do this.

## Configuration

Everything lives in `.fleet-board.yml`. Set only what differs from the defaults. The keys most projects touch:

| Key | Default | What it does |
|---|---|---|
| `commands.test_one` | none | runs one test file; `{file}` is replaced by its path |
| `commands.typecheck` | none | run by the agents, and on `main` after a merge |
| `commands.lint` | none | run by the agents |
| `worktrees.setup` | none | run once in each new worktree, for example `npm ci` |
| `merge.policy` | `human` | `auto` merges clean, green PRs for you |
| `merge.ignore_checks` | `[]` | dated, reasoned exceptions for flaky checks |
| `review.stages` | `[]` | extra review stages after the main review |
| `review.max_rounds` | `3` | review/fix rounds before a card is blocked |
| `followups.status` | `ready` | where follow-up cards are filed (`ready` or `backlog`) |
| `human_qa_paths` | `[]` | globs whose changes always go to Human QA (for example `deploy/**`) |
| `models.implementor` / `reviewer` / `fixer` / `merger` | `sonnet` / `opus` / `sonnet` / `sonnet` | the model each role runs on |
| `limits.concurrency` | `6` | agent sessions running at once |
| `limits.max_tokens` | `20000000` | the token budget for one run, cache reads excluded |
| `limits.max_hours` | `8` | wall-clock budget for one run |

The full reference, including providers and per-stage settings, is in [docs/config.md](plugins/fleet-board/docs/config.md).

## More

- [Plugin README](plugins/fleet-board/README.md): writing good cards, dependencies between cards, review stages, moving
  an existing GitHub-issue board over, and upgrading.
- [Design](docs/design.md): the decisions behind the board, the gates and the review process, and the alternatives
  considered.

MIT licensed.
