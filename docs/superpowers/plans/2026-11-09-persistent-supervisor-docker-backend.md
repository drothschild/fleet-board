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
- `tests/test-supervisor-docker-host.sh`: optional real Docker denial probe using only the image ID supplied in `FLEET_BOARD_DOCKER_PROBE_IMAGE`; absent or unavailable images fail qualification and are never pulled.
- `plugins/fleet-board/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`: bump plugin version in the implementation commit above current `origin/main`.

## Review Focus

- Missing Docker daemon or absent image: refuse launch without a fallback or pull; test command construction and capability refusal.
- Malformed, oversized, truncated, or unknown stdio frames: reject without invoking a host callback; test framing and operation allowlist.
- Concurrent worker RPCs and delayed responses: correlate by request ID and preserve attempt binding; test out-of-order responses.
- Cancellation, timeout, Docker CLI failure, or host relay failure: kill/reap worker and remove its container; test bounded completion and cleanup.
- Paths containing Docker mount delimiters or symlink roots: reject before launch; test comma/delimiter and canonical-path validation.

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

- [x] Write host-transport tests for authorized request relay/output, unknown-operation refusal, cancellation/output overflow cleanup, malformed CID, and daemon failure.
- [x] Run the focused provider suite with host socket access; the four transport cases and explicit Runner-dispatch case were RED before their respective implementations.
- [x] Implement host relay, validated container cleanup, bounded output, cancellation/deadline handling, and explicit Runner dispatch.
- [x] Run the focused provider suite (60 tests), Python compile checks, and `git diff --check`; commit implementation.

### Task 4: Add Docker host qualification probes

**Files:** create `tests/test-supervisor-docker-host.sh`; modify `scripts/supervisor/isolation.py`, `fixtures/supervisor/provider_cases.py`.

**Interfaces:** The host probe runs only when `FLEET_BOARD_DOCKER_PROBE_IMAGE` contains an immutable image ID already present locally. It never pulls or builds. It verifies protected host paths and daemon sockets are absent, only intended mounts are writable, public egress is blocked, the relay works, forged human control is rejected after authentication, and timeout leaves no container. Attempt-labeled containers let the probe confirm the exact timed-out worker was removed. Every named check must be true for `available: true`; missing image/daemon or any probe failure returns unavailable.

- [x] Add unit tests for fail-closed missing-daemon/image and incomplete protected-resource paths, plus an attempt-label assertion for exact cleanup; observe RED and commit tests.
- [ ] Implement the Docker host probe and shell wrapper. Run with the existing cached image ID `sha256:043ab74ba0ad529734d7d77ca3e893f286410864619329d5e8ca0524c3d260c1`; no pull/build.
- [ ] Run `bash plugins/fleet-board/tests/test-supervisor-providers.sh` and `bash plugins/fleet-board/tests/test-supervisor-docker-host.sh` with the cached image ID.
- [ ] Run `bash plugins/fleet-board/tests/test-clean-room.sh`, `test-version-bumped.sh`, Python AST checks, `bash -n`, and `git diff --check`.
- [ ] Obtain fresh `gpt-6-luna` spec and quality reviews at the final commit; fix findings test-first and rerun focused checks.
- [ ] Push commits to the existing draft PR #237 only after the final reviews; do not mark ready or merge.
