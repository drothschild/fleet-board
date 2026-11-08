# Task 4.3 production wiring fix report

Base: `5a310c5d47fa73695b3170e1eca5a6421aff0473`
Branch: `codex/persistent-supervisor-effects`
Production activation: disabled
Host isolation qualification: open

## Changes

- Provider calls now inherit the attempt's durable deadline and cancellation event through `Runner.launch_production`, `InferenceChannel`, and `InferenceBroker`. Attempt cancellation terminates only its active provider process group.
- `run_isolated` now sends TERM, waits the grace period, and sends KILL to the entire worker process group after `OSError`, broken pipe, selector, timeout, or cancellation failures. It closes bootstrap stdin during cleanup. The group probe skips KILL only for ESRCH; other probe errors still trigger KILL.
- Attempt in-flight/quota claims happen before shared inference accounting. Rejected over-quota requests do not consume the channel quota.
- The production bootstrap advertises only authenticated `heartbeat`, `result`, and `scope_request` operations alongside inference. The channel validates exact operation envelopes against domain, job, attempt, generation, and input SHA, rejects unsupported operations, and persists each operation key, body SHA, state, and completed result in a private controller journal. Restart replay returns a completed result without rerunning callbacks; a persisted `in_flight` or `failed` operation is consumed and fails closed.
- The controller journal uses mode-0600 atomic replacement, fsyncs the file and parent directory, and serializes updates with `flock`. A controller with a stale snapshot fails closed rather than overwriting another controller's journal. Records are capped at 4096 entries/16 MiB. `retire_attempt_operations` compacts only completed records after a factory-built Store checker proves the exact attempt is terminal and execution-released; any in-flight record blocks retirement. Store distinguishes active, revoked, and terminal-released attempts, and rejects reconnect after records are retired. There is no automatic eviction: the controller must invoke retirement after durable process-stop evidence. Production validates that the journal is private and disjoint from worker-writable workspace, private Git, and channel roots.
- `OwnerThreadDispatcher` marshals Store result, scope, heartbeat, checkpoint, release, bind, and retirement checks to the SQLite connection's owning thread. If a callback is still queued when the wait deadline expires, the dispatcher marks it cancelled before returning; the owner pump skips it. If the owner already claimed the callback, the caller waits for actual completion so the operation journal cannot record failure while a trusted mutation is still running. The controller must pump `run_pending` on its owner loop; `Runner.launch_production` must run off that thread, and fails closed when called on the owner thread to avoid blocking the pump. No background pump is started implicitly.
- Provider cancellation now checks whether the process group survives after TERM even when its leader exits; it sends KILL to surviving descendants and waits for the leader.
- `TrustedAttemptResultHandler` accepts relative artifact names only, confines worker scratch to the prepared workspace and away from the private Store, copies files into the attempt-owned artifact directory, compares actual hashes with worker claims, validates the role report with `parse-report.sh`, derives result outcome from parsed role status and exit code, and calls `Store.record_result` with parser-derived status. Store verifies that outcome and applies durable cancellation inside the same transaction before persisting. Runner and channel require the exact handler type; arbitrary functions and subclasses overriding validation cannot be used by production launch.
- Runner also verifies that the private result Store does not overlap any worker-writable isolation root (`workspace`, `private_git`, or `channels`).
- `build_attempt_operation_handlers` keeps the Store controller-side and routes scope requests through `request_scope_expansion`/`Store.expand_scope`. A conflict checkpoints, releases the slot, and reports `retry_penalty: false`. `Runner.launch_production` fails closed unless all three callbacks are supplied and the result handler is bound to the exact worker workspace and attempt.

The operation interface is injected by trusted controller code; no Store object or callback is serialized to the worker. The result callback is constructed by the trusted factory rather than supplied as an arbitrary function. A controller still must provide the heartbeat updater, checkpoint, and slot-release callbacks before any production launch can be enabled. No board, merge, lifecycle, or credential operation is exposed.

## RED evidence and test-first commits

