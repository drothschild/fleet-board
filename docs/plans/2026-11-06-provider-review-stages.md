# Provider-backed review stages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a review stage run on a model from OpenAI or another provider instead of a Claude subagent, so a repo can get a review from a model family that does not share the writer's blind spots.

**Architecture:** A stage names either an `agent` (the review-stages design as approved) or a `provider`. A provider stage is not an Agent dispatch. The manager runs one script, `stage-review.sh`, through Bash. The script builds the prompt from the card, the PR diff and the stage brief, calls the provider through an OpenAI-compatible Chat Completions adapter (`curl` + `jq`), checks the reply with `parse-report.sh --role stage-reviewer`, and re-asks the model once if the reply is rejected. It then posts the report, adds the spend to a ledger and prints a JSON result. From there the stage's fix, re-review and advance loop is exactly the one in the review-stages design. The headless wrapper adds the ledger's spend to the tick's cost, so `limits.max_cost_usd` still holds.

**Tech Stack:** bash 3.2, `jq`, `curl` (≥ 7.55 for `-H @file`), `gh`; the plain-bash assertion suites under `plugins/fleet-board/tests/`.

**Spec:** `2026-11-06-review-stages-design.md` (assumed implemented: `review.stages`, `review_<name>` states, `advance_stage`/`review_stage`, `parse-report.sh --role stage-reviewer`, `review-stages.sh`). This plan adds the provider decisions below. There is no separate design doc for them, so the plan states them here:

- **Scope: review stages only.** The implementor, fixer and evidence reviewer stay Claude agents. They need tools in a worktree (edit, run tests, mutation), and a one-shot API call has none. An agentic external runner (Codex CLI, Gemini CLI) is a follow-up, not part of this plan: the portability rule forbids assuming either CLI is installed.
- **One wire protocol: OpenAI-compatible `POST <base_url>/chat/completions`.** It covers OpenAI, Gemini's OpenAI-compatible endpoint, OpenRouter and a local Ollama with one adapter. The native Anthropic, Gemini and Responses APIs are out of scope.
- **A provider stage reviews the diff, not the worktree.** It runs no tests. The evidence reviewer in In Review already did that.
- **Keys stay in environment variables.** Config names the variable and never holds the value.
- **A provider stage must declare its price**, so the cost ceiling never counts unpriced spend as zero.

## Prerequisite

This plan is executed through `2026-11-06-review-stages-and-providers.md`, which orders its tasks among the review-stages plan's and lists the deltas. Do not run it on its own: Task 1 assumes `review.stages` and the stage defaults fill already exist in `config.sh`, Task 3 assumes `parse-report.sh --role stage-reviewer`, and Task 4 assumes `tick-plan.sh` emits `advance_stage` and `review_stage`.

## Global Constraints

- Every existing config keeps its behavior: `providers` defaults to `{}`, and a stage without `provider` is the agent stage from the review-stages design.
- A stage sets exactly one of `agent` and `provider`.
- Provider names: `^[a-z][a-z0-9_-]*$`. Built-in presets: `openai`, `gemini`, `openrouter`, `ollama`.
- `api_key_env` matches `^[A-Z_][A-Z0-9_]*$`, or is `null` (only for a loopback `base_url`).
- `base_url` must start with `https://`, or with `http://localhost`, `http://127.0.0.1` or `http://[::1]`.
- The key value never appears in argv, in a log, in a comment, in the ledger, in stderr or in a test fixture's recorded output.
- Bash 3.2, BSD and GNU tools: `sed -i.bak`, `unset CDPATH` before a captured `cd`, `LC_ALL=C` for any `awk` on decimals.
- Runtime data goes under `${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}`.
- Clean-room files (`agents/manager.md`, `skills/reporting/SKILL.md`, …) are never hand-edited. Change the spec, re-author with `claude -p --bare`, and update the manifest and `specs/README.md` revision record in the same commit. Check the API-key spend total in the private handoff first.
- Every suite is written first and seen to fail before its implementation lands. Run only the suite you touched, plus `test-clean-room.sh` after any change under the plugin.
- Plugin version bump in both `.claude-plugin/plugin.json` and `marketplace.json` (minor bump).

## Review Focus

