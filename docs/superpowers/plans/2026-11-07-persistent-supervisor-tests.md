# Persistent Supervisor Test Requirements

**Design:** [Persistent Jobs and Supervisor](../specs/2026-11-07-persistent-supervisor-design.md)

**Implementation plan:** [Persistent Supervisor](2026-11-07-persistent-supervisor.md)

**Status:** Requirements only. No runtime tests, paid behavioral runs, service installation, or reboot rehearsals have been performed for this document. All implementation and validation gates remain pending.

## Execution and evidence rules

Follow the implementation plan's test-first sequence. For each task, demonstrate the named new cases failing for the intended missing behavior, commit the tests, implement, then run the same focused suite. Use plain-bash entrypoints with standard-library Python fixture drivers. Run only the suite changed in that implementation slice; run `bash plugins/fleet-board/tests/test-clean-room.sh` after plugin changes. Do not run the full suite.

Every suite below is invoked as `bash <exact path>`. Existing suites are extended in isolated task slices; new suites are created by the cited plan task. Fake providers must reject accidental live calls. Missing required dependencies, a failed server launch, or skipped required scenarios are not passing evidence. Use deterministic clocks and synchronization barriers for time and race cases; use real local fake processes for lifetime, identity, signals, and descendant checks.

For each executed case, record the tested commit, case ID, exact command, expected outcome, actual outcome, exit status, and relevant safe artifact paths. Evidence should include durable job/attempt/claim/event snapshots and fake external-call records, not merely log text saying success. Retain failure-injection location and before/after external state for crash cases. Redact credentials; retain uncertain workspaces and pending-QA evidence. The evidence location is chosen per run outside the plugin installation.

## Acceptance coverage index

| Criterion | Automated cases below | Implementation tasks | Additional qualification |
| --- | --- | --- | --- |
| S1 | S1.1-S1.3 | 3.1, 4.2, 5.1 | Production slow/fast workflow in 7.2 |
| S2 | S2.1-S2.3 | 2.1, 2.2, 5.1, 5.2 | Browser/chat closure and reboot in 6.2 |
| S3 | S3.1-S3.4 | 1.2, 2.1, 2.2, 4.1, 4.2 | Production publication interruption in 7.2 |
| S4 | S4.1-S4.4 | 2.2, 3.2, 4.1 | Real-process evidence required offline |
| S5 | S5.1-S5.3 | 1.2, 2.2, 4.3, 5.1, 5.2 | Production interruption retry in 7.2 |
| S6 | S6.1-S6.4 | 1.2, 3.1, 4.2, 5.1 | None beyond integrated qualification |
| S7 | S7.1-S7.4 | 3.2, 4.1, 5.2 | Reservation conflict rehearsal in 7.2 |
| S8 | S8.1-S8.4 | 3.1, 4.1, 4.2, 4.3, 7.1 | Production role contracts in 7.2 |
| S9 | S9.1-S9.5 | 3.1, 5.1, 5.2 | Human visual/keyboard check in 5.2 |
| S10 | S10.1-S10.4 | 1.1, 1.2, 5.1, 6.1, 6.2 | Actual supported-host reboot in 6.2 |
| S11 | S11.1-S11.4 | 1.1, 1.2, 3.1, 4.2, 4.3, 5.1, 5.2 | Provider usage observations in 7.2 |
| S12 | S12.1-S12.4 | 5.1, 6.1, 6.2, 7.1, 7.2 | Host, provenance, independent review gates |

## S1 — Independent progress

**Suites:** `plugins/fleet-board/tests/test-supervisor-scheduler.sh`, `plugins/fleet-board/tests/test-supervisor-integration.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`.

- **S1.1 (Task 3.1):** Hold A behind a controlled worker barrier; complete disjoint B while C is ready. B's result is reconciled and C receives a claimed attempt before A is released. Evidence: ordered event sequence and A's still-live process identity; no elapsed-time guess.
- **S1.2 (Task 4.2):** Let B progress through review, merge, and successful main verification while A remains held. Evidence: one merge call bound to B's reviewed head, literal verification success, B terminal state, and A still active.
- **S1.3 (Task 5.1):** Issue CLI reconciliation with active workers and inject a slow planner/effect. Reconcile returns a bounded snapshot/cursor; health and cancellation remain responsive. Evidence: request completions while worker/planner barriers are still held; no wait-for-all report dependency.

