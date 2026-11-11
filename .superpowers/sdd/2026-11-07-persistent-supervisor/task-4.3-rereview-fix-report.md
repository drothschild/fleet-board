# Task 4.3 re-review fixes

Base: `e228faf011d941cbaf18421d7ff1d760e9c3de8c`

RED test commit: `e78ec65`

Implementation commit: `54d3ac9`

## Changes

- Imported `stat` so an already-existing inference socket is recognized through `S_ISSOCK` rather than raising `NameError`.
- Replaced temporary protected-resource sentinels with a required exact map for the controller database and socket, board storage, shared Git metadata, host credential/helper paths, SSH agent, and keychain paths. Every entry must identify an existing canonical path of the expected type; missing, unknown, symlinked, or uncheckable paths leave capability unavailable. The probe checks the actual mapped paths with shell access checks and no content reads. Controller and SSH sockets use local Unix socket connect-only checks with no payload. Network checks remain loopback-only; the publication check targets only a private temporary path.
- Moved the broker's global request accounting after envelope and capability authentication. Quota exhaustion returns a bounded per-connection error without stopping the listener. A semaphore bounds in-flight connection handlers independently of the authenticated request quota.
- Required production attempts to carry finite `started_at` and unexpired `deadline` values plus a `threading.Event` cancellation handle. `Runner.launch_production` passes the remaining durable deadline and cancellation event to `run_isolated`; timeout and cancellation terminate the worker process group. Missing or malformed contracts fail closed.
- Kept production admission disabled. `launch_production` cannot pass its gate without a complete trusted protected-resource map and a successful host capability result.

## TDD evidence

The provider suite was run before implementation with local-only Unix socket permission. It reported `Ran 22 tests`, `FAILED (failures=1, errors=4)`: the protected-resource API was missing, the existing-socket probe could not accept its map, cancellation was not accepted, an unauthenticated connection flood prevented the subsequent valid inference request, and production launch did not reject a missing cancellation handle.

After implementation, fresh focused verification produced:

- `bash plugins/fleet-board/tests/test-supervisor-providers.sh` — 22 passed.
- `bash plugins/fleet-board/tests/test-supervisor-runner.sh` — passed (`runner identity tests passed`).
- `bash plugins/fleet-board/tests/test-clean-room.sh` — 118 passed, 0 failed.
- `bash plugins/fleet-board/tests/test-version-bumped.sh` — both manifests passed, bumped from `0.18.6` to `0.18.10` after fetching `origin`.
- `python3 -m py_compile` on the changed Python modules and fixture, plus `git diff --check` — passed.

No provider, service, package installation, board, or card `#224` action was used. Nothing was pushed.

## Remaining gate

The host's macOS deny-default sandbox still aborts or returns `Operation not permitted`, so this work does not establish supported-host policy enforcement or real-resource denial. The production capability gate remains unavailable until a supported host successfully probes the complete real-resource map, including controller/broker socket separation and all required denial checks. Task 4.3 remains incomplete; Phase 4 is not complete. `progress.md` was left untouched by this work; its pre-existing modification remains in the worktree.
