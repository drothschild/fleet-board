# Task 4.2 review-fix report

## Result

Verified and fixed the four current-head review findings. The implementation keeps failed or uncertain merge/verification work fenced, requires fresh exact merged evidence before a standalone verification recovery, rechecks board state before moving a verified card to Done, and enforces the cleanup retention predicate against a fresh Store snapshot. Cleanup ignores its own pending journal row while retaining other unresolved effects as a hold. Both plugin manifests are now 0.18.8, above the local `origin/main` version 0.18.6.

The existing `integration_merge` recovery path still requires matching controller operation key, PR, planned and observed head, and `MERGED` state before running verify-only. Fresh standalone `main_verification` submissions are rejected. A recovery `main_verification` must reference a durable merge intent and pass a fresh external inspection against that exact operation, PR, and head.

## TDD evidence and commits

- Test-only commit: `84406f1` (`test: cover supervisor integration review findings`).
- RED: `test-supervisor-integration.sh` failed 3 new cases: helper failure did not close admissions, unpaired paused/stopped verification was accepted, and the cleanup predicate allowed an active lifecycle. `test-supervisor-effects.sh` observed cleanup execute instead of being held. `test-merge-reviewed.sh` moved cards to Done after mid-flight Human QA and blocked-state changes (2 failures).
- Implementation commit: `1c72744` (`fix: close supervisor integration review gaps`).
- GREEN: `test-supervisor-integration.sh` passed 13/13; `test-supervisor-effects.sh` passed 18/18; `test-merge-reviewed.sh` passed 80/80.

The verification-helper regression was observed RED before the scheduler fix. It pairs the pending verification with a durable merge effect, proves the exact parent operation/PR/head through fresh inspection, then throws from the helper adapter. The existing paused/stopped already-merged `integration_merge` recovery test remains green and confirms verify-only behavior with no second merge.

## Additional required checks

- `test-clean-room.sh`: 118 passed, 0 failed.
- `test-version-bumped.sh`: both manifests confirmed 0.18.8 above 0.18.6.
- `test-repo-version-guidance-branch-independent.sh`: passed.
- `git diff --check` and `bash -n plugins/fleet-board/scripts/merge-reviewed.sh`: passed.
- `test-supervisor-store.sh` was not run because Store code was unchanged.

No provider calls, live board processing, service operations, or card mutations were performed. The supplied `progress.md` modification was preserved. PR readiness was not changed; the branch remains associated with the existing draft PR #237.