## S2 — Process independence and adoption

**Suites:** `plugins/fleet-board/tests/test-supervisor-runner.sh`, `plugins/fleet-board/tests/test-supervisor-recovery.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`, `plugins/fleet-board/tests/test-supervisor-web.sh`.

- **S2.1 (Task 2.1):** Exit the launching parent and later kill the supervisor; the detached runner continues. Evidence: same attempt nonce and process-start identity, one provider invocation, continued result publication. Its inherited descriptors cannot keep the old supervisor ownership lock held.
- **S2.2 (Tasks 2.2, 5.1):** Restart with live matching attempts in each operating mode. Adopt monitoring without a second dispatch and restore claims/accounting. Evidence: identical attempt IDs and invocation count; paused/stopped state forbids admission.
- **S2.3 (Task 5.2):** Close the client, stop/restart the board server, and reconnect. Workers continue, durable active indicators remain, and the UI reads the same attempts. Evidence: service/worker records and HTTP snapshots before and after server restart.

## S3 — Crash boundaries and effect recovery

**Suites:** `plugins/fleet-board/tests/test-supervisor-store.sh`, `plugins/fleet-board/tests/test-supervisor-runner.sh`, `plugins/fleet-board/tests/test-supervisor-recovery.sh`, `plugins/fleet-board/tests/test-supervisor-effects.sh`, `plugins/fleet-board/tests/test-supervisor-integration.sh`.

- **S3.1 (Tasks 1.2, 2.1, 2.2):** Inject termination before/after claim/intent commit, runner creation, exclusive registration, receipt persistence, and provider start. Reopen/recover repeatedly. Evidence: zero partial claims, no two executions for one attempt identity, or explicit quarantine where absence cannot be proved.
- **S3.2 (Tasks 2.1, 2.2):** Crash during temporary result write, after durable result publication, and before/after notification and reconciliation. Partial files are ignored; lost notifications are recovered; duplicate notifications do not duplicate effects or usage. Evidence: validated artifact hashes, a single reconciliation/effect record, unchanged known-spend total on replay. Ingest referenced artifacts into durable controller-owned storage before publishing the final result envelope, acknowledging completion, or deleting provider scratch; inject failure during copy/hash verification and remove scratch only after acknowledged ingest. Evidence: recovery can read all required artifacts after scratch deletion; partial ingest remains retryable without falsely reconciled results.
- **S3.3 (Task 4.1):** For every worktree/refresh/publication/PR/report/note/move/follow-up/cleanup adapter, inject a crash before mutation, after mutation but before local acknowledgement, and after observation persistence. Evidence: external observation identifies already-applied effects; uncertain non-idempotent outcomes enter attention instead of blind replay.
- **S3.4 (Tasks 2.2, 4.2):** Deliver an old-generation result and recover a merge whose external success predates its journal update. Evidence: stale result remains retained but cannot mutate; exactly one fake merge invocation; recovery verifies the actual merge commit before releasing the merge lane.

## S4 — Uncertainty fails closed

**Suites:** `plugins/fleet-board/tests/test-supervisor-recovery.sh`, `plugins/fleet-board/tests/test-supervisor-reservations.sh`, `plugins/fleet-board/tests/test-supervisor-effects.sh`.

- **S4.1 (Task 2.2):** Reuse a PID with another start identity; make the process inspector unavailable; supply contradictory launch receipt/lock evidence. Evidence: no adoption by PID alone, no signal to the unrelated process, and no retry or capacity release while ownership is uncertain.
- **S4.2 (Tasks 2.2, 3.2):** Keep a TERM-resistant or escaped descendant alive after the leader exits. Evidence: cancellation escalation is recorded, uncertainty quarantines the attempt, capacity/scope stay held, and its workspace is not reused. A result-ready runner still holds capacity until exit is confirmed.
- **S4.3 (Task 4.1):** Fail fresh board/head/note lookups during reconciliation. Evidence: affected effects remain held, retry/release is refused, and independent cards continue when repository-wide authority remains trustworthy.

