# Command-Provider Evidence Reviewer Implementation Plan

> **For agentic workers (any agent):** Read `AGENTS.md` and the two `CLAUDE.md` files it names, then the spec below. Implement this plan task by task, in order. Steps use checkbox (`- [ ]`) syntax: tick each one in this file as you finish it, and commit after each task. Stop and ask a person before Task 6 Step 4 and Task 7 Steps 3 and 4, which spend money.

**Goal:** Let `models.reviewer` name a command provider (Codex, `gpt-6-astra`) that runs the full evidence review, mutation included, in a sandboxed scratch clone, in place of the Claude reviewer subagent.

**Architecture:** A new `evidence-review.sh`, shaped like `stage-review.sh`, clones the PR head, runs the provider's new `review_command` in that clone through `chat.sh`, checks the reply as a `reviewer` report, and posts it. `config.sh` accepts a reviewer object, `tick-plan.sh` passes it through, and the clean-room manager runs the script in the background instead of dispatching `fleet-board:reviewer` when the reviewer is an object.

**Tech Stack:** bash 3.2, jq, git, the Codex CLI; plain-bash test suites.

**Spec:** `docs/superpowers/specs/2026-11-06-codex-evidence-reviewer-design.md`

## Global Constraints

- Scripts run under macOS `/bin/bash` 3.2 and BSD and GNU tools: no bash 4 features; `sed -i.bak`, never bare `sed -i`; `unset CDPATH` before a captured `cd`; `LC_ALL=C` for any `awk` reading a decimal.
- No absolute or personal paths in plugin files; scripts find each other through their own directory.
- `agents/*.md` and `skills/{reporting,tick,run,status}/SKILL.md` are clean-room: never hand-edit; change the spec under `docs/implementation-plans/2026-09-28-fleet-board/specs/`, run an isolated in-place edit, record a Revision in `specs/README.md`, update `specs/clean-room-manifest.txt`.
- Tests are plain-bash suites under `plugins/fleet-board/tests/`. Run only the suite you touched. After any change under `plugins/fleet-board/`, `bash plugins/fleet-board/tests/test-clean-room.sh` must pass.
- Every new suite is shown to fail once before it is trusted.
- Reviewer object defaults: `timeout` `1500`, maximum `1500` seconds. The manager's background call timeout is `(timeout + 300) * 1000` ms.
- `codex` preset `review_command`, verbatim: `codex exec --ephemeral --skip-git-repo-check -s workspace-write -c sandbox_workspace_write.network_access=false -C {dir} -m {model}`
- Forbidden in any `review_command`: `--dangerously-bypass-approvals-and-sandbox`, `danger-full-access`, `--dangerously-bypass-hook-trust`.
- `evidence-review.sh` exit codes: 0 posted or checked; 1 provider failure, empty reply, timeout, tripwire, marker in reply, setup failure or failed post; 2 usage error or `models.reviewer` not an object; 3 the `review_command` program is not on PATH; 6 rejected twice.
- Version: bump `fleet-board` from `0.14.0` to `0.15.0` in both `plugins/fleet-board/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.

## Review Focus

1. **The PR head moves during the review** (someone pushes while Codex works): the report naming the step-1 head is accepted, and the printed `sha` is the step-1 head, so the next tick sees the move and re-reviews. Test in Task 5.
2. **Codex is not installed**: exit 3 with `evidence-review: codex is not on PATH`, before any clone is made, so the manager counts a report error instead of crashing. Test in Task 5.
3. **The review runs past its timeout**: exit 1, nothing posted, the scratch clone removed. Test in Task 5.
4. **`worktrees.setup` fails in the clone** (a missing dependency): exit 1 with `evidence-review: setup failed`, nothing sent to the provider. Test in Task 5.
5. **A scratch path with a space or a quote** reaches `{dir}`: `chat.sh` substitutes it shell-quoted, and the command still receives the exact path. Test in Task 1.

---

### Task 1: `chat.sh` runs a command in a given directory

**Files:**
- Modify: `plugins/fleet-board/scripts/providers/chat.sh` (header comment, argument parsing, the command-mode block near line 98)
- Test: `plugins/fleet-board/tests/test-providers.sh`

**Interfaces:**
- Produces: `chat.sh --command <string> --model <id> --timeout <s> [--dir <path>]`. With `--dir`, the command runs with `<path>` as its working directory and `{dir}` in the string is replaced by `<path>` single-quoted for `sh -c` (`'` inside becomes `'\''`). Without `--dir`, behavior is unchanged: repo root, `{dir}` left as written. `--dir` without `--command` is a usage error (exit 2). A `--dir` that is not a directory exits 2.

- [x] **Step 1: Write the failing tests** in `test-providers.sh`, using a fake command `sh -c 'pwd; printf "%s\n" "$0"' {dir}` style or an equivalent fake script:
  - `command mode --dir runs in the given directory`: stdout's text starts with the given dir.
  - `command mode --dir substitutes {dir}`: the fake echoes its argument; it equals the dir.
  - `command mode --dir quotes a path with a space and a quote`: dir `"$TMP/a b'c"`; the echoed argument equals it exactly.
  - `--dir without --command is a usage error`: exit 2.
  - `--dir naming a missing directory exits 2`.
- [x] **Step 2: Run** `bash plugins/fleet-board/tests/test-providers.sh` — Expected: the five new cases FAIL, the rest pass.
- [x] **Step 3: Implement `--dir`** in `chat.sh`: parse it, validate it, quote it, substitute `{dir}` after `{model}`, and `cd` into it instead of `$ROOT`.
- [x] **Step 4: Run** `bash plugins/fleet-board/tests/test-providers.sh` — Expected: `failed: 0`.
- [x] **Step 5: Commit** `chat.sh: run a command provider in a given directory`.

### Task 2: Config accepts a command-provider reviewer

**Files:**
- Modify: `plugins/fleet-board/scripts/providers/presets.json` (add `review_command` to `codex`)
- Modify: `plugins/fleet-board/scripts/config.sh` (`PROVIDER_DEFAULTS`, `STAGE_DEFAULTS`, a new reviewer-defaults step, the validation script)
- Modify: `plugins/fleet-board/docs/config.md` (`models.reviewer` object, `review_command`, data egress), `plugins/fleet-board/README.md` (config table rows)
- Test: `plugins/fleet-board/tests/test-config.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: merged config where `models.reviewer` is either a string or `{provider, model, price: {input, output}, timeout}` with `timeout` filled (default `1500`), and `providers.<reviewer.provider>` present with its preset merged in (so `review_command` is readable at `.providers[$p].review_command`). Error messages, verbatim:
  - `models.reviewer must be a non-empty string or an object`
  - `models.reviewer.provider <name> names no provider`
  - `models.reviewer.provider <name> has no review_command`
  - `models.reviewer.model must be a non-empty string`
  - `models.reviewer.price must have non-negative input and output`
  - `models.reviewer.timeout must be an integer from 1 to 1500`
  - `models.escalation must be set when models.reviewer is a provider`
  - `review.stages[<i>].model must be set when models.reviewer is a provider` (agent stages only)
  - `providers.<name>.review_command must contain {dir}`
  - `providers.<name>.review_command must not contain <flag>`
  - `providers.<name> sets both review_command and base_url`

