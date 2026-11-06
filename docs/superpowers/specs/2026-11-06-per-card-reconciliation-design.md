# Per-card reconciliation: a card advances when its own role returns

Date: 2026-11-06. Status: approved 2026-11-06 (full settle-table follow-on, 60 s wait, clean-room
spend approved), not yet implemented. Nothing under `plugins/` has changed.

## Problem

The manager issues all of a tick's role dispatches in one message and waits for the whole
batch before it reconciles any report (`agents/manager.md` 0.4, 0.5, 2.1). A card whose
implementor finished early therefore waits for the slowest sibling, then for the tick to end,
then for `settle.sh` to move it to In Review, then for `limits.tick_interval`, before its
reviewer is dispatched. On a six-card board that is routinely half an hour of idle time per
card. The user wants a card to move as soon as its own role agent returns.

Rejected before this design: running `settle.sh` on a timer during a tick. It makes two
writers on one card (a clean last review could send a card to Human QA while the same tick's
reviewer is about to post findings).

## What the runtime actually does (measured)

Two things had to be known before anything could be designed: whether a nested agent can
dispatch in the background at all, and who receives a role's completion once the manager has
stopped its turn. Three probes on 2026-11-06, Claude Code 2.1.319, haiku, subscription auth:

| Probe | Setup | Result |
|---|---|---|
| Desktop app, nested | this session → agent → background child | The nested Agent call returned only when the child stopped (16.5 s): nested background dispatch is synchronous in the desktop app. |
| Headless, depth 1 | `claude -p` → background child (`sleep 40`) | Launch acknowledgement in 3 s. The session ended its turn with a partial report; the process stayed alive and the session was re-invoked on each completion (three `result` events, 65 s wall). |
| Headless, depth 2 | `claude -p` → foreground mid agent → background child (`sleep 40`) | Mid got a launch acknowledgement in 1 s, stopped its turn, and its foreground call returned to the top session 9 s later with the child still running. The child's completion and report went to the **top session**; the mid agent was never re-invoked (no events for it after its hand-back). `num_turns` of the top-level result stayed at 3 while mid made nine tool calls, so subagent turns do not count toward `--max-turns`. |

Consequences for the manager, which is the mid agent of the third probe:

1. In headless runs (the overnight wrapper) a role can be dispatched in the background and
   the manager keeps working while it runs.
2. The manager must never end its turn to wait. If it does, its dispatches' reports go to the
   tick skill's session, the manager's Agent call returns, and the tick ends with unreconciled
   dispatches. Waiting has to be a tool call inside the turn.
3. A notification for a finished background dispatch is delivered at the manager's next
   tool-result boundary (this is how every `<task-notification>` in these probes arrived).
   So a bounded Bash `sleep` is a correct wait: when it returns, every report that arrived
   meanwhile comes with it.
4. In the desktop app the nested call is synchronous, so the same rules degrade to today's
   batch behavior with no special casing: every dispatch in a message returns together, no
   dispatch is ever "live" after a call returns, and the wait is never needed.

## Design

### 1. Dispatch in the background, wait inside the turn

- Every role Agent call passes `run_in_background: true` (replacing today's `false`). The
  three mandatory parameters stay: `subagent_type`, `model` from the plan card, and the
  background flag. The `description` names the card and role (`#12 implementor`), and the
  manager keeps a dispatch list for the tick: card, role, round, model, the agent id from the
  launch acknowledgement, and whether its report has arrived.
- A dispatch whose Agent call returns a launch acknowledgement instead of a report is
  **live**. A dispatch whose call returns the report itself (a runtime with no background
  option) is reconciled at once, as today.
- When no reconciliation, follow-on step or queued dispatch is possible and at least one
  dispatch is live, the manager waits with one Bash call, `sleep 60`, with a 600000 ms
  timeout, then handles whatever arrived. It repeats this until no dispatch is live. It never
  polls a card, reads a role's output file or transcript, or re-dispatches to find out.
- The tick report is written only when no dispatch is live and the queue is empty. The manager
  never ends its turn, hands back, or writes a message containing `dispatchable:` while a
  dispatch is live. This is the safety property restated for background dispatch: the tick
  ends only after every dispatch it issued was reconciled. If the manager is cut off anyway
  (`max_hours`, a signal), the role agents die with the `claude` process, because they are
  in-process subagents, and the next tick resumes from the board exactly as after a crash
  today.
- The report of a background dispatch is the text the role hands back in its completion
  message. The wrapping the harness adds (agent id, usage block, hand-back frame, a line
  saying tags were neutralized) is metadata under rule 0.12 and is left out of the report
  file. The token count for the cost line comes from that same usage block (0.13 unchanged).

### 2. Reconcile per report, then re-plan that one card

After a report is accepted and the card's note-upkeep merge is written (steps 3 and 4 of the
spec, unchanged), the manager re-plans **that card only** with the existing settle planner:

