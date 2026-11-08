# Task 4.3 implementation evidence

## Scope and safety

Implemented version 1 provider request/result contracts, explicit provider/model selection, attempt-bound broker validation, a private length-framed Unix socket with random per-attempt capabilities, inference-only operations, bounded stdout/stderr and request/result frames, hard deadlines, cancellation of the provider process group, missing-executable errors, exact input SHA checking, and unknown usage preservation in `plugins/fleet-board/scripts/supervisor/inference_broker.py`. `Runner.launch_production` passes the validated attempt, exact provider request, socket path, and attempt capability to worker stdin; the worker receives no database, board, publication, or human-control interface.

Added deny-by-default macOS and Linux worker policy construction, private attempt path validation, an allowed-write/denied-read capability probe, and fail-closed execution in `plugins/fleet-board/scripts/supervisor/isolation.py`. `Runner.launch_production` requires a successful host probe and an explicit enabled flag; its default is false. `supervisor.enabled` in `config-defaults.json` remains false. Existing scope expansion continues through `store.expand_scope`; a conflict checkpoints, releases the worker slot, ends the attempt, and has no retry penalty.

No clean-room files changed. No provider/API call, service or package installation, board processing, role activation, or work on card #224 occurred. No change was made to the original checkout. The pre-existing dirty `progress.md` was left untouched.

## Test-first evidence

- Test commit `cfa96bf` introduced the focused shell suite and fake-provider cases. RED: `bash plugins/fleet-board/tests/test-supervisor-providers.sh` exited 1 with `ModuleNotFoundError: No module named 'supervisor.inference_broker'`.
- Commit `f75f257` corrected the harness scratch-directory argument and canonicalized its temporary root after those harness errors were discovered.
- Commit `3efd634` added the fake end-to-end broker case and attempt binding checks.
- Channel tests were committed RED in `dcec340`, `75262f6`, and `e6dfb07`; the import failed with `ImportError: cannot import name 'InferenceChannel'` and `ImportError: cannot import name 'InferenceClient'` before their implementations existed.
- Commit `4a6f107` added the provider input to the worker bootstrap. With socket permission available, the expected RED showed the bootstrap missing `provider_request`.
- GREEN: `bash plugins/fleet-board/tests/test-supervisor-providers.sh` passed, 9 tests, using the authorized local-only escalation because this environment denies Unix socket creation in the default sandbox.
- `bash plugins/fleet-board/tests/test-clean-room.sh` passed, 118 checks.
- `bash plugins/fleet-board/tests/test-version-bumped.sh` passed: both manifests moved from recorded `origin/main` 0.18.6 to 0.18.9.
- `git diff --check` and `python3 -m py_compile` on the changed Python modules passed.
- `bash plugins/fleet-board/tests/test-supervisor-runner.sh` failed in the default tool sandbox before runner assertions at `processes._boot_id()` with `OSError: boot identity unavailable`; the sandbox denies the Darwin `sysctlbyname` boot-session query. Re-running with host process metadata access passed (`runner identity tests passed`).

## Isolation qualification and remaining gate

The host reports Darwin/macOS and has `/usr/bin/sandbox-exec`, but the generated deny-default policy cannot be applied. The tool sandbox reports `sandbox_apply: Operation not permitted`; with host process metadata access, the generated profile exits by SIGABRT and an individual `process-fork` permission is rejected with exit 71. A minimal `(allow default)` profile succeeds, but that does not enforce the required boundary and was not used. The capability probe therefore returns `available: false`; the focused suite verifies that `run_isolated` and `Runner.launch_production` refuse launch in that state. This environment could not perform a successful host-enforced negative-access run. Linux/bubblewrap capability was not available for testing. Production isolation is **not qualified**, and production remains disabled. Do not enable production admission until policy application and negative access probes pass on a supported host.

The local channel and runner bootstrap are implemented, but the host sandbox could not be applied to the launched worker here. The production runner path is therefore deliberately not qualified for use; the fail-closed default is retained. Its macOS local-socket allow rule and Linux bubblewrap channel behavior need qualification on supported unsandboxed hosts before production admission can be enabled.

## Commits and external state

Test commits: `cfa96bf`, `f75f257`, `3efd634`, `dcec340`, `75262f6`, `e6dfb07`, `4a6f107`. Task implementation/plan commit: `27bc8ef`. The task remains incomplete pending supported-host isolation qualification and explicit push authorization. Fetching `origin/main` previously failed because the common Git metadata is outside the writable sandbox; the version check used the provided recorded base 0.18.6. PR #237 state was not refreshed during this offline implementation.