- [x] **Step 1: Write the failing tests** in `test-config.sh`, one case per message above (exit 5, stderr contains the message), plus:
  - `reviewer object is accepted`: `models.reviewer: { provider: codex, model: gpt-6-astra, price: { input: 0, output: 0 } }` with `models.escalation: opus` exits 0, `.models.reviewer.timeout` is `1500`, and `.providers.codex.review_command` equals the Global Constraints string.
  - `reviewer string is unchanged`: a config that does not set `models.reviewer` yields `.models.reviewer == "opus"` (the default in `config-defaults.json`), and no `models.escalation` error.
  - `codex stage keeps its read-only command`: a stage with `provider: codex` still reads `.providers.codex.command` with `-s read-only`.
- [x] **Step 2: Run** `bash plugins/fleet-board/tests/test-config.sh` — Expected: new cases FAIL.
- [x] **Step 3: Implement** in `config.sh`: include `models.reviewer.provider` in the providers filled by `PROVIDER_DEFAULTS`; fill the reviewer object's `timeout`; make `STAGE_DEFAULTS` leave an agent stage's `model` `null` when `models.reviewer` is an object (validation then names it); replace the `reviewer` arm of the `models.<role> must be a non-empty string` rule with the reviewer rules; add the `review_command` rules beside the `command` rules. Add `review_command` to the `codex` preset.
- [x] **Step 4: Run** `bash plugins/fleet-board/tests/test-config.sh` — Expected: `failed: 0`.
- [x] **Step 5: Docs.** In `docs/config.md`, document the object form under a `models.reviewer` heading, `review_command` in the `providers` key table, and add the egress sentence from the spec's "Data egress". Add the README config-table rows.
- [x] **Step 6: Commit** `config: models.reviewer may name a command provider`.

