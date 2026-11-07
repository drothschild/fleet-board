# Board Throughput Implementation Plan

**Goal:** Drain reviewed merges safely, reserve scopes during admission, then advance cards on worker completion.

**Architecture:** Keep the planner authoritative and merges serialized. Replan after mutations; require successful main verification before further merges. Reserve ready-card scopes within each plan. Prepare completion-driven manager behavior through the clean-room spec.

**Tech Stack:** Bash 3.2, jq, plain-bash offline tests.

**Spec:** `docs/superpowers/specs/2026-11-07-board-throughput-design.md`

## Task 1: Merge draining and verification
- [x] Add failing regressions to tests/test-merge-reviewed.sh and focused planner tests; run and commit tests.
- [x] Drain a bounded snapshot of eligible cards, replanning after every attempt; never retry a failed card in the same pass.
- [x] Enforce literal successful main verification, preserve failed evidence, stop subsequent merges on verification/recovery failure.
- [x] Run touched suites and clean-room checks; commit and push.

## Task 2: Scope reservations
- [x] Add and commit failing planner regressions for overlapping starts in one plan, disjoint starts and existing active scope.
- [x] Reserve scopes incrementally in deterministic order and account for actual PR paths when available.
- [x] Run touched suites and clean-room checks; commit and push.

## Task 3: Completion-driven scheduling
- [x] Prepare spec and behavioral scenario for per-completion reconciliation, bounded advancement, shared worker slots, and fresh stop decisions.
- [x] Add failing offline wrapper regressions; implement fresh dispatchability after settlement and merge draining.
- [x] Obtain approval for paid isolated manager re-authoring (user approved in chat).
- [x] Obtain separate approval for the core behavioral validation run once its harness is ready.
- [x] Re-author, run structural checks, independently review and push approved changes.
- [ ] Pass runtime completion validation: two approved attempts cost $0.1918922 total but dispatched no reviews because bare mode omitted Write. Harness now uses isolated non-bare mode, confirmed offline to expose Write; another paid attempt needs separate approval.

All source paths above are relative to plugins/fleet-board/. Never edit clean-room primitives by hand. Follow test-first commits and run only touched suites plus test-clean-room.sh. No paid calls without explicit approval.
