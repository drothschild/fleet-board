# CLI supervisor live smoke: one headless reviewer session

Date: 2026-11-11 (task 3.4, Phase 3). Branch `feat/cli-supervisor-p3`, head `ad1c014`. Claude Code 2.1.322.
Result: the supervisor's own code path launched one real `claude -p --agent fleet-board:reviewer` session; the plugin
agent resolved, the session acted as the reviewer, its report passed `parse-report.sh`, and the card and ledger were
updated. No fallback was needed; `roles.command` is unchanged.

## What ran

A throwaway git repo (acme/toy, `.fleet-board.yml` with `worktrees.dir .fw`, `models.reviewer opus`,
`headless.permission_mode auto`, `limits.max_turns 25`, `commands.test_one "python3 {file}"`), a local board with card 12
in `in_review` (one acceptance bullet: `subtract(5, 2) returns 3`), and a review worktree at a one-commit PR head that
adds `subtract` and its test. `gh` was `tests/fake-gh.sh` with a routes file (`pr diff`, `pr view`), so no GitHub call
was made; `worktree.sh review` was stubbed to return the fixture worktree. `FLEET_BOARD_CLAUDE` was unset, so the real
`claude` ran, and `FLEET_BOARD_PLUGIN_DIR` pointed at this checkout's `plugins/fleet-board`.

Path: `loop.config_loader` -> `CardDriver.begin(review candidate)` (`resolver.resolve` -> `role_prompt` ->
`roles.command` -> `roles.launch`) -> `Session.poll()` until a `RoleResult` -> `CardDriver.finish`.

## argv (prompt shortened)

```
claude -p <PROMPT 2535 chars> --agent fleet-board:reviewer --plugin-dir ~/Projects/.fleet-worktrees/cli-supervisor-p3/plugins/fleet-board --model opus --permission-mode auto --output-format stream-json --verbose --max-turns 25
```

## init event

- `permissionMode`: `auto` (matches the request; no mismatch).
- `model`: `claude-opus-5-5`.
- `agents` lists `fleet-board:reviewer` (and the other fleet-board agents): `--plugin-dir` made the plugin's agents
  available to `--agent`.
- `plugins` shows `fleet-board@inline` version 0.22.0 loaded from the checkout.
- `tools`: `Read, Write, Edit, Bash` (the agent's tool list was applied; the agent file also lists Grep and Glob, which
  this build does not show as separate tools).

## Did `--agent fleet-board:reviewer` resolve

Yes. claude accepted the flag and the session behaved as the reviewer agent: it recorded `reviewed head: <sha>`, mapped
the acceptance bullet to a test, made one mutant (`a - b` to `a + b`, killed), ran one claim check, and wrote the
fixed-shape report (Status, Findings, For the card, Acceptance map, Mutation, Claim check, VERIFIED). It posted the
report with `board-comment.sh` itself, as the agent prompt instructs. It changed no code (review worktree clean).

## RoleResult

`exit_code 0`, `failure None`, `reason None`, `timed_out False`, `cancelled False`, `session_id` set,
`usage = (input 12, output 3195, cache_write 27430, cache_read 121727, model claude-opus-5-5)`. Wall time about 53 s.

## `result` event usage

`subtype success`, `is_error false`, `num_turns 8`, `terminal_reason completed`.

| field | tokens |
|---|---|
| input_tokens | 12 |
| output_tokens | 3195 |
| cache_creation_input_tokens | 27430 (all `ephemeral_1h`) |
| cache_read_input_tokens | 121727 |

`modelUsage` carries the same four numbers under `claude-opus-5-5`. The total is about 152 thousand tokens for a
one-line PR with one acceptance bullet, mutation and claim check on. Against the 20M default limit that is about 0.76
percent per review, so the default allows on the order of 130 such reviews. A real PR with a long diff, several bullets
and more turns will cost several times more. Cache reads are about 80 percent of the total; whether the limit should
count them at full weight is a policy question this single sample cannot settle.

## Ledger line (`.fleet-board/usage.jsonl`, one line)

```
{"run_id":"smoke-run","card":12,"kind":"card","column":"in_review","action":"review","role":"reviewer","provider":"claude","model":"claude-opus-5-5","input":12,"output":3195,"cache_write":27430,"cache_read":121727,"started_at":"2026-11-12T03:05:55Z","ended_at":"2026-11-12T03:06:48Z","log":"/tmp/fb-smoke.<id>/logs/card-12-review-<ms>-1.jsonl"}
```

## Reconciliation

`finish()` returned `Outcome(card=12, progressed=True, redispatch=False, provider_failure=None)`:
`parse-report.sh --role reviewer` exited 0 (verdict: status `clean`, 0 Critical, 0 Important, 1 Minor). The card's note
got `last_review = {round 1, sha <PR head>, critical 0, important 0, findings [one Minor], stage null, ...}`. The card
holds the posted report as a comment next to the manager note.

## Posted report, first lines

```
## Status
clean

## Findings
- [Minor] The latest implementor report was empty, so there was no stated claim to check; the claim check used the PR's implied claim that its touched test file passes

## For the card
reviewed head: <sha>
```

The empty implementor report is a fixture gap, not a defect.

## Process note

The harness unset `FLEET_BOARD_CLAUDE` in-process, so an intended dry run with a fake claude became the real run. Only
one real session was started in total.