### Task 3: The planner passes the reviewer object through

**Files:**
- Modify: `plugins/fleet-board/scripts/tick-plan.sh` (models block near line 776, warnings near line 836)
- Test: `plugins/fleet-board/tests/test-tick-plan.sh`

**Interfaces:**
- Consumes: Task 2's merged reviewer object.
- Produces: each plan card's `models.reviewer` is the merged object, byte-for-byte as `config.sh` emits it. Escalated implementor and fixer use `models.escalation`, and fall back to `models.reviewer` only when it is a string. New warning, verbatim: `reviewer <provider>/<model> has price 0; max_cost_usd does not count its spend`.

- [x] **Step 1: Write the failing tests** in `test-tick-plan.sh`:
  - `reviewer object: plan card carries it unchanged`: `.cards[0].models.reviewer == {provider:"codex", model:"gpt-6-astra", ...}`.
  - `reviewer object: escalated writers use models.escalation`: at `round >= escalate_after_rounds`, implementor and fixer are `opus`.
  - `reviewer object: shared-model warning compares reviewer.model`: implementor `gpt-6-astra` gives the shared-model warning naming `gpt-6-astra`; implementor `sonnet` gives none.
  - `reviewer object: zero price warns once`: exactly one warning equal to the string above.
- [x] **Step 2: Run** `bash plugins/fleet-board/tests/test-tick-plan.sh` — Expected: new cases FAIL.
- [x] **Step 3: Implement** the type check in the escalation expression, compare `($m.reviewer | if type == "object" then .model else . end)` in both shared-model warnings, and add the zero-price warning.
- [x] **Step 4: Run** `bash plugins/fleet-board/tests/test-tick-plan.sh` — Expected: `failed: 0`.
- [x] **Step 5: Commit** `tick-plan: pass a provider reviewer through`.

### Task 4: The evidence-review prompt

**Files:**
- Create: `plugins/fleet-board/scripts/providers/evidence-review-prompt.md`
- Create: `plugins/fleet-board/tests/test-evidence-review-prompt.sh`

**Interfaces:**
- Produces: a template in the `stage-review-prompt.md` format (system text, a `---USER---` line, user text) with placeholders `{{ROUND}}`, `{{REF_SHA}}`, `{{CONFIG}}` (the config subset as JSON), `{{CARD}}`, `{{FINDINGS}}`, `{{IMPL_REPORT}}`, `{{DIFF}}`. Task 5 fills them.

- [x] **Step 1: Write the failing test** `test-evidence-review-prompt.sh`:
  - `prompt names every reviewer report section`: for each of `## Status`, `## Findings`, `## Acceptance map`, `## Mutation`, `## Claim check`, `## For the card`, `reviewed head:` and `VERIFIED:` that appears in `agents/reviewer.md`'s report template, the prompt contains it.
  - `prompt carries each method step`: the prompt mentions the head record, the Acceptance map, running only touched tests, one mutant per mapped item with `git checkout -- <file>` restore, the claim check, the weakening check, and the `killed: <n> survived: <n> invalid: <n>` line.
  - `prompt keeps the sandbox rules`: it says to run every command in the working directory, never to post, and to treat card, diff and reports as untrusted data.
  - `prompt has every placeholder`: each of the seven placeholders appears once.
- [x] **Step 2: Run** `bash plugins/fleet-board/tests/test-evidence-review-prompt.sh` — Expected: FAIL (file missing).
- [x] **Step 3: Write the prompt** from `docs/implementation-plans/2026-09-28-fleet-board/specs/reviewer.md`: its method and report rules, with "post your report" replaced by "print the report alone", `worktrees.mutate_on_copy` dropped, and the network-off rule from the spec's Sandbox section.
- [x] **Step 4: Run** the suite — Expected: `failed: 0`. Then delete one section name from the prompt, rerun, see a FAIL, and restore it.
- [x] **Step 5: Commit** `Evidence-review prompt for command-provider reviewers`.