1. **Key leakage through an error body.** A provider that echoes the `Authorization` header or the key in its error JSON. Expected: stderr and the ledger show `[redacted]`, never the key (Task 2 test `error_body_echoing_key_is_redacted`).
2. **A reply that would be read as a manager note or a clean review when it is neither.** A model reply that contains `FB_MARKER`, is empty, or was cut off (`finish_reason: "length"`). Expected: no comment is posted, exit 1. Never a clean review (Task 3 tests `marker_in_reply_is_refused`, `truncated_reply_is_a_failure`, `empty_reply_is_a_failure`).
3. **A diff too large for one request, or a binary-only diff.** Expected: no network call, exit 7, and the manager blocks the card with a reason naming the byte count and `max_diff_bytes` (Task 3 `oversized_diff_makes_no_call`; Task 5 manager row).
4. **The headless run with the key variable unset.** Expected: a tick-plan warning naming the stage and variable, and `stage-review.sh` exits 3 without calling `curl`. The failure counts toward `action_failures` like any report error (Task 3 `missing_key_env_makes_no_call`; Task 4 warning test).
5. **Two runs sharing one ledger.** Expected: each wrapper adds only lines carrying its own `FLEET_BOARD_RUN_ID` (Task 6 `ledger_lines_from_other_runs_are_ignored`).

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/providers/presets.json` (new) | Built-in provider presets: `base_url`, `api_key_env`, `max_tokens_param` |
| `scripts/providers/chat.sh` (new) | The one adapter: request JSON on stdin → normalized reply JSON on stdout. Retries, redaction. |
| `scripts/providers/stage-review-prompt.md` (new) | The prompt template, with the stage-reviewer report shape. A script asset, not a primitive. |
| `scripts/stage-review.sh` (new) | Builds the prompt, calls the adapter, checks the reply, re-asks once, posts the report, writes the ledger, prints the result |
| `scripts/config.sh`, `scripts/config-defaults.json` | `providers` map, stage `provider`/`price`/`timeout`/`max_output_tokens`/`max_diff_bytes`, validation, merged output with presets filled in |
| `scripts/tick-plan.sh` | Plan card `stage` gains `provider`; warning for an unset key variable |
| `scripts/status.sh` | Stage card line shows `<provider>:<model>` |
| `scripts/fleet-board-run.sh` | Exports `FLEET_BOARD_RUN_ID`; adds ledger spend to each tick's cost |
| `docs/.../specs/manager.md` → `agents/manager.md` | Provider-stage rows (clean-room re-author) |
| `tests/fake-curl.sh` (new), `tests/test-providers.sh` (new), `tests/test-stage-review.sh` (new) | Offline suites |
| `tests/eval/run.sh` | `--provider` mode for the seeded-defect catch rate |
| `docs/config.md`, `README.md`, `docs/design.md`, `plugins/fleet-board/CLAUDE.md` | Docs and contracts |

---

### Task 1: Config — `providers` map and provider stages

**Files:**
- Create: `plugins/fleet-board/scripts/providers/presets.json`
- Modify: `plugins/fleet-board/scripts/config.sh` (validation block near the `review.stages` checks; merge step)
- Modify: `plugins/fleet-board/scripts/config-defaults.json` (add `"providers": {}`)
- Create: `plugins/fleet-board/fixtures/config/provider-stage.yml`, `bad-provider-*.yml`
- Test: `plugins/fleet-board/tests/test-config.sh`
- Docs: `plugins/fleet-board/docs/config.md` (`## providers`, provider keys under `## review.stages`, a data-egress paragraph), README key table rows `providers` and `review.stages[].provider`, `tests/test-readme-claims.sh`

**Interfaces:**
- Produces: merged config where every provider stage has `provider`, `model`, `price: {input, output}` (USD per million tokens), `timeout` (default `600`), `max_output_tokens` (default `16000`), `max_diff_bytes` (default `400000`), and `agent: null`. Every agent stage has `provider: null`. Top-level `providers.<name>` is `{base_url, api_key_env, max_tokens_param}` for every provider a stage names, with the preset filled in and user keys overriding it key by key.

Config shape:

```yaml
providers:                       # optional; a preset name needs no entry
  corp:
    base_url: https://llm.corp.example/v1
    api_key_env: CORP_LLM_KEY
    max_tokens_param: max_tokens  # or max_completion_tokens; default max_completion_tokens
review:
  stages:
    - name: security
      provider: openai           # instead of agent
      model: gpt-x               # required with provider; passed verbatim
      price: { input: 1.25, output: 10 }
```

`presets.json`: `openai` → `https://api.openai.com/v1`, `OPENAI_API_KEY`, `max_completion_tokens`; `gemini` → `https://generativelanguage.googleapis.com/v1beta/openai`, `GEMINI_API_KEY`, `max_tokens`; `openrouter` → `https://openrouter.ai/api/v1`, `OPENROUTER_API_KEY`, `max_tokens`; `ollama` → `http://localhost:11434/v1`, `null`, `max_tokens`. Check each URL against the provider's current docs when implementing.

- [ ] **Step 1: Write the failing tests** in `test-config.sh`:
  - `provider_stage_merges_preset`: `provider-stage.yml` with `provider: openai` → `.providers.openai.base_url == "https://api.openai.com/v1"`, `.review.stages[0].agent == null`, `.timeout == 600`, `.max_output_tokens == 16000`, `.max_diff_bytes == 400000`.
  - `user_provider_overrides_preset_key_by_key`: `providers.openai.api_key_env: WORK_OPENAI` keeps the preset `base_url`.
  - Exit 5 with exactly these lines (one fixture each):
    - `review.stages[0] must set exactly one of agent and provider` (both set; neither set)
    - `review.stages[0].provider must match ^[a-z][a-z0-9_-]*$`
    - `review.stages[0].provider foo names no provider` (not a preset, no `providers.foo`)
    - `review.stages[0].model must be set when provider is set`
    - `review.stages[0].price is required when provider is set`
    - `review.stages[0].price.input must be a non-negative number` (and `.output`)
    - `review.stages[0].timeout must be a positive integer` (and `max_output_tokens`, `max_diff_bytes`)
    - `providers.corp.base_url must start with https:// or a loopback http:// address`
    - `providers.corp.api_key_env must match ^[A-Z_][A-Z0-9_]*$` 
    - `providers.corp.api_key_env may be null only for a loopback base_url`
    - `providers.corp.max_tokens_param must be max_tokens or max_completion_tokens`
    - `providers.corp.api_key is not allowed; name an environment variable in api_key_env` (also for keys `key`, `token`, `secret`)
    - `providers.corp is not used by any stage` (a warning on stderr, exit 0)
  - `agent_stage_unchanged`: an existing agent-stage fixture prints the same merged JSON as before, plus `provider: null`.
  - README claim test: rows for `providers` and `review.stages[].provider` exist.

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-config.sh`. Expected: the new cases FAIL and the old ones pass.

- [ ] **Step 3: Implement.** Add the validation to the existing jq validation program, in its message style. The merge order: preset → `providers.<name>` from the file. Load the presets file through `${HERE}/providers/presets.json`, never by an absolute path. Write the docs. The data-egress paragraph says that a provider stage sends the card body and the PR diff to that provider.

- [ ] **Step 4: Run** the same suite plus `test-readme-claims.sh` and `test-clean-room.sh`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(config): provider-backed review stages`.

---

### Task 2: The provider adapter `providers/chat.sh`

