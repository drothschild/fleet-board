# Task 4.3 review-fix report

Base reviewed: `7b1daf7e5f81ffb8c3e43be38d4bd5a9a1f2a44e`.
Implementation branch: `codex/persistent-supervisor-effects`.
Implementation head before this report: `bb0cd22028472d9490b2b3f93a837e4ed3b8fb8c`.

## Review findings addressed

- Inference socket requests now use a bounded worker pool. Each request has a framing deadline; each attempt has one in-flight request and an independent quota of eight requests. Slow provider work for one attempt no longer serializes another attempt. Invalid or incomplete connections do not consume an attempt's quota.
- Host qualification now returns a named result for workspace read/write, controller database/socket, board storage, shared Git metadata, host credentials, SSH agent, keychain, symlink escape, loopback network, publication writes, forged control access, and inference-channel access. Production remains unavailable unless every required probe succeeds.
- Isolated worker output uses bounded selector-driven capture. Timeout, output overflow, and cancellation signal the worker process group with TERM, allow a short grace period, then KILL any remaining group members, including descendants whose leader already exited.
- `prepare_private_git` creates an independent private metadata clone and worker clone using local Git only, removes remotes, rejects nonempty/symlink destinations, verifies each common directory stays in its attempt-owned root, and rejects alternates and external credential/config references. Production launch requires this setup.
- Provider requests now carry request IDs. The broker replays a completed identical request, rejects an ID reused with a different body, records structured per-call outcome and usage (preserving unknown usage as `null`), and caps provider invocations at eight per attempt.
- Result generation validation now rejects JSON booleans.

## TDD evidence and commits

Each regression test was committed separately and observed failing before its implementation commit:

| Finding | RED test commit | Implementation commit | RED evidence |
| --- | --- | --- | --- |
| Boolean generation | `3f6bc99` | `4924ee8` | `ContractError not raised` for `generation: true` when expected generation was `1`. |
| Bounded worker capture | `cfa5064` | `9583a22` | No `IsolationUnavailable` was raised after a worker emitted 1 MiB + 1 byte. |
| Attempt inference accounting/deduplication | `a9940d7` | `127e11e` | Broker rejected a request carrying its request ID as an invalid request shape. |
| Channel concurrency and quotas | `c2c46a7` | `1fdacf9` | Slow attempt forced the fast request to wait `1.0178828749340028` seconds (limit `.6`); `_claim_attempt` was absent. |
| Private Git setup | `29b3199` | `890fbb6` | Trusted private Git setup helper was absent. |
| Full host probe | `a752fc6` | `8108036` | Capability result had no named boundary checks. |
| Descendant cleanup | `4958860` | `bb0cd22` | TERM-ignoring child created its `surviving-child` marker after output cancellation. |

Focused GREEN runs passed after their implementations. The full provider fixture suite and runner suite were rerun at final implementation head.

## Verification

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=plugins/fleet-board/scripts python3 plugins/fleet-board/fixtures/supervisor/provider_cases.py /private/tmp` — 17/17 passed.
- `bash plugins/fleet-board/tests/test-supervisor-runner.sh` — passed (`runner identity tests passed`). Host process metadata access was used as requested.
- `bash plugins/fleet-board/tests/test-clean-room.sh` — 118 passed, 0 failed.
- `bash plugins/fleet-board/tests/test-version-bumped.sh` — passed; plugin and marketplace versions advanced from `0.18.6` to `0.18.9`.
- `python3 -m py_compile plugins/fleet-board/scripts/supervisor/inference_broker.py plugins/fleet-board/scripts/supervisor/isolation.py plugins/fleet-board/scripts/supervisor/runner.py` — passed.
- `git diff --check` — passed.

## Open qualification gate

The expanded host probe was run with temporary sentinel files and local-only sockets. On this macOS host, applying the deny-default sandbox still aborts with exit `-6`. The probe reports `available: false`; all 14 named checks remain false because the sandbox process aborts before it can produce probe results. This is an unsupported-host application blocker, not evidence that the access denials passed. Production admission remains fail closed. Task 4.3 implementation/qualification and final acceptance remain open until the sandbox applies on a supported host and every denial and inference-channel probe passes there.

No provider calls, services/packages, board processing, role activation, clean-room file edits, or card #224 activity occurred. Nothing was pushed. The pre-existing `progress.md` modification was preserved and not edited by this work.