- **S4.4 (Task 2.2):** Combine fake time with a real fake worker: send periodic heartbeats without semantic progress, repeat log lines, run a recognized healthy quiet bounded operation, and suppress heartbeats while the matching process remains alive. Evidence: no-progress triggers suspected-stuck inspection; recognized healthy work continues only within its original deadline; heartbeats/log repetition reset neither progress nor absolute-deadline timers; missing heartbeats cause identity/activity inspection, never immediate duplicate dispatch. At the original hard deadline, cancellation follows the normal grace/termination protocol.

## S5 — Exactly one eligible infrastructure retry

**Suites:** `plugins/fleet-board/tests/test-supervisor-store.sh`, `plugins/fleet-board/tests/test-supervisor-recovery.sh`, `plugins/fleet-board/tests/test-supervisor-providers.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`, `plugins/fleet-board/tests/test-supervisor-web.sh`.

- **S5.1 (Tasks 1.2, 2.2):** Interrupt a safely terminated infrastructure attempt; advance fake time through backoff; interrupt its retry; restart repeatedly. Evidence: at most two attempts for the same logical job, retries-used remains one, and the exhausted tombstone prevents replan-based allowance reset.
- **S5.2 (Task 2.2):** Exercise intentional cancel, semantic failure, invalid report, unexplained stall, and ambiguous publication. Evidence: no automatic retry; cancellation preserves allowance, while ambiguity requires attention. A due retry does not launch while card/domain is paused or stopped.
- **S5.3 (Tasks 4.3, 5.1, 5.2):** Exercise bounded provider transport/report retries inside one attempt. Evidence: all subcalls and usage are visible; supervisor classification does not multiply them into unbounded whole-job retries. New input may form a new job; unchanged input cannot evade the exhausted-job record. Exercise the explicit audited resolve/retry command separately from Resume: require human authority, current revision, safe termination, reconciled effects and a stated reason before granting a new execution opportunity; stale/unsafe resolution leaves the job held and its automatic-retry history intact.

## S6 — Atomic capacity, fairness, and integration lane

**Suites:** `plugins/fleet-board/tests/test-supervisor-store.sh`, `plugins/fleet-board/tests/test-supervisor-scheduler.sh`, `plugins/fleet-board/tests/test-supervisor-integration.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`.

- **S6.1 (Tasks 1.2, 3.1):** Race independent admission requests/connections for the last global slot, provider slot, and one card. Evidence: committed claims never exceed any applicable cap, and failed claims leave no partial scope or attempt state.
- **S6.2 (Task 3.1):** Lower global/provider limits below current occupancy and saturate execution with verification/build attempts. Evidence: healthy work continues, no additional claim is admitted until permitted, and control/result recording remains available through its separate bounded pool.
- **S6.3 (Task 3.1):** Maintain review and explicit high-priority arrivals while a normal/low-priority eligible card ages; restart/replan and place a scope-blocked card ahead of a fitting candidate. Evidence: persisted eligibility sequence drives promotion across the full scheduling rank, including explicit priority, so sustained high-priority arrivals cannot starve older eligible work; deterministic ties and conflict bypass never violate scope.
- **S6.4 (Tasks 4.2, 5.1):** Present two merge candidates and concurrent control requests. Evidence: one repository merge/verification chain at a time; pending verification is recovered before the next merge, including across restarts and linked-worktree clients.

## S7 — Scope lifecycle and explicit human override

**Suites:** `plugins/fleet-board/tests/test-scope-reservations.sh`, `plugins/fleet-board/tests/test-supervisor-reservations.sh`, `plugins/fleet-board/tests/test-supervisor-effects.sh`, `plugins/fleet-board/tests/test-supervisor-web.sh`.

