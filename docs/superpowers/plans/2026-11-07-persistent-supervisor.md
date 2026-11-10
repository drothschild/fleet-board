# Persistent Supervisor Implementation Plan

**Design:** [Persistent Jobs and Supervisor](../specs/2026-11-07-persistent-supervisor-design.md)

**Goal:** Replace tick-wide waits with independently running durable attempts, completion-driven scheduling, recoverable controller effects, and board lifecycle controls.

**Baseline:** `db52f9f313adf2d6d5cd6c70c793296a13abb679` (revalidated 2026-11-07; originally `28866b0`). All existing paths below were checked against the original baseline and the intervening PR #200/#207 changes. New paths are explicitly marked Create. The prototype on `codex/standalone-profiles` is not merged and is not a prerequisite; do not copy its fixture worker as a production adapter.

**Status:** Phase 1 merged at e4ea2c7. Phase 2 implementation, specification review, and quality review are complete on PR #229 (runtime head 5a815d2). Later phases and boot service remain unimplemented. Supervisor execution remains disabled.

## Current-main impact assessment

PR #200 (`bf5152e`) and PR #207 (`db52f9f`) are merged into this planning branch. They affect board rendering/API and server hardening, not the supervisor architecture, phase ordering, retry policy, boot default, or scope lifecycle. Task 5.2 and acceptance coverage now explicitly preserve their behavior. The persistent supervisor runtime remains incomplete.

Reuse the new DOM interaction harness and atomic-import regression suite rather than recreate them. Preserve per-import concurrency independently from execution scheduling. Do not mistake import metadata's atomic rename helper for the flush-and-publish durability required by Task 2.1.

## Execution rules

1. Read repository `AGENTS.md`, root `CLAUDE.md`, plugin `CLAUDE.md`, and the paired design. Recheck current main before each phase, preserving new upstream work.
2. Create an isolated implementation branch and draft PR before code. Use one reviewable PR per phase, dependent on the preceding merged phase. Keep supervisor disabled by default until Phase 7. Refresh main before starting each dependent phase.
3. For each functionality task below: write the named failing cases first; run only its focused suite and confirm the intended failure; commit the failing tests; implement the stated contract; run that suite to green; run `bash plugins/fleet-board/tests/test-clean-room.sh` after plugin changes; commit implementation and push. Tick each completed step and commit after each task. New tests use plain-bash entrypoints and Python helpers; no new test framework.
4. When a task names several existing suites, make separate test/implementation slices and run only the suite affected by each slice. Never run the full suite. Use fake providers and offline fixtures, never an accidental live CLI/API invocation.
5. An independent reviewer verifies the current PR head and posts a summary on that PR. Resolve findings before advancing. Open the completed PR with `gh pr view --web`. Implementation PRs require appropriate release-version changes in both manifests; this documentation PR does not change plugin behavior/version.
6. Never hand-edit clean-room `agents/*.md` or `skills/{reporting,tick,run,status}/SKILL.md`. Phase 7 explicitly gates paid re-authoring and behavioral runs. OS installation/reboot validation is a separate human execution gate; do not install services while writing this plan.
7. All scripts must retain Bash 3.2 and BSD/GNU portability. Runtime state lives outside the plugin tree. Preserve user changes and pending-QA/recovery artifacts during cleanup.

## Test and implementation conventions

New Python modules form package `plugins/fleet-board/scripts/supervisor/` with `__init__.py`. Execute via `supervisor.sh` with a resolved scripts directory and `python3 -m supervisor.cli`; paths are argv elements, never shell-interpolated command strings. Inject clock, process inspector, provider transport, and effect transport through constructor parameters; production defaults are real implementations, tests pass local fakes explicitly. Test fixture mode must not be discoverable from worker-controlled content or silently replace production isolation.

Plain-bash tests create private `mktemp -d` directories, install cleanup traps, use a fake provider that fails on unintended network invocation, and assert externally observable state/events rather than source text. Deterministic clocks cover long timeouts without sleeping. Real fake subprocess tests cover actual process lifetime and cancellation. Report launch absence, script errors, and unavailable tools as failures for required checks, not green skips.