```
cd <repo root> && bash <scripts>/tick-plan.sh --settle N
```

It performs the one action the settle plan gives, exactly as its action table says:

| Settle plan says | The manager does, in the same tick |
|---|---|
| `move_to_review` | the `start_review` row: route → move to In Review → note (`round: 1`, `pr`) → `worktree.sh review` → dispatch the reviewer; with no free slot the whole step waits in the queue (3) |
| `advance_stage` | the `advance_stage` row, including the `review_stage` dispatch or provider call that follows it; with no free slot the whole step waits in the queue (3) |
| `to_human_qa`, `mark_ready`, `block` | that row, as today; a `block` whose reason starts with `no progress after` is left to the next tick (2.D is the plan's call) |
| `skip`, anything else | nothing; the next tick plans the card |

Rules:

- Only an accepted report triggers a re-plan. A report rejected twice, or one whose Status is
  `blocked`, leaves the card where step 3 puts it.
- One re-plan per report. The chain therefore runs implementor → reviewer → stage → stage…
  and stops at the first step that needs a `fix` or a `review` of a drifted head, because the
  settle planner never emits those (they are `skip` in a settle plan). The review/fix loop
  still spans ticks, so `max_rounds` pacing and the human checkpoint between ticks are
  unchanged.
- A follow-on step that fails is a warning in the tick report, and the next tick's action for
  the card counts it (the rule 2.8a and 2.9 already use for the dispatch that follows
  `advance_stage` and `fix`). The plan action that produced the report keeps its own
  progress accounting (2.C.3), written before the re-plan, so the planner never sees a stale
  failure count.
- The re-plan is read-only until the manager acts on it, and the manager is still the only
  writer: `settle.sh` runs after the tick, as before.

Why the settle planner and not a new flag: `--settle N` already answers "what moves this card
without the next agent", through the same decision table the tick uses, and `settle.sh`
already mirrors every row it can emit. The manager reusing it means no second table, no new
script, and the follow-on set is exactly the set the user asked for (In Review, the reviewer,
the stages, Human QA, ready, block) and nothing more.

### 3. Concurrency as a running count

- `live` = dispatches issued minus reports received. A role dispatch is issued only when
  `live < limits.concurrency`; otherwise it goes to the back of a FIFO queue. Plan-order first
  steps are queued first; a follow-on dispatch joins the back when it arises. Every report
  that arrives frees a slot, and the manager drains the queue before it waits again.
- Re-dispatches after a rejection, stage dispatches and the reviewer after a fix count, as
  now (2.1). Provider stages do not count and still run inline as one Bash call (0.16).
- The non-dispatch parts of a queued follow-on step (route, move, note merge) run when the
  step is reached, not when its dispatch is issued, so the board never shows In Review for a
  card whose reviewer has not been asked for. A queued dispatch is therefore the whole step.

### 4. Tick report

Same shape. The Action cell lists the chain the card ran this tick, joined by ` → `, and the
Result cell lists the outcomes in the same order, separated by `; `:

```
| #12 | start → start_review | moved to in_progress; implementor reported draft PR #34; routed to []; moved to in_review; round 1 reviewed: 0 Critical, 1 Important |
| #15 | review → to_human_qa | round 2 reviewed: 0 Critical, 0 Important; moved to human_qa |
| #16 | start | moved to in_progress; implementor reported draft PR #35 |
```

Nothing else changes: one row per plan card, `Warnings:` (now also carrying each failed
follow-on step), `Reports rejected:`, the cost line (every dispatch, follow-ons included),
`dispatchable:` from the initial plan or the `file_pending` rule. The wrapper and the tick and
run skills read the report as before.

### 5. `settle.sh` keeps its job

It stays unchanged and still runs after every headless tick. It now mostly finds nothing to
do, and covers what the manager cannot: a follow-on step that failed in the tick (the next
tick retries, settle moves it sooner), a card a person moved by hand between ticks, and a
tick whose manager was cut off. It is still the only mover besides the manager, and still
never runs while the manager does, so there is still one writer at a time. The design note
"One step per card per tick" is reworded to "one step per card per role return": the plan
gives a card its first step, each report it produces earns it one more from the settle
table, and the tick ends when every chain has reached a step that needs the next tick.

### 6. What does not change

The action table rows, the note schema, `tick-plan.sh`, `settle.sh`, `parse-report.sh`, the
gate, the tick and run skills (the tick skill still dispatches the manager with
`run_in_background: false` and waits; a manager that sleeps inside its turn is just a longer
foreground call), the wrapper (it already keeps the last `result` event), config keys,
`limits.concurrency` and `limits.tick_interval` semantics.

## Alternatives considered

- **End the turn to wait for notifications.** Rejected by the depth-2 probe: the manager is
  not re-invoked; its reports go to the tick session and the tick ends unreconciled.
- **One agent per card that drives it to completion.** Rejected in `docs/design.md` ("One
  step per card per tick"): state in memory, no inspectable plan, a hung session takes its
  card with it.
- **Poll the board or the role's output file from Bash.** Rejected: the manager must not read
  role transcripts, the report must be the text the role hands back, and per-card GitHub
  polling spends rate limit for nothing the notification does not already give.
- **Shorter `tick_interval`.** Does not touch the wait for the slowest sibling inside the
  tick, and multiplies plan runs.
- **A new `tick-plan.sh --cards N` that emits agent actions too.** Would let a card run
  review → fix → review inside one tick. Rejected for now: it removes the between-ticks
  checkpoint and the `max_rounds` pacing a person relies on, and the settle table already
  gives exactly the moves asked for. Easy to add later if wanted.

## Risks and how they are covered

- **Harness drift.** Everything above rests on three measured behaviors (async nested
  dispatch, notification at the next tool-result boundary, synchronous nesting in the desktop
  app). The behavioral scenario below re-measures the first two on every run; if a future
  build changes them the scenario fails instead of a tick silently degrading.
- **Sleep granularity.** A finished card can idle up to 60 s. Today it idles for the batch,
  the tick end, settle and `tick_interval` (300 s default).
- **Wake cost.** Each wake is one cached model turn. A 40-minute tick is about 40 wakes, well
  under what a tick already spends on its scripts. Subagent turns do not count toward the
  wrapper's `--max-turns`.
- **Longer ticks.** A tick now lasts until every chain quiesces (implementor plus reviewer,
  plus stages), roughly twice today's wall time. `limits.max_hours` bounds it as before.
- **A neutralized report.** The harness rewrites tag-like text in a hand-back (`<` becomes
  `<\`). A role report holds none by shape, and this already applies to foreground results.
- **Sonnet keeping the count.** The dispatch list and the `live` count are the one piece of
  in-tick state the manager must track. The spec makes both explicit, and the behavioral
  scenario asserts the cap from the transcript's `task_started` events.

## Implementation plan (after approval)

1. **Spec and brief.** `specs/manager.md`: 0.4 (`run_in_background: true`), 0.5 (wait inside
   the turn, the sleep, never end the turn while live), 0.12 (the report of a background
   dispatch), 2.1 (running count and queue), new 2.19 "Follow-on step" (the `--settle N`
   re-plan and its table), 5.2 (the chained Action and Result cells), Must never (end the turn,
   hand back or write `dispatchable:` while a dispatch is live; poll or read an output file;
   re-plan after a rejected report; take more than one follow-on step per report), the example
   tick report. A "Revision 20 requirements" section in `briefs/spec-req-manager.md`.
2. **Re-author `agents/manager.md`** through the documented clean-room process: one isolated
   in-place edit, `claude -p --bare --model opus --tools "Read,Edit" --permission-mode
   acceptEdits --max-turns 40`, fresh empty `CLAUDE_CONFIG_DIR`, staging dir with `edit-req.md`
   and the spec copy, path audit, minimality check, `evidence/author-manager.r20.init.json`,
   README revision entry, manifest hash. Estimated API spend about $0.60 to $0.90 (Revision 17
   cost $0.60 for 33 edits). The running total after Revision 19 is about $42.47.
3. **Offline tests.** New `tests/test-manager-background.sh` in the style of
   `test-manager-stages.sh`: the manager file and the spec carry the background flag, the
   sleep wait, the live rule, the `--settle N` re-plan, the follow-on table and the new
   Must-never lines, and no role-dispatch rule still says `run_in_background: false`.
   `test-tick-background.sh` keeps asserting the tick skill's `false`. `test-tick-plan.sh`
   gains a case that `--settle` on an in_progress card whose note just gained `pr` plans
   `move_to_review` (the exact call the manager now makes). `test-settle.sh` unchanged.
4. **Behavioral evidence.** A new `behavioral-tick.sh --scenario early-review`: two Ready
   cards; a plugin copy whose implementor sleeps 120 s when the card title says so; assert
   from the tick's stream-json that card A's `board-move.sh A in_review` and reviewer
   `task_started` precede card B's implementor hand-back, that `task_started` for roles never
   exceeds `limits.concurrency` at once, and that the report ends with `dispatchable:`. Run
   once, transcript kept as evidence in the PR.
5. **Docs and version.** `docs/design.md` "One step per card per tick" → the reworded
   rationale; `plugins/fleet-board/CLAUDE.md` (the dispatch rule under Invariants, the settle
   step's new role); README `limits.concurrency` row; plugin `0.12.0` → `0.13.0` in both
   manifests.

## Open decisions for approval

1. Follow-on scope: the full settle table after every accepted report (this design), or only
   implementor → reviewer. The full table is the same mechanism with one rule instead of one
   special case, and is what "moves as soon as its role returns" means for a clean review.
2. Wait length: `sleep 60`.
3. API-key spend for the clean-room run: about $1, on top of the ~$42.47 running total.
