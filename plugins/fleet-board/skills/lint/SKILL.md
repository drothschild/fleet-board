---
name: lint
description: Use when the user runs /fleet-board:lint or asks to check, lint or validate fleet-board cards before moving them to Ready, such as "lint the Ready cards", "is card 12 ready to go", or "check my backlog cards". Reports untestable Acceptance bullets, dependency cycles, unresolved dependencies and missing files, read-only. Invoke as /fleet-board:lint [card...].
user-invocable: true
---

# fleet-board: lint

Checks cards before an agent spends a round on them. It only reads; it never edits a card,
moves one, or files an issue.

## Locating the script

```
<this skill's base directory>/../../scripts/lint.sh
```

Substitute the real base directory announced when the skill loaded. Run it from the user's
repository.

## Method

1. Run `bash <scripts>/lint.sh [card...]`. With no card numbers it lints every Ready and
   Backlog card; with numbers, only those.
2. Relay the output verbatim. Each line is `#<card>: <rule>: <detail>`. No output and exit 0
   means every card passes; exit 1 means at least one failed.
3. Suggest the fix per rule, and leave making it to the user.

`lint.sh` runs `scripts/card-lint.sh` for the base rules (`no-heading`, `no-bullets`,
`manual-check`) and adds:

| Rule | Meaning | Fix |
|---|---|---|
| `untestable-bullet` | an Acceptance bullet says "manual", "visually" or "looks" | rewrite as an assertion a test can make, or move it under `## Human QA` |
| `dependency-cycle` | cards depend on each other; the detail names them | drop one dependency |
| `unresolved-dependency` | a `## Depends on` reference matches no issue | correct the reference |
| `missing-file` | a backticked path is not on the default branch | fix the path (lines that create or add a file are skipped) |

`/fleet-board:import-plan` runs the same linter on its generated cards and refuses to create
any card while one fails.