New fixtures: `plugins/fleet-board/fixtures/supervisor/`. Python fixture drivers are invoked from the focused shell suite and use standard-library assertions. Crash injection points are named protocol boundaries (before/after intent, registration, execution, result persistence, external effect, effect observation) and can only be enabled by the test harness's explicit injected transport.

## Phase 1 — Contracts, configuration, and durable state

### Task 1.1: Validate settings without changing the current launcher

**Modify:** `plugins/fleet-board/scripts/config-defaults.json`; `scripts/config.sh` (default merge near line 110, section validation near 191, limits near 348); `tests/test-config.sh`. All abbreviated plugin paths in this plan are relative to `plugins/fleet-board/`.

**Create:** `fixtures/config/supervisor-default.yml`, `supervisor-disabled-boot.yml`, `supervisor-invalid.yml`.

- [x] Write failing cases for omitted supervisor defaults, boolean boot/enabled flags, integer durations, heartbeat relation, grace/deadline relation, provider cap validation, and rejecting invalid nested types. Preserve ordinary reviewer/provider configuration cases.
- [x] Run `bash plugins/fleet-board/tests/test-config.sh`; confirm new validation/default failures and commit tests.
- [x] Add the design's configuration schema, including rollout `enabled: false` and `start_on_boot: true`. Preserve old limits. Normalize provider identity including built-in `claude`; reject unknown cap keys. No UI/launcher cutover yet.
- [x] Run the focused suite and clean-room check; commit/push.

**Verifies:** S10, S11 configuration subset. Expected normalized config contains the exact defaults; invalid settings fail before provider execution.

### Task 1.2: Create transactional store and state contracts

**Create:** `scripts/supervisor/__init__.py`, `models.py`, `store.py`; `tests/test-supervisor-store.sh`; `fixtures/supervisor/store_cases.py`.

**Interfaces:** `Store.open(domain)`, `prepare_attempt(job, expected_revision, claims)`, `record_result(envelope)`, `record_command(request)`, `append_event(event)`, `snapshot()`, `backup(destination)`. Transactions own expected-revision checks and claims; callers cannot mutate tables directly.

- [x] Write persistence/reopen tests for every design record, desired state and session budgets; uniqueness tests for job key, attempt nonce, operation key and command ID; concurrent claim tests using two independent connections.
- [x] Add failure cases for schema mismatch, invalid paths/results, foreign identity/generation, and transaction rollback leaving no partial claims. Verify unknown usage remains null/unknown and stale results cannot double-charge usage.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-store.sh` to intended failure; commit tests.
- [x] Implement versioned schema, explicit transactions, private runtime directories, WAL/full synchronous settings, local-storage requirement, atomic revision/event writes and SQLite backup API. Make schema migration backup-first and fail closed for future versions.
- [x] Run the focused suite and clean-room check; commit/push.

**Initial schema:** Version 1 is the first supported schema; populated unversioned and future stores fail closed. There are no supported migrations yet; future migrations must use a backup before writing. Report semantics and durable artifact ingestion are runner responsibilities. Scope expansion is Task 3.2.

**Verifies:** S3, S5, S6, S10, S11 durable-state subset. No background service starts in this phase.

## Phase 2 — Independent attempts, recovery, and cancellation

### Task 2.1: Launch runners and publish durable results

**Create:** `scripts/supervisor/processes.py`, `runner.py`, `workers.py`; `tests/test-supervisor-runner.sh`; `fixtures/supervisor/fake_worker.py`, `runner_cases.py`.

**Interfaces:** `ProcessIdentity(boot_id, pid, started_at, nonce)`, `Runner.launch(prepared_attempt)`, `Runner.inspect(identity)`, `Runner.cancel(identity, deadline)`. Runner artifacts use the envelope in the design; provider execution begins only after exclusive attempt registration.

- [x] Write real fake-process cases: parent exits while child continues; supervisor dies before registration acknowledgement; duplicate launch nonce permits one provider invocation; worker writes a result while notification is lost; provider scratch is deleted after durable artifact ingestion but before notification; partial result file is ignored; result appears before process exit and slot stays held.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-runner.sh` to intended failure; commit tests.
- [x] Implement detached runner/process containment, execution lock and receipt, identity registration, heartbeat/progress channels, bounded logs, immutable artifact ingestion with hashes and safe retention, result validation and atomic publication. Close inherited supervisor-lock/socket descriptors. Separate runner heartbeat from provider progress.
- [x] Run the focused suite and clean-room check; commit/push.

