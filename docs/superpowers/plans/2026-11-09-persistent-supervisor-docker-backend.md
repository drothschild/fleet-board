# Persistent supervisor Docker backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit Docker Desktop backend that confines one worker attempt in an offline Linux container and relays only the authorized broker operations to the trusted host controller.

**Architecture:** The host launches one non-root container per attempt with no network, read-only root, no capabilities, bounded resources, and only workspace/private-Git mounts. A guest agent exposes the existing Unix-socket client inside the container and multiplexes framed requests over attached stdio; the host relays them through the existing authenticated `InferenceChannel`. No Docker socket or host broker socket enters the container.

**Tech Stack:** Python 3, Docker CLI/Desktop Engine, Bash fixture suite, JSON length framing, Unix sockets inside the Linux container.

**Spec:** `docs/superpowers/specs/2026-11-09-persistent-supervisor-docker-backend-design.md`

## Global Constraints

- Keep `supervisor.enabled: false`.
- Use only locally cached immutable image IDs; invoke Docker with `--pull=never`; do not install packages/services or pull/build images.
- Worker containers use `--network none`; never use host networking or expose the Docker daemon socket.
- Do not mount host home, board storage, controller state/socket, shared Git metadata, credentials, SSH agent, keychain, or Docker socket.
- Only `heartbeat`, `result`, `scope_request`, and `infer` are worker-visible operations; the host remains authoritative for attempt identity and Store callbacks.
- No paid provider calls, board processing, production activation, or card #224 changes.
- Follow repository TDD with a failing test commit before each implementation commit.
- Run only `bash plugins/fleet-board/tests/test-supervisor-providers.sh`, the Docker host-probe script when explicitly configured with the cached image, and `bash plugins/fleet-board/tests/test-clean-room.sh`.
- Keep Task 4.3 plan checkboxes open until all real Docker denials pass and fresh Luna reviews approve the final head.

## File Map

- `scripts/supervisor/isolation.py`: explicit backend selection and Docker capability entrypoint; preserve native/Linux backends separately.
- `scripts/supervisor/docker_transport.py`: trusted host-side Docker launch, framed stdio relay, bounded output, deadline/cancellation, container cleanup.
- `scripts/supervisor/docker_agent.py`: guest-side attempt-local Unix socket and framed stdio multiplexer; no controller credentials or Store access.
- `scripts/supervisor/runner.py`: select Docker transport for an explicit Docker policy and give the worker its in-container socket path.
- `fixtures/supervisor/provider_cases.py`: red/green policy, guest, host-relay and lifecycle regressions.
- `tests/probe-supervisor-docker-host.sh`: optional real Docker denial probe using only the image ID supplied in `FLEET_BOARD_DOCKER_PROBE_IMAGE`; absent or unavailable images fail qualification and are never pulled.
- `plugins/fleet-board/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`: bump plugin version in the implementation commit above current `origin/main`.

## Review Focus

- Missing Docker daemon or absent image: refuse launch without a fallback or pull; test command construction and capability refusal.
- Malformed, oversized, truncated, or unknown stdio frames: reject without invoking a host callback; test framing and operation allowlist.
- Concurrent worker RPCs and delayed responses: correlate by request ID and preserve attempt binding; test out-of-order responses.
- Cancellation, timeout, Docker CLI failure, or host relay failure: kill/reap worker and remove its container; test bounded completion and cleanup.
- Paths containing Docker mount delimiters or symlink roots: reject before launch; test comma/delimiter and canonical-path validation.


#### Post-push CI portability correction (2026-11-09)

The first PR CI run (`42763898232`) found that provider fixtures used a noncanonical or unavailable `/private/tmp` path on Linux, and that the Docker host qualification script was included by the generic `test-*.sh` offline-suite glob without its required cached image. The fixtures now use a canonical path under `/tmp`; the macOS policy test selects Darwin explicitly. The host-only qualification script is named `probe-supervisor-docker-host.sh`, with a guard test ensuring it stays opt-in. Local verification after these changes: provider suite 89/89, clean-room 118/0, and all 24 cached-image Docker checks passed. Fresh Luna spec and quality reviews approved exact head `ae87cbf0f1406140d7456f85fe4e3286f1425dfb`; reports: `/private/tmp/persistent-supervisor-provider-portability-spec-review.md` and `/private/tmp/persistent-supervisor-provider-portability-quality-review.md`. A fresh PR CI run will start after the reviewed fixes are pushed.

---

### Task 1: Build the explicit Docker launch policy

**Files:** `scripts/supervisor/isolation.py`, `fixtures/supervisor/provider_cases.py`; implementation also bumps both plugin manifests.

