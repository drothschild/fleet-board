# Task 3.2 report — persistent scope reservations

## Status

Implemented and locally committed on `feat/supervisor-scheduling`, based on `8f05187`. No push was made, as directed. PR #230 remains untouched.

## Changes

- Persisted scope union in the existing durable event log, including scope reservations created atomically with initial attempt admission. Reservations survive later plans and store reopen; conflicts use normalized, path-boundary-aware paths, traversal and symlink escapes are rejected, and providers without scoped-write enforcement can claim repository-wide ownership.
- Added transactional expansions, wait-cycle attention, audited human release with expected domain/reservation revision checks, paused-mode and no-live-writer/no-pending-effect checks, resume with an injected branch-refresh effect and evidence invalidation, and unauthorized-change publication holds.
- Scheduler admission accepts durable reservations and reports scope waits. Worker adapters checkpoint denied expansions without retry penalty and hold publication for unauthorized writes.
- Candidate tick planning includes Human-QA scope evidence and actual PR file completeness; legacy and settle output remain unchanged.

## TDD evidence

- `test-scope-reservations.sh`: first RED run found the Human-QA candidate missing (the incomplete-file candidate assertion already returned `false`). After adding the Human-QA candidate coverage, the suite passed 21 assertions, 0 failures.
- `test-supervisor-reservations.sh`: initial RED run failed because `Store.reserve_scope` did not exist. Additional RED checks exposed missing attempt-admission persistence (`StopIteration`) and missing denied-expansion checkpoint adapter (`ImportError`). Final run passed 14 tests, 0 failures.
- Candidate `test-tick-plan.sh` first exposed missing Human-QA fake-list routes (494 passed, 10 failed). Test routes now use an isolated temporary copy with absolute fixture paths. Final run passed 504 assertions, 0 failures.

## Verification

- `bash plugins/fleet-board/tests/test-supervisor-reservations.sh` — passed, 14 tests, 0 failures.
- `bash plugins/fleet-board/tests/test-scope-reservations.sh` — passed, 21 assertions, 0 failures.
- `bash plugins/fleet-board/tests/test-tick-plan.sh` — passed, 504 assertions, 0 failures.
- `bash plugins/fleet-board/tests/test-clean-room.sh` — passed, 118 assertions, 0 failures.
- `git diff --check` — passed before implementation commit.

## Commits

- `daf93b6 test: cover candidate human QA scope evidence`
- `9bbbef7 test: specify persistent scope reservations`
- `5637264 test: cover denied scope expansion checkpoint`
- `b62861d test: bind initial attempts to durable scope`
- `905660e feat: persist supervisor scope reservations`

## Concerns

- No end-to-end supervisor controller currently wires store snapshots into scheduler `reservations` or worker callbacks into real runner exit/publication. The task adds and tests those explicit interfaces; production effect orchestration and real branch refresh remain Task 4.1 as specified.
- Push and independent review are deferred by the task guard. `supervisor.enabled` was not changed; card #224 and PR #230 status were not touched.

## Fix round 1 (review `task-3.2-review.md`)

- Test-first commit `187a81d` added the reviewed release, lifecycle, verifier, publication, refresh-restart, and slot-release contracts before implementation. RED command: `bash plugins/fleet-board/tests/test-supervisor-reservations.sh`; the first run failed with 18 expected setup errors because `Store.open` lacked the injected `human_actor_verifier` contract. Later intermediate assertions exposed incorrect test revision expectations and a generic lifecycle error; those were corrected to assert the intended guards.
- Release revision 1 finding was checked against the exact base schema: `effects` includes `card TEXT NOT NULL`; no schema or join change was needed. The pending-effect regression now asserts `ValueError("pending effect")`, and the no-effect release path succeeds.
- Added per-card lifecycle state, transactionally checked at release and worker admission; reservation revision is mandatory and compared exactly. Release requires an injected human capability verifier and fails closed if absent or rejecting; this is an interface contract only, not a claimed service authentication boundary.
- Unauthorized scope changes now durably quarantine active job/attempt state, block publication effect preparation and observation, and put pending effects on hold. Denied expansions checkpoint and invoke an explicit slot-release callback while retaining prior claims.
- Resume records an intent and refresh-pending lifecycle state atomically before invoking the injected effect, then records success or failure. Restart snapshots surface pending cards; attempt admission rejects them. The successful path leaves Human QA workflow state intact.
- Lifecycle persistence now exercises review, CI wait, Human QA, retry wait, pause, and store reopen. Slot-release coverage proves an unrelated card can use the freed execution slot while the denied card's previous reservation remains held.

### Fix-round verification

- `bash plugins/fleet-board/tests/test-supervisor-reservations.sh` — passed, 18 tests, 0 failures.
- `bash plugins/fleet-board/tests/test-scope-reservations.sh` — passed, 21 assertions, 0 failures.
- `bash plugins/fleet-board/tests/test-supervisor-store.sh` — passed, 52 tests, 0 failures.
- `bash plugins/fleet-board/tests/test-clean-room.sh` — passed, 118 assertions, 0 failures.
- `git diff --check` — passed. `test-tick-plan.sh` was not rerun because this fix round did not change it.

Fix-round commits: `187a81d test: close reservation release and resume gaps`; `7f60a12 fix: enforce reservation release and resume guards`.

## Fix round 2 (review `task-3.2-rereview-1.md`)

- Test-first commit `0a097f0` adds `test_missing_legacy_reservation_durably_holds_publication`. RED reproduced against the pre-fix store from that commit in a temporary copy: `FAIL: ...`; `AssertionError: 'active' != 'needs_attention'`; `Ran 19 tests`; `FAILED (failures=1)`; exit 1.
- The missing-reservation branch now writes a durable `scope_violation` through the same `BEGIN IMMEDIATE` transaction used to quarantine active jobs/attempts and block pending publication effects. The event log keeps `_publication_held` effective after reopening; this path does not modify reservation events. Existing unauthorized-path violations use the same transaction helper.
- GREEN: `bash plugins/fleet-board/tests/test-supervisor-reservations.sh` — `Ran 19 tests`; `OK` (0).
- `bash plugins/fleet-board/tests/test-clean-room.sh` — `passed: 118   failed: 0` (0).
- `git diff --check` — passed (0).
- Implementation commit: `fix: persist missing reservation quarantine` (hash reported with this task result).
