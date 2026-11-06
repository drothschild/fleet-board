# Review stages: extra review columns with their own agent and model

Date: 2026-11-06. Status: approved design, not yet planned.

## Goal

Today a card has exactly one review stage: In Review, where the clean-room reviewer judges
the PR on evidence and the fixer loop runs until the review is clean or the card blocks.
This design adds **review stages**: extra review columns on the board (Security Review, UX
Review, whatever the repo configures), each with its own reviewer agent and model. A PR
visits a stage when its files match that stage's path globs, and a person can force or
skip a visit with a label. A stage either runs the normal review, fix, re-review loop and
can block the card, or is advisory and only posts its report. After the last stage the card
goes to Human QA, is marked ready for review, or merges exactly as it does now.

Decisions taken during brainstorming (2026-11-06):

- Stages are real board columns, configured in `.fleet-board.yml`, not phases hidden inside
  In Review and not a fixed set shipped by the plugin.
- Routing is per card: path globs by default, with a label a person can add or remove.
- The reviewer in a stage is any agent named in the config. fleet-board requires only that
  it posts the fixed-shape report so the fixer loop works unchanged.
- A finding in a stage is fixed and re-reviewed **in that stage only**; earlier stages are
  not re-run. A stage can be marked advisory.

Out of scope: re-running the evidence reviewer after a later stage's fix; stages before In
Review; per-stage fixers; a stage that runs more than one agent.

## Config

`review.stages` is a list, empty by default, so every existing config keeps its behavior.

```yaml
review:
  max_rounds: 3
  stages:
    - name: security                 # required; ^[a-z][a-z0-9_]*$; unique
      agent: acme:security-reviewer  # required; ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$
      model: opus                    # default: models.reviewer
      paths: ["src/auth/**", "**/*.sql"]   # default: [] (label-only routing)
      label: needs-security-review   # default: needs-<name>-review
      advisory: false                # default false
      max_rounds: 2                  # default: review.max_rounds
      brief: "Focus on authz, secrets, injection."   # optional; passed verbatim
```

Each stage is a canonical state **`review_<name>`**, appended to the fixed state list in
config order: `backlog ready in_progress in_review review_security review_ux human_qa
blocked done wont_do`. `FB_STATES` in `board-lib.sh` becomes config-derived (set by
`fb_load_config`); every script that loops over it (adapter `move`, `init.sh`, the gate's
state resolution) picks the new states up without its own change. Board names come from the
existing mechanism: on the labels backend `fleet:review_security`, on Projects
`Review: security`, both overridable in `board.states`.

`config.sh` validation (exit 5, one line per problem, in the style of the existing messages):

- `review.stages must be a list`
- `review.stages[<i>].name must match ^[a-z][a-z0-9_]*$`
- `review.stages[<i>].name <name> is not unique`
- `review.stages[<i>].agent must match ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$`
- `review.stages[<i>].model must be a non-empty string`
- `review.stages[<i>].paths must be a list of non-empty strings`
- `review.stages[<i>].label must be a non-empty string` (and unique across stages, and not
  `needs-human-qa` or `needs-manual-step`)
- `review.stages[<i>].advisory must be boolean`
- `review.stages[<i>].max_rounds must be a positive integer`
- `review.stages[<i>].brief must be a string`
- `board.states key review_<name> names no stage` when a `board.states` key starts with
  `review_` and no stage has that name.

`config.sh` prints the merged config with every stage's defaults filled in, so no reader
re-derives them. `board.states` keys of the form `review_<name>` are accepted when the stage
exists (the fixed-key regex in the validator grows that alternative).

`config-defaults.json` gains `"stages": []` under `review`. `docs/config.md` gets a
`## review.stages` section and the README key table a `review.stages` row.

## Routing

A new script, `scripts/review-stages.sh`, has two verbs.

- **`route <n> <pr>`**: lists the PR's changed files (`gh pr view <pr> --json files`), and
  for every stage with a `paths` glob that matches a file, adds the stage's label to the
  card (idempotent: a label already present is left alone; a label is never removed). The
  glob rule is the one in `needs-human-qa.sh` (shared by moving it into `board-lib.sh`).
  When `gh` lists fewer files than the PR changes, every stage's label is added and a
  warning says why, matching `needs-human-qa.sh`. Prints the JSON list of stage names whose
  label the card now carries. Exit 1 when the PR's files or the card cannot be read.
