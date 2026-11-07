# Command-provider evidence reviewer: Codex in place of the Claude reviewer

Date: 2026-11-06. Status: design approved in conversation, spec awaiting review.

## Goal

Today the evidence reviewer, the In Review role that maps Acceptance items to tests, runs
the touched tests, makes one mutant per mapped item, re-executes one claim and checks for
weakened tests, can only be the clean-room Claude subagent `fleet-board:reviewer`. Provider
stages can send a PR to another vendor's model, but only as a diff-only reviewer that runs
nothing, so it cannot do mutation.

This design lets `models.reviewer` name a **command provider**, such as the built-in
`codex` preset running `gpt-6-astra`. When it does, the manager runs a new script,
`evidence-review.sh`, instead of dispatching the Claude reviewer. The script gives the
provider a writable throwaway clone of the PR head and the same reviewer contract the
Claude reviewer follows, and checks its reply with the same `parse-report.sh --role
reviewer` rules. The reviewer stops being tied to one vendor; its findings block exactly as
the Claude reviewer's do.

Success: a Codex review posts a reviewer report with `killed / survived / invalid` counts
from mutants it actually ran in its clone, and a report that lacks them, or names a head
other than the PR head, is rejected.

### What the user asked for, and what this design assumes

- Asked: Codex (`gpt-6-astra`) replaces the Opus evidence reviewer, not a second review
  after it. Its findings block. The reviewer is agent-independent and can do mutation.
- Assumed: "agent-independent" means one reviewer contract and one report shape whatever
  runs it. The provider never writes outside a scratch clone. Its mutation counts are
  self-reported, as the Claude reviewer's are today.

### Out of scope

- Making the implementor or fixer pluggable. A generic role runner for all three roles is
  a later step once this one has run on real cards.
- Changing `agents/reviewer.md`. The Claude reviewer stays available as the string form of
  `models.reviewer`.
- HTTP providers as the evidence reviewer. They cannot run commands.
- Re-executing the report's `VERIFIED:` command outside the sandbox (see Risks).

## Config

`models.reviewer` takes either form:

```yaml
models:
  reviewer: opus                      # a Claude model: the clean-room reviewer subagent
```

```yaml
models:
  reviewer: { provider: codex, model: gpt-6-astra, price: { input: 0, output: 0 }, timeout: 1500 }
  escalation: opus
```

Rules `config.sh --check` enforces, each exit 5 with a message naming the key:

- `models.reviewer` is a non-empty string or an object. Any other type is rejected.
- The object's `provider` names a provider whose merged entry has a `review_command`.
  A provider without one (every HTTP provider) is rejected:
  `models.reviewer.provider <name> has no review_command`.
- `model` is a non-empty string. `price` is required, with non-negative `input` and
  `output`, as for provider stages. `timeout` is a positive integer of at most `1500`
  seconds, default `1500` (see "Long reviews").
- When `models.reviewer` is an object, `models.escalation` must be a non-empty string.
  Today escalated implementors and fixers fall back to the reviewer's model, and a command
  provider cannot drive a Claude writer.
- When `models.reviewer` is an object, an agent stage (`review.stages[i].agent`) must set
  its own `model`. Today it defaults to `models.reviewer`.

### `providers.<name>.review_command`

A provider gains an optional `review_command`, used only when that provider is the
evidence reviewer. The existing `command` is unchanged and still serves provider stages.

The `codex` preset in `scripts/providers/presets.json` gains:

```
codex exec --ephemeral --skip-git-repo-check -s workspace-write -c sandbox_workspace_write.network_access=false -C {dir} -m {model}
```

- `{dir}` is replaced by the scratch clone's absolute path and `{model}` by the reviewer's
  `model`. The prompt is written to stdin and stdout is the reply, the contract `chat.sh`
  already uses for `command`.
- `--ephemeral` keeps review sessions off disk. Network is off explicitly, not left to the
  Codex default.

Rules, each exit 5:

- `review_command` must contain `{dir}`.
- `review_command` must not contain `--dangerously-bypass-approvals-and-sandbox`,
  `danger-full-access` or `--dangerously-bypass-hook-trust`.
- `review_command` may not be set together with `base_url`, matching the rule for `command`.

## Planning

`tick-plan.sh` passes the object through unchanged as the plan card's `models.reviewer`,
so the manager can tell the two forms apart by type. The escalation rule becomes
`models.escalation // models.reviewer` only when `models.reviewer` is a string; the config
rule above guarantees `models.escalation` is set otherwise.

Warnings:

- The shared-model warning compares the implementor's model with `models.reviewer.model`
  when the reviewer is an object.
- A reviewer object whose `price` is zero for both `input` and `output` adds one warning:
  `reviewer <provider>/<model> has price 0; max_cost_usd does not count its spend`.

Planning of `review`, `fix`, rounds, stages and merges does not change.

## `evidence-review.sh`

```
evidence-review.sh <n> <pr> --round <r> [--prev-sha <sha>] [--findings <json-file>]
                   [--impl-report <file>] [--card-file <f>] [--diff-file <f>] [--no-post]
```

Arguments mirror `stage-review.sh`. Steps:

1. **Review worktree.** Run `worktree.sh review <n> <pr>`, exactly as the manager does for
   the Claude reviewer. Keep its `sha` (the PR head) and `base` (round 1's merge-base). The
   reference SHA is `base` in round 1 and `--prev-sha` from round 2.
2. **Scratch clone.** `git clone --quiet` the `-review` worktree into a new `mktemp -d`
   directory and check out `sha` detached. Run `worktrees.setup` there when it is set. The
   clone has its own `.git`, so the provider can restore a mutant with
   `git checkout -- <file>`. The existing `-review-copy` cannot serve: it is a `cp -R`
   without `.git`. A git worktree cannot either: it writes into the main repository's
   `.git`, outside the sandbox.
3. **Prompt.** Build it from `scripts/providers/evidence-review-prompt.md` with the inputs
   `agents/reviewer.md` lists: card, PR diff, latest implementor or fixer report, the config
   subset (`commands.test_one`, `commands.typecheck`, `commands.lint`, `review.mutation`,
   `review.verify_claim`, `test_paths`), round, reference SHA and previous Critical and
   Important findings. The prompt tells the model to run every command in its working
   directory, to make and restore mutants there, never to post anything, and to end by
   printing the report alone. Card, diff and reports are framed as untrusted data, as in
   `stage-review-prompt.md`. `worktrees.mutate_on_copy` does not apply: the clone is already
   a copy.
4. **Tripwire snapshot.** Record `git status --porcelain` and `git rev-parse HEAD` for the
   main checkout and the `-review` worktree.
5. **Run.** Call the provider through `providers/chat.sh` with the merged `review_command`,
   `{dir}` and `{model}` filled in, the reviewer's `timeout`, and the scratch clone as the
   working directory.
6. **Tripwire check.** Repeat the snapshot. Any difference is a provider failure: exit 1,
   nothing posted, stderr `evidence-review: <path> changed during the review`. The script
   does not clean up that worktree, so a person can see what happened.
7. **Check.** Run `parse-report.sh --role reviewer` on the reply, then two checks of the
   script's own:
   - `## For the card` holds `reviewed head: <sha>` with the step-1 `sha`.
   - When `review.mutation` is true, `## Mutation` is a `killed: survived: invalid:` line,
     not `skipped`.

   On a rejection, re-ask once, in the same scratch clone, with the rejection quoted, as
   `stage-review.sh` does. The second rejection is exit 6.
8. **Post and record.** Post with `board-comment.sh` unless `--no-post`. Append one line to
   `${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}/provider-spend.jsonl` with `"role":
   "reviewer"`. Print
   `{status, report_file, parsed, provider, model, sha, input_tokens, output_tokens, cost_usd, attempts}`.
9. **Clean up.** An EXIT trap removes the scratch clone on every exit. The `-review`
   worktree is never written by the provider.

Exit codes, matching `stage-review.sh`:

| Exit | Meaning |
|---|---|
| 0 | posted (or checked, with `--no-post`) |
| 1 | provider failure, empty reply, tripwire, a reply holding a `<!-- fleet-board:` marker, or a failed post |
| 2 | usage error, or `models.reviewer` is not an object |
| 3 | the provider is unavailable (its command is not on PATH) |
| 6 | the reply was rejected twice |

There is no exit 7: the provider reads the repository itself, so the diff it is sent is a
starting point, not the whole input, and `max_diff_bytes` does not apply.

## Sandbox

- **Writable:** the scratch clone, and the system temp directory, which `workspace-write`
  allows by default.
- **Read-only:** everything else, including the main checkout, the `-review` worktree and
  the card store.
- **Network:** off. A touched test that needs the network fails inside the review; the
  prompt tells the model to report that in `## For the card`, not to guess.
- The sandbox is the guard. The tripwire (steps 4 and 6) only detects a write that got past
  it to the two checkouts that matter.

### Data egress

A Codex evidence reviewer can read the whole repository and sends what it reads to OpenAI
through the Codex CLI. That is more than a diff-only provider stage sends. The README and
`docs/config.md` say so next to the existing data-egress note.

## Manager

`agents/manager.md` is clean-room: the change is made in the manager spec under
`docs/implementation-plans/2026-09-28-fleet-board/specs/`, then `agents/manager.md` is
re-authored by an isolated `claude -p --bare` run, the manifest is updated and
`test-clean-room.sh` passes. Check the spend ceiling in the plan's `HANDOFF.md` first.

The spec change:

- **Where.** Every place the manager dispatches the reviewer: the `review` action and the
  re-review after `fix`.
- **What.** When the plan card's `models.reviewer` is an object, make no Agent call and do
  not run `worktree.sh review`. Run one Bash call,
  `cd <repo root> && bash <scripts>/evidence-review.sh N <pr> --round <r> --prev-sha <sha> [--findings <f>] --impl-report <f>`,
  with the arguments built as for provider stages (0.18), run in the background as
  "Long reviews" below describes.
- **Exit 0.** Run `parse-report.sh --role reviewer` on the printed `report_file` and record
  `last_review` exactly as for the Claude reviewer, with `sha` from the script's output and
  `provider` and `model` added. The report is already posted.
- **Exit 1, 3 or 6.** A report error, handled like a provider stage's: the card stays
  where it is, the action made no progress and is counted (2.C.4), with
  `last_action_error` the script's last stderr line, and on exit 6 a `report_errors` entry
  with `"role": "reviewer"`.
- **Exit 2.** The error is in the manager's own call: fix the call and run it again.
- **Concurrency.** Unlike a provider stage, an evidence review counts against
  `limits.concurrency`: it runs tests and mutants for minutes.
- **Note.** Every dispatch records the `models` it used, so the note holds the reviewer
  object.

### Long reviews

A Bash call inside `claude -p` is limited to 10 minutes, and a review with mutants can run
longer. So the manager runs `evidence-review.sh` as a **background** Bash call
(`run_in_background: true`) with an explicit `timeout` of `(models.reviewer.timeout + 300)`
seconds, in milliseconds, and waits for its completion notice before reconciling, as it
waits for Agent calls. It reads the script's JSON from the task's output file once
notified. It does not poll the output file while the script runs.

The explicit `timeout` is required. Without it a background call is still killed at the
10-minute default.

`config.sh --check` limits `models.reviewer.timeout` to at most `1500` seconds, so the
background call's timeout never exceeds the 30 minutes the spike below confirmed.

#### Spike result (2026-11-06)

One headless `claude -p --model sonnet --permission-mode auto` session was told to run a
12-minute script in the background and wait for it.

- The first call set `run_in_background: true` and no `timeout`. It was killed at the
  10-minute default.
- The session restarted it with `timeout: 1800000`, waited, was re-invoked when the job
  finished, and returned the job's last line (`SPIKE-DONE`) correctly, 22 minutes after
  start.

So a headless tick can wait on a long background call, provided the call sets `timeout`.
A background timeout above 30 minutes was not tested.

`agents/reviewer.md`, the `reporting` skill and the `tick` skill do not change: the
reviewer's report shape is the same.

## Tests

Offline, one suite at a time, with a fake provider command that follows a script.

1. **`tests/test-evidence-review.sh`** (new):
   - A good report is posted, and the output names `sha`, `provider` and `model`.
   - A report whose `reviewed head:` differs from the PR head is rejected, re-asked once,
     then exit 6.
   - A report with `skipped` mutation while `review.mutation` is true is rejected likewise.
   - The fake writes into the main checkout: exit 1, nothing posted, stderr names the path.
   - The fake writes and commits in its clone: the `-review` worktree is unchanged and the
     clone is gone afterwards.
   - The command exits non-zero, or prints nothing: exit 1.
   - The command receives the clone as `{dir}` and the prompt on stdin, holding the card,
     the diff, the reference SHA and the previous findings.
   - The suite is proved able to fail: run once against a copy of the script with the head
     check removed, and that case fails.
2. **`tests/test-config.sh`:** a reviewer object is accepted; an HTTP provider as reviewer,
   a missing `price`, a missing `models.escalation`, an agent stage without `model`, a
   `review_command` without `{dir}` and one with each forbidden flag are each rejected with
   their message.
3. **`tests/test-tick-plan.sh`:** the plan card carries the reviewer object unchanged; the
   shared-model warning compares `reviewer.model`; a zero-price reviewer gives one warning.
4. **Prompt drift:** a case asserting `providers/evidence-review-prompt.md` names every
   report section and method step `agents/reviewer.md` requires.
5. **Manager branch:** behavioral, not unit. One scenario, after the re-author, with the
   fake provider as reviewer, asserting the tick runs `evidence-review.sh` instead of
   dispatching `fleet-board:reviewer`, and records `last_review` with `provider` and
   `model`. It costs plan usage and runs once.
6. **Live check:** one real `gpt-6-astra` review of a known small PR in `SANDBOX_REPO`,
   only with approval, before this board's `.fleet-board.yml` switches over.

`test-clean-room.sh` passes after the re-author.

## Risks and open points

- **Self-reported mutation.** Codex's `killed / survived / invalid` counts are its own
  claim, as the Claude reviewer's are today. The script checks the head and that counts
  exist; it does not re-run mutants.
- **`VERIFIED:` not re-executed.** Re-running the report's command outside the sandbox
  would execute a model-written command with full access. That risk outweighs the trust it
  adds, so the script does not do it.
- **Zero price.** With `price: {0, 0}` (a ChatGPT-plan login), `max_cost_usd` never sees
  Codex spend. The plan warns once.
- **Sandbox depends on the Codex CLI.** The guarantees above are the Codex CLI's
  `workspace-write` sandbox. The config rules forbid the flags that turn it off, and the
  tripwire detects a write to the two checkouts, but a write elsewhere on disk would not be
  caught.
- **Tests that need setup.** A repo whose tests need dependencies installed relies on
  `worktrees.setup` running in the clone, with the network off unless setup itself needs it.
  Setup runs before the sandboxed provider, outside the sandbox.
- **The existing `codex` stage.** This board's blocking `codex` review stage stays until
  the new reviewer ships. Once Codex is the evidence reviewer, that stage reviews the same
  PR a second time with the same model, and should be removed.
