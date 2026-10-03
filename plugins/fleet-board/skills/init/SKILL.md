---
name: init
description: Use when the user wants to set up fleet-board in a repository - asks which board backend to use, writes .fleet-board.yml, creates the fleet:* labels or verifies the GitHub Projects Status options, and checks gh scopes. Invoke as /fleet-board:init.
user-invocable: true
---

# fleet-board: init

Sets up fleet-board in the current repository. You gather the answers; `init.sh` does all
the work. Never write `.fleet-board.yml` yourself, not even to fix it up afterwards. Only
`init.sh` writes it, because it validates the file and sets up the board first.

## Locating the script

The Skill tool announced this skill's base directory when it loaded. The script is at:

```
<this skill's base directory>/../../scripts/init.sh
```

Substitute the real base directory. Do not guess an install path.

## Step 1: Detect the repository

Run:

```bash
gh repo view --json nameWithOwner -q .nameWithOwner
```

This is the `--repo` value. If it fails, ask the user for `OWNER/NAME`.

## Step 2: Choose the backend

Ask the user which board to use:

- **Labels** (`github-labels`): a new board. fleet-board creates one `fleet:<state>` label
  per state.
- **Projects v2** (`github-projects`): an existing GitHub project board.

If they choose Projects v2:

1. Ask for the project number and its owner. The owner defaults to the repo owner.
   Always pass `--project <N>`; init.sh refuses Projects without it. Pass
   `--owner <OWNER>` only when the project's owner differs from the repo owner (for
   example, an organization project for a personal repo).
2. Show the project's Status options:
   ```bash
   gh project field-list <N> --owner <OWNER> --format json \
     | jq -r '.fields[] | select(.name == "Status") | .options[].name'
   ```
3. Ask how each canonical state maps to a column. The canonical states are `backlog`, `ready`,
   `in_progress`, `in_review`, `human_qa`, `blocked`, `done` and `wont_do`. Their default
   column names are `Backlog`, `Ready`, `In Progress`, `In Review`, `Human QA`, `Blocked`,
   `Done` and `Won't Do`. Default each state to the option with exactly that name. For every
   state whose column has a different name, pass `--state <canonical>=<Column name>`.

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
bash "<this skill's base directory>/../../scripts/init.sh" \
  --backend <github-labels|github-projects> --repo <OWNER/NAME> [flags...]
```

Map each answer to exactly one flag. Leave a flag out when the user gave no answer for
it, so the default applies:

| Answer | Flag |
|---|---|
| Backend | `--backend github-labels` or `--backend github-projects` |
| Repository | `--repo <OWNER/NAME>` |
| Project number (Projects only, required) | `--project <N>` |
| Project owner, when it is not the repo owner | `--owner <OWNER>` |
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

- If the user has already confirmed replacing an existing `.fleet-board.yml`, add `--force`.
  Otherwise, when init.sh refuses because the file exists, ask before re-running with
  `--force`.
- Exit 2 is a usage error. Fix the flags and run it again.

## Step 6: Missing scopes

If init.sh exits 1 and prints `Run: gh auth refresh -s ...`, tell the user to run exactly
that command, then stop. Do not run it for them, and do not work around it.

For any other exit 1, show the message and help the user fix its cause, such as a
missing Status option. Then run init.sh again.

## Step 7: On success

Show the written `.fleet-board.yml`, and suggest committing it:

```bash
git add .fleet-board.yml && git commit -m "chore: add fleet-board config"
```