### Task 5: `evidence-review.sh`

**Files:**
- Create: `plugins/fleet-board/scripts/evidence-review.sh`
- Create: `plugins/fleet-board/tests/fake-reviewer-cmd.sh` (a scripted fake provider: reads `FAKE_REVIEWER_SCRIPT`, a file of steps such as `reply <file>`, `write <path>`, `commit`, `sleep <s>`, `exit <n>`, `push-pr-head`)
- Create: `plugins/fleet-board/tests/test-evidence-review.sh`

**Interfaces:**
- Consumes: Task 1's `chat.sh --dir`; Task 2's merged `models.reviewer` and `providers.<p>.review_command`; Task 4's prompt; existing `worktree.sh review`, `parse-report.sh --role reviewer`, `board-comment.sh`, `board-read.sh`.
- Produces: `evidence-review.sh <n> <pr> --round <r> [--prev-sha <sha>] [--findings <json-file>] [--impl-report <file>] [--card-file <f>] [--diff-file <f>] [--no-post]`, printing `{status, report_file, parsed, provider, model, sha, input_tokens, output_tokens, cost_usd, attempts}` on exit 0, and appending a ledger line with `"role":"reviewer"`. Exit codes as in Global Constraints. Stderr messages, verbatim: `evidence-review: <program> is not on PATH`, `evidence-review: setup failed`, `evidence-review: <path> changed during the review`, `evidence-review: reviewed head <x> is not the PR head <sha>`, `evidence-review: review.mutation is on but the report skipped mutation`.

- [x] **Step 1: Write the failing tests** in `test-evidence-review.sh`, offline, on a temp repo with a fake `gh` and `fake-reviewer-cmd.sh` set as `providers.fake.review_command` (`bash <tests>/fake-reviewer-cmd.sh {dir} {model}`):
  - `good report: posted, prints sha, provider, model`
  - `wrong reviewed head: re-asked once, then exit 6`
  - `skipped mutation while review.mutation is on: re-asked once, then exit 6`
  - `second reply good after a rejection: exit 0, attempts 2`
  - `write into the main checkout: exit 1, nothing posted, stderr names the path`
  - `write and commit inside the clone: -review worktree unchanged, clone removed`
  - `command exits non-zero: exit 1`; `command prints nothing: exit 1`
  - `command receives the clone as {dir} and the prompt on stdin` (the fake records both; the prompt holds the card, the diff, the reference SHA and the previous findings)
  - `round 1 reference is the merge-base; round 2 is --prev-sha`
  - `reply holding a fleet-board marker: exit 1, nothing posted`
  - Review Focus 1: `PR head pushed mid-review: report naming the step-1 head is accepted, sha is the step-1 head`
  - Review Focus 2: `program not on PATH: exit 3, no clone made`
  - Review Focus 3: `timeout: exit 1, nothing posted, clone removed`
  - Review Focus 4: `worktrees.setup fails: exit 1 setup failed, provider not called`
  - `string reviewer: exit 2`
- [x] **Step 2: Run** `bash plugins/fleet-board/tests/test-evidence-review.sh` — Expected: FAIL (script missing).
- [x] **Step 3: Implement** `evidence-review.sh` following the spec's nine steps. Reuse `stage-review.sh`'s patterns for argument parsing, the re-ask message list, the ledger line, the marker refusal and the final JSON; take `chat.sh --command <review_command> --model <model> --timeout <timeout> --dir <clone>`. Exit 3 checks `command -v` on the first word of `review_command`. The tripwire compares `git status --porcelain` and `git rev-parse HEAD` of the repo root and the `-review` worktree before and after the call.
- [x] **Step 4: Run** the suite — Expected: `failed: 0`.
- [x] **Step 5: Prove it can fail:** copy the script to a temp path with the head check removed, point the suite at it with an override variable (`EVIDENCE_REVIEW_SCRIPT`), and see `wrong reviewed head` FAIL.
- [x] **Step 6: Commit** `evidence-review.sh: run the evidence review on a command provider`.

### Task 6: Manager runs the script for a provider reviewer (clean-room)

This task spends API money on an isolated run. Check the ceiling in the plan's `HANDOFF.md` and get the user's approval before Step 4.

