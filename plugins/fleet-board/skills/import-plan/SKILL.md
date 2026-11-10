---
name: import-plan
description: Use when the user has a spec and one or more implementation plans and wants them turned into fleet-board cards - groups plan tasks into PR-sized cards, infers dependencies across repos, shows a dry-run table, and after confirmation creates the cards in dependency order on the local board. Invoke as /fleet-board:import-plan <spec> <plan...> [--status ready] [--preview <file>].
user-invocable: true
---

# fleet-board: import-plan

Turns a spec plus per-repo plans into board cards. You do the reading and grouping;
`import-plan.sh` does the mechanical part (dependency order, real card numbers, state). It
writes each card's acceptance and blockers into the card's `acceptance` and `blocked_by`
fields. Never create cards yourself, with `gh` or by writing files.

## Locating the script

```
<this skill's base directory>/../../scripts/import-plan.sh
```

Substitute the real base directory announced when the skill loaded.

## Step 1: Read the inputs

Read the spec and every plan named in the arguments. Note each plan's repo (`owner/repo`).
`--status ready` in the arguments is passed through; the default is Backlog. `--preview <file>`
in the arguments makes the run stop after the dry run (see Step 3).

Read each plan whatever its shape. `import-plan.sh parse` is an optional shortcut, not a
requirement: it applies only to plans with `## Task N: <title>` headings and `Files:` /
`Test steps:` blocks. For any other plan layout, group the tasks yourself and copy the
test steps verbatim as acceptance.

## Step 2: Group tasks into cards

Group plan tasks into PR-sized cards (one reviewable PR each). For each card write:

- `key`: a short unique id, `title`, `repo`, `labels`.
- `why`: the problem, from the spec.
- `scope`: bullets from the tasks' Interfaces and files.
- `acceptance`: one testable behavior per bullet, from the tasks' test steps and exact
  values. Give plain text; the script adds the `- `.
- `produces` and `consumes`: the interface names from the tasks' Interfaces
  (Produces/Consumes). Use identical spelling for the same interface in both places, also
  across repos. The script infers each card's blockers (`blocked_by`) from them. Use `depends_on` (card keys or
  `owner/repo#N`) only for a dependency no interface shows.

Write `{"cards": [...]}` to a file in the system temp directory (create it with `mktemp`).

## Step 3: Dry run

```bash
bash <scripts>/import-plan.sh <cards file> --dry-run
```

Show the user the table (title, repo, depends on, labels). Fix the cards file and rerun
if a dependency or title is wrong. Nothing is created in this step.

With `--preview <file>`, copy the cards file to `<file>` after a clean dry run, print the table,
and stop: do not run Step 4, do not ask.

## Step 4: Confirm and create

Ask the user whether to create the cards. Only on a yes, run:

```bash
echo y | bash <scripts>/import-plan.sh <cards file> [--status ready]
```

On no, run nothing. Report the `Created #N: <title>` lines the script prints. Before the table the script lints every card (the same rules as `/fleet-board:lint`) and
creates nothing while one fails: fix the card in the cards file and rerun. A failure
(cycle, unknown dependency, lint) exits 1 with the reason; relay it.


If a card's Why or Acceptance names a `.md` doc that is missing on the default branch,
the script lists the docs and asks: `[m]` commit and merge the docs first, or `[e]` embed
the section into the card. Ask the user which, then pipe both answers
(`printf 'y\ne\n' | ...`). `m` (or no answer) creates nothing and exits 1; `e` replaces the
reference with the section text from the working tree. Role worktrees branch from the
default branch, so a card must never point at a file that is not there.