- **S7.1 (Task 3.2):** Transition a card through review, fix, CI wait, Human QA, retry delay, and pause. Evidence: its reservation union persists through every state/restart; omitted later paths do not shrink ownership; terminal verified completion safely releases it. Cover directory boundaries, repository-root scope, traversal, symlink escape, and incomplete PR-file lists.
- **S7.2 (Task 3.2):** Race expansions into the same path and deny one expansion. Evidence: only the holder may write; denied worker checkpoints/exits without retry penalty, releases capacity, retains old scope, and exposes its blocker. Cyclic waits surface attention. Providers without enforceable scoped writes receive repository-wide ownership; detected unauthorized changes cannot publish.
- **S7.3 (Tasks 3.2, 5.2):** Attempt release while running, with a survivor, pending effect/merge, stale revision, or non-human authority; then release a safely paused card. Evidence: unsafe calls fail with no claim changes; successful release records actor, reason, revision, exact paths and time. Supply a forged actor field and a worker-originated human-override request; the trusted control boundary rejects spoofed identity and derives audit identity from authenticated local authority, never request-body claims.
- **S7.4 (Tasks 3.2, 4.1, 5.2):** Resume a released card after overlapping work merges. Evidence: reacquisition precedes refresh; a conflict holds the card; successful refresh changes input revision and invalidates affected review/test evidence before dispatch. Human QA stays authoritative and requires its normal acceptance path.

## S8 — Existing workflow gates remain effective

**Suites:** `plugins/fleet-board/tests/test-tick-plan.sh`, `plugins/fleet-board/tests/test-supervisor-effects.sh`, `plugins/fleet-board/tests/test-merge-reviewed.sh`, `plugins/fleet-board/tests/test-settle.sh`, `plugins/fleet-board/tests/test-supervisor-integration.sh`, `plugins/fleet-board/tests/test-supervisor-providers.sh`, `plugins/fleet-board/tests/test-supervisor-migration.sh`.

- **S8.1 (Tasks 3.1, 4.2):** Compare candidate-mode decisions with existing workflow eligibility; exercise unmet dependencies, routed review stages, changed head and incomplete lookups. Evidence: candidate output preserves the existing gate reasons while supervisor admission owns ordering and durable reservations.
- **S8.2 (Tasks 4.1, 4.2):** Move a card into Human QA during an active attempt; set human merge policy or non-green/draft PR; move the head after review. Evidence: fresh effect checks prevent advancement/merge, preserving returned evidence and requiring the correct review/acceptance.
- **S8.3 (Task 4.2):** Return `ok: false`, absent `ok`, or `ok: "true"` from main verification; separately return literal `ok: true`. Evidence: only the boolean true enables completion/release; failure holds integration, closes admissions, and preserves recovery evidence.
- **S8.4 (Tasks 4.1, 4.3, 7.1):** Attempt worker-side publication and migrate existing approved/reviewed state. Evidence: controller owns credentials and journaled mutations through board adapters; worker output cannot forge authority, approved state is not silently weakened, and migration launches no duplicate completed work. Negative tests run under the real host-enforced boundary and attempt reads/writes of the controller database, socket, board storage, credential files and ambient authenticated tools; every forbidden access fails. Environment filtering or prompt instructions alone are not passing evidence; unavailable isolation blocks production admission.

## S9 — Lifecycle controls and truthful monitoring

**Suites:** `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`, `plugins/fleet-board/tests/test-board-web.sh`, `plugins/fleet-board/tests/test-supervisor-web.sh`, `plugins/fleet-board/tests/test-board-unknown-interaction.sh`, `plugins/fleet-board/tests/test-board-web-atomic.sh`, `plugins/fleet-board/tests/test-supervisor-scheduler.sh` (run individually for their corresponding change slices).