**Verifies:** S2-S4 process lifecycle subset. Production provider integration remains disabled.

### Task 2.2: Reconcile interrupted attempts and enforce the retry ceiling

**Create:** `scripts/supervisor/recovery.py`; `tests/test-supervisor-recovery.sh`; `fixtures/supervisor/recovery_cases.py`.
**Modify:** `models.py`, `store.py`, `processes.py`, `workers.py` as required by these contracts.

- [x] Add restart matrix for every launch/result boundary; matching live worker adoption; missing worker; boot change; PID reuse; unreachable process inspector; detached descendant; stale generation result; retry count preserved across repeated restart.
- [x] Add liveness cases: heartbeat without progress, legitimate quiet bounded tool, hard deadline, graceful cancellation, TERM-resistant child, uncertain termination, and intentional Stop not consuming/triggering infrastructure retry.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-recovery.sh` to failure; commit tests.
- [x] Implement suspected-stuck inspection, generation revocation, TERM/grace/KILL with descendant confirmation, quarantine on uncertainty, and one backoff retry only after safe infrastructure classification. Retain workspace/scope/occupancy until termination is proven. Ordinary semantic failure remains attention, not an infrastructure retry.
- [x] Run the focused suite and clean-room check; commit/push.

**Verifies:** S2-S5. Test records must show at most two attempts for one automatically retried job even after multiple restarts.

**Evidence pending independent review:** Task 2.1 was independently approved at `6793a88`. Task 2.2's recovery tests began with the failing ambiguous-launch case (`9f923af`; `/private/tmp/supervisor-recovery-red.log`). Subsequent test-first slices cover receipt adoption, missing and unreachable workers, changed boot UUID, PID-start mismatch, stale and corrupt results, durable publication, bounded cycles, quiet tools, heartbeat/progress separation, managed TERM/KILL, escaped descendants, and intentional stop. A real fixture retry is launched once after trusted stop evidence and backoff, then the store is reopened and repeated recovery retains exactly two attempts (`01fbdf3`); retry tests also cover unknown usage, unsettled effects, stale proof, card eligibility and lowered caps. At implementation head `1163fcc`, the final focused store suite passed 52 cases, recovery suite passed 30 cases, touched runner suite passed, and clean-room passed 118 checks; logs are `/private/tmp/supervisor-store-final.log`, `/private/tmp/supervisor-recovery-final.log`, `/private/tmp/supervisor-runner-final.log`, and `/private/tmp/supervisor-clean-room-final.log`. Native same-boot descendant containment remains unproven and holds claims; fixture complete-tree and never-executed proofs require explicitly injected trusted verifiers. Effect-bearing retries remain blocked pending Phase 4.1. The complete restart-boundary matrix and implementation checkboxes remain open for independent audit; no production provider, live board, paid call, or service installation was used.

## Phase 3 — Scheduling, limits, and scope

### Task 3.1: Expose planner candidates and build bounded admissions

**Modify:** `scripts/tick-plan.sh` (scope extraction near 572, actual scope near 660, jq ordering near 900).
**Create:** `scripts/supervisor/scheduler.py`; `tests/test-supervisor-scheduler.sh`; `fixtures/supervisor/scheduler_cases.py`.
**Existing tests:** `tests/test-tick-plan.sh`, `tests/test-scope-reservations.sh`, each exercised only in its corresponding change slice.

**Planner contract:** add `--candidates` read-only mode returning schema version, per-card action/preconditions, declared/actual paths and completeness, dependencies, stage/head/round, priority and observed state revision. Keep existing default/settle behavior until cutover. Candidate mode removes tick-local ordering/reservation decisions while preserving workflow eligibility and fail-closed reads.

- [x] First extend `test-tick-plan.sh` with candidate-mode workflow parity and invalid-mode cases; demonstrate failure, commit, implement, and run this suite plus clean-room.
- [x] Write scheduler cases for a blocked A while B finishes and C launches, racing admission requests, global/provider/card caps, independent candidates bypassing conflicts, lowering caps, priority/aging ties and age persistence across restart, including a sustained stream of new high-priority reviews while an old low-priority start eventually runs.
- [x] Add an unknown-workflow-state case matching PR #200: no admission or silent state normalization, existing claims retained for reconciliation, and a visible wait/attention reason for status consumers.
- [x] Add fake-clock cases for retry backoff, launch-rate spacing, rate-limit wait caps, session deadlines/cost stops, unknown spend and invalid reload; no sleeps proportional to configured production timeouts.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-scheduler.sh` to failure; commit tests.
- [x] Implement coalesced bounded cycles, async planning snapshots, fresh precondition checks and atomic claim/attempt preparation. Implement normal priority default plus explicit labels `fleet:priority:high|normal|low`; conflicting priority labels require attention. Age the full combined class-and-priority rank until any eligible card reaches the highest rank, preserving initial eligibility sequence as the tie breaker.
- [x] Make deadline and cancellation timers independent of planning completion. Bound concurrent control operations separately; keep status/cancel responsive under saturated worker capacity.
- [x] Run the focused suite and clean-room check; commit locally. Push deferred because network access is unavailable.

