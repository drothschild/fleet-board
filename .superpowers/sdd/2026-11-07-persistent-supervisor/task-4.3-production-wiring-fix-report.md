# Task 4.3 production wiring fix report

Base: `5a310c5d47fa73695b3170e1eca5a6421aff0473`
Branch: `codex/persistent-supervisor-effects`
Production activation: disabled
Host isolation qualification: open

## Changes

- Provider calls now inherit the attempt's durable deadline and cancellation event through `Runner.launch_production`, `InferenceChannel`, and `InferenceBroker`. Attempt cancellation terminates only its active provider process group.
- `run_isolated` now sends TERM, waits the grace period, and sends KILL to the entire worker process group after `OSError`, broken pipe, selector, timeout, or cancellation failures. It closes bootstrap stdin during cleanup.
- Attempt in-flight/quota claims happen before shared inference accounting. Rejected over-quota requests do not consume the channel quota.
- The production bootstrap advertises only authenticated `heartbeat`, `result`, and `scope_request` operations alongside inference. The channel validates exact operation envelopes against domain, job, attempt, generation, and input SHA, rejects unsupported operations, and persists each operation key, body SHA, state, and completed result in a private controller journal. Restart replay returns a completed result without rerunning callbacks; a persisted `in_flight` or `failed` operation is consumed and fails closed.
- The controller journal uses mode-0600 atomic replacement, fsyncs the file and parent directory, and serializes updates with `flock`. A controller with a stale snapshot fails closed rather than overwriting another controller's journal. Records are cumulative and capped at 4096 entries/16 MiB; there is no automatic eviction, so capacity requires controller-side archival/retention before future attempts can dispatch operations. Production validates that the journal is private and disjoint from worker-writable workspace, private Git, and channel roots.
- Provider cancellation now checks whether the process group survives after TERM even when its leader exits; it sends KILL to surviving descendants and waits for the leader.
- `TrustedAttemptResultHandler` accepts relative artifact names only, confines worker scratch to the prepared workspace and away from the private Store, copies files into the attempt-owned artifact directory, compares actual hashes with worker claims, validates the role report with `parse-report.sh`, reconstructs the Store envelope from its captured binding, and calls `Store.record_result`. Runner and channel require the exact handler type; arbitrary functions and subclasses overriding validation cannot be used by production launch.
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

Every RED was observed before its corresponding implementation. The final focused provider suite passed all 33 tests.

## Verification

- `bash plugins/fleet-board/tests/test-supervisor-providers.sh` — passed, 33 tests. Host access was needed for local Unix socket binding; the default sandbox attempt failed those socket cases with `PermissionError`.
- `bash plugins/fleet-board/tests/test-supervisor-runner.sh` — passed (`runner identity tests passed`) with host process metadata access. The default sandbox attempt could not read boot identity.
- `bash plugins/fleet-board/tests/test-clean-room.sh` — passed, 118 checks, 0 failures.
- `bash plugins/fleet-board/tests/test-version-bumped.sh` — passed; both manifests are `0.18.12`, above `origin/main` `0.18.6`.
- Python AST syntax check — passed for `inference_broker.py`, `isolation.py`, `runner.py`, `workers.py`, and `provider_cases.py`; `bash -n` passed for the provider, runner, clean-room, and version test scripts; `git diff --check` passed.

No live provider, service, board, or host-isolation qualification was run.

## Remaining gate

The transport does not qualify production execution. The reviewed macOS host's deny-default sandbox still has not passed a supported-host real access-denial probe. Keep production disabled until host isolation is proven and the controller injects durable heartbeat, checkpoint, and slot-release callbacks for the trusted operation factory. The journal currently assumes one current writer: concurrent controller instances are serialized by a file lock, but stale snapshots are rejected rather than merged; the controller must recover or restart from the latest journal before dispatching further operations.