**Interfaces:** Add `build_policy(..., backend='docker', docker_image=<sha256 image ID>)`. Add pure `docker_run_argv(argv, policy, cidfile)` returning a Docker CLI argument list with `--pull=never`, `--network=none`, `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, bounded PIDs/resources, non-root UID/GID, a private `/tmp`, workspace/private-Git mounts, and a read-only guest-package mount. It must not include a channel, host home, host socket, Docker socket, or credential mount.

- [x] Write explicit local-image, offline/read-only argv, and unsafe mount-root rejection cases.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-providers.sh` with required host socket access; the three new cases fail because Docker policy/argv construction is absent. The sandboxed invocation also fails pre-existing socket tests with `EPERM`.
- [x] Commit the failing tests (`14d95ff`).
- [x] Implement explicit immutable image validation and deterministic Docker argv construction; reject missing/unpinned images and unsafe mount paths.
- [x] Bump plugin manifests from `0.18.12` to `0.18.13`, above `origin/main` `0.18.6`.
- [x] Run the focused provider suite (50 tests), `test-version-bumped.sh`, and `git diff --check`; commit the implementation.

### Task 2: Implement the guest stdio relay agent

**Files:** create `scripts/supervisor/docker_agent.py`; modify `fixtures/supervisor/provider_cases.py`.

**Interfaces:** The guest accepts one framed `start` message, creates an attempt-local Unix socket under `/tmp`, and runs the worker. Each worker socket envelope is validated for the attempt binding and exact four-operation allowlist, then sent as a framed `rpc` message with a unique request ID; host responses are correlated by ID and returned to the waiting socket client. The agent separately emits bounded stdout/stderr frames. Reject malformed, oversized, truncated, duplicate-ID, and unsupported-operation frames.

- [x] Write tests for worker Unix-socket roundtrip, concurrent out-of-order responses, output forwarding, oversized/truncated frames, and unsupported operations.
- [x] Run the focused provider suite with host socket access; all five new cases are RED because `docker_agent.py` does not exist. The prior sandbox EPERM still applies to existing local-socket cases.
- [x] Implement the guest agent with standard-library sockets, `json`, and base64 only; do not add dependencies.
- [x] Run the focused provider suite (55 tests); commit the guest agent.

### Task 3: Implement host Docker transport and Runner integration

**Files:** create `scripts/supervisor/docker_transport.py`; modify `scripts/supervisor/runner.py`, `scripts/supervisor/isolation.py`, `fixtures/supervisor/provider_cases.py`.

**Interfaces:** `DockerWorkerTransport.run(argv, policy, *, bootstrap, channel, attempt_id, capability, timeout, cancel_event)` returns a bounded `CompletedProcess`-compatible result. It launches the command from Task 1, sends bootstrap to the guest agent, forwards only the exact four supported operations through a host `InferenceClient` bound to the attempt, collects bounded stdout/stderr, and force-removes the validated container ID on timeout/cancellation/error. Runner uses it only when `policy['backend'] == 'docker'`; native and Linux paths retain their current behavior.

Docker transport and identity timeout values are exact `int`/`float` (excluding `bool`), finite, greater than zero, and at most 86,400 seconds. Missing-cid label reconciliation polls through the full 2.0-second stabilization grace at 50 ms cadence and does not start a Docker CLI query in its final 0.2 seconds. When the trusted channel has an `operation_journal`, a protected sidecar registry records labels before launch and survives transport interruption. Short flock-protected atomic transitions distinguish controller `starting`, live Docker CLI `active`, and unresolved `pending` records using PID start identities; no registry lock is held for the worker lifetime. Later invocations leave verifiably live active CLIs alone and block on live `starting` or unknown process identities. After a CLI is proven gone, a successful listing with no match during the grace retains the record for future polling but allows an independent Docker attempt; a late appearance can only be an unstarted container and is removed on a later reconciliation. After any observed ID is removed, three consecutive empty listings are required to clear its record. A listing failure or any observed container that cannot be removed retains the record and blocks admission. Fake/qualification channels without a trusted journal fail closed on uncertain missing-CID launches.