- **`next [--labels <json>] <n> --after <in_review|review_<name>> --done <json-list>`**:
  prints the name of the first stage, in config order, that comes after `--after`, whose
  label is on the card, and whose name is not in `--done`; prints nothing when there is
  none. `--labels` takes the card's label names from a read the caller already has, as
  `needs-human-qa.sh` does. Exit 2 on a bad argument.

The labels are the route of record from `start_review` on. A person adds or removes one at
any time before that stage begins; a stage already in `reviewed_stages` is never revisited,
even if its label is put back.

`init.sh` creates, on both backends, each stage's routing label (`--force`, colour
`d93f0b`, description `fleet-board: route to review stage <name>`), and on the labels
backend each stage's state label (colour `5319e7`, the In Review colour). On Projects it
requires a Status option for every stage column and names the missing ones with the same
`board.states` hint it uses today.

## State machine and manager note

The note gains two fields, validated by `note.sh`:

- `stage`: null (the card is in In Review, or before it) or a stage name matching
  `^[a-z][a-z0-9_]*$`.
- `reviewed_stages`: a list of stage names (default `[]`), each matching the same pattern.

`round` resets to 1 on entering a stage. `last_review` gains `stage` (null for In Review),
so a review record from another stage never satisfies the current one. `blocked_from`
accepts `review_<name>` as well as `ready`, `in_progress` and `in_review`; `accept.sh`
returns the card to that stage column.

Two new tick-plan actions:

| Action | Agent? | What the manager (and settle) does |
|---|---|---|
| `advance_stage` | no | `board-move.sh N review_<next>` → `note.sh merge` with `stage: <next>`, `round: 1`, `reviewed_stages` + the stage just finished (`in_review` is not listed; only stage names) → the manager then does `review_stage` for the card in the same tick, as `start_review` dispatches the reviewer today; settle only moves and records. |
| `review_stage` | yes | `worktree.sh review N <pr>` → dispatch the plan card's `stage.agent` on `stage.model`, with the inputs in "Agents and reports" below. |

The plan card carries `stage: {name, agent, model, advisory, brief, max_rounds}` for
`advance_stage`, `review_stage` and `fix` in a stage column, and `null` otherwise. `models`
on the plan card stays as it is; the stage reviewer's model is in `stage.model`.

`tick-plan.sh` lists every `review_<name>` column in addition to ready, in_progress,
in_review and blocked. The decision for a card in a stage column is the In Review branch
with these substitutions:

- "not reviewed yet" is `$lr == null or $lr.stage != <stage> or $lr.round < $round` and
  plans `review_stage`.
- A head that moved after a review plans `review_stage`, with the same reasons as today.
- Critical or Important findings, stage not advisory: `fix` while `round < stage.max_rounds`,
  else `block` (reason `<ci> Critical/Important findings survive round <r> of <max> in
  <stage>`). The manager's `fix` row re-dispatches the **stage's** agent after the fixer, not
  the reviewer, when the plan card has a stage.
- Critical or Important findings, stage advisory: treated as clean for the decision; the
  findings stay in `last_review` and the report is on the card.
- Clean (or advisory): `review-stages.sh next` decides. A next stage plans `advance_stage`;
  none falls into today's tail unchanged: `to_human_qa`, `skip` (human-QA need unknown),
  `mark_ready`, `merge`, `wait`.

