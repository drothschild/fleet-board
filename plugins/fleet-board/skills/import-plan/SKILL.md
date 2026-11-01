---
name: import-plan
description: Use when the user has a spec and one or more implementation plans and wants them turned into fleet-board cards - groups plan tasks into PR-sized cards, infers dependencies across repos, shows a dry-run table, and after confirmation creates the issues in dependency order on the project. Invoke as /fleet-board:import-plan <spec> <plan...> [--status ready].
user-invocable: true
---

# fleet-board: import-plan

Turns a spec plus per-repo plans into board cards. You do the reading and grouping;
`import-plan.sh` does the mechanical part (dependency order, real issue numbers, project
and status). Never create issues yourself with `gh issue create`.

## Locating the script

```
<this skill's base directory>/../../scripts/import-plan.sh
```

Substitute the real base directory announced when the skill loaded.

## Step 1: Read the inputs

Read the spec and every plan named in the arguments. Note each plan's repo (`owner/repo`).
`--status ready` in the arguments is passed through; the default is Backlog.

## Step 2: Group tasks into cards

Group plan tasks into PR-sized cards (one reviewable PR each). For each card write:

- `key`: a short unique id, `title`, `repo`, `labels`.
- `why`: the problem, from the spec.
- `scope`: bullets from the tasks' Interfaces and files.
- `acceptance`: one testable behavior per bullet, from the tasks' test steps and exact
  values. Give plain text; the script adds the `- `.
- `produces` and `consumes`: the interface names from the tasks' Interfaces
  (Produces/Consumes). Use identical spelling for the same interface in both places, also
  across repos. The script infers `## Depends on` from them. Use `depends_on` (card keys or
  `owner/repo#N`) only for a dependency no interface shows.

Write `{"cards": [...]}` to a file in the system temp directory (create it with `mktemp`).

## Step 3: Dry run

```bash
bash <scripts>/import-plan.sh <cards file> --dry-run
```

Show the user the table (title, repo, depends on, labels). Fix the cards file and rerun
if a dependency or title is wrong. Nothing is created in this step.

## Step 4: Confirm and create

Ask the user whether to create the cards. Only on a yes, run:

```bash
echo y | bash <scripts>/import-plan.sh <cards file> [--status ready]
```

On no, run nothing. Report the `Created owner/repo#N` lines the script prints. A failure
(cycle, unknown dependency, missing project option) exits 1 with the reason; relay it.