- [x] Write host-transport tests for authorized request relay/output, unknown-operation refusal, cancellation/output overflow cleanup, malformed CID, and daemon failure.
- [x] Run the focused provider suite with host socket access; the four transport cases and explicit Runner-dispatch case were RED before their respective implementations.
- [x] Implement host relay, validated container cleanup, bounded output, cancellation/deadline handling, and explicit Runner dispatch.
- [x] Run the focused provider suite (60 tests), Python compile checks, and `git diff --check`; commit implementation.
- [x] Add test-first bounds for Docker transport/identity timeouts and delayed label visibility; validate timeout types, finiteness and range, and retain label reconciliation through the full 2.0-second stabilization grace.
- [x] Add test-first durable pending-cleanup cases: pre-launch record, empty-listing retention and blocked relaunch, later visible labeled container removal, successful known-CID record cleanup, insecure journal refusal, concurrent atomic updates, and stale active-PID reconciliation. Red was observed before the implementation; focused provider suite passed (82 tests, run with host Unix-socket access). Popen failure removes an unlaunched `starting` record; stale `starting` records use the controller PID/start identity and are reconciled after that process is proven stale.

### Task 4: Add Docker host qualification probes

**Files:** create `tests/probe-supervisor-docker-host.sh`; modify `scripts/supervisor/isolation.py`, `fixtures/supervisor/provider_cases.py`.

**Interfaces:** The host probe runs only when `FLEET_BOARD_DOCKER_PROBE_IMAGE` contains an immutable image ID already present locally. It never pulls or builds. It verifies protected host paths and daemon sockets are absent, only intended mounts are writable, public egress is blocked, the relay works, forged human control is rejected after authentication, and timeout leaves no container. Attempt-labeled containers let the probe confirm the exact timed-out worker was removed. Every named check must be true for `available: true`; missing image/daemon or any probe failure returns unavailable.

- [x] Add unit tests for fail-closed missing-daemon/image, incomplete protected-resource paths, exact cleanup labeling, and the read-only guest package check; observe RED and commit tests.
- [x] Implement the Docker host probe and shell wrapper. Run with the existing cached image ID `sha256:043ab74ba0ad529734d7d77ca3e893f286410864619329d5e8ca0524c3d260c1`; no pull/build.
- [x] Run `bash plugins/fleet-board/tests/test-supervisor-providers.sh` (63 tests) and `bash plugins/fleet-board/tests/probe-supervisor-docker-host.sh` with the cached image ID (all 23 checks true, including guest-package read-only).
- [x] Run `bash plugins/fleet-board/tests/test-clean-room.sh` (118 checks), `test-version-bumped.sh`, Python AST checks, `bash -n`, and `git diff --check`.
- [x] Add RED regression cases for bounded frame queuing, relay-task settlement after transport failure, verified Docker Desktop daemon identity, deadline/cancellation-aware startup writes with CID cleanup, and a separate cancellation-cleanup qualification check. The focused provider suite reports the expected eight assertion failures; 11 existing Unix-socket tests also error with sandbox `EPERM`.
- [x] Implement the Docker review fixes: bounded reader backpressure, cancellation and settlement of relay futures, verified local daemon identity at policy/qualification/launch, deadline-aware asynchronous bootstrap writes, and a separate real-container cancellation-cleanup qualification. The focused provider suite passes (69 tests); final live host qualification remains with the integrating agent.
- [x] Bound late label reconciliation polls: RED regression committed as `3d5eed2`; skip Docker CLI queries in the final 0.2 seconds while consuming the full grace; no-match observations admit independently, and observed removals require three consecutive empty listings.
- [x] Distinguish successful no-match observations from post-removal confirmation: RED regression committed as `20ec133`; a slow successful empty query can consume most of the grace and still permit independent admission, while post-removal reconciliation remains fail-closed until three consecutive empty listings.
- [x] Obtain fresh `gpt-6-luna` spec and quality reviews at final Docker implementation head `fbb212e9c77b21ce8dde25deadd1ebdfb79ddae2`; both approve. Follow-up spec and quality reviews approved the CI portability fixes at `ae87cbf0f1406140d7456f85fe4e3286f1425dfb`. Reports: `/private/tmp/persistent-supervisor-docker-final7b-spec-review.md`, `/private/tmp/persistent-supervisor-docker-final7b-quality-review.md`, `/private/tmp/persistent-supervisor-provider-portability-spec-review.md`, and `/private/tmp/persistent-supervisor-provider-portability-quality-review.md`.
- [x] Final verification after portability fixes: `bash plugins/fleet-board/tests/test-supervisor-providers.sh` passed (89 tests); opt-in guard passed; renamed Docker host probe with cached image `sha256:043ab74ba0ad529734d7d77ca3e893f286410864619329d5e8ca0524c3d260c1` passed all 24 checks on Docker Desktop; clean-room passed 118/0; version checks advanced both manifests from `0.18.6` to `0.18.19`; AST/JSON, shell syntax, and `git diff --check` passed. No image pull/build.
- [ ] Push the reviewed portability fixes to existing draft PR #237; keep draft and do not merge. The initial PR CI failed only the provider portability cases and the opt-in Docker probe discovery; all local focused checks now pass.
