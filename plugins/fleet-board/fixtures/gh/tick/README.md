# tick-plan fixtures

One directory per `test-tick-plan.sh` scenario. Each holds a `routes` file for
`tests/fake-gh.sh` and, when the card has a manager note, the card's comments
(`comments-<n>.json`, the note by `fleet-bot`). Fixture paths in a `routes`
file are relative to that file; every `routes` file routes `api user` to
`../../labels/user.json`.

`common/` holds what several scenarios share: board listings
(`list-<state>-<n>.json`), issues (`issue-<n>-<state>.json`), PR views
(`pr-34-*.json`, `pr-41-*.json`) and PR file lists (`files-*.json`).

Worktree paths are never stored in these notes: the normalized worktrees base
depends on the test's temporary repo, so the tests build it at run time.
