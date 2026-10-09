# fleet-board

Turns a GitHub issue board into a work queue for a fleet of Claude Code agents. You write cards with an `## Acceptance` section and mark them ready. Each tick, a manager agent moves every open card one step: an implementor writes a failing test first and opens a draft PR, a reviewer checks it on evidence (an Acceptance-to-test map, mutation testing, one re-run claim), and a fixer addresses what the review found. Each role works in its own git worktree. Finished cards land in Human QA or as a PR ready for review, and you do the merge. A hook keeps agents from releasing Human QA, merging when they shouldn't, or starting a card without acceptance criteria.

## Install

```
/plugin marketplace add drothschild/fleet-board
/plugin install fleet-board@fleet-board
```

You need `gh` (logged in, with the `repo` scope, plus `project` for a Projects board), `jq`, `git` and Claude Code 2.1.x. `/fleet-board:init` checks the `gh` scopes and tells you how to add a missing one.

## Adding fleet-board to an existing project

Check these first. Each one stopped a real card when fleet-board was adopted on an existing app.

- **`main` is green.** A test that already fails shows up as noise in every card that touches it.
- **Setup works in a fresh worktree.** Whatever you give as `worktrees.setup` (`npm ci`, `uv sync`, ...) must succeed in a brand-new worktree of `main`, not just your checkout:

  ```bash
  git worktree add /tmp/fb-check origin/HEAD && (cd /tmp/fb-check && npm ci); git worktree remove --force /tmp/fb-check
  ```

  A lockfile out of sync with its manifest, or a dependency on a relative path outside the repo (`file:../lib.tgz`), breaks here.