- **S9.1 (Task 5.1):** Repeat/race Start with the same and different command IDs; pause and resume; drain-stop and cancel-stop; crash during each transition. Evidence: durable commands have one outcome, one owner exists, pause closes dispatch/new merges but records results, drain waits only for current attempts, and cancel confirms termination or reports unresolved shutdown.
- **S9.2 (Task 5.2):** Hold service readiness, sever its socket, and return stale revisions. Evidence: spawn acknowledgement is not shown as Running; unreachable differs from Stopped; unsafe controls are disabled or rejected with an actionable reason.
- **S9.3 (Task 5.2):** Disconnect/reconnect event polling, replay a cursor, expire a cursor, and deliver duplicate commands. Evidence: stable ordered history, bounded replay, snapshot recovery after expiration, and no repeated effects. Test all routes with CSRF/Host enforcement and reject arbitrary log paths.
- **S9.4 (Task 5.2):** Render structured capacity, spend/unknown-spend, heartbeat, semantic progress, wait reasons, attempt/retry history, reserved paths and release audit. Evidence: HTTP snapshots expose the correct fields; manual keyboard/narrow-layout review confirms usable controls without relying on source-string assertions.

- **S9.5 (Tasks 3.1, 5.2; current-main compatibility at `db52f9f`):** Preserve PR #200 unknown-state visibility/repair while supervisor status changes: `known: false` cards remain visible, drawer edits preserve the original state until explicitly repaired, scheduler admission does not normalize/dispatch them, and unresolved execution reservations remain held. Preserve PR #207 oversized-request rejection/silent-client timeout, corrupt-card errors, temp cleanup, per-import concurrency/atomic metadata, created-card status, private run-file modes, actual server-port URLs and cached legacy log behavior. Evidence: existing DOM interaction and atomic-import suites remain valid, plus focused API/scheduler cases exercising supervisor-active and unreachable conditions. Import metadata rename is not evidence of result-artifact power-loss durability; retain Task 2.1's separate flush/hash/publication cases.

## S10 — Boot setting and durable operating intent

**Suites:** `plugins/fleet-board/tests/test-config.sh`, `plugins/fleet-board/tests/test-supervisor-store.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`, `plugins/fleet-board/tests/test-supervisor-boot.sh`.

- **S10.1 (Task 1.1):** Omit supervisor configuration, set boot true/false explicitly, and pass invalid nested/boolean values. Evidence: normalized `start_on_boot` is true by default, false is preserved, invalid configuration fails before work, and rollout `enabled` stays false until authorized cutover.
- **S10.2 (Tasks 1.2, 5.1):** Restart in running/paused/stopped states with used retry/time/spend allowances. Evidence: identical session/accounting records; Resume does not reset allowances; explicit Start after an ended session is the only new allowance interval.
- **S10.3 (Task 6.1):** Simulate same-boot crash versus changed host boot identity; change YAML from true to false after service registration. Evidence: boot reads current YAML, false suppresses automatic activation, paused/stopped are not converted to running, and manual Start remains available.
- **S10.4 (Task 6.2, human host gate):** Repeat the running/paused/stopped and false cases through an actual reboot on each claimed supported service mode. Evidence: pre/post boot identity, OS service logs, desired state/session/attempt records, and whether execution occurred before login. Login-agent evidence must not be labeled pre-login boot recovery.

## S11 — Limits and failures do not freeze control

**Suites:** `plugins/fleet-board/tests/test-config.sh`, `plugins/fleet-board/tests/test-supervisor-store.sh`, `plugins/fleet-board/tests/test-supervisor-scheduler.sh`, `plugins/fleet-board/tests/test-supervisor-integration.sh`, `plugins/fleet-board/tests/test-supervisor-providers.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`, `plugins/fleet-board/tests/test-supervisor-web.sh`.

