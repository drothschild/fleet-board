# Persistent supervisor Docker Desktop backend

## Goal

Qualify this Mac using its already-installed Docker Desktop Linux VM, while keeping the controller trusted on macOS, the worker isolated, external network access disabled, and no image pulls or service/package installations in this task.

## Evidence

- Docker Desktop 4.98.0 starts with temporary host-level launch permission. Docker Engine 29.9.2 reports Linux/ARM64. Two images are cached locally.
- A disposable cached-image container with `--network none`, `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, and a read-only bind mount cannot connect to a host Unix socket bind-mounted from macOS (`Errno 95: Not supported`).
- An internal Docker network blocks public egress but does not resolve or reach the macOS host broker from the container.
- With no host mounts, a disposable container cannot see the host home, Docker socket, SSH-agent socket, or macOS filesystem paths.
- The cached Home Assistant image has Python and `nc`, but is not a suitable production worker image. The other cached image does not have Python. No packages or images were installed or pulled.

## Design

### Worker boundary

Add an explicit Docker Desktop isolation backend. Do not invoke `sandbox-exec` for this backend. The host chooses the backend and a locally available immutable worker image reference; it does not fall back silently. Missing Docker Desktop, an absent image, or a failed probe makes production launch unavailable.

Start one `docker run --rm -i` container per attempt with `--pull=never`, `--network none`, a read-only root filesystem, no Linux capabilities, no-new-privileges, a non-root UID, bounded PIDs/resources, and private temporary storage. Mount only the attempt workspace and private Git metadata writable, and the trusted guest transport package read-only. Do not mount host home, board data, shared Git metadata, credentials, Docker socket, SSH agent, keychain, or channel directory.

The container receives no network interface beyond Docker's `none` network. Docker Desktop's host network mode is prohibited because it shares the host network stack.

### Broker relay

Replace the host-mounted Unix socket with a framed bidirectional stdio relay. A small guest transport agent exposes an attempt-local Unix socket inside the container for the existing worker client. It forwards only inference, result, heartbeat, and scope requests over Docker's attached stdin/stdout stream to the trusted macOS controller. The guest agent uses request IDs to multiplex concurrent calls. The host validates the worker-visible operation allowlist and forwards through the existing authenticated `InferenceChannel` using the exact attempt binding. Store callbacks remain on the host controller; the Docker daemon API is never exposed inside the container.

Worker stdout/stderr travel as separate bounded relay frames and cannot be parsed as control messages. Malformed frames, unknown operations, broken streams, deadlines, and cancellation fail closed and force container removal by a validated container ID.

### Image contract

The worker image is an explicit immutable image reference already available locally. `docker run --pull=never` is mandatory. The image must provide Python 3 for the guest relay and any role-specific executable selected inside the image. Tests may use only an already-cached image for fake workers. Production implementor/fixer activation and provider image preparation remain gated on Phase 7; missing executables fail closed.

### Capability probes

Require actual Docker-backed checks before admission: expected workspace/private-Git read/write; host home, controller state/socket, board storage, shared Git, credentials, SSH agent, keychain, and Docker socket absent; no public network; no host publication route; no channel path write; authenticated inference relay succeeds; forged human-control operation is rejected; cancellation leaves no container or worker descendant. Docker CLI presence alone is not a pass.

## Scope and constraints

- This adds Docker Desktop as an explicit Task 4.3 backend; native macOS and Linux Bubblewrap paths remain separate and fail closed when unavailable.
- No image pull, package/service installation, paid provider call, production activation, board processing, or card #224 operation is allowed.
- `supervisor.enabled` remains `false`.
- Task 4.3 remains open until the focused suite, clean-room checks, final Luna reviews, and all real Docker boundary probes pass.