- `90bb3d8` — cancellation test failed because `InferenceChannel` lacked attempt controls.
- `4d7b99f` — bootstrap I/O failure test observed a surviving descendant and marker.
- `8a3eb81` — over-quota flood exhausted shared quota and rejected a second authorized attempt.
- `795c20c` — operation contract test failed because attempt-scoped dispatch did not exist.
- `e87adf0` — request-ID replay test failed because worker operations lacked idempotent deduplication.
- `c5ab4b9` — scope adapter test failed because controller scope requests were not wired through the reservation API.
- `037f8f1` — result-handler tests failed because no trusted artifact/report/Store ingestion handler existed.
- `61e4a5a` — the production launch test failed to reject an arbitrary result callback explicitly.
- `ae8716c` — the launch test failed to bind the result handler to the prepared workspace.
- `482d71b` — the factory test failed to reject overlap between worker scratch and the Store directory.
- `d0a8d31` — production launch accepted a result Store located under worker-writable channels.
- `528f403` — production launch accepted a subclass overriding trusted result validation.
- `eeab552` — descendant regression failed because TERM-resistant provider child survived when its parent exited.
- `55f8c67` — restart/replay test failed because `InferenceChannel` had no durable operation-journal argument.
- `51d9414` — persisted-in-flight recovery test failed against baseline because durable journal loading was absent.
- `769be38` — valid blocked report and nonzero-exit tests failed because worker outcome claims were trusted; cancellation result stored success.
- `217a24f` — non-ESRCH group probe failure test failed because worker cleanup skipped SIGKILL.
- `9c052a3` — journal retirement test failed because no terminal-proof API existed.
- `1e0e10d` — actual Store-over-channel test failed because there was no owner-thread dispatcher.
- `20849f5` — arbitrary terminal-checker test failed because a lambda was accepted as retirement authority.
- `41bdc3f` — off-owner launch test failed against baseline Runner because owner-thread launch was not rejected.
- `68a89fe` — cancellation authority test failed because boolean false conflated active with revoked attempts.
- `4addc59` — the timeout/later-pump regression failed because `run_pending` executed a queued callback after `call` returned `TimeoutError`.

Every RED was observed before its corresponding implementation. After the timeout-handshake implementation, the focused provider suite passed all 41 tests.

## Verification

- `bash plugins/fleet-board/tests/test-supervisor-providers.sh` — passed, 41 tests. Host access was needed for local Unix socket binding; the default sandbox attempt failed those socket cases with `PermissionError`.
- `bash plugins/fleet-board/tests/test-supervisor-runner.sh` — passed (`runner identity tests passed`) with host process metadata access. The default sandbox attempt could not read boot identity.
- `bash plugins/fleet-board/tests/test-clean-room.sh` — passed, 118 checks, 0 failures.
- `bash plugins/fleet-board/tests/test-version-bumped.sh` — passed; both manifests are `0.18.12`, above `origin/main` `0.18.6`.
- Python AST syntax check — passed for `inference_broker.py`, `isolation.py`, `runner.py`, `store.py`, `workers.py`, and `provider_cases.py`; `bash -n` passed for the provider, runner, clean-room, and version test scripts; `git diff --check` passed.

No live provider, service, board, or host-isolation qualification was run.

## Remaining gate

The transport does not qualify production execution. The reviewed macOS host's deny-default sandbox still has not passed a supported-host real access-denial probe. Keep production disabled until host isolation is proven and the service controller pumps the owner-thread dispatcher, injects durable heartbeat/checkpoint/slot-release callbacks, and retires attempts only after recorded execution-stop evidence. This real service/controller integration belongs to Phase 5, Task 5.1, which creates `service.py` and defines lifecycle ownership; Task 4.3 supplies only the injected transport and fail-closed interface. Do not treat the dispatcher interface as a running controller. The journal assumes one current writer: concurrent controllers serialize through a file lock, but stale snapshots are rejected rather than merged; a controller must recover from the latest journal before dispatching more operations.
