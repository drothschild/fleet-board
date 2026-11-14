# Multi-repo board design

Status: spec only. No code changes with this document.

## Why

A board is tied to one repository today. `.fleet-board.yml` has a single `board.repo`, the board
lives inside that repo, cross-repo `owner/repo#N` dependencies are never checked, and the board
page drops another repo's PR. Holding cards from several repos touches config, the store, the
supervisor, the gate and the page, so the decisions are written down before code.

## Decisions

- One home repo holds the board (option A). The board directory, cards and config live there.
- Each card still has one repo and one PR.
- Each card uses its own repo's `merge.policy`, `test_paths`, `commands` and `review.stages`.
- Sessions in another repo get `FLEET_BOARD_HOME`, so board scripts find the home board.
- There is one merge lane for the whole board.

## Config

The home repo's `.fleet-board.yml` gains `board.repos`, a list of the repos the board may hold
cards for. Each entry has a `name` (`owner/repo`) and a `path`.

```yaml
board:
  repo: owner/home
  repos:
    - name: owner/other
      path: /Users/me/Projects/other
```

`board.repos[].path` must be an absolute path. A relative path is rejected when the config is
loaded, with an error naming the entry. There is no `~` or environment expansion and no
resolution against the home repo, so a path means one thing wherever it is read.

A tracked absolute path is machine-specific: it only works on the machine that wrote it. The
repo list therefore belongs in an untracked local override (or must be re-entered per machine),
and a tracked `.fleet-board.yml` should not carry another machine's paths. A missing path on this
machine is reported as a config error for that entry only; cards of other repos keep working.

Per-repo settings are read from the card's own repo (its `.fleet-board.yml` at `path`), not from
the home repo. See Scope.

## Card field

A card gets an optional `repo` field holding an `owner/repo` that appears in `board.repos` (or
the home repo). A card without `repo` belongs to the home repo, so existing boards need no
migration. A card has exactly one repo and one PR. Changing `repo` after work has started is
refused.

Dependencies written as `owner/repo#N` are resolved against the board's repos and checked like
local ones; an unknown repo is a visible error on the card, not a silent pass.

## Supervisor

The supervisor runs once, from the home repo. For a card whose repo is not the home repo it
creates the worktree in that repo's `path`, on the card's branch, and starts the session there.

Sessions in another repo get `FLEET_BOARD_HOME` set to the home root, so `board-read.sh`,
`board-comment.sh` and the other scripts read and write the home board rather than looking for a
board in the working repo. Sessions in the home repo behave as today.

## Scope

Each card uses its own repo's `merge.policy` and other per-repo settings: `test_paths`,
`commands` (`test_one`, `typecheck`, `lint`) and `review.stages`. The implementor, reviewer and
merger receive the config of the card's repo. Board-wide settings stay with the home repo:
`limits`, `supervisor`, `models`, `board.states` and the port.

The card's `Scope` paths are relative to the card's repo. A scope check compares the diff of the
card's PR against that repo's tree only.

## Merge lane

There is one merge lane for the whole board. Merges are serial across all repos, so a card in
one repo can wait behind a card in another. This keeps the lane's invariants (one merge at a
time, no reordering mid-merge) unchanged. Per-repo lanes are a later option, not part of this
design.

## Gate

The gate runs against the card's repo: the PR, the head SHA, the checks and the merge command
all use that repo's `owner/repo`, and the gate applies that repo's `merge.policy`. A repo set to
`manual` holds only its own cards; it does not stop cards of an `auto` repo.

## Board page

The page shows cards from every repo and marks each with its repo. A card's PR link and status
come from the card's repo, so a PR in another repo is shown instead of dropped. Filtering by repo
is a display option only and does not change what the supervisor works on.

## Out of this design

- Several PRs for one card.
- Per-repo merge lanes.
- Relative or expanded `board.repos[].path` values.