**Verifies:** S1, S6, S11. Acceptance uses durable attempt counts and simulated time, not thread timing guesses.

### Task 3.2: Persist scope ownership and implement safe release/reacquisition

**Modify:** `store.py`, `scheduler.py`, `workers.py`; `scripts/tick-plan.sh` candidate scope completeness and Human-QA coverage.
**Create:** `tests/test-supervisor-reservations.sh`; `fixtures/supervisor/reservation_cases.py`.

- [x] Extend `test-scope-reservations.sh` in its own TDD slice for Human-QA scope evidence and incomplete PR-file handling without changing legacy mode expectations.
- [x] Add persistent reservation cases across review/CI/QA/retry/pause; normalized directory boundaries, traversal and symlink escapes; atomic competing expansions; denied expansion checkpoints with slot release but retained scope; cyclic waits surfaced.
- [x] Test override rejection while any live/uncertain writer or pending effect exists; successful human release audits identity/reason/revision; stale release command rejected; resume waits for scope, refreshes branch and invalidates evidence; QA remains unchanged.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-reservations.sh` to failure; commit tests.
- [x] Implement durable reservation union and command contracts. For providers without enforceable scoped-write mediation, assign repository-wide write ownership; expose the reduced concurrency in status rather than claiming safe disjoint execution. Add unauthorized-write detection and publication hold.
- [x] Run the focused suite and clean-room check; commit locally. Push is deferred by the explicit Task 3.2 guard.

**Verifies:** S7 and S4 scope safety. Resume's real branch refresh is supplied by Task 4.1; this phase tests its requested effect contract with an injected deterministic effect adapter.

## Phase 4 — Effects, integration, and merges

### Task 4.1: Journal and reconcile controller-owned effects

**Create:** `scripts/supervisor/effects.py`; `tests/test-supervisor-effects.sh`; `fixtures/supervisor/effect_cases.py`.
**Reuse without bypass:** `board-*.sh`, `note.sh`, `parse-report.sh`, `review-stages.sh`, `worktree.sh`.

**Interface:** `Effect.prepare(key, preconditions, intent)`, `Effect.observe()`, `Effect.apply()`, `Effect.reconcile()`. Supported adapters: worktree preparation, branch refresh, commit publication, PR create/update, report post, note update, card move, follow-up filing and cleanup. Each documents observation evidence and ambiguous-outcome behavior.

- [x] Add failure injection before/after every external mutation and before local observation commit. Cover changed/deleted cards, moved PR head, invalid note, human-QA arrival mid-flight, duplicate report/create response, and ambiguous publication.
- [x] Assert controller-generated operation IDs are separate from untrusted report text and all effect mutations revalidate current authority/generation and card state.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-effects.sh` to failure; commit tests.
- [x] Implement bounded subprocess effect adapters and safe observation/replay. No direct filesystem edits to board storage. Uncertain non-idempotent results enter attention. Resume refresh produces a new validated input revision and resets only invalidated review evidence, not infrastructure retry history for unchanged work.
- [x] Run the focused suite and clean-room check; commit/push.

**Verifies:** S3, S4, S7, S8. This phase does not claim exactly-once external delivery.