- **S11.1 (Tasks 1.1, 3.1, 5.1):** Advance fake time past deadline while a worker/planner hangs; reach the known cost cap. Evidence: admissions close without waiting for completion, cancellation follows grace/termination rules, and status/control still responds.
- **S11.2 (Tasks 1.2, 4.3, 5.1, 5.2):** Return missing usage, repeated usage records, and delayed final charges. Evidence: unknown stays unknown rather than zero, new paid admission stops pending resolution, repeated records do not double count, and actual overshoot is visible. Resume alone cannot clear unknown usage or attention. Exercise the explicit human resolve command with audit identity, reason, revision and supplied evidence; preserve original unknown-usage records, reject unsupported/stale reconciliation, and reopen admission only under the documented safe resolution policy.
- **S11.3 (Tasks 1.1, 3.1):** Reload invalid config, provider caps, timeout relationships, and missing credentials. Evidence: no partial config application/new unsafe dispatch; prior active work is reconciled and the error/config revision is visible.
- **S11.4 (Tasks 3.1, 4.2, 5.1):** Hold a control effect/planner, exhaust rate-limit wait allowance, or fail repository-wide main verification. Evidence: bounded operations and independent timers remain responsive; appropriate admissions/merge gates close while existing results are preserved.

## S12 — Migration, service ownership, and qualification

**Suites:** `plugins/fleet-board/tests/test-run.sh`, `plugins/fleet-board/tests/test-supervisor-lifecycle.sh`, `plugins/fleet-board/tests/test-supervisor-boot.sh`, `plugins/fleet-board/tests/test-supervisor-migration.sh`, `plugins/fleet-board/tests/test-clean-room.sh`.

- **S12.1 (Task 5.1):** Race legacy/new launchers and linked-worktree clients; recover stale ownership; keep the old owner alive but unhealthy. Evidence: one owner under shared exclusion, no lease-only takeover, no duplicate schedulers for a common repository/board identity.
- **S12.2 (Tasks 6.1, 7.1):** Exercise installation path spaces, missing stable runtime/repository/credentials, protocol incompatibility, backup/schema migration interruption, legacy active workers, unknown survivors, and rollback with unsettled effects. Evidence: actionable diagnostics and retained state, deterministic resume, and refusal to roll back while writers/effects remain unsafe.
- **S12.3 (Task 7.2, paid authoring gate):** Re-author affected clean-room primitives through the existing isolated provenance workflow after explicit approval; run integrity checks. Evidence: changed source specs, exact generated-file hashes/manifest, fresh configuration and session initialization record, recorded budget/use. Text integrity alone does not prove behavior.
- **S12.4 (Tasks 6.2, 7.2, host/behavioral gates):** Complete actual supported-host lifecycle checks and separately authorized production-provider scenarios; obtain independent current-head review. Evidence: exact commits/providers, commands and outcomes, review summary, resolved findings, and explicit pass/pending status for every acceptance criterion before default cutover.

## Human and paid execution gates

| Gate | Why automation alone is insufficient | Required authorization/evidence |
| --- | --- | --- |
| UI usability, Task 5.2 | API assertions do not establish visual clarity or keyboard usability | Inspect desktop/narrow layouts, control labels, Stop menu, waiting/error/unreachable states with fake workers; record observations/screenshots |
| OS installation/reboot, Task 6.2 | Generated service files cannot prove real startup ordering, credentials, or pre-login execution | Explicit approval for the rendered service and host interruption; run the S10.4 matrix and retain uninstall/restore evidence |
| Clean-room authoring, Task 7.2 | Repository rules require isolated re-authoring, which incurs usage | Explicit approval for exact inputs, command and budget before execution; retain provenance and integrity-check results |
| Production behavior, Task 7.2 | Fake providers cannot establish real role/transport behavior | Separately authorize each scenario and spend; execute one at a time; retain slow/fast progress, interrupted publication, one retry, scope conflict, and stop/reboot evidence |
| Release/default cutover | An incomplete gate cannot be represented as completed acceptance | Independent current-head review and all required evidence; no default enablement with unresolved required cases |

No pending gate blocks writing these documents or implementing offline cases. It does block claiming final rollout qualification. Service installation, reboot, paid runs, and merge are not authorized by this documentation task.

## Completion record

At implementation time, append a per-case evidence index or link a durable run report here. Keep pending/failed cases visible. Do not replace requirements with a blanket “tests pass” statement. Current completion state: **Phase 1 configuration and durable-store subsets pass; end-to-end runtime cases and host/paid qualification gates remain pending**.


