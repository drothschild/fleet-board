# Card fields and a local-only board: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every card carries `pr_url`, `acceptance` and `blocked_by` as first-class fields in its JSON file, and the local store is the only board. The `github-labels` and `github-projects` backends are removed.

**Architecture:** The card file becomes the schema: `acceptance` is a list of strings, `blocked_by` a list of card numbers, `pr_url` a GitHub PR URL or null. The body is free prose and no longer carries `## Acceptance` or `## Depends on`. Every script reads the fields through `board-read.sh`. GitHub stays only as the home of PRs (`gh pr ...`, pushes); no script touches GitHub issues, labels or projects.

**Tech Stack:** bash 3.2 + jq, Python 3.9 stdlib (server), vanilla JS (page), plain-bash suites; clean-room re-authoring with `claude -p --bare` for the role prompts.

**Supersedes:** the earlier draft of this file (render-into-body, GitHub kept). **Updates:** `docs/superpowers/specs/2026-11-06-local-board-design.md` (Task 8).

## Decisions taken in this plan (confirm before execution)

1. **The board is local only.** `board.backend` and `board.project_number`, `board.project_owner` go away; `config.sh` rejects them with a message pointing at the migration. `board.repo` stays: it is where PRs live.
2. **`blocked_by` holds card numbers on this board only.** Cross-repo refs (`owner/other#n`) have no home once there is no GitHub board to look them up on. The migration keeps such refs as text in a `## Blocked outside this board` body section and warns; `deps.sh` ignores them. Multi-repo plans import into one board.
3. **The role prompts are re-authored, not rendered around.** The implementor, reviewer, fixer and manager prompts and the reporting skill read `## Acceptance` from the body and cite `gh issue view <n>` as the way to re-read a card. They are clean-room files, so they change only by editing their behavior specs and re-authoring them in isolated `claude -p --bare` runs. That costs API spend; the memory puts clean-room spend at about $42 so far against a ceiling recorded in the private handoff. Check the ceiling before Task 6.
4. **The body keeps a rendered copy until the prompts are re-authored.** Tasks 1–5 render the fields back into the body on read so the current prompts keep working; Task 7 removes the rendering once Task 6 has landed. This keeps every intermediate commit runnable.
5. **`pr_url` follows the manager note's `pr`.** The manager (clean-room) keeps writing `pr` into its note; the local `note` verb mirrors it into `pr_url`. A person can set or clear it in the drawer; a later note overwrites a hand-set URL only when it names a different PR.
6. **Version 0.15.0.** PR 199 (Codex provider) takes 0.14.0. (Update 2026-11-07: main reached 0.15.1 before this merged, so the branch ships as 0.16.0, 0.17.0 once main shipped its own 0.16.0 (PR 222), and 0.18.0 once main shipped its own 0.17.0 (PR 228); Task 8's "both manifests at 0.15.0" reads 0.16.0.)

## Global constraints

- `/bin/bash` 3.2 portable: no bash 4 features, `sed -i.bak` only, `unset CDPATH` before a captured `cd`, `LC_ALL=C` for decimal awk.
- Every card write goes through `fl_write_card` under `fb_lock`; JSON built with `jq --arg/--argjson/--rawfile`.
- Clean-room files change only by re-authoring (Task 6); `tests/test-clean-room.sh` passes after every task, with the manifest updated in the same commit as a re-author.
- Plain-bash suites with a `gh` stub that exits 99 for every non-PR subcommand; each new case proven able to fail.
- The gate hook keeps G1 (nothing leaves Human QA), G2 (merge policy) and G3 (Ready needs acceptance), reading the fields.

## Review focus

1. A migrated body with two `## Acceptance` headings, or one inside a code fence, splits the way `fb_has_acceptance` reads it today (first real heading wins); test in Task 1.
2. `blocked_by` naming a card that does not exist, or the card itself, is refused on write (exit 2) rather than leaving a card waiting forever; test in Task 1.
3. A cycle (`#5` blocked by `#6`, `#6` by `#5`) is reported by `deps.sh check` and `status.sh`, not looped on; test in Task 3.
4. The gate refuses a move to Ready for a card whose `acceptance` is `[]` whatever its body says; test in Task 3.
5. After Task 4 nothing under `scripts/` or `hooks/` calls `gh issue`, `gh label`, `gh project` or GraphQL, except the read-only importer `scripts/import-github.sh`; a grep test in Task 4 pins it.

---

### Task 1: Card schema, split and render helpers, migration

**Files:** `scripts/adapters/local/local-lib.sh`, `create.sh`, `edit.sh`, `read.sh`, new `scripts/migrate-card-fields.sh`, `tests/test-board-local.sh`

**Produces:**
- Card file keys added: `acceptance` (array of strings), `blocked_by` (array of integers), `pr_url` (string or null), `pr_url_source` (`"note"`, `"person"` or null).
- `fl_split_body <body-file>` → `{"body", "acceptance", "blocked_by", "outside"}`: removes the first `## Acceptance` and `## Depends on` sections outside code fences; bullets with `- ` stripped and trimmed; `#n` and `<board.repo>#n` refs become numbers, other refs go to `outside`.
- `fl_render_body <card-file>` → the body with `## Acceptance` and `## Depends on` re-inserted from the fields (transitional; removed in Task 7).
- `board-read.sh <n>` output gains `acceptance`, `blocked_by`, `pr_url`.
- `create.sh` and `edit.sh` take the fields: `create.sh <title> <body-file> [--label L]... [--state S] [--acceptance-file F] [--blocked-by N]...`; `edit.sh <n> --title-file F --body-file F --acceptance-file F --blocked-by-json J --pr-url U` with every flag optional. A body passed with the old sections is split.
- `migrate-card-fields.sh [--dry-run]`: rewrites every card file lacking the fields; idempotent; one line per changed card; warns on each `outside` ref.

- [ ] Failing cases first: split and render round-trip byte for byte on a sample body; review-focus cases 1 and 2; create with `--acceptance-file` and `--blocked-by`; edit of one field leaves the others; migration of two old cards (one with a note holding `pr`) and a second run that changes nothing.
- [ ] Implement; run `test-board-local.sh`, `test-board-web.sh`, `test-gate.sh`, `test-card-lint.sh`; commit.
- [ ] Run the migration on this repo's store with `--dry-run`, then for real; report the warnings.

### Task 2: pr_url from the manager note

**Files:** `scripts/adapters/local/note.sh`, `tests/test-board-local.sh`

- [ ] Failing cases: a note with `"pr": 41` sets `pr_url` to `https://github.com/<board.repo>/pull/41`, source `note`; a later `"pr": 42` updates it; `"pr": null` clears a `note`-sourced URL and keeps a `person`-sourced one; a hand-set URL is replaced by a note naming a different PR.
- [ ] Implement under the existing lock; an unparsable note leaves the fields and warns. Commit.

### Task 3: Readers switch to the fields

**Files:** `scripts/board-lib.sh` (`fb_has_acceptance` reads `.acceptance` from `board-read.sh` output), `adapters/local/move.sh`, `hooks/gate.sh` (G3), `scripts/card-lint.sh` (lint the `acceptance` items; `manual-check` rule unchanged), `scripts/deps.sh` (`parse` reads `blocked_by`; `check` reads local card states; cycles reported), `scripts/tick-plan.sh` (wait on `blocked_by`), `scripts/status.sh` (dependency graph from `blocked_by`), `scripts/lint.sh`, `scripts/human-qa-handoff.sh`, their suites.

- [ ] Failing cases per reader, including review-focus cases 3 and 4; then implement; run each touched suite; commit.

### Task 4: Writers produce fields; remove the GitHub backends

**Files:** `scripts/import-plan.sh` (cards file `acceptance` and `depends_on` go straight into fields; no labels/projects branches), `scripts/file-followups.sh` and `scripts/verify-main.sh` (create with fields; drop the GitHub branches), `scripts/review-stages.sh` (route and setup local only), `scripts/init.sh` (local only: no `--backend`, `--project`, `--owner`; still checks `gh` for the `repo` scope), `scripts/config.sh` and `config-defaults.json` (remove backend keys; reject them with a migration hint), `scripts/board-lib.sh` (`fb_default_name` single table), `hooks/gate.sh` (drop the labels/projects branches and the `cards.sh` rules), delete `scripts/adapters/github-labels/`, `scripts/adapters/github-projects/`, `scripts/cards.sh`, `tests/test-board-labels.sh`, `tests/test-board-projects.sh`, `tests/test-cards.sh`; update `tests/fake-gh.sh` users to PR routes only.

- [ ] Add the grep test (review-focus 5) and failing config cases first. The grep test exempts exactly one file, `scripts/import-github.sh` (below).
- [ ] Remove and rewrite; run every suite once; commit in two commits (writers, then removal).

**Read-only GitHub importer (user decision, added during execution).** With the backends gone, nothing could read an existing GitHub board any more, so moving another repo's board onto the local store would be impossible. Keep one read-only importer:

- `scripts/import-github.sh --repo OWNER/NAME [--project N [--owner LOGIN]] [--dry-run] [--force]`, run from the target repo root (its `.fleet-board.yml` already `local`). It lists every issue (open and closed) with its comments through `gh` (labels board: state from the `fleet:<state>` label; `--project`: state from the item's Status column mapped through the same default names the removed Projects adapter used, `Review: <stage>` included), keeps each issue number as the card number, and writes cards in the new shape: `acceptance` and `blocked_by` split from the body with `fl_split_body`, `pr_url` from the manager note's `pr` (source `note`), the manager-note comment re-authored to the local login as `migrate-to-local.sh` does today.
- It writes only to the local store, never to GitHub: every `gh` call it makes is a read (`gh issue list`, `gh api ... /comments` GET, `gh project item-list`). It refuses (exit 1) when the store already has cards unless `--force`; validates everything before writing; prints one line per card; `--dry-run` prints the same lines and writes nothing.
- It replaces `scripts/migrate-to-local.sh` and `tests/test-migrate-to-local.sh`, which only worked on JSON saved by the removed backends; delete both and move their still-relevant cases (numbers kept, note re-authored, `next` set, refusal without `--force`) into `tests/test-import-github.sh`.
- `tests/test-import-github.sh`: fake `gh` with fixtures for a labels board and a Projects board (reuse `fixtures/gh/labels` and `fixtures/gh/projects` where they fit), asserting the written cards' fields, states, numbers, note author, `next`, `--dry-run` writing nothing, and that the fake logs no write verb (`issue edit|create|comment|close`, `label create`, `project item-edit|item-add`, any `-X POST|PATCH|PUT|DELETE`).
- README (Task 8): a "Moving an existing GitHub board" paragraph pointing at this script.

### Task 5: Server and page

**Files:** `scripts/board-web.py`, `scripts/board-web/static/board.js`, `index.html`, `board.css`, `tests/test-board-web.sh`

- [ ] API: summaries gain `pr_url`, `acceptance_count`, `blocked_by` and `blocked` (true when any blocker is not done); `GET /api/cards/<n>` returns the three fields; `PATCH` accepts `acceptance` (array of strings), `blocked_by` (array of card numbers, validated as in Task 1) and `pr_url` (`https://github.com/<board.repo>/pull/<n>` or null; else 400).
- [ ] Page: the drawer shows Acceptance as an editable list, Blocked by as card chips with an add box that accepts `#n`, and a PR field; the body editor shows prose only; card faces show `blocked by #n` in amber when a blocker is open, and the PR link.
- [ ] Failing API cases first; verify the page by hand on a scratch board and replace the drawer screenshot; run the suite twice; commit.

### Task 6: Re-author the role prompts (clean-room)

**Files:** behavior specs and briefs under `docs/implementation-plans/2026-09-28-fleet-board/specs/` for implementor, reviewer, fixer, manager and reporting; then the re-authored `agents/{implementor,reviewer,fixer,manager}.md` and `skills/reporting/SKILL.md`; `specs/README.md` (revision entry) and `clean-room-manifest.txt`.

- [ ] Check the API-spend ceiling and the running total; stop and report if this run would exceed it.
- [ ] Spec changes only: acceptance is `board-read.sh <n> | jq '.acceptance'`, blockers `.blocked_by`, PR `.pr_url`; every `gh issue view <n>` example becomes `board-read.sh <n>`; no other behavior changes.
- [ ] Re-author each file in an isolated `claude -p --bare` run with a fresh `CLAUDE_CONFIG_DIR`, as `specs/README.md` documents; assert on each run's `system/init` event that no user plugin loaded.
- [ ] Update the manifest hashes; run `test-clean-room.sh`, `test-parse-report.sh`, `test-manager-*.sh`; commit with the revision entry.
- [ ] Run one live behavioral scenario (`behavioral-tick.sh --scenario ready-path`) against a sandbox repo on the local backend, only with the user's go-ahead for its spend.

### Task 7: Drop the rendered body sections

**Files:** `adapters/local/local-lib.sh`, `read.sh`, `tests/test-board-local.sh`

- [ ] Failing case: `board-read.sh` body no longer contains `## Acceptance` or `## Depends on`; then remove `fl_render_body` and its calls; run `test-board-local.sh`, `test-gate.sh`, `test-card-lint.sh`, `test-board-web.sh`; commit.

### Task 8: Docs, spec, version

**Files:** spec (store section, adapter table, "Changes elsewhere"), `plugins/fleet-board/CLAUDE.md` (Board adapter contract becomes the local store contract; note trust boundary; card fields), `README.md` (setup is local-only; card fields; migration), `docs/config.md`, `docs/gates.md` (drop labels/projects residuals), `docs/design.md` (a short section on going local-only), `skills/init/SKILL.md`, `skills/import-plan/SKILL.md`, `skills/lint/SKILL.md`, both manifests at 0.15.0.

- [ ] Write; run `test-readme-claims.sh`, `test-version.sh`, `test-clean-room.sh`, and every suite once; push and open the PR.

## Self-review notes

- Ordering keeps each commit runnable: fields arrive (1–2), readers move (3), GitHub goes (4), the page follows (5), the prompts learn the fields (6), and only then does the body stop carrying them (7).
- Every reader of acceptance and dependencies today is in the Task 3 list or the clean-room set of Task 6; every non-PR `gh` call is in Task 4.
- Not in scope: changing the manager note's shape beyond mirroring `pr`; moving other note fields onto the card.