**Files:**
- Create: `plugins/fleet-board/scripts/providers/chat.sh`
- Create: `plugins/fleet-board/tests/fake-curl.sh` (on `PATH` ahead of the real one; records argv and every `@file` argument's contents to `$FAKE_CURL_LOG`; replies from `$FAKE_CURL_REPLIES`, one `<http_code> <body-file>` line per call)
- Create: `plugins/fleet-board/fixtures/providers/*.json` (ok, length-truncated, empty-content, 429, 500, 401-echoing-key)
- Test: `plugins/fleet-board/tests/test-providers.sh`

**Interfaces:**
- Produces: `chat.sh --base-url <url> --key-env <NAME|-> --model <id> --max-tokens <n> --max-tokens-param <p> --timeout <s>`. It reads `{"messages":[{role,content}...]}` on stdin. On exit 0 it prints `{"text": str, "finish_reason": str, "input_tokens": int, "output_tokens": int, "model": str}`, taking the tokens from `usage.prompt_tokens`/`usage.completion_tokens` and the model the provider reports. Exit 1: HTTP or transport failure, with one stderr line `provider: <reason>`. Exit 2: usage. Exit 3: `--key-env` names an unset or empty variable (stderr `provider: <NAME> is not set`, no `curl` call).

- [ ] **Step 1: Write the failing tests** in `test-providers.sh`:
  - `ok_reply_is_normalized`: the fake returns the ok fixture → stdout matches the interface, with exact token counts.
  - `key_never_in_argv`: with `TEST_KEY=sk-test-123`, no recorded argv line contains `sk-test-123`. The header arrives through `-H @<file>`, and that file's mode is `600` (record `stat` in the fake).
  - `temp_files_removed`: after exit 0 and after exit 1, the adapter's temp dir no longer exists.
  - `error_body_echoing_key_is_redacted`: the 401 fixture body contains the key → exit 1, stderr contains `[redacted]` and not the key.
  - `retries_429_then_succeeds`: replies `429`, `200` → exit 0, two calls. `Retry-After: 2` is honored through an injectable `FB_SLEEP` command so the test does not sleep.
  - `retry_cap`: three `500`s → exit 1 after 3 calls (1 try + 2 retries), stderr `provider: HTTP 500 after 3 attempts`.
  - `retry_after_capped_at_60`: `Retry-After: 900` → the sleep is called with `60`.
  - `missing_key_env_makes_no_call`: exit 3, the fake curl log is empty.
  - `loopback_without_key`: `--key-env -` sends no `Authorization` header.
  - `max_tokens_param_used`: the request body carries `max_completion_tokens` or `max_tokens` as asked, and not both.
  - `stdout_never_holds_key`.

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-providers.sh`. Expected: FAIL (`chat.sh` missing).

- [ ] **Step 3: Implement** `chat.sh`. Use `mktemp -d` with `umask 077` and a `trap` cleanup. The header file holds `Authorization: Bearer <key>`. Call `curl -sS --max-time <timeout> -w '%{http_code}' -D <headers-out> -H @<hdr> -H 'Content-Type: application/json' --data-binary @<body>`. Redact with a fixed-string replace of the key value (jq `gsub` on the literal, escaped) before printing any provider text to stderr, and truncate the message to 300 characters. Retry on 429 and 5xx only.

- [ ] **Step 4: Run** the suite. Expected: PASS. Then **prove it can fail**: temporarily pass the key with `-H "Authorization: Bearer $KEY"` and confirm `key_never_in_argv` fails. Revert.

- [ ] **Step 5: Commit** `feat(providers): OpenAI-compatible chat adapter`.

---

### Task 3: `stage-review.sh` — one provider review, checked and posted

**Files:**
- Create: `plugins/fleet-board/scripts/stage-review.sh`
- Create: `plugins/fleet-board/scripts/providers/stage-review-prompt.md`
- Test: `plugins/fleet-board/tests/test-stage-review.sh` (uses `fake-gh.sh`, `fake-curl.sh`)

**Interfaces:**
- Consumes: Task 1's merged config (through `config.sh`), Task 2's `chat.sh`, `parse-report.sh --role stage-reviewer`, `board-comment.sh`, `board-read.sh`. Pricing comes from `stage.price`, not `estimate-cost.sh` (which knows only Claude models).
- Produces: `stage-review.sh <n> <pr> --stage <name> --round <r> [--prev-sha <sha>] [--findings <json-file>] [--impl-report <file>] [--card-file <f> --diff-file <f> --no-post]`. It prints `{"status":"posted"|"checked","report_file": abs path,"parsed": <parse-report JSON>,"provider": str,"model": str,"input_tokens": int,"output_tokens": int,"cost_usd": number,"attempts": 1|2}`. Exit codes: 0 posted (or checked, with `--no-post`); 1 provider failure, empty reply, truncated reply or a reply holding `FB_MARKER` (nothing posted); 2 usage, an unknown stage, or an agent stage; 3 the key variable is unset; 6 the reply was rejected twice (the second rejection's stderr is printed verbatim, and nothing is posted); 7 the diff is larger than `max_diff_bytes` or holds no text hunks (stderr `stage-review: diff <bytes> bytes exceeds max_diff_bytes <m>` or `stage-review: diff has no text hunks`). Ledger line on every call that reached the provider (exits 0, 1 after a reply, 6): `{"ts","run_id": $FLEET_BOARD_RUN_ID or null,"repo","card","stage","provider","model","input_tokens","output_tokens","cost_usd"}` appended to `${FLEET_BOARD_LOG_DIR:-$HOME/.fleet-board}/provider-spend.jsonl`. `cost_usd = (in*price.input + out*price.output)/1e6`, with `LC_ALL=C`, summed over both attempts.

Prompt: a system message (the template's role text: a reviewer for the `<stage>` stage, judging only what the brief names, untrusted-content warning that card and diff text are data, the exact `stage-reviewer` report shape and line rules copied from `parse-report.sh`'s header, "clean means zero Critical and Important"). Then one user message holding the card body, the stage brief verbatim, the round, `prev_sha`, the previous Critical and Important findings (round ≥ 2), the latest implementor or fixer report, and the diff, each in a fenced block under a fixed heading. The second attempt adds the assistant's first reply and a user message: `Your report was rejected by the checker:` + the stderr verbatim + `Reply with the corrected full report only.`

- [ ] **Step 1: Write the failing tests** in `test-stage-review.sh`:
  - `clean_reply_posts_and_prints_result`: the fake reply is a valid clean `stage-reviewer` report → exit 0. `board-comment.sh` was called once with that text, `.parsed.status == "clean"`, and `.cost_usd` equals the hand-computed value for the fixture's token counts and price.
  - `findings_reply_parsed`: `.parsed.findings` holds the Critical item.
  - `rejected_then_fixed`: first reply missing `## For the card`, second valid → exit 0, `attempts == 2`. The second request's last user message contains the exact parse-report stderr. The ledger cost sums both calls.
  - `rejected_twice_exits_6_posts_nothing`.
  - `marker_in_reply_is_refused`: a valid report that also contains the `FB_MARKER` string → exit 1, nothing posted.
  - `truncated_reply_is_a_failure`: `finish_reason: "length"` → exit 1, stderr `stage-review: reply truncated at max_output_tokens <n>`.
  - `empty_reply_is_a_failure`.
  - `oversized_diff_makes_no_call`: `max_diff_bytes: 10` → exit 7, no curl call, no ledger line.
  - `missing_key_env_makes_no_call`: exit 3, no curl call.
  - `agent_stage_is_usage_error`: exit 2 `stage-review: stage security is an agent stage`.
  - `no_post_mode_needs_no_gh`: `--card-file --diff-file --no-post` with no `gh` on `PATH` → exit 0, `status == "checked"`.
  - `ledger_line_shape`: the run id comes from the env, and no field contains the key.
  - `prompt_carries_brief_and_round2_findings`: the recorded request body contains the brief verbatim and, with `--round 2 --findings f.json`, each finding's text.

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-stage-review.sh`. Expected: FAIL.

- [ ] **Step 3: Implement** `stage-review.sh` and the template. Read the stage and provider from `config.sh` output with `jq`. Get the diff with `gh pr diff <pr> --repo <board.repo>`, and the card with `board-read.sh`. Fill the template with `jq --rawfile`, not `sed`, so no input can break the substitution.

- [ ] **Step 4: Run** the suite. Expected: PASS. Prove `marker_in_reply_is_refused` can fail by removing the check. Revert.

- [ ] **Step 5: Commit** `feat: stage-review.sh runs a provider-backed review stage`.

---

### Task 4: Tick plan and status carry the provider

**Files:**
- Modify: `plugins/fleet-board/scripts/tick-plan.sh` (the plan card's `stage` object; warnings)
- Modify: `plugins/fleet-board/scripts/status.sh` (stage card line)
- Test: `tests/test-tick-plan.sh`, `tests/test-status.sh`, fixtures under `fixtures/gh/tick/` for one provider stage

**Interfaces:**
- Produces: plan card `stage: {name, agent, provider, model, advisory, brief, max_rounds}`, with `provider` null for an agent stage and `agent` null for a provider stage. Warning `stage <name>: <ENV> is not set; provider reviews will fail`, once per stage per plan, only when a card in the plan has action `review_stage` or `fix` in that stage. Status line `#<n> <title> · round <r> · PR #<pr> · <fixer model>/<provider>:<model>`.

- [ ] **Step 1: Write the failing tests**:
  - `review_stage_plan_card_has_provider` (`.stage.provider == "openai"`, `.stage.agent == null`).
  - `agent_stage_plan_card_has_null_provider`.
  - `unset_key_warns_once` (two cards in the stage → one warning).
  - `set_key_no_warning`.
  - `no_warning_when_stage_not_acted_on`.
  - `test-status.sh`: `provider_stage_line`.
- [ ] **Step 2: Run** both suites. Expected: the new cases FAIL.
- [ ] **Step 3: Implement.** Pass the env check into jq as `--argjson unset '<list of stage names whose variable is unset>'`, computed in bash before the jq call, so jq never reads the environment.
- [ ] **Step 4: Run** both suites and `test-clean-room.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(tick-plan): plan and show provider stages`.

---

### Task 5: Manager runs provider stages (clean-room re-author)

**Files:**
- Modify: `docs/implementation-plans/2026-09-28-fleet-board/specs/manager.md`, and its brief under `specs/briefs/`
- Re-author: `plugins/fleet-board/agents/manager.md` (isolated `claude -p --bare`, canonical command form in `specs/README.md`)
- Modify: `specs/clean-room-manifest.txt`, `specs/README.md` (revision record, init evidence under `specs/evidence/`)
- Test: `tests/test-clean-room.sh`, `tests/test-clean-room-manifest.sh`, `tests/test-manager-*.sh` grep-style claims if present

**Interfaces:**
- Consumes: the plan card's `stage.provider` (Task 4), `stage-review.sh` (Task 3).

Spec changes (exact behavior to write into `specs/manager.md`):

- `review_stage` row: when `stage.provider` is non-null, there is no `worktree.sh review` and no Agent call. Instead: `cd <root> && bash <scripts>/stage-review.sh N <pr> --stage <name> --round <round> --prev-sha <sha>`, plus `--findings <file>` from round 2 and `--impl-report <file>`, as one Bash call with literal values (0.6, 0.7).
- The `fix` row's re-review, for a provider stage, runs that same call in place of re-dispatching `stage.agent`.
- Exit mapping: on 0, the manager runs `parse-report.sh --role stage-reviewer` on the printed `report_file` and reconciles exactly as for an agent stage report, recording `last_review.agent: null`, `last_review.provider` and `last_review.model`. On 1, 3 or 6 it records a report error (`last_action_error` = the script's last stderr line) with no state change, and `action_failures` counts it, the same as a rejected re-dispatch. On 7 it blocks the card with the stderr line as the reason. On 2 it treats the call as the manager's own error (as parse-report exit 2).
- The manager does not re-run the script on exit 6, because the script already re-asked once.
- 0.3 is unchanged in wording, since a provider stage makes no Agent call. Add to the "never" list: never call a provider by any means other than `stage-review.sh`.
- 5.4 cost line: add each `stage-review.sh` result's `cost_usd` to the sum.
- Note: `models` is unchanged. `last_review` gains `provider` (null for agent stages and In Review). `note.sh` validates `provider` as null or `^[a-z][a-z0-9_-]*$` (add that check and its test to `test-note.sh` in this task).

- [ ] **Step 1: Write the failing test** in `test-note.sh`: `last_review.provider` accepts `null` and `openai`, and rejects `Open AI`. Run it and see it fail. Implement it in `note.sh` and see it pass. Commit.
- [ ] **Step 2: Edit `specs/manager.md` and the brief** with the changes above. Check the API-key spend total first.
- [ ] **Step 3: Re-author `agents/manager.md`** with the canonical isolated command. Run the per-run init assertion and the tool_use audit from `specs/README.md`, and commit the init evidence.
- [ ] **Step 4: Verify** that the authored file contains the `stage-review.sh` row and the exit mapping. Update the manifest hash and the README revision record. Run `test-clean-room.sh` and `test-clean-room-manifest.sh`. Expected: PASS.
- [ ] **Step 5: Commit** spec, brief, authored file, manifest, README and evidence together: `feat(manager): run provider-backed review stages via stage-review.sh`.

---

### Task 6: The headless run counts provider spend

**Files:**
- Modify: `plugins/fleet-board/scripts/fleet-board-run.sh` (run id export; `tick_cost`)
- Test: `tests/test-run.sh` (with `fake-claude.sh`)
- Docs: `docs/overnight.md` (provider spend counts toward `max_cost_usd`; the key variables must be exported in the environment that starts the wrapper)

**Interfaces:**
- Consumes: Task 3's ledger lines.
- Produces: `FLEET_BOARD_RUN_ID` (exported, `<epoch>-<pid>`). A tick's cost is the Claude cost plus the sum of `cost_usd` over the ledger lines appended during that tick that carry this run id. The log line becomes `cost_estimate_usd=<total> (estimate; provider <x>)` when provider spend is non-zero.

- [ ] **Step 1: Write the failing tests**:
  - `provider_spend_added_to_tick_cost`: fake-claude tick writes two ledger lines (0.10, 0.05) with the run id → the tick cost is the Claude cost + 0.15.
  - `ledger_lines_from_other_runs_are_ignored`.
  - `provider_spend_trips_max_cost`: the Claude cost is under the cap and the total is over it → `stopped: max-cost`.
  - `missing_ledger_is_zero`.
  - `malformed_ledger_line_is_skipped_with_warning`.
- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-run.sh`. Expected: the new cases FAIL.
- [ ] **Step 3: Implement.** Record the ledger's line count before each tick. Sum only the lines after it, filtered by run id, with `jq -s` and `LC_ALL=C` for the decimal add.
- [ ] **Step 4: Run** the suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat(run): count provider spend toward max_cost_usd`.

---

### Task 7: Catch rate for a provider reviewer, and the docs that close the loop

**Files:**
- Modify: `plugins/fleet-board/tests/eval/run.sh` (`--provider <name> --model <id>`), `tests/test-eval-run.sh`
- Modify: `plugins/fleet-board/docs/reviewer-eval.md` (provider rows, `not run` until measured)
- Modify: `docs/design.md` (a short section on why a provider stage is a script and not an agent: no tools, diff-only, one code path for checking, spend in the ledger; the trade-off that it runs no tests is named)
- Modify: `plugins/fleet-board/CLAUDE.md` (contracts: `stage-review.sh` exits, the ledger, `providers`, `last_review.provider`; Last verified date)
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (minor version bump, both)

**Interfaces:**
- Consumes: `stage-review.sh --card-file --diff-file --no-post` (Task 3).
- Produces: with `--provider`, the eval runner calls `stage-review.sh` once per defect and run, with no `claude -p`. Its verdict comes from `parse-result.sh` on the report file, and the `results.tsv` model column is `<provider>:<model>`. The eval's stage config is a temp `.fleet-board.yml` with one blocking stage, `brief: "Judge whether the tests prove the Acceptance bullets."`, and the price from `--price-in`/`--price-out` (both required with `--provider`, exit 2 otherwise).

- [ ] **Step 1: Write the failing tests** in `test-eval-run.sh`:
  - `provider_dry_run_prints_stage_review_commands` (no `claude -p` in the output).
  - `provider_requires_prices`.
  - `provider_verdict_from_fake_reply` (fake-curl canned caught and missed reports → `caught`/`missed` rows).
- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-eval-run.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** the runner flag, and write the docs and version bump.
- [ ] **Step 4: Run** `test-eval-run.sh`, `test-version.sh`, `test-readme-claims.sh` and `test-clean-room.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(eval): measure a provider reviewer's catch rate`.
- [ ] **Step 6 (paid, only when asked):** `bash run.sh --provider openai --model <id> --price-in <p> --price-out <p> --runs 3`. Record the rows in `reviewer-eval.md` next to the opus rows, then commit.

---

## Not in this plan

- External models for the implementor, fixer or evidence reviewer (they need an agentic runner with worktree tools, such as Codex CLI or Gemini CLI, behind the same "config names it, script runs it" pattern).
- Native Anthropic, Gemini and Responses APIs, streaming, and tool or function calling for provider stages.
- A live behavioral scenario. The offline suites cover the path with fake `curl`. If one is wanted later, add `behavioral-tick.sh --scenario provider-stage` against an Ollama on loopback, which costs nothing.
