---
name: qa
description: Use when the user runs /fleet-board:qa or asks to rebuild a card for human QA or file QA feedback, such as "rebuild card 12 for QA", "build the PR for QA" or "file my QA notes as cards". Builds the card's PR head merged with its base in a detached worktree, prints the QA checks, built commit and build exit status, then files each piece of feedback as a Backlog card. Invoke as /fleet-board:qa <card>.
user-invocable: true
---

# fleet-board: qa

Helps a person run human QA on a card. It rebuilds the card's PR the way the supervisor does
when the card goes to Human QA, and files the feedback the person gives as new cards. It never
moves the QA card.

## Steps

1. **Read the card and its PR.** Run `board-read.sh <card>` from the scripts directory (the last
   line of `/fleet-board:status` names it). Find the PR with `gh pr list --head <branch> --json
   number,headRefName,baseRefName,headRefOid`. Stop and say so when the card has no PR.
2. **Create a detached worktree.** Fetch the remote, then
   `git worktree add --detach <dir> <PR head commit>` under the configured `worktrees.dir`, and
   merge the PR's base branch (`origin/<baseRefName>`) into it with `git merge --no-edit`. On a
   merge conflict, stop, report it and leave the worktree for the person to inspect.
3. **Build.** Run `commands.qa_build` from `.fleet-board.yml` in that worktree. When it is not
   set, say so and skip the build. Record its exit status.
4. **Print.** Show the card's QA checks (the `## Human QA` section of the card body, or the
   acceptance items when there is none), the built commit (`git rev-parse HEAD` in the worktree)
   and the build's exit status.
5. **File feedback.** For each piece of feedback the person gives, write the body to a file made
   with `mktemp`, then run
   `board-create.sh "<title>" <body-file> --blocked-by <card>`.
   The new card lands in Backlog, blocked by the QA card. Print each `Created #N` line.

## Rules

- Never move the QA card or any other card; the person or the supervisor does that.
- File one card per piece of feedback; do not batch or merge items.
- Do not push, open or merge a PR from the QA worktree.