The In Review branch changes in one place: after a clean, current review, before the
`needs_human_qa` test, a next stage plans `advance_stage`. `start_review` gains the routing
call: the manager (and settle's `move_to_review`) runs `review-stages.sh route N <pr>` right
after the move, and `start_review`'s plan card lists the stages whose globs matched under
`route` for the tick report.

Escalation (`models.escalate_after_rounds`) reads the stage's round, so a fixer escalates
within a stage the same way it does in In Review. `action_failures` counting is unchanged.

Settle mode keeps `advance_stage` (it starts no agent) and turns `review_stage` into a
`skip` that waits for the next tick. `settle.sh` lists the stage columns as well as
in_progress and in_review. `merge-reviewed.sh --settle-merge` eligibility extends from
"card is in_review" to "card is in_review or in a stage column", through the same plan.

`review-drift.sh` and gate G2 key on `last_review.sha`; a stage review records the head it
reviewed there, so an advisory or clean stage review counts as the reviewed head and a later
commit is drift as it is today. G1 (Human QA) and G3 (Acceptance) need no change.

## Agents and reports

`parse-report.sh --role stage-reviewer` requires `## Status` (`clean` or `findings`),
`## Findings`, `## For the card` and exactly one `VERIFIED:` line, with the same line rules,
and no `## Acceptance map`, `## Mutation` or `## Claim check`. `clean` still means zero
Critical and Important findings. The reporting spec and the clean-room reporting skill gain
the role, its rules and its rejection messages.

The manager dispatches a stage agent with `subagent_type` = `stage.agent`, `model` =
`stage.model`, `run_in_background: false`, and these inputs: the card number and body; the
PR number; the PR diff (file path over 1500 lines, as for the reviewer); the latest
implementor or fixer report text; the review worktree path; the config JSON; the stage
name and its `brief` verbatim; the round; `prev_sha`; the previous Critical and Important
findings from round 2 on; the absolute scripts dir; and the instruction to check and post
its report with `parse-report.sh --role stage-reviewer` and `board-comment.sh` in one Bash
call, as every role does. The manager checks the report with `--role stage-reviewer`, and
re-dispatches once on rejection, as for any role.

The manager's standing rule 0.3 ("every Agent call has `subagent_type` set to one of the
three fleet roles") becomes: one of the three fleet roles, **or the `stage.agent` of the
plan card being acted on**, never any other agent. Rule 0.4 adds `stage.model` as the
model source for that dispatch. The note's `models` is unchanged; `last_review` records
`agent` and `model` for a stage review.

The manager agent and the reporting skill are clean-room: `specs/manager.md` and
`specs/reporting.md` change, the briefs are updated, and both files are re-authored by the
isolated `claude -p --bare` process described in `specs/README.md`, with the manifest and
the README's revision record updated in the same commit. That run spends API key against
the ceiling recorded in the private handoff; check the running total first. The reviewer,
implementor and fixer agents are untouched.

## Status, docs and tests

`status.sh` prints one section per stage column after In Review, in config order, titled
by the stage's board name, with each card's line as `#<n> <title> · round <r> · PR #<pr> ·
<fixer model>/<stage agent>@<stage model>`. `--forecast` lists the stage columns too. The
status skill is a hand-edited exception already and needs no text change: the script owns
the format.

`docs/design.md`'s state diagram gains `in_review --> review_<stage>` and
`review_<stage> --> review_<stage>` (fix), `--> human_qa`, `--> done` and `--> blocked`
edges, with a short section on why stages are columns and why a later stage's fix is not
re-reviewed by the evidence reviewer (cost; the trade-off is named, not hidden).
`plugins/fleet-board/CLAUDE.md` records the new note fields, actions and the
config-derived `FB_STATES`.

Offline suites, each written before its implementation and each proven to fail first:

- `test-config.sh`: stages parse, defaults fill in, every validation message above.
- `test-review-stages.sh` (new): `route` labels on glob match, large-PR fallback, `next`
  ordering, done-skip, no-label skip, usage errors.
- `test-tick-plan.sh`: `advance_stage` from In Review and from a stage; `review_stage` when
  unreviewed, when the record is from another stage, when the head moved; `fix` and `block`
  at the stage's own max_rounds; advisory findings advance; last stage falls into the tail;
  settle filtering; the stage columns are listed.
- `test-note.sh`: `stage`, `reviewed_stages`, `blocked_from: review_x` validation.
- `test-parse-report.sh`: the `stage-reviewer` role.
- `test-settle.sh`: `advance_stage` and `move_to_review` routing.
- `test-status.sh`, `test-init.sh`, `test-board-labels.sh`, `test-board-projects.sh`:
  stage columns and labels.
- `test-clean-room.sh` and `test-clean-room-manifest.sh` after the re-authoring.
- `test-readme-claims.sh`: the new config row.

One live behavioral scenario (`behavioral-tick.sh --scenario stage-path`), run once when
asked: a toy card whose PR touches a routed path goes Ready → In Progress → In Review →
Security Review (a project-local stub agent that posts a clean `stage-reviewer` report) →
ready-for-review PR, with the stage label applied by the fleet and the note's
`reviewed_stages` holding `security`.

## Risks and open points

- **Agent name trust.** The stage agent comes only from the repo's own config, validated by
  `config.sh`, and the manager is told never to dispatch any other name. A hostile config is
  the repo owner's own doing, as with `commands.*` today.
- **A third-party agent that never posts.** Handled by the existing report path: rejection,
  one re-dispatch, then a report error in the note and no state change; `action_failures`
  blocks the card after `review.max_rounds` such ticks.
- **Later-stage fixes unseen by the evidence reviewer.** Accepted trade-off, documented in
  `docs/design.md`. A later design may add `review.recheck_after_stages: true`.
- **Projects boards** need a Status option per stage before `init.sh` passes; the hint names
  them.