### Phase 1 evidence — PR #228

Configuration at `61d4a69`: `bash plugins/fleet-board/tests/test-config.sh` passed 448 assertions (exit 0). The preceding test-only commit `c5b8442` produced 140 failures, including absent supervisor defaults and validation. This covers the configuration portions of S10.1 and S11.3, not service startup or reload behavior.

Store at `08d2bff`: `bash plugins/fleet-board/tests/test-supervisor-store.sh` passed all 30 cases below (exit 0). The Bash entrypoint invokes the standard-library fixture driver; each case asserts persisted state or rejection behavior. Initial tests at `7710d53` failed for the absent store; subsequent regression commits preceded their fixes. Most recently, `934dd93` reproduced missing schema-constraint rejection (three failures and one error); `08d2bff` passed after the fix. Independent spec review reran the same 30 cases and approved this head.

These cases cover only the durable-state portions of S3, S5, S6, S10 and S11. Detached lifetime, safe termination, retry classification, scheduling, scope lifecycle, effect execution, service/UI controls, and production isolation remain unimplemented. No passing store case establishes an end-to-end acceptance criterion.

The case IDs are methods in `plugins/fleet-board/fixtures/supervisor/store_cases.py`; all expected outcomes were observed at `08d2bff`:

| Store case | Outcome |
| --- | --- |
| `test_reopen_retains_domain_state_and_events` | Pass |
| `test_command_replay_does_not_advance_revision` | Pass |
| `test_default_inspector_accepts_real_local_scratch` | Pass |
| `test_concurrent_first_open_creates_one_store` | Pass |
| `test_session_budget_survives_reopen` | Pass |
| `test_concurrent_same_card_admission_is_atomic` | Pass |
| `test_admission_conflict_rolls_back_job_and_event` | Pass |
| `test_result_replay_and_unknown_usage` | Pass |
| `test_rejects_invalid_result_and_preserves_accounting` | Pass |
| `test_result_rejects_symlinked_artifact_root_and_spend_overflow` | Pass |
| `test_stale_result_is_evidence_and_charged_once` | Pass |
| `test_capacity_and_nonoverlap_across_connections` | Pass |
| `test_admission_rejects_missing_session_and_unsafe_nonce` | Pass |
| `test_conflicts_are_checked_after_revision_refresh` | Pass |
| `test_desired_modes_reopen_with_same_budget` | Pass |
| `test_database_rejects_duplicate_job_keys_and_attempt_nonces` | Pass |
| `test_duplicate_nonce_does_not_leave_partial_job` | Pass |
| `test_injected_failure_rolls_back_partial_admission` | Pass |
| `test_scope_rejects_symlink_escape` | Pass |
| `test_effect_observation_is_durable_and_unique` | Pass |
| `test_metadata_and_attempt_lifecycle_survive_reopen` | Pass |
| `test_unsafe_runtime_directories_are_rejected` | Pass |
| `test_populated_unversioned_store_fails_closed` | Pass |
| `test_missing_schema_constraints_fail_closed_without_writes` | Pass |
| `test_corrupt_schema_fails_closed` | Pass |
| `test_racing_capacity_rechecks_after_revision_change` | Pass |
| `test_future_schema_fails_closed_without_modification` | Pass |
| `test_retry_tombstone_and_effect_intent_reopen` | Pass |
| `test_backup_includes_uncheckpointed_commits` | Pass |
| `test_rejects_nonlocal_storage` | Pass |

Integrity: `bash plugins/fleet-board/tests/test-clean-room.sh` passed 118 checks (exit 0) after the schema fix and again after release metadata changes. No generated primitive was edited. Both release manifests now specify `0.17.0`; `bash plugins/fleet-board/tests/test-version-bumped.sh` failed for both unbumped manifests before the change and passed afterward (exit 0). Supervisor execution remains disabled.

Schema 1 is the initial released format. Empty databases initialize transactionally; populated unversioned, corrupt, and unsupported-version databases are rejected. There is no historical supported schema migration to execute. Future registered migrations must use the backup API before changing an existing supported schema.