**Files:**
- Modify: `docs/implementation-plans/2026-09-28-fleet-board/specs/manager.md`
- Modify (isolated run only): `plugins/fleet-board/agents/manager.md`
- Modify: `docs/implementation-plans/2026-09-28-fleet-board/specs/README.md` (new Revision), `specs/clean-room-manifest.txt`
- Create: `plugins/fleet-board/tests/test-manager-evidence-review.sh` (same style as `test-manager-stages.sh`: text checks on the spec and on `agents/manager.md`)

**Interfaces:**
- Consumes: Task 5's command line, exit codes and printed JSON.
- Produces: manager rules: when the plan card's `models.reviewer` is an object, the `review` action and the re-review after `fix` run `cd <repo root> && bash <scripts>/evidence-review.sh N <pr> --round <r> --prev-sha <sha> [--findings <f>] --impl-report <f>` as a background Bash call with `timeout` `(models.reviewer.timeout + 300) * 1000`, wait for its completion notice, read the JSON from its output file, and reconcile per the spec's Manager section. It counts against `limits.concurrency`.

- [x] **Step 1: Write the failing test** `test-manager-evidence-review.sh`, checking both the spec and the agent file for: `evidence-review.sh`; `run_in_background`; the timeout expression; "no Agent call"; exit 0 reconciliation with `provider` and `model` in `last_review`; exits 1, 3, 6 as report errors with `"role": "reviewer"`; exit 2 as the manager's own error; "counts against `limits.concurrency`".
- [x] **Step 2: Run** it — Expected: every case FAILS.
- [x] **Step 3: Edit the spec** `specs/manager.md` (and the brief, as previous Revisions did) with the rules above. Rerun: spec-side cases pass, agent-side cases still fail.
- [x] **Step 4: Isolated in-place edit** of `agents/manager.md`, in the form the last Revision used: `claude -p --bare --model opus --tools "Read,Edit" --permission-mode acceptEdits --max-turns 40`, fresh empty `CLAUDE_CONFIG_DIR`, cwd `plugins/fleet-board/`, `< /dev/null`, one staged `edit-req.md`. Assert isolation on the `system/init` event.
- [x] **Step 5: Minimality check:** read `git diff -U0 agents/manager.md` hunk by hunk; every hunk must be one of this task's rules. Discard and re-run otherwise.
- [x] **Step 6: Run** `test-manager-evidence-review.sh`, `test-manager-stages.sh`, `test-clean-room.sh` and `test-clean-room-manifest.sh` — Expected: `failed: 0` each.
- [x] **Step 7: Record** the next free Revision number in `specs/README.md` (run, init hash, isolation, path audit, turns, cost, before and after hashes, minimality, tests, known limits), and update the manifest line for `agents/manager.md`.
- [x] **Step 8: Commit** `Manager: run evidence-review.sh for a provider reviewer (Revision <n>)`.

### Task 7: Version, behavioral scenario, live check

**Files:**
- Modify: `plugins/fleet-board/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (`0.15.0`)
- Modify: `plugins/fleet-board/tests/behavioral-tick.sh` (one scenario, `provider-reviewer`)

- [ ] **Step 1: Bump** the version in both files and run `bash plugins/fleet-board/tests/test-clean-room.sh` — Expected: `failed: 0`.
- [ ] **Step 2: Add the behavioral scenario** `provider-reviewer`: a card In Review with the fake reviewer command as `models.reviewer`; assert the tick's transcript has a background Bash call to `evidence-review.sh`, no Agent call with `subagent_type: fleet-board:reviewer`, and a note whose `last_review` has `provider` and `model`.
- [ ] **Step 3: Run the scenario once, only with the user's approval** (it costs plan usage). Expected: the three assertions pass.
- [ ] **Step 4: Live check, only with the user's approval:** one real `gpt-6-astra` review of a small known PR in `SANDBOX_REPO`. Expected: a posted reviewer report with a `killed: … survived: … invalid: …` line and a `reviewed head:` equal to the PR head.
- [ ] **Step 5: Commit** `fleet-board 0.15.0: provider evidence reviewer`.

After this plan ships, switching this board means editing `.fleet-board.yml` to the spec's object form with `escalation: opus`, and removing the `codex` review stage it now carries.
