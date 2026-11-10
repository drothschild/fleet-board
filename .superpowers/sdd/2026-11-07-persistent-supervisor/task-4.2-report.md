# Task 4.2 evidence report

## Result

Implemented the durable repository merge/verification lane. Existing zero-argument `merge-reviewed.sh` and `settle.sh` contracts remain intact; bounded per-card invocations preserve fresh eligibility and planned-head checks. Merge operations persist their controller key, PR, and planned head before mutation. Recovery inspects that note together with fresh PR/head state, resumes verification without another merge after an observed merge, and releases the durable lease only after literal boolean `ok: true`. Paused or stopped recovery refuses to invoke merge when the PR is still open or evidence is unresolved.

The lane lease is an event-sourced Store record acquired under SQLite `BEGIN IMMEDIATE`; this is the minimal Store extension needed to serialize separate Store/controller instances and survive supervisor restart. The worker uses its own Store connection. Failed or uncertain verification closes admissions and retains the lease. Both plugin manifests were bumped from 0.18.6 to 0.18.7.

## TDD commits

Test-only commits were made before implementation. RED slices covered bounded merge and settle, integration-lane contracts, malformed verification, controller-key/evidence binding, cross-Store lease contention, failed verification fencing, stopped recovery of an open PR, and crash recovery after merge but before verification. The integration fixture also covers two independent Store handles and verify-only recovery of an already merged operation.

Test-only commit sequence: `5207b0b`, `7eaed49`, `f18bd6a`, `2ef1728`, `0188c56`, `c7c2305`, `6596a62`, `f2acf20`, `aa0f0ae`, `5893461`, `ae533ee`, `efc213b`, `eaf4811`, `9f3a5d1`, `5907e4f`, `32c1475`, `fe4932c`.

Implementation commit: `6ea7e6d` (`feat: add durable integration merge lane`).

## Verification

All focused checks passed after implementation:

- `test-merge-reviewed.sh`: 78 passed, 0 failed. Includes post-merge replan/head binding, operation-bound inspection, and crash recovery that verifies once with no second merge.
- `test-settle.sh`: 101 passed, 0 failed.
- `test-supervisor-integration.sh`: 13 tests passed, including cross-Store lease serialization, paused/stopped recovery fencing, and verify-only completion.
- `test-supervisor-store.sh`: 53 tests passed.
- `test-supervisor-effects.sh`: 17 tests passed.
- `test-clean-room.sh`: 118 passed, 0 failed.
- `test-version-bumped.sh`: both manifests confirmed bumped from 0.18.6 to 0.18.7.
- `test-repo-version-guidance-branch-independent.sh`: passed.
- `git diff --check` and `bash -n plugins/fleet-board/scripts/merge-reviewed.sh`: passed.

No provider/API calls, service installs, live board processing, or card mutations were performed. The supervisor remains disabled. The pre-existing uncommitted `progress.md` change was left untouched.