### Task 4.2: Adapt merge/settle work into the independent integration lane

**Modify:** `scripts/merge-reviewed.sh`, `scripts/settle.sh`, `scripts/verify-main.sh` only where a bounded entrypoint needs it; `effects.py`, `scheduler.py`.
**Tests:** existing `tests/test-merge-reviewed.sh` and `tests/test-settle.sh`, separate TDD slices; new `tests/test-supervisor-integration.sh` with `fixtures/supervisor/integration_cases.py`.

- [x] Write failing existing-suite cases for a bounded per-card operation retaining fresh eligibility/head binding and pending verification recovery; commit tests before adapting helpers. Preserve their existing default invocation contracts.
- [x] Add integration cases: B completes review/merge/verification while unrelated A is still running; at most one repository merge/verification lane; crash after merge before journal update issues no second merge; failed main verification closes admissions; Human QA and human merge policy forbid mutation.
- [x] Cover head drift, configured review stages, dependency readiness, green CI requirement, post-merge refresh and deferred cleanup. `ok: "true"`, missing `ok`, and `ok: false` are all failure.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-integration.sh` to failure; commit tests.
- [x] Implement lane scheduling and effect recovery outside the event loop. Already-merged verification can proceed while paused/stopping; no new merge can. Cleanup cannot remove active/quarantined/pending-QA worktrees.
- [x] Run the focused suite and clean-room check; commit/push.

**Verifies:** S1, S3, S8, S11.

### Task 4.3: Wire production provider contracts without activating legacy role instructions

**Modify:** `workers.py`, `runner.py`; existing `scripts/evidence-review.sh`, `stage-review.sh`, `providers/chat.sh` only for explicit no-post/result transport and cancellation interfaces.
**Create:** `scripts/supervisor/isolation.py`, `scripts/supervisor/inference_broker.py`, `scripts/supervisor/policies/worker.sb`; `tests/test-supervisor-providers.sh`; `fixtures/supervisor/provider_cases.py`.
**Prepare specs:** `docs/implementation-plans/2026-09-28-fleet-board/specs/{implementor,reviewer,fixer,reporting,manager}.md` (existing spec sources verified at the baseline).

- [x] Write fake CLI/provider cases for explicit role/model selection, bounded stdout/stderr, missing executable, cancellation, unknown usage, retry accounting, exact input SHA, no board/merge credentials, and expansion requests. Add host-enforced negative access probes for controller DB/socket, board files, shared Git metadata, host credential stores/helpers/keychain/SSH agent, arbitrary network/publication, symlink escapes and forged human-control requests. Test that missing isolation support refuses production launch.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-providers.sh` to failure; commit tests.
- [x] Implement versioned provider adapter contracts, native macOS sandbox policy and Linux bubblewrap isolation with required capability probes, private Git metadata, and a minimal inference-only credential broker. Keep the trusted runner outside the worker boundary and pass only the attempt-scoped result/heartbeat/scope-request channel. Test real access denial on supported hosts separately from injected adapter tests. Unsupported sandbox hosts fail closed; no prompt-only or environment-only fallback. Pin/review external sandbox requirements at execution time using their official documentation linked in the design. Capture provider-level transport/report retries visibly under one attempt, with their existing bounds; never multiply them through an unclassified supervisor retry. On this Mac, the native `sandbox-exec` policy could not be applied; the approved Docker Desktop backend is the qualified supported-host path. Its immutable-image probe passed all 24 named checks without a pull.
- [x] Keep production implementor/fixer activation blocked until re-authored role contracts pass Phase 7. A fake-provider success is not production qualification.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-providers.sh` (87 tests) and `bash plugins/fleet-board/tests/test-clean-room.sh` (118 checks); run version, AST/JSON, syntax, and diff checks; commit and push after fresh Luna reviews. Final Docker host probe passed all 24 checks. PR #237 remains draft at `3022b53`; final review summary is posted.

Execution note (2026-11-08): Provider contract, attempt-bound inference socket, bootstrap, and fail-closed macOS/Linux policy code are implemented. The host is macOS 27.2, but `sandbox-exec` aborts or returns `Operation not permitted` even under the approved host probe, so supported-host denial behavior remains unqualified. The production supervisor remains disabled, and the implementation checkbox stays open until real host isolation probes and execution-time sandbox requirement review are complete. The focused runner suite passes only with host process metadata access; see the implementation report for commands and results.

Execution note (2026-11-09): The host's macOS Unix-socket bind mount is unsupported inside Docker Desktop's Linux VM, so the approved Docker backend design uses an attempt-local guest socket and framed stdio relay to the trusted host controller. Its detailed spec and task-by-task TDD plan are `docs/superpowers/specs/2026-11-09-persistent-supervisor-docker-backend-design.md` and `docs/superpowers/plans/2026-11-09-persistent-supervisor-docker-backend.md`. The cached-image Docker host probe passes all 24 checks; after the first CI run exposed portable-temp-path and opt-in probe-discovery issues, the focused provider suite passes 89/89, the opt-in guard passes, and clean-room passes 118/118. Fresh Luna Docker reviews approved implementation head `fbb212e`; follow-up spec and quality reviews approved the CI portability corrections at `ae87cbf`. PR #237 received the reviewed fixes, and offline CI run `42767755929` passed on head `a4f43c4`. Native macOS `sandbox-exec` remains unsupported here; Docker is the qualified local isolation backend. Production remains disabled.

**Verifies:** S2-S5, S8, S11 transport subset. No paid calls occur in this task.

## Phase 5 — Persistent service, commands, and UI

### Task 5.1: Own the repository and serve lifecycle commands

**Create:** `scripts/supervisor/service.py`, `cli.py`, `scripts/supervisor.sh`; `tests/test-supervisor-lifecycle.sh`; `fixtures/supervisor/lifecycle_cases.py`.
**Modify:** `scripts/claim-run-lock.py`, `fleet-board-run.sh` to use shared ownership exclusion.
**Existing test slice:** `tests/test-run.sh` for legacy/new lock contention.

- [ ] Add legacy/new and linked-worktree singleton tests in `test-run.sh`; prove failure and implement shared lock compatibility before service integration.
- [ ] Write lifecycle cases for concurrent/repeated Start, persisted desired state, pause/resume, drain/cancel stop, crash during shutdown, recovering while stopped, blocked controller RPC, stale command revision, and session accounting across Start/Resume/reboot.
- [ ] Run `bash plugins/fleet-board/tests/test-supervisor-lifecycle.sh` to failure; commit tests.
- [ ] Implement private local socket, authenticated actor derivation (reject spoofed body actors), separate restricted worker IPC, bounded requests, durable command deduplication, service readiness acknowledgement, and offline Start ownership path. Expose read-only status when execution cannot start. Capture host boot identity and preserve compatible runner versions across process restart.
- [ ] Implement CLI `start|pause|resume|stop --mode drain|cancel|status|reconcile|events|resolve --card <n> --action <action>`; `reconcile` returns a snapshot/cursor without waiting for jobs. Reject unsupported/contradictory arguments with exit 2.
- [ ] Run focused suite and clean-room check; commit/push.

**Verifies:** S2, S9-S12 service subset. Stopping an uncertain writer reports unresolved shutdown, not successful termination.

### Task 5.2: Replace PID/log inference with supervisor status and controls

**Modify:** `scripts/board-web.py` (`is_active`, `run_status`, `start_run`, `stop_run`, routes); `scripts/board-web/static/{board.js,board.css,index.html}`; `tests/test-board-web.sh`.
**Create:** `tests/test-supervisor-web.sh`; `fixtures/supervisor/web_cases.py`.
**Reuse:** `tests/board-dom-harness.js`, `board-interaction-harness.js`, `board-unknown-interaction.js`; focused regressions `tests/test-board-unknown-interaction.sh` and `tests/test-board-web-atomic.sh` (already merged). Check Node availability for DOM tests; it is not a new production runtime requirement.

- [ ] Preserve legacy-mode API cases in `test-board-web.sh`; add focused routing assertions where its handlers change. New-mode lifecycle cases belong to the new suite. Retain PR #207 request-size/time limits, corrupt-card errors, temp cleanup, per-import create locks/atomic metadata, `created` status, private run-file modes, actual-listen-port URLs, and legacy log-cache behavior.
- [ ] Reuse the existing DOM harness to test `known: false`, the Unknown state group and drawer repair while supervisor status is active/unreachable. Never auto-normalize or dispatch an unknown-state card; retain existing reservations pending reconciliation. Run `bash plugins/fleet-board/tests/test-board-unknown-interaction.sh` only for this rendering slice, plus clean-room checks.
- [ ] Preserve import independence while the supervisor is saturated or unreachable: separate imports can create concurrently, one import remains serialized, and metadata readers see a complete old or new value. For the import-metadata slice, run `bash plugins/fleet-board/tests/test-board-web-atomic.sh` plus clean-room; do not reuse its non-fsync helper as the durable runner publication implementation.
- [ ] Add API cases for every design route, CSRF/Host enforcement, idempotency and stale revisions, acknowledgement versus ready status, unreachable versus stopped, bounded event replay/cursor expiration, safe log IDs, explicit reservation release audit, and QA-preserving resume. Include audited resolution cases for manual retry after exhaustion (automatic count/budget unchanged), evidence-backed usage recording, verified external-effect confirmation, and safe abandonment; reject resolution while a writer/effect remains uncertain.
- [ ] Run `bash plugins/fleet-board/tests/test-supervisor-web.sh` to failure; commit tests.
- [ ] Implement HTTP-to-socket proxy and compatibility `/api/run` projection. Remove marker clearing/PID inference in supervisor mode. Render health/slots/budgets/boot status, wait reasons, attempt history and reservation controls; show dates/ages from structured data rather than log parsing.
- [ ] Implement bounded cursor polling with reconnect/full-snapshot behavior; disable unsafe controls while stale/unreachable and show the reason. Never use optimistic Running for spawn acknowledgement.
- [ ] Run focused suite and clean-room check. Manually inspect desktop/narrow layouts, keyboard controls, Stop menu and error states with fake workers; record evidence before commit/push.

**Verifies:** S2, S7, S9. Killing/restarting the board server must leave workers and durable active indicators intact.

## Phase 6 — Boot registration, upgrades, and host recovery

### Task 6.1: Generate and diagnose supported OS services

**Create:** `scripts/supervisor/boot.py`; `scripts/supervisor/templates/launchd.plist`, `systemd.service`; `tests/test-supervisor-boot.sh`; `fixtures/supervisor/boot_cases.py`.
**Modify:** `cli.py`, `service.py`; `plugins/fleet-board/docs/overnight.md`.

- [ ] Test template generation and command invocation with fake launchctl/systemctl executables; explicit argv quoting for spaces; missing installation; false YAML after prior true installation; running/paused/stopped restore; same-boot crash versus reboot; invalid YAML, missing repo/executable/credentials; version/protocol incompatibility.
- [ ] Run `bash plugins/fleet-board/tests/test-supervisor-boot.sh` to failure; commit tests.
- [ ] Implement stable versioned launcher installation and domain registry with private permissions and no embedded secrets. Bootstrap reads current YAML and boot identity. Add `service install|uninstall|status` CLI; setup does not start new work on never-started domains.
- [ ] Implement macOS boot LaunchDaemon under owning unprivileged user, separately labeled login-agent fallback, and Linux user service with lingering diagnostics. Never request administrator access merely to read or generate templates; actual install is an explicit later action.
- [ ] Implement upgrade compatibility check, backup/migration and previous-version rollback path. Missing runtime or unreadable config leaves visible recoverable status; never wipes state.
- [ ] Run focused suite and clean-room check; commit/push.

**Verifies:** S10-S12 service generation subset. Source references: Apple launchd and systemd loginctl links in the design; generated-file tests alone do not prove reboot behavior.

### Task 6.2: Validate real host lifecycle separately

- [ ] Prepare an isolated fake-work board, exact rendered service configuration, credential requirements, uninstall command and evidence location for review.
- [ ] Obtain explicit authorization for installing the service and rebooting the selected host. This plan does not authorize disrupting the user's machine.
- [ ] Verify default-true recovery after actual reboot in running/paused/stopped states; false suppression; explicit Start with false; closed browser/chat; missing credentials/repository; service upgrade with a live fake attempt. Record pre-login versus post-login observations accurately.
- [ ] Restore prior host configuration after the rehearsal unless continued installation was requested. Retain logs and results. Record any unsupported host as an open acceptance gate rather than claiming success.

**Verifies:** S2, S10, S12 host subset. This gate may remain pending while offline development proceeds; final rollout cannot claim it passed.

## Phase 7 — Migration, clean-room authoring, and rollout

### Task 7.1: Migrate existing boards and provide rollback

**Create:** `scripts/supervisor/migrate.py`; `tests/test-supervisor-migration.sh`; `fixtures/supervisor/migration_cases.py`.
**Modify:** `fleet-board-run.sh`, `board-web.py`, `cli.py`, `config-defaults.json` only at final cutover.

- [ ] Write cases for legacy active wrapper refusal, old unknown worker quarantine, importing existing PR/note state without duplicate work, Human-QA reservations, pending merge verification, schema backup, migration interruption/resumption, and rollback refusing live writers/unsettled effects.
- [ ] Run `bash plugins/fleet-board/tests/test-supervisor-migration.sh` to failure; commit tests.
- [ ] Implement explicit migrate/rollback operations under shared ownership lock. Preserve store and artifacts on rollback. Emit compatibility status with active/waiting/quiescent distinctions; no false done on an empty ready queue.
- [ ] Run focused suite and clean-room check; commit/push. Keep `enabled: false` until the remaining gates pass.

**Verifies:** S8, S10, S12.

### Task 7.2: Re-author changed primitives and qualify production behavior

**Modify spec sources:** `docs/implementation-plans/2026-09-28-fleet-board/specs/{manager,implementor,reviewer,fixer,reporting,tick,run,status}.md`, `specs/README.md` and provenance manifest after authorized generation.
**Generated outputs only:** corresponding `plugins/fleet-board/agents/*.md` and clean-room skill files.
**Documentation:** plugin `CLAUDE.md`, `README.md`, `docs/overnight.md`; root documentation where semantics changed.

- [ ] Update specs to make tick one bounded reconcile request; run enables supervisor; status reads durable state; roles return versioned artifacts without board authority and obey scope/write boundaries. Remove transient tick registry and wait-for-all semantics from the new mode. Document legacy-mode compatibility explicitly.
- [ ] Prepare exact authoring commands, inputs, budget and expected provenance for review. Obtain explicit human authorization before paid isolated re-authoring; use fresh empty configuration and the repository's audit process. Do not hand-edit generated outputs.
- [ ] Run clean-room integrity checks. Perform separately authorized behavioral scenarios one at a time: slow A/fast B progressing to merge, supervisor loss during publication, one retry after interruption, reservation release/resume through conflict, and a stop/reboot sequence. Record exact commits/providers and charges or unknown usage.
- [ ] Resolve independent current-head review findings. Post review summary on PR. Confirm every acceptance criterion in the coverage document has passing evidence or an explicitly unresolved gate; do not enable default cutover with unresolved required criteria.
- [ ] Bump plugin/marketplace versions together and switch `supervisor.enabled` default true in a focused config-test slice. Update command/exit-status and migration documentation. Verify the affected focused suite plus clean-room, commit/push, and open PR in browser.
- [ ] After separately authorized merge, verify merged main using affected focused checks. Safely clean only disposable worktrees/artifacts; retain design, test evidence, pending-QA outputs and recovery data.

**Verifies:** S1-S12 final integration. No full-suite, paid-run, service-install or merge authorization is implied by the documentation request.

## Review checklist and handoff

- [ ] Every acceptance criterion maps to tests or explicit host/behavioral verification in [test requirements](2026-11-07-persistent-supervisor-tests.md).
- [ ] No runtime claim is based only on instruction text, PID existence, or fake provider success.
- [ ] Scheduler never waits on worker or network operations in its event loop.
- [ ] Restart cannot reset retry/spend/time limits or override paused/stopped intent.
- [ ] Fencing, process termination, scope release and Human QA are independently enforced.
- [ ] Concurrent upstream standalone work has been reconciled against actual main before implementation.

Phase 1 was independently approved in PR #228 and merged at e4ea2c7. Task 2.1 implementation is pending independent review; Task 2.2 remains pending. Supervisor execution remains disabled; host installation and paid qualification remain separate gates.
