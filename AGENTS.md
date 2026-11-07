# AGENTS.md

Instructions for coding agents other than Claude Code (Codex and others) working in this
repository. The rules are the same for every agent; they live in the Claude files below, so
read them rather than relying on this summary.

## Read first

1. `CLAUDE.md` (repo root): structure, plugin conventions, git rules, testing, shell
   portability.
2. `plugins/fleet-board/CLAUDE.md`: the fleet-board plugin's contracts, including the
   clean-room rule. Read it before changing anything under `plugins/fleet-board/`.

## Rules that are easy to miss

- Never commit on `main`; work on a branch. Never `git push --force`.
- `plugins/fleet-board/agents/*.md` and `plugins/fleet-board/skills/{reporting,tick,run,status}/SKILL.md`
  are clean-room files. Never edit them by hand. Changing one means editing its spec under
  `docs/implementation-plans/2026-09-28-fleet-board/specs/` and an isolated re-author run;
  stop and ask a person before that step, since it spends API money.
- Scripts must run under macOS `/bin/bash` 3.2 with BSD and GNU tools: no bash 4 features,
  `sed -i.bak` (never bare `sed -i`), `unset CDPATH` before a captured `cd`.
- Tests are plain-bash suites: `bash plugins/fleet-board/tests/test-<name>.sh`. Run only the
  suite you touched, then `bash plugins/fleet-board/tests/test-clean-room.sh`. Do not run
  `behavioral-*.sh`; they cost money and run only when a person asks.
- Write the failing test first, see it fail, then implement.

## Plans

Implementation plans are in `docs/superpowers/plans/`, each with its design spec in
`docs/superpowers/specs/`. Read both. Work a plan task by task, in order, ticking each
step's checkbox in the plan file as you finish it, and commit after each task.

Current plan: `docs/superpowers/plans/2026-11-06-codex-evidence-reviewer.md`
(spec: `docs/superpowers/specs/2026-11-06-codex-evidence-reviewer-design.md`).
