# Review stages + provider-backed stages: combined execution plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship review stages (extra review columns with their own agent and model) and provider-backed stages (a stage reviewed by an OpenAI-compatible model instead of a Claude agent) as one change, with one clean-room re-author of the manager.

**Architecture:** This document is an ordering over two task plans that live beside it. Each task below names the plan and task number whose body the implementer follows, and lists the **deltas** that the other plan imposes on it. Where both plans touch the same file in the same task, the delta says what changes in the base task's tests and interfaces. The clean-room re-author of the manager and reporting skill happens once, for both designs.

**Tech Stack:** bash 3.2, jq, curl, gh, plain-bash suites; `claude -p --bare` for the re-author.

**Specs and plans:**
- Review stages design: `docs/specs/2026-11-06-review-stages-design.md`
- Review stages plan (**RS**): `docs/plans/2026-11-06-review-stages.md` — Task 1 is done on this branch (commits `fb70dd6`..`a935836`).
- Provider stages plan (**P**): `docs/plans/2026-11-06-provider-review-stages.md` — its design decisions are in its header; its Prerequisite section is satisfied by this ordering.

## Global Constraints

Both plans' Global Constraints apply. Where they differ:

- One version bump: `0.10.0` → `0.11.0` in both manifests, in the docs task (RS 11 + P 7), not twice.
- One clean-room revision (Revision 16) covering both designs; one authoring run per file (`manager.md`, `reporting/SKILL.md`). Check the API-key running total in the private handoff before the run.
- Commit messages carry `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Every stage object printed by `config.sh` has the same nine keys: `name, agent, provider, model, paths, label, advisory, max_rounds, brief`, plus `price, timeout, max_output_tokens, max_diff_bytes` (P Task 1 adds the last four and `provider`). Agent stages carry `provider: null, price: null` and the three numeric defaults filled in.

## Review Focus

Both plans' Review Focus lists stand. Two interactions between them are not covered by either plan alone; their tests are added below:

1. A stage with `provider` set and no `agent` must be accepted by `config.sh`, and its plan card must carry `stage.agent == null` so the manager never tries an Agent dispatch (Task C1 config test, Task C7 tick-plan test).
2. `settle.sh` must treat `review_stage` for a provider stage as a `skip` like any other, never run `stage-review.sh` itself: provider calls happen only inside a tick, where the manager records the outcome in the note (Task C8 settle test `provider_review_stage_is_skipped_by_settle`).

---

## Task order

| # | Base task | Deltas |
|---|---|---|
| C1 | RS 2 `review-stages.sh` | none |
| C2 | RS 3 note fields | + P 5 Step 1 (`last_review.provider`) |
| C3 | RS 4 `parse-report.sh --role stage-reviewer` | none |
| C4 | P 1 config `providers` and provider stages | on top of RS 1 as implemented; see below |
| C5 | P 2 `providers/chat.sh` | none |
| C6 | P 3 `stage-review.sh` | none |
| C7 | RS 5 tick-plan + P 4 (tick-plan half) | one task; see below |
| C8 | RS 6 settle, merge-reviewed | + one settle test; see below |
| C9 | RS 7 init | none |
| C10 | RS 8 status + P 4 (status half) | see below |
| C11 | RS 9 gate | none |
| C12 | RS 10 + P 5 clean-room re-author | one Revision 16; see below |
| C13 | P 6 headless run ledger | none |
| C14 | P 7 eval runner (Steps 1–5 only) | docs and version move to C15 |
| C15 | RS 11 + P 7 docs | one version bump; see below |
| C16 | RS 12 live scenario (only when asked) | none |

---

### Task C1: `review-stages.sh` — follow RS Task 2 as written.

### Task C2: Note fields — follow RS Task 3, then add P Task 5 Step 1

- [ ] After RS 3 Step 3, add to `test-note.sh`: `last_review.provider` accepts `null` and `"openai"`, rejects `"Open AI"` (`{}` + warning naming `last_review.provider`). Pattern `^[a-z][a-z0-9_-]*$`. Implement in `note.sh`'s `invalid_field`, beside the `last_review.stage` check. Commit with RS 3 Step 4.

### Task C3: `parse-report.sh --role stage-reviewer` — follow RS Task 4 as written.

### Task C4: Config — follow P Task 1 with these deltas

RS Task 1 is already implemented in `config.sh` (`STAGE_DEFAULTS` fill and the stage validation block). P Task 1 extends them:

- `STAGE_DEFAULTS` gains `provider: ($s.provider // null)`, `price: ($s.price // null)`, `timeout: ($s.timeout // 600)`, `max_output_tokens: ($s.max_output_tokens // 16000)`, `max_diff_bytes: ($s.max_diff_bytes // 400000)`, and `agent` becomes `($s.agent // null)`.
- Validation: `review.stages[<i>] must set exactly one of agent and provider` fires when both or neither are non-null; the existing `agent must match` check runs only when `provider` is null; `model` is required with `provider` (`review.stages[<i>].model must be set when provider is set`) and keeps its `models.reviewer` default only for agent stages.
- Update two existing expectations in `test-config.sh`: the `stages: defaults filled` and `stages: explicit values kept` JSON strings gain `"provider":null,"price":null,"timeout":600,"max_output_tokens":16000,"max_diff_bytes":400000` (key order: after `agent` for `provider`; the rest after `brief`). The `stage missing agent` case's expected message becomes `review.stages[0] must set exactly one of agent and provider`.
- `fixtures/config/stages.yml` gains a third stage `{name: compliance, provider: openai, model: gpt-test, price: {input: 1, output: 2}}` so later suites have a provider stage.
- Everything else in P Task 1 (presets, `providers` validation, README rows, `docs/config.md`) as written.

### Task C5: `providers/chat.sh` — follow P Task 2 as written.

### Task C6: `stage-review.sh` — follow P Task 3 as written.

The `--stage` must name a provider stage; `agent_stage_is_usage_error` stays. Config comes from `config.sh` as in C4.

### Task C7: tick-plan — follow RS Task 5, then P Task 4's tick-plan half, in one task

- The plan card's `stage` object is the config stage object whole, so it carries `provider` (and `price`, `timeout`, `max_output_tokens`, `max_diff_bytes`) with no extra code; RS 5's assertions stand.
- Add P Task 4's tests `review_stage_plan_card_has_provider`, `agent_stage_plan_card_has_null_provider`, `unset_key_warns_once`, `set_key_no_warning`, `no_warning_when_stage_not_acted_on`, using the `compliance` stage from C4's fixture. Warning text: `stage <name>: <ENV> is not set; provider reviews will fail`. The env check runs in bash, passed to jq as `--argjson unset`.
- Commit RS 5's tests and P 4's tests together, then the implementation.

### Task C8: settle and merge-reviewed — follow RS Task 6, plus one test

- [ ] Add to `test-settle.sh`: a card in `review_compliance` (provider stage), note stage `compliance`, no `last_review` → settle plans `skip` with reason `review_stage waits for the next tick`, and `stage-review.sh` is not on the fake's call log (put a `stage-review.sh` stub on `PATH` that writes to the log and fails if called).

### Task C9: init — follow RS Task 7 as written.

### Task C10: status — follow RS Task 8, plus P Task 4's status half

- The stage card line: `· <models.fixer>/<stage.agent>@<stage.model>` for an agent stage, `· <models.fixer>/<stage.provider>:<stage.model>` for a provider stage. Add P 4's `provider_stage_line` test beside RS 8's expected block (a card in `fleet:review_compliance` → `sonnet/openai:gpt-test`).

### Task C11: gate — follow RS Task 9 as written.

### Task C12: Clean-room Revision 16 — RS Task 10 and P Task 5 as one revision

- The "Revision 16 requirements" list in both briefs holds RS 10's rules **and** P 5's spec changes (the `review_stage` and `fix` rows for `stage.provider` non-null, the exit mapping, the `stage-review.sh` "never by any other means" rule, the 5.4 cost line, `last_review.provider`). Edit `specs/manager.md` and `specs/reporting.md` for both in one pass.
- `test-manager-stages.sh` greps RS 10's phrases plus `stage-review.sh` and `stage.provider` in both the spec and `agents/manager.md`.
- One authoring run per file, RS 10 Steps 5–9. Evidence files `author-manager.r16.init.json`, `author-reporting.r16.init.json`.
- Skip P Task 5 Step 1 (done in C2) and P 5's separate re-author.

### Task C13: Headless run ledger — follow P Task 6 as written.

### Task C14: Eval runner — follow P Task 7 Steps 1–5, but leave `docs/reviewer-eval.md` rows, `docs/design.md`, `CLAUDE.md` and the version bump to C15. Step 6 (paid) only when asked.

### Task C15: Docs and version — RS Task 11 and P Task 7's docs as one task

- `README.md`: rows `review.stages`, `providers`, `review.stages[].provider` (C4 already added the two provider rows with their readme-claims checks; RS 11's `review.stages` row and check join them).
- `docs/config.md`: RS 11's `## review.stages` section, with the provider keys and data-egress paragraph from P 1 folded into it, and `## providers`.
- `docs/design.md`: RS 11's diagram edges and "Review stages are columns" section, plus P 7's paragraph on why a provider stage is a script.
- `plugins/fleet-board/CLAUDE.md`: both plans' contract lines; `Last verified: 2026-11-06`.
- `docs/reviewer-eval.md`: provider rows marked `not run`.
- `docs/overnight.md`: P 6's paragraph.
- Version `0.10.0` → `0.11.0` once. `test-version.sh`, `test-readme-claims.sh`, `test-clean-room.sh` pass. Commit, push, `gh pr view --web`.

### Task C16: Live scenario — RS Task 12, run only when asked.

---

## Not in this plan

Both plans' "Not in this plan" / "Out of scope" sections stand: no external models for the implementor, fixer or evidence reviewer; no native provider APIs; no provider live scenario (an Ollama-on-loopback `provider-stage` scenario is the natural follow-up).
