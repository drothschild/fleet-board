# Evidence: command-line supervisor, end to end on HMB Workout Server

Phase 7.1 of `docs/superpowers/plans/2026-11-11-cli-supervisor.md`. On 2026-11-12, one card went from Ready to merged to
deployed with no tick system involved.

## Setup

- Repository: `drothschild/HMBWorkoutServer`. The local board has `merge.policy: auto` and `human_qa_paths: ["deploy/**"]`.
- fleet-board plugin 0.25.3, installed from the marketplace. The supervisor was started from the installed plugin:
  `supervisor.sh start --detach`, pid 25584, at 2026-11-12T19:46:51Z.
- Merger persona: `.fleet-board/merger.md`. It is untracked and local to that checkout. Approved by the owner.
  - After a merge it fetches both repositories and checks the PR merged into `main`.
  - It deploys from fresh detached worktrees of the server and `HMBWorkoutWebClient`.
  - The deploy command is `deploy/nas/deploy.sh <client>`: it builds the client locally, ships both to the QNAP NAS and
    rebuilds the API image there.
  - It verifies `GET /api/v1/health` returns `{"ok":true}` and `GET /` returns 200, then removes the worktrees.
- Only one card was in Ready, and the startup check found no stuck cards.

## The card

Card 50, "Small Fix for Test". Body: bump the API package version from 0.0.0 to 0.1.0. Acceptance: `node -p
"require('./apps/server/package.json').version"` prints `0.1.0`, and `packages/shared/package.json` stays at `0.5.0`.

PR: drothschild/HMBWorkoutServer#56, squash-merged at 2026-11-12T19:53:17Z as `e9368594f347d9d5126c47982bce6c970633f5a6`.
CI check `check` passed (5m16s).

## Actions

From `supervisor usage --card 50 --json`. Token counts are input / output / cache write / cache read.

| Ledger column | Action | Role | Model | Tokens (in / out / cache w / cache r) | Started → ended (UTC) |
|---|---|---|---|---|---|
| ready | start | implementor | claude-sonnet-5-5 | 24 / 3,369 / 24,936 / 242,388 | 19:46:55 → 19:48:00 |
| in_progress | start_review | reviewer | claude-opus-5-5 | 18 / 4,151 / 29,373 / 204,457 | 19:48:04 → 19:49:15 |
| merging | after_merge | merger | claude-sonnet-5-5 | 14 / 2,119 / 15,191 / 80,285 | 19:53:31 → 19:54:04 |
| merging | after_merge | merger | claude-sonnet-5-5 | 18 / 2,474 / 12,223 / 121,115 | 20:17:34 → 20:19:42 |

The first two rows are recorded one column early. That is Defect 2 below; the work ran in `in_progress` and `in_review`.

Total: **742,155 tokens**. Of these, 74 were input, 12,113 output, 81,723 cache write and 648,245 cache read. No usage was
unknown. The planner used 0 tokens.

- **Implementor:** wrote `apps/server/tests/package-version.test.ts` first, committing it at `b107d48`. On the old
  version the test showed 1 failing and 1 passing. The passing one was the guard that the shared package stays at 0.5.0.
  The implementation commit `887650d` made both pass. Typecheck passed.
- **Reviewer:** clean in round 1.
  - The touched test passes at head `887650d`.
  - It killed one mutant: the version was reverted to 0.0.0 and the test went red.
  - The shared package was unchanged from the merge base.
- **Merge:** the merge lane merged the PR once checks were green. The merged commit is on `origin/main`.
- **Deploy:** the merger's second run deployed in about 80 s. It deployed server `e9368594` and client `9cb79dd5`.
  - Health returned `{"ok":true}` and `/` returned 200.
  - It removed its worktrees.
  - The card moved to Done.
- **Stop:** `supervisor stop --drain` exited cleanly.

## What needed a person

1. Card setup. The owner wrote card 50 and moved it to Ready; the gate keeps that a human step. The first draft of the
   card targeted the web client repo and had a body and acceptance that contradicted each other. It was rewritten before
   the run.
2. The plugin update from 0.19.0 to 0.25.3, approved by the owner.
3. **Defect 1, the merger persona (fixed outside the plugin).**
   - What happened: step 2 of the persona checked that the PR's *head* commit was an ancestor of `origin/main`. HMB
     squash-merges, so that commit is never on `main`. The merger correctly reported `attention` at 19:53:58 and the
     card waited in Merging.
   - Fix: the persona now checks `gh pr view --json state,mergeCommit` and the merge commit's ancestry. The attention was
     cleared with `note.sh merge 50 {"merger": null}`, the documented way out, and the next cycle deployed.
   - The supervisor did what it was meant to: a merger `attention` held the card and nothing else was deployed.

## Defects found

- **Defect 1:** the persona's squash-merge check, described above. It was project configuration, not plugin code, and
  is fixed in the persona.
- **Defect 2:** the ledger `column` was the card's state before the action moved it. Implementor tokens landed under
  Ready and reviewer tokens under In Progress, so the column totals and the drill-down were off by one column. Fixed
  test-first in this PR; the action's column is now the column the card is in while the role works.

## Notes

- The deploy needs the owner's Mac awake, on the LAN, with `gh` logged in. The client build reads a private package.
- The card's worktree `.worktrees/50-small-fix-for-test` stays after Done, as before. `/fleet-board:status` flags it.