- **One test file at a time.** `commands.test_one` must take a single test path in place of `{file}`, for example `npm test -- --runTestsByPath {file}` or `pytest {file}`.
- **Pick the board.** **Labels** creates eight `fleet:<state>` labels and `needs-human-qa`, and overwrites the color and description of any existing label with those names. **Projects** uses your existing board: every state needs a column (add a Blocked column first if you have none), and you map names that differ in [`board.states`](docs/config.md#boardstates).
- **Cards already on the board.** The manager acts on every card in Ready, In Progress, In Review and Blocked, including ones that were there before. Run `/fleet-board:status` first, and move work you want to finish by hand back to Backlog.
- **Process docs.** If `AGENTS.md` or `CLAUDE.md` has board, review or merge rules, remove them; the agents read those files and would argue with the manager. Keep the project facts.

Then run `/fleet-board:init`, get `.fleet-board.yml` onto the default branch (role worktrees branch from `origin/HEAD`), move **one** small card to Ready, and run `/fleet-board:tick` until it reaches a ready PR or Human QA.

## On a fresh repo

1. **Create a repo** with a little code and a test runner that can run one test file, and clone it.
2. **Run `/fleet-board:init`** and choose **Labels**. Confirm or edit the commands it proposes; `commands.test_one` matters most, for example `node --test {file}`.
3. **Commit and push `.fleet-board.yml`:**

   ```bash
   git add .fleet-board.yml && git commit -m "chore: add fleet-board config" && git push
   ```

4. **Write one small card**: an issue with an `## Acceptance` section of testable `- ` bullets (see [Writing a card](#writing-a-card)). Add `needs-human-qa` if you want to look before any PR is marked ready.
5. **Label it `fleet:ready`.**
6. **Run `/fleet-board:tick`** a few times, or `/fleet-board:run` to keep going until nothing is left. Each tick ends its report with `dispatchable: true` or `false`.
7. **Watch it move.** With a clean review:

   | After | Card | What you'll see |
   |---|---|---|
   | tick 1 | `fleet:in_progress` | A `fleet/<n>-<slug>` branch, a worktree, and a draft PR whose first commit holds only the failing tests |
   | tick 2 | `fleet:in_review` | The reviewer's report on the card |
   | tick 3 | `fleet:human_qa`, or a ready PR | Human QA with a "What to check" comment, or the PR marked ready for review |
   | tick 4 | unchanged | `dispatchable: false` |

8. **Release Human QA yourself** in the GitHub UI: check the change, merge the PR, and move the card to `fleet:done` (or back to `fleet:ready`). No agent can do this; the gate blocks it.

## The board

```
Backlog → Ready → In Progress → In Review → Human QA → Done
                        ↓             ↓
                     Blocked       Blocked
```

Plus Won't Do. On the labels board a card's state is a `fleet:<state>` label; on a Projects board it is the Status column.

**Who moves what.** You move cards from Backlog to Ready, and out of Human QA. The manager makes every other move. Role agents never move cards; they post reports as comments.

### Writing a card

- **`## Acceptance` lists only what a test can check**, one `- ` bullet per behavior. The reviewer maps each bullet to a test; a bullet with no test is a finding.
- **Put on-device and manual checks under `## Human QA`**, not in Acceptance. No agent can test them, so in Acceptance they only get the card blocked.

**When a card gets blocked.** The manager blocks a card, with a comment saying why, when Critical or Important findings survive `review.max_rounds` rounds, when the implementor produces no PR in that many attempts, or when that many actions in a row make no progress. From round `models.escalate_after_rounds` on, the implementor and fixer run on the reviewer's model.

More on how ticks, notes, follow-ups and the `main` check work: [docs/config.md](docs/config.md#how-the-board-works-in-detail).

## Config

`.fleet-board.yml` lives at the repo root. Set only what differs from the defaults. A list you give (`test_paths`, `human_qa_paths`) replaces the default list.

| Key | Default | What it does |
|---|---|---|
| `board.backend` | `github-labels` | `github-labels` or `github-projects` |
| `board.repo` | none (required) | `owner/name` of the repo the cards live in |
| `board.project_number` | none | the Projects board number; required for `github-projects` |
| `board.project_owner` | `null` | the project's owner, when it isn't the repo owner |
| `board.states` | `{}` | maps a state to your label or column name ([details](docs/config.md#boardstates)) |
| `commands.test_one` | none | runs one test file; `{file}` is replaced by its path |
| `commands.typecheck` | none | run by roles, and on `main` after a merge |
| `commands.lint` | none | run by roles |
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
| `models.manager` / `implementor` / `reviewer` / `fixer` | `sonnet` / `sonnet` / `opus` / `sonnet` | each role's model |
| `models.escalate_after_rounds` | `2` | from this round on, implementor and fixer use `models.reviewer` |
| `limits.concurrency` | `6` | role agents running at once |
| `limits.tick_interval` | `300` | seconds between ticks |
| `limits.max_hours`, `max_cost_usd`, `max_consecutive_failures`, `max_turns` | `8`, `40`, `3`, `200` | headless wrapper limits |
| `headless.permission_mode` | `auto` | `--permission-mode` for each headless tick |

The config file accepts a subset of YAML; see [docs/config.md](docs/config.md#supported-yaml).

## Gates

A `PreToolUse` hook blocks any agent command that would move a card out of Human QA, merge a PR under `merge.policy: human`, or mark a card Ready without `## Acceptance`. It does nothing in repos without `.fleet-board.yml`. It is a text check, so it has blind spots and some false positives; [docs/gates.md](docs/gates.md) lists them, along with how fleet-board behaves alongside your other plugins. Branch protection on GitHub remains the backstop for merges.

## Running overnight

The headless wrapper runs ticks one after another until the board is settled or a limit is reached. Find its path on the last line of `/fleet-board:status`, then from the repo root:

```bash
bash <path from /fleet-board:status> --repo .
```

Stop it gracefully with `touch .fleet-board.stop`, or at once with Ctrl-C. Merges stay with you: an overnight run leaves reviewed PRs for you to merge. Stop reasons, exit codes, the run log, cost estimates and scheduling with launchd are in [docs/overnight.md](docs/overnight.md).

## Known issues

- **Unblocking a card re-runs the implementor.** A card you move from Blocked back to Ready goes through `start` again, so the implementor runs once more before review. Its branch and PR are reused, so no work is lost. Planned for 0.1.1.

## Demo

[`docs/demo.cast`](docs/demo.cast) records `tests/behavioral-tick.sh --scenario ready-path` on a sandbox repo: one card goes from Ready to a PR ready for review in four ticks, with all 48 checks passing. Play it with `asciinema play docs/demo.cast`.

## License

MIT
