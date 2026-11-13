---
name: init
description: Use when the user wants to set up fleet-board in a repository - writes .fleet-board.yml, creates the local card store (.fleet-board/, kept out of git) and checks that gh is logged in with the repo scope; it can then move an existing GitHub board onto the store. Invoke as /fleet-board:init.
user-invocable: true
---

# fleet-board: init

Sets up fleet-board in the current repository. You gather the answers; `init.sh` does all
the work. Never write `.fleet-board.yml` yourself, not even to fix it up afterwards. Only
`init.sh` writes it, because it validates the file and sets up the card store first.

The board is always local: cards are files under `.fleet-board/` in this repo, shown by
the board page. GitHub is still where the PRs live, so `gh` must be logged in with the
`repo` scope.

## Locating the scripts

The Skill tool announced this skill's base directory when it loaded. The scripts are at:

```
<this skill's base directory>/../../scripts/init.sh
<this skill's base directory>/../../scripts/import-github.sh
```

Substitute the real base directory. Do not guess an install path.

## Step 1: Detect the repository

Run:

```bash
gh repo view --json nameWithOwner -q .nameWithOwner
```

This is the `--repo` value. If it fails, ask the user for `OWNER/NAME`.

## Step 2: Column names

The canonical states are `backlog`, `ready`, `in_progress`, `in_review`, `human_qa`,
`blocked`, `done` and `wont_do`. Their default column names are `Backlog`, `Ready`,
`In Progress`, `In Review`, `Human QA`, `Blocked`, `Done` and `Won't Do`. Ask whether the
user wants a different name for any column; for each, pass
`--state <canonical>=<Column name>`. When they are moving an existing GitHub Projects
board (Step 8), offer that board's column names, so the import maps each column.

## Step 3: Propose commands

Read the repository and propose commands, then let the user confirm or edit each one:

- If `package.json` exists, take its scripts: `test` for `--test-one` (with `{file}` where
  the single test file goes), `lint` for `--lint`, and `typecheck` or a `tsc` script for
  `--typecheck`.
- Otherwise, ask the user for each command.

Leave out any command the user does not want; the defaults then apply.

## Step 4: Human QA paths and merge policy

- Ask which paths need a human to look at the result, such as UI code. Pass one
  `--human-qa-path <glob>` for each.
- Ask for the merge policy: `human` (the default) or `auto`. Pass `--merge <policy>`.

## Step 5: Run init.sh

Run it from the repository root, with the flags gathered above:

```bash
bash "<this skill's base directory>/../../scripts/init.sh" --repo <OWNER/NAME> [flags...]
```

Map each answer to exactly one flag. Leave a flag out when the user gave no answer for
it, so the default applies:

| Answer | Flag |
|---|---|
| Repository | `--repo <OWNER/NAME>` |
| Each state whose column name differs from the default | `--state <canonical>=<Column name>`, once per state |
| Single-test command | `--test-one "<cmd with {file}>"` |
| Typecheck command | `--typecheck "<cmd>"` |
| Lint command | `--lint "<cmd>"` |
| Build for human QA | `--qa-build "<cmd>"` |
| Worktrees directory | `--worktrees-dir <dir>` |
| Worktree setup command | `--setup "<cmd>"` |
| Each path needing human QA | `--human-qa-path "<glob>"`, once per path |
| Merge policy | `--merge human` or `--merge auto` |
| The user confirmed replacing an existing `.fleet-board.yml` | `--force` |

Give each `--state` key once, with a non-empty column name; init.sh rejects a repeated key
or an empty name. Never pass `--force` unless the user has confirmed the overwrite.

Show its output to the user verbatim.

init.sh also installs the `fleet-board` command in `~/.local/bin` (or `FLEET_BOARD_BIN_DIR`),
even when it refuses an existing config, so the user can run `fleet-board board` and
`fleet-board supervisor ...` from the repo. Its messages are on stderr and never change the
exit code. If they include an `export PATH=...` line, tell the user to add it to their shell
profile; if init says the command was not installed, show the `install-cli.sh` command it names.

- If the user has already confirmed replacing an existing `.fleet-board.yml`, add `--force`.
  Otherwise, when init.sh refuses because the file exists, ask before re-running with
  `--force`.
- Exit 2 is a usage error. Fix the flags and run it again.

## Step 6: Missing scopes

If init.sh exits 1 and prints `Run: gh auth refresh -s ...`, tell the user to run exactly
that command, then stop. Do not run it for them, and do not work around it.

For any other exit 1, show the message and help the user fix its cause, such as a
missing tool (`gh`, `jq` or `git`). Then run init.sh again.

## Step 7: On success

Show the written `.fleet-board.yml`, and suggest committing it:

```bash
git add .fleet-board.yml && git commit -m "chore: add fleet-board config"
```

## Step 8: Moving an existing GitHub board (optional)

Ask whether the repo already has a fleet-board board on GitHub (`fleet:<state>` labels, or
a Projects v2 board). If it does, `import-github.sh` copies it into the new store. It only
reads GitHub; it writes nothing there. Run it from the repository root, first with
`--dry-run` and show the user the lines it prints:

```bash
bash "<this skill's base directory>/../../scripts/import-github.sh" --repo <OWNER/NAME> --dry-run
```

For a Projects board add `--project <N>`, and `--owner <OWNER>` when the project's owner is
not the repo owner. When the user agrees, run it again without `--dry-run`. It refuses a
store that already has cards; pass `--force` only when the user confirms overwriting the
imported numbers. An exit 1 naming a project column means that column has no state in
this config: add it with `--state` (re-run init.sh with `--force`) or as a review stage,
then import again.
