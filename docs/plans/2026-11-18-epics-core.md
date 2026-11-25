# Epics Core Implementation Plan (built by hand)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the board an epic record, a card's link to it, and a design that a session revises after each child merges, so the cards in `docs/plans/2026-11-18-epics-cards.md` have something to build on.

**Architecture:** An epic is a folder under `<board.dir>/epics/<id>/` owned by one script, `scripts/epic.sh`. A card points at its epic through a new `epic` field. Whether a merged child has been recorded is read from the epic's own log, so no new note field is needed: `epic.sh pending` lists Done children with a pull request and no log line, the scheduler plans `record_epic` for each, and the driver runs a headless session whose report `epic.sh record` turns into a log line and, when the design changed, a new revision.

**Tech Stack:** bash 3.2 + jq (store scripts, scheduler table), Python 3 standard library (supervisor), plain-bash and `unittest`-style suites with the existing fakes.

**Spec:** `docs/specs/2026-11-18-epics-design.md`. Read it and `plugins/fleet-board/CLAUDE.md` before any task. This plan covers the spec's sections 1, 2 and 5, and the `premise-settle.sh` part of section 4. Everything else is in the cards plan.

## Global Constraints

- All paths below are relative to `plugins/fleet-board/` unless they start with `docs/specs/`, `docs/plans/`, `plugins/` or `.claude-plugin/`, which are relative to the repository root. The plugin's own docs are `plugins/fleet-board/docs/`.
- This part is built by hand, outside the fleet, because it changes `scripts/tick-plan.sh`, `scripts/supervisor/driver.py` and `hooks/gate.sh`, which the fleet runs on while it builds.
- One branch and one draft PR per task, opened before any code. Test-first: the first commit holds only the failing test. Run only the suites the task names, then `bash plugins/fleet-board/tests/test-clean-room.sh`. Never the full suite.
- Each PR gets the adversarial code review before it merges. Never skip it.
- Each PR raises the plugin version by one patch in both `plugins/fleet-board/.claude-plugin/plugin.json` and the fleet-board entry of `.claude-plugin/marketplace.json`, strictly above `origin/main`. Fetch `origin` immediately before choosing the number, since the fleet merges between tasks.
- After each merge: fast-forward local `main`, run the task's suites on the merged code, and tell the owner to update the plugin and restart the Claude app, the terminal supervisor and the board page.
- No file under `agents/` and no `skills/{reporting,status}/SKILL.md` is edited. The record session has no agent file.
- The supervisor never executes text a card, a report or an epic supplies. The driver reaches a script only when it is in `scripts.ALLOWED` (`scripts/supervisor/scripts.py`) and passes only dash-flags listed in `driver._FLAGS`.
- A session never changes an epic. Gate rule G5 (Task 4) refuses every `epic.sh` verb except `read`, `list`, `pending` and `report` inside a Claude session.
- Card writes go through `fl_write_card` under `fb_lock`. Epic writes go through `epic.sh` under the epic's lock. An epic file that does not have the shape Task 1 gives is read as absent, never as valid.
- No session output is ever written to an epic's `intent`.
- A merged card is never moved, blocked or held by anything in this plan. `record_epic` never writes `action_failures`.
- Bash 3.2, BSD and GNU tools: no bash 4 features, `sed -i.bak`, `unset CDPATH` before `cd`, `LC_ALL=C` for awk decimals. Python standard library only. No new dependencies.
- Nothing may assume this repository's test layout. Fixtures use the neutral example project the existing suites use.
- Each task updates the matching contract lines in `plugins/fleet-board/CLAUDE.md` for what it adds.
- An epic is written `E<id>` wherever a person reads it, and as the bare integer in JSON.
- A card is written `C<n>` in every string this plan adds that a person reads (plan reasons, events, errors, prompt text). Strings that exist today keep `#<n>`; the cards plan's Task 20 changes what the page and `status` show. Where this plan reads a card reference that a session wrote (the record report's `## Affects`), `C<n>` and `#<n>` are both accepted. `#<n>` alone, in new copy, always means a pull request.
- User-visible copy, exact:
  - plan reason: `merged child of E<id> is not recorded`;
  - log attention reasons: `not recorded: the record session failed 3 times`, `contradicts the intent: <text>`;
  - errors: `epic E<id> does not exist`, `card C<n> is already recorded in E<id>`, `E<id> is at design revision <a>, not <b>`;
  - gate: `fleet-board gate: only a person or the supervisor changes an epic; use the board page or a terminal`.

## Before Task 1: re-check the plan against the code

This plan was written against `main` at `7f8ae3b9` on 2026-11-18. The board runs between then and the build. Before a task starts, fetch `origin/main`, re-read the task's Files and Interfaces blocks against the code, and correct the plan if they disagree. In particular:

- **Names, not line numbers.** `tick-plan.sh` and `driver.py` move often; this plan names functions and rows and gives no line numbers.
- **#476, #477, #478 (premise check).** #476 adds proposal routes to `board-web.py`; Task 8 changes what `premise-settle.sh approve` and `reject` do for one kind of proposal, so re-read #476's use of them once it merges.
- **#463 (parallel passes).** It touches the scheduler's reviewer rules; re-check Task 5's one-per-epic rule against it.
- **Provider runners (#566, #567, Task 7).** A provider implementor builds its own prompt and `role_prompt` is skipped when `run.script` is set; an evidence-review provider reviewer never uses `_SECTIONS`. Task 7's Epic section must reach those prompts too, with a test for each, or say why not. Cards Task 15 (samples) inherits the same gap.
- **Failure paths (Task 6).** Any `_Fail` from a `_do_*` reaches `_failed`, which calls `failure_patch`, and an escaped exception reaches `loop._count_exception`, which writes `action_failures`. `record_epic` must bypass both: test a failed `worktree.sh epic` and a raised exception, not only an empty reply, and assert the card's note is unchanged.
- **The Architect rename** (cards plan, Tasks 1 to 3) may merge first. It moves `skills/planner/` and renames the `planner.*` keys. Nothing here depends on either name.

## Review Focus

1. **Two children of one epic reach Done in the same cycle.** Expected: one `record_epic` runs, the other waits, and the second session is given the first's revision. (Task 5.)
2. **A card points at an epic whose folder is gone or whose `epic.json` is not valid.** Expected: `epic.sh pending` leaves the card out with one warning on stderr, the scheduler's plan is unaffected, `board-read.sh` still returns the id, and a role prompt for the card has no Epic section. (Tasks 1, 5 and 7.)
3. **The report says the design is revised, but the design file is missing or empty, or the owner approved a new design while the session ran.** Expected: nothing is written, neither the log line nor a revision; the attempt counts as one failure and is planned again. (Tasks 4 and 6.)
4. **A Done child whose pull request was closed without merging, or that has no pull request.** Expected: no session runs. A card with no pull request is never pending; a closed one gets a `skipped` log line and is never planned again. (Tasks 5 and 6.)
5. **A store with hundreds of Done cards and no epics.** Expected: the scheduler makes no extra call per card; `epic.sh pending` is not run at all when `<board.dir>/epics` does not exist. (Task 5.)

---

### Task 1: The epic record and `epic.sh`

**Files:**
- Create: `scripts/epic.sh`, `scripts/adapters/local/epic-lib.sh`, `tests/test-epic.sh`
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: `<board.dir>/epics/next` (the next id, a positive integer) and `<board.dir>/epics/<id>/`. Both are made by the first `epic.sh create`; a store that has no `epics/` directory has no epics and needs no migration.
- Produces: `epic.json`:

  ```
  {id: <int>, title: <string>, state: "open"|"closed", repo: <string|null>, intent: <string>,
   design_rev: <int, 0 when there is no design>, conversation: <string|null>,
   attention: [{reason: <string>, card: <int|null>, at: <UTC ISO>}],
   created_at, updated_at, exported: null}
  ```

  The stored `state` is only `open` or `closed`. `complete` is derived on read (below) and never stored, so it cannot go stale.
- Produces, in `epic-lib.sh` (sourced after `local-lib.sh`): `fl_epics_dir`, `fl_epic_dir <id>`, `fl_epic_exists <id>` (true only for a folder whose `epic.json` is an object with that `id`), `fl_next_epic_id` (allocates under a lock, as `fl_next_number` does), `fl_epic_lock <id>` (`fb_lock_acquire` on `<epics dir>/.<id>.lock`, released by the caller's EXIT trap), `fl_write_epic <id> <json-file>` (atomic, refuses content that is not an object with that id).
- Produces: `epic.sh create --title-file <f> [--intent-file <f>] [--design-file <f>] [--repo <r>]` prints `{"id": <id>}`. A non-empty design file becomes `design.md` with `design_rev` 1. `--repo` is checked with `fl_check_repo`.
- Produces: `epic.sh read <id>` prints the stored object plus:
  - `design`: the text of `design.md`, or `""`;
  - `log`: the lines of `log.jsonl` as an array (Task 4 writes them), `[]` when there is none;
  - `children`: `[{number, title, state, pr_url, repo, blocked_by, progress}]`, every card whose `epic` is this id, by number;
  - `progress`: `{waiting, ready, in_flight, blocked, done, dropped}` counts;
  - `effective_state`: `closed` when stored so; else `complete` when there is at least one child, every child's `progress` is `done` or `dropped`, and every child with a `pr_url` in Done has a log line; else `open`.
- Produces: a child's `progress`, from its state: `backlog` -> `waiting`; `ready` -> `waiting` when any `blocked_by` card is not in `done`, else `ready`; `in_progress`, `in_review`, any stage state from `fb_stage_states`, `merging`, `human_qa` -> `in_flight`; `blocked` -> `blocked`; `done` -> `done`; `wont_do` -> `dropped`.
- Produces: `epic.sh list [--all]` prints `[{id, title, effective_state, progress, attention: <count>}]` by id; without `--all`, only `open` ones.
- Produces: `epic.sh set-intent <id> <file>`, `epic.sh set-state <id> open|closed`, `epic.sh clear-attention <id> <index>` (0-based; an index out of range exits 1).
- Exit codes: 0 done; 1 failure; 2 usage; 3 the epic does not exist (`epic E<id> does not exist`).
- Task 2 adds the card field, so in this task the tests write a card's `epic` into its file directly.

- [ ] **Step 1: Write the failing tests** in `tests/test-epic.sh`, with a temp git repo and a store made by `init.sh`, as `tests/test-premise.sh` sets one up:

```
create makes the store:       no epics/ dir -> create prints {"id":1}; epics/next holds 2; epics/1/epic.json has state "open", design_rev 0, attention [], exported null
create with a design:         --design-file with text -> design.md equals it, design_rev 1
create with an empty design:  --design-file of zero bytes -> no design.md, design_rev 0
second create:                prints {"id":2}
create bad repo:              --repo nobody/nothing -> exit 2, no folder made, epics/next unchanged
read missing:                 read 9 -> exit 3, stderr "epic E9 does not exist"
read malformed:               epics/1/epic.json holding "x" -> read 1 exit 3
read children:                cards 4 and 7 with epic 1, card 5 with epic 2 -> read 1 .children numbers == [4,7]
progress backlog:             child in backlog -> progress "waiting"
progress ready, dep unmet:    child ready, blocked_by [4], card 4 in_review -> "waiting"
progress ready, dep met:      card 4 done -> "ready"
progress in flight:           one child each in in_progress, in_review, merging, human_qa -> all "in_flight"
progress counts:              .progress sums to the number of children
effective open, no children:  -> "open"
effective complete:           one child done with pr_url null, one wont_do -> "complete"
effective not complete:       child done with a pr_url and no log line -> "open"
effective complete with log:  a log.jsonl line {"card": <n>} for that child -> "complete"
closed wins:                  set-state 1 closed -> effective_state "closed"; list omits it; list --all has it
set-intent:                   intent equals the file's text; updated_at changes; design.md untouched
clear-attention:              attention of two entries, clear-attention 1 0 -> one left, the second; index 5 -> exit 1
usage:                        no verb, unknown verb, read with no id, set-state 1 nonsense -> exit 2
```

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-epic.sh`. Expected: every case fails (`epic.sh` missing).
- [ ] **Step 3: Implement** `epic-lib.sh` and the verbs above in `epic.sh`. `read` and `list` compute children with one `jq -s` over the card files, never one process per card.
- [ ] **Step 4: Run** the suite. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

### Task 2: The card's `epic` field

**Files:**
- Create: `tests/test-epic-card-field.sh`
- Modify: `scripts/board-create.sh`, `scripts/adapters/local/create.sh`, `scripts/adapters/local/edit.sh`, `scripts/adapters/local/read.sh`, `scripts/adapters/local/list.sh`, `scripts/adapters/local/local-lib.sh`, `scripts/import-plan.sh`, `tests/test-board-local.sh`, `CLAUDE.md`

**Interfaces:**
- Consumes: `fl_epic_exists` (Task 1).
- Produces: card field `epic`: a positive integer, or absent. A value that is not a positive integer is read as absent.
- Produces: `fl_check_epic <id|"">` in `local-lib.sh`: exit 2 with `epic E<id> does not exist` unless the value is empty or names an existing epic.
- Produces: `board-create.sh ... --epic <id>` and `adapters/local/create.sh --epic <id>`; `adapters/local/edit.sh --epic <id>`, where an empty value clears the field. Setting or clearing `epic` alone does not change the card's `premise`.
- Produces: `board-read.sh` returns `epic` (the id or null). `board-list.sh` rows gain `epic` the same way.
- Produces: `import-plan.sh` reads an optional `epic` (an id) on each card of the cards file and passes `--epic` to `board-create.sh`. A cards file naming an epic that does not exist stops the run before anything is created, as a lint failure does.

- [ ] **Step 1: Write the failing tests** in `tests/test-epic-card-field.sh`:

```
create with an epic:      board-create.sh --epic 1 -> card file .epic == 1; board-read.sh .epic == 1
create without:           card file has no epic key; board-read.sh .epic == null
create, unknown epic:     --epic 9 -> exit 2, "epic E9 does not exist", no card file, next unchanged
create, bad value:        --epic abc -> exit 2
edit sets it:             edit.sh <n> --epic 1 -> .epic == 1
edit clears it:           edit.sh <n> --epic "" -> no epic key
edit does not stamp:      seeded premise stamp unchanged after edit.sh --epic
malformed stored value:   card file with "epic": "x" -> board-read.sh .epic == null
list row:                 board-list.sh row for the card carries "epic": 1
import-plan passes it:    a cards file whose card has "epic": 1 -> the created card has .epic == 1
import-plan, unknown:     "epic": 9 -> exit 1, nothing created
epic.sh read sees it:     epic.sh read 1 lists the card under .children
```

In `tests/test-board-local.sh`, the assertions that pin whole list rows gain `"epic": null`.

- [ ] **Step 2: Run** `test-epic-card-field.sh` and `test-board-local.sh`. Expected: the new cases and the pinned rows fail.
- [ ] **Step 3: Implement** the flag in each script and the two readers.
- [ ] **Step 4: Run** both suites, then `test-epic.sh`. Expected: `failed: 0` in each.
- [ ] **Step 5: Commit.**

### Task 3: The record report

**Files:**
- Modify: `scripts/parse-report.sh`, `tests/test-parse-report.sh`, `CLAUDE.md`
- Create: fixtures under `fixtures/reports/architect-*.md`

**Interfaces:**
- Produces: `parse-report.sh --role architect --mode record <file>`. Common sections as for the checker (`## Status`, `## Findings`, `## For the card`, one `VERIFIED:` line). `--role architect` with no `--mode`, or another mode, is a usage error (exit 2), as for the checker.
- Status values: `recorded`, `no_change`.
- Role sections, all required, and the JSON keys they produce:

| Section | Content | JSON |
|---|---|---|
| `## Built` | one paragraph | `built: <string>` |
| `## Decisions` | bullets, or the single word `none` | `decisions: [<string>]` |
| `## Departures` | bullets, or `none` | `departures: [<string>]` |
| `## Design` | the single word `revised` or `unchanged` | `design: "revised"\|"unchanged"` |
| `## Intent` | the single word `holds`, or one paragraph | `intent: null` for `holds`, else the paragraph |
| `## Affects` | card references, each `C<n>` or `#<n>`, separated by spaces or commas, or `none` | `affects: [<int>]` |

- Rejections (exit 1, each stderr line with the `parse-report: ` prefix), worded like the checker's so `driver._RULES` does not match them by an earlier wildcard row: `architect status <s> is not allowed in mode record`, `architect report needs ## <section>`, `## Design must be revised or unchanged`, `## Affects must list cards (C<n> or #<n>) or none`, `architect status no_change cannot carry decisions, departures, a revised design or affected cards`.

- [ ] **Step 1: Write the failing tests** in `tests/test-parse-report.sh`: one accepted fixture for `recorded` with a revised design, bullets under Decisions and Departures and `## Affects` of `C12, #14`, asserting each JSON key with `jq` (`affects == [12,14]`, `intent == null`); one accepted `no_change` fixture (`decisions == []`, `design == "unchanged"`, `affects == []`); one accepted fixture whose `## Intent` is a paragraph (`intent` equals it); one rejected fixture per message above, asserting exit 1 and the exact line; `--role architect` with no `--mode` exits 2; `--role architect --mode check` exits 2; a reviewer status (`clean`) is rejected.
- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-parse-report.sh`. Expected: the new cases fail with the unknown-role usage error.
- [ ] **Step 3: Implement** the role in the usage text, the role and mode checks and the section handling, following how the checker is done.
- [ ] **Step 4: Run** the suite. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

### Task 4: Writing the log and the design, and the gate

**Files:**
- Modify: `scripts/epic.sh`, `scripts/adapters/local/epic-lib.sh`, `hooks/gate.sh`, `hooks/gate-lex.awk` (only if the lexer needs a new token), `tests/test-epic.sh`, `tests/test-gate.sh`, `CLAUDE.md`, `README.md` (the Gates section)

**Interfaces:**
- Consumes: the epic folder (Task 1), the card's `epic` field (Task 2).
- Produces: `epic.sh record <id> <card> <json-file> [--design-file <f>] [--expect-rev <n>]`. The file holds exactly one of three shapes:

  ```
  {pr: <int|null>, merge_commit: <40-hex|null>, built: <string>, decisions: [<string>], departures: [<string>], intent: <string|null>}
  {unrecorded: true, pr: <int|null>}
  {skipped: <string>, pr: <int|null>}
  ```

  - First shape: appends `{card, pr, merge_commit, at, built, decisions, departures, design_rev}` to `log.jsonl`. With `--design-file` naming a non-empty file: copies the current `design.md` to `revisions/<design_rev>.md` (skipped when `design_rev` is 0), writes the new `design.md`, and raises `design_rev` by one; the log line carries the new number. A string `intent` appends `{reason: "contradicts the intent: <text>", card, at}` to `attention`.
  - Second shape: appends `{card, pr, at, unrecorded: true}` and the attention entry `not recorded: the record session failed 3 times`.
  - Third shape: appends `{card, pr, at, skipped: <string>}` and no attention entry.
  - All of it happens under the epic's lock, and the log line and the design are written together or not at all: every check below runs before the first write.
  - Refusals, exit 1, nothing written: the card's `epic` is not this id; the log already has a line for the card (`card C<n> is already recorded in E<id>`); `--design-file` is missing or empty; `--expect-rev` differs from the stored `design_rev` (`E<id> is at design revision <a>, not <b>`, exit 4 so the driver can tell it apart). Exit 2 for a file that matches none of the shapes.
- Produces: `epic.sh approve-design <id> <file>`: the same revision step with no log line. The cards plan uses it; it is here because it shares the code and must be gated from the first day.
- Produces: `epic.sh fail <id> <card>`: raises the card's count in `<epic dir>/failures.json` and prints the new count. A card's count is removed when `record` writes its line.
- Produces: `epic.sh pending`: prints `[{epic, card, pr_url, failures}]` for every card in `done` with an `epic` that exists, a non-null `pr_url`, and no line for it in that epic's log, by card number. A card whose epic is missing or malformed is left out with `fleet-board: warning: card C<n> names epic E<id>, which cannot be read` on stderr. Exit 0 with `[]` when there is no `epics/` directory.
- Produces: gate rule G5 in `hooks/gate.sh`: a Bash command that runs `epic.sh` with any verb other than `read`, `list`, `pending` or `report` is blocked with `fleet-board gate: only a person or the supervisor changes an epic; use the board page or a terminal`. G5 matches `epic.sh` only where it runs: as the command word of a simple command (at the start, after `;`, `&&`, `||`, `|`, `(`, a command substitution's opening, or leading `VAR=value` words), or as the script argument of `bash` or `sh`. A word anywhere else, such as `cat scripts/epic.sh`, `git diff -- scripts/epic.sh`, `sed -i.bak ... scripts/epic.sh` or `grep -rn epic plugins/`, is not a run and is allowed; the bare word `epic` is never matched. This is narrower than G4, which matches the basename of every word in `gate.sh`'s word loop and so also blocks reads of the premise settle script; do not copy that. Once G5 has found a run, it takes the verb as G4's `parse_settle` does and fails closed the same way: a verb it cannot resolve is blocked.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-epic.sh`:

```
record appends:            first shape -> log.jsonl has one line with card, pr, merge_commit, built, decisions, departures, design_rev 0
record with a design:      epic at rev 1, --design-file new -> revisions/1.md holds the old text, design.md the new, design_rev 2, log line design_rev 2
record, first design:      epic at rev 0, --design-file -> no revisions/0.md, design_rev 1
record, intent paragraph:  intent "x" -> attention has reason "contradicts the intent: x" with the card
record, intent null:       attention unchanged
record twice:              second record for the same card -> exit 1, "card C7 is already recorded in E1", log still one line
record, wrong epic:        card 5 has epic 2, record 1 5 -> exit 1, nothing written
record, empty design file: --design-file of zero bytes -> exit 1, no log line, design.md and design_rev unchanged
record, missing design:    --design-file /nonexistent -> exit 1, no log line
record, stale rev:         epic at rev 2, --expect-rev 1 -> exit 4, "E1 is at design revision 2, not 1", no log line
record, matching rev:      --expect-rev 2 -> exit 0
record unrecorded:         second shape -> log line has unrecorded true; attention has "not recorded: the record session failed 3 times"
record skipped:            third shape -> log line has skipped "pull request was closed without merging"; attention unchanged
record, bad file:          {"x":1} -> exit 2, nothing written
approve-design:            epic at rev 1 -> revisions/1.md, new design.md, design_rev 2, log.jsonl untouched
fail counts:               fail 1 7 prints 1, again prints 2; after record 1 7 <first shape> failures.json has no entry for 7
pending, no epics dir:     prints [] and exits 0
pending lists:             done card 7 (epic 1, pr_url set, no log line) -> [{epic:1, card:7, pr_url, failures:0}]
pending, recorded:         after record -> []
pending, no pr:            done card with epic and pr_url null -> not listed
pending, not done:         in_review card with epic and pr_url -> not listed
pending, missing epic:     done card with epic 9, no folder -> not listed; stderr holds "card C8 names epic E9, which cannot be read"; exit 0
pending carries failures:  after fail 1 7 twice -> failures 2
```

In `tests/test-gate.sh`, in the style of the G4 cases:

```
G5 blocks:   epic.sh record 1 7 f.json | bash scripts/epic.sh set-intent 1 f | epic.sh approve-design 1 f | epic.sh create --title-file f
             | epic.sh set-state 1 closed | epic.sh clear-attention 1 0 | epic.sh fail 1 7 | epic.sh export 1 | epic.sh choose-sample 1 a
             each exits 2 with the G5 message
G5 allows:   epic.sh read 1 | epic.sh list | epic.sh list --all | epic.sh pending | epic.sh report 1
G5 unknown:  epic.sh "$V" 1 (a verb held in a variable) -> blocked
G5 inert:    the same commands in a directory with no .fleet-board.yml -> allowed
G5 reads:    cat scripts/epic.sh | sed -n 1,5p scripts/epic.sh | grep -n create scripts/epic.sh
             | git diff origin/main -- scripts/epic.sh | sed -i.bak 's/a/b/' scripts/epic.sh
             | grep -rn epic plugins/ -> each allowed
```

- [ ] **Step 2: Run** `test-epic.sh` and `test-gate.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement** the verbs and the gate rule.
- [ ] **Step 4: Run** both suites. Expected: `failed: 0`. Prove the G5 cases can fail by removing the rule for one run, and say so in the PR.
- [ ] **Step 5: Commit.**

### Task 5: The scheduler plans `record_epic`

**Files:**
- Modify: `scripts/tick-plan.sh`, `scripts/config-defaults.json`, `scripts/config.sh`, `scripts/supervisor/scheduler.py`, `scripts/supervisor/state.py`, `scripts/supervisor/loop.py`, `scripts/supervisor/driver.py`, `tests/tick-plan-lib.sh`, `tests/test-tick-plan-merging.sh`, `tests/test-config.sh`, `fixtures/supervisor/scheduler_cases.py`, `CLAUDE.md`, `plugins/fleet-board/docs/config.md`

**Interfaces:**
- Consumes: `epic.sh pending` (Task 4).
- Produces: config `epics: {record: false}` (boolean; `config.sh` refuses anything else with `epics.record must be true or false`) and `models.architect_record` (string, default `"sonnet"`). **The default is `false` in this task**: until Task 6 the driver does not know the action, and an action the driver refuses would be planned on every cycle. Task 6 flips it to `true`.
- Produces: plan action `record_epic`, reason `merged child of E<id> is not recorded`. The row carries `state: "done"` and `epic: <id>`. It appears in the plan and in `--candidates`. `--candidates --card <n>` for such a card returns the same row; today that mode reads only the active states, so this task adds `done` to the states it reads for a single card.
- When it is planned: `epics.record` is true, `<board.dir>/epics` exists, and `epic.sh pending` lists the card. `tick-plan.sh` runs `epic.sh pending` at most once per plan and not at all when the directory is absent. It lists no Done column and reads no Done card's note for this.
- A failed `epic.sh pending` (non-zero exit or output that is not an array) plans nothing for epics and adds one entry to the plan's JSON `warnings` array (the channel `candidates.py` surfaces; stderr never reaches the supervisor); the rest of the plan is unchanged.
- Never planned in `--settle-merge` mode.
- Produces, in `scheduler.py`: `record_epic` in `_ACTION_CLASS` (the class the premise check uses) and in `SCOPE_FREE_ACTIONS`. A new rule: at most one `record_epic` per `epic` value is admitted, and none while a `record_epic` for that epic is running; the held row's reason is `E<id> is recording C<other>`. Rows of different epics are admitted together. The lowest card number goes first.
- The running half of that rule needs the epic on a running claim, which it does not have today: `state.Action` gains `epic` (int or null), `driver.begin` copies it from the plan row, and `loop._active_claims` carries it, so the scheduler sees `epic` on running `record_epic` actions. `test_every_planned_action_is_classified` in `scheduler_cases.py` pins the `_ACTION_CLASS` set; add `record_epic` to its expected set.
- `tests/tick-plan-lib.sh`: `setup_case` writes `epics: {record: false}` into the case config unless the case's extra YAML sets the key, so no existing scenario changes when Task 6 flips the default.

- [ ] **Step 1: Write the failing tests.**

In `tests/test-tick-plan-merging.sh`, with the lib's `plan` and `assert_jq`, and a scenario builder added to the lib that makes an epic and a Done child:

```
epic-pending:          done card 7, epic 1, pr_url set, no log line, epics.record true -> a row for 7 with action "record_epic", reason "merged child of E1 is not recorded", epic 1, state "done"
epic-recorded:         the log has a line for 7 -> no row for 7
epic-off:              epics.record false -> no row for 7
epic-no-dir:           no epics/ directory, a done card -> the plan has no record_epic row and no warnings entry
epic-pending-fails:    epic.sh pending exits 1 (its cards directory made unreadable with chmod 000 for the case, since tick-plan runs the real epic.sh from its own directory and the suites fake only gh) -> no record_epic row, every other row as without it, one entry in the plan's warnings
epic-candidates:       --candidates has the row for 7 with epic 1
epic-one-card:         --candidates --card 7 returns the record_epic row
epic-settle:           --settle-merge 7 -> no record_epic row
epic-two-epics:        done children 7 (E1) and 9 (E2) -> a row for each
epic-default-lib:      after setup_case with no extra YAML the case config sets epics.record false; with extra YAML setting it true the file keeps true
```

In `scheduler_cases.py`:

```
test_one_record_epic_per_epic_is_admitted          candidates 7 and 8, both epic 1 -> 7 admitted; 8 held, reason "E1 is recording C7"
test_record_epic_waits_for_a_running_one           7 running record_epic for epic 1 -> 8 held
test_a_running_claim_carries_its_epic              driver.begin on a record_epic row -> the Action and loop._active_claims hold epic 1
test_record_epics_of_two_epics_run_together        7 (epic 1) and 9 (epic 2) -> both admitted
test_record_epic_is_scope_free                     admitted beside a start of another card whose Scope overlaps the child's
test_record_epic_is_a_classified_action            'record_epic' in the classified actions; it never goes to attention as unknown
```

In `tests/test-config.sh`: `epics.record: "yes"` is refused with the message above; defaults print `epics.record: false` and `models.architect_record: "sonnet"`.

- [ ] **Step 2: Run** `test-tick-plan-merging.sh`, `test-supervisor-scheduler.sh` and `test-config.sh`. Expected: `epic-pending`, `-candidates`, `-one-card`, `-two-epics`, `-default-lib`, the scheduler cases and the config cases fail. `epic-recorded`, `-off`, `-no-dir`, `-pending-fails` and `-settle` assert what holds today; they are guards. Show each can fail in Step 4 by breaking the rule it guards for one run.
- [ ] **Step 3: Implement.** The rows are added after the per-column cards are decided, from the `pending` list, for cards the plan does not already hold.
- [ ] **Step 4: Run** the three suites, then `bash plugins/fleet-board/tests/test-tick-plan.sh` (the aggregate) and `test-tick-plan-split.sh`, since this task adds a kind of row to every plan. Expected: `failed: 0` in each.
- [ ] **Step 5: Commit.**

### Task 6: The record session

**Files:**
- Create: `scripts/supervisor/defaults/epic-record-prompt.md`
- Modify: `scripts/worktree.sh`, `scripts/premise.sh`, `scripts/supervisor/resolver.py`, `scripts/supervisor/driver.py`, `scripts/supervisor/scripts.py`, `scripts/config-defaults.json`, `fixtures/supervisor/driver_cases.py`, `fixtures/supervisor/resolver_cases.py`, `tests/test-worktree.sh`, `tests/test-premise.sh`, `tests/test-config.sh`, `CLAUDE.md`, `README.md`

**Interfaces:**
- Consumes: plan action `record_epic` with `epic` (Task 5); `parse-report.sh --role architect --mode record` (Task 3); `epic.sh read|record|fail` (Tasks 1 and 4).
- Produces: `worktree.sh epic <n>`: the same behaviour as `worktree.sh premise <n>` with the path `<base>/<n>-epic_record`; prints `{path, head}`. The driver removes it with the path form of `worktree.sh remove`. Update the Invariants line in `CLAUDE.md` that lists which checkouts the driver removes.
- Produces: `premise.sh clear <n>`: sets the card's `premise` to null and `premise_recheck` to true under the card's lock; exit 0, 3 when the card cannot be read.
- Produces: `adapters/local/move.sh` does not re-stamp a card moved into Ready by a person while its `premise_recheck` is true, so a Backlog sibling named under `## Affects` is still checked before it starts. The premise check drops `premise_recheck` when it stamps the card. `scripts/adapters/local/move.sh` and `tests/test-board-local.sh` join this task's Files.
- Produces: `resolver.resolve` returns `Dispatch('claude', None, CLAUDE, <models.architect_record or 'sonnet'>, False)` for `record_epic`.
- Produces: `ROLE_ACTIONS` and `_ROLE_OF` gain `record_epic -> 'architect'`. `scripts.ALLOWED` gains `epic.sh`. `driver._FLAGS` gains `--design-file` and `--expect-rev`.
- Produces: an `architect` entry in `_SECTIONS` and `_LABELS`. Its inputs, in order: card number, title, body, numbered acceptance; `mode` (`record`); `pull_request` (the number and the merge commit); `reports` (every role report comment on the card, oldest first, each under its author line; a role report is a comment with `## Status` and a `VERIFIED:` line); `epic_intent`; `epic_design` (with its revision number); `epic_log` (one line per entry: `#<card>: <built>`, then its decisions and departures); `siblings` (each child of the epic with no `pr_url` in `backlog` or `ready`, as `C<n> <state> <title>` followed by its Scope text and numbered acceptance); `design_out` (an absolute path the session writes a revised design to); the checkout path; the scripts directory; `instructions` (the text of `defaults/epic-record-prompt.md`); the config.
- `design_out` is `<log dir>/epic-record/<card>-<ms>.md`, made by the driver, outside the checkout and outside the store. The driver deletes it when the action ends.
- The instructions file tells the session: work only in the checkout and change no file in it; read the merged change (`git show <merge commit>`) and the reports; write a revised design to the `design_out` path only when the design changed, as the whole design and never a patch; never restate or edit the intent; name under `## Affects` only siblings from the list given; end with the report as its final reply.
- Produces: `CardDriver._do_record_epic(c)`. Before any session it reads the pull request (`gh pr view <pr> --json state,mergeCommit`):
  - `MERGED`: continue.
  - `CLOSED`: `epic.sh record <epic> <n> <file>` with `{skipped: "pull request was closed without merging", pr}`; no session.
  - `OPEN` or a failed read: nothing is written and the action ends with one event; it is planned again.
- Produces: `CardDriver._settle_epic(c, run, parsed)`, called where `_settle_premise` is called for the checker:
  1. posts the accepted report on the card with `board-comment.sh`;
  2. writes the first-shape JSON from the parsed report and runs `epic.sh record <epic> <n> <file> --expect-rev <rev read at launch>`, adding `--design-file <design_out>` when `design` is `revised`;
  3. for each number in `affects` that the `siblings` input listed, runs `premise.sh clear <m>` and records one event `E<id>: C<m> will be checked before it starts`; any other number is ignored with one event;
  4. removes the checkout.
  It ignores `Out of scope:` and `Bugs found:` lines in the report, so a record files no follow-ups.
- Failure handling, which is unlike every other action: an empty reply, a report rejected twice, a non-zero `epic.sh record` (exit 4 included), a `revised` report with a missing or empty `design_out`. The driver runs `epic.sh fail <epic> <n>`. When the printed count is 3 or more it runs `epic.sh record` with `{unrecorded: true, pr}`. It never writes the card's note, never counts `action_failures`, and never moves the card.
- Produces: the usage line, through the existing `_record_usage`: `kind: 'card'`, `column: 'done'`, `action: 'record_epic'`, `role: 'architect'`. No key is added to the ledger.
- Produces: `epics.record` default `true` in `config-defaults.json`.

- [ ] **Step 1: Write the failing tests.**

In `fixtures/supervisor/driver_cases.py`, using `board_for`, `begin` and `run_role`, with a fake `epic.sh` recording its calls:

```
test_record_epic_starts_a_session_in_an_epic_checkout
    begin(b, 'record_epic').kind == 'session'; calls include ('worktree.sh', 'epic', n); the argv has no '--agent' and has
    '--tools', 'Read,Write,Bash,Grep,Glob' before '--permission-mode'
test_the_record_prompt_carries_the_epic_and_the_reports
    the prompt holds the intent, the design with its revision number, each log entry, both role reports in order,
    the merge commit, the design_out path, and a sibling's Scope and acceptance
test_siblings_leave_out_cards_with_a_pull_request_and_cards_in_flight
test_a_recorded_report_writes_the_log
    ('epic.sh', 'record', '1', n, <file>, '--expect-rev', '2'); the file holds built, decisions, departures, pr, merge_commit;
    the report is posted with board-comment.sh; ('worktree.sh', 'remove', n, <path>)
test_a_revised_design_is_passed_as_a_file
    design_out written by the fake session -> '--design-file', <design_out> in the record call
test_revised_without_a_design_file_is_a_failure
    no record call; ('epic.sh', 'fail', '1', n)
test_affected_siblings_lose_their_stamp
    affects [12, 99], 12 a listed sibling -> ('premise.sh', 'clear', '12'); no call for 99; one event names 99 as ignored
test_a_closed_pull_request_is_skipped_without_a_session
    gh says CLOSED -> the record file holds skipped "pull request was closed without merging"; no session started
test_an_unreadable_pull_request_writes_nothing
    gh fails -> no epic.sh call, no session, one event
test_a_failed_record_counts_on_the_epic_not_the_card
    empty final reply -> ('epic.sh', 'fail', '1', n); no note.sh call; no board-move.sh call
test_the_third_failure_writes_unrecorded
    the fake fail prints 3 -> the next record file holds unrecorded true
test_a_stale_revision_is_a_failure
    epic.sh record exits 4 -> ('epic.sh', 'fail', ...); the checkout is still removed
test_follow_up_lines_in_a_record_report_file_nothing    no file-followups.sh call
test_the_usage_line_is_a_card_line_in_done
    kind 'card', column 'done', action 'record_epic', role 'architect'
```

In `resolver_cases.py`: the dispatch above, and a configured `models.architect_record` is used. In `tests/test-worktree.sh`: `epic 12` prints a path ending `/12-epic_record` and the default head; `remove 12 <that path>` deletes it and leaves `<base>/12-some-slug` and `<base>/12-premise_check`. In `tests/test-premise.sh`: `clear` on a stamped card leaves `premise` null and `premise_recheck` true, and `premise.sh moved` then reports `no premise stamp`; `clear 999` exits 3; a stamp written by the premise check removes `premise_recheck`. In `tests/test-board-local.sh`: a Backlog card with `premise_recheck` true that a person moves to Ready keeps `premise` null; one without it is stamped as today. In `tests/test-config.sh`: the default `epics.record` is now `true`.

- [ ] **Step 2: Run** `test-supervisor-driver.sh` (one test at a time with `FLEET_TEST_ONLY=<name>`), `test-supervisor-resolver.sh`, `test-worktree.sh`, `test-premise.sh` and `test-config.sh`. Expected: the new cases fail.
- [ ] **Step 3: Implement.** `_do_record_epic` follows `_do_check_premise`'s shape. Keep the failure path separate from `failure_patch`, which writes the note.
- [ ] **Step 4: Run** the same suites, then `test-tick-plan-merging.sh`. Expected: all pass.
- [ ] **Step 5: Commit.**

### Task 7: The epic reaches the premise check and the roles

**Files:**
- Modify: `scripts/supervisor/driver.py`, `scripts/supervisor/defaults/premise-check-prompt.md`, `fixtures/supervisor/driver_cases.py`, `CLAUDE.md`

**Interfaces:**
- Consumes: `epic.sh read` (Task 1); the card's `epic` from `board-read.sh` (Task 2).
- Produces: an `epic` input and section, label `Epic`, in `_SECTIONS` for `implementor`, `reviewer`, `fixer` and `checker`. Its text is `E<id>: <title>`, then `Intent`, then `Design (revision <n>)`. For the checker it also holds the as-built log in the form Task 6 gives. A card with no epic has no such section.
- The section is read once per dispatch with `epic.sh read <id>`. A read that fails gives no section and one event `E<id> could not be read for C<n>`; the action goes on.
- `defaults/premise-check-prompt.md` gains two sentences: when an Epic section is present, a proposed rewrite must keep to the epic's intent, and a card that contradicts the design or the as-built log is `stale`.
- No file under `agents/` changes. Whether the three clean-room roles act on a section their files do not mention is not known. It is checked after this task by one live run per role against a fixture card (`behavioral-*.sh`, which costs usage: run it only when the owner asks). If a role ignores the section, re-authoring its agent file is a separate decision.

- [ ] **Step 1: Write the failing tests** in `driver_cases.py`:

```
test_an_implementor_prompt_for_a_child_carries_the_epic
    the prompt holds '## Epic', 'E1: <title>', the intent and 'Design (revision 2)'; it does not hold a log entry
test_a_reviewer_and_a_fixer_prompt_carry_the_epic
test_the_checker_prompt_also_carries_the_as_built_log
test_a_card_without_an_epic_has_no_epic_section
test_an_unreadable_epic_gives_no_section_and_one_event
    epic.sh read exits 3 -> the session still starts; the prompt has no '## Epic'; one event 'E9 could not be read for C<n>'
```

- [ ] **Step 2: Run** each with `FLEET_TEST_ONLY=<name> bash plugins/fleet-board/tests/test-supervisor-driver.sh`. Expected: the first three and the last fail.
- [ ] **Step 3: Implement** one helper that builds the section and is called from each dispatch.
- [ ] **Step 4: Run** the five tests, then the whole of `test-supervisor-driver.sh` once, since every role prompt passes through the change. Expected: all pass.
- [ ] **Step 5: Commit.**

### Task 8: A proposal that came from the Architect

**Files:**
- Modify: `scripts/premise-settle.sh`, `tests/test-premise-settle.sh`, `CLAUDE.md`

**Interfaces:**
- Produces: a `rewrite` proposal may carry `source: "architect"` and, with it, `from: "backlog"|"ready"`. `propose` keeps both keys when `source` is `architect`; `from` without that source, or any other `source` value, is a malformed proposal (exit 2). A proposal with no `source` is stored exactly as today.
- Produces: `propose` with `source: architect` on a card that already holds a proposal with no `source` exits 1 with `card C<n> already has a premise-check proposal`, and stores nothing. A second Architect proposal replaces the first.
- Produces: `approve` on a proposal with `source: architect` moves the card to the proposal's `from` instead of `ready`. Everything else it does is unchanged (Scope and acceptance replaced, `blocked_by` kept, the stamp, the proposal cleared).
- Produces: `reject` on a proposal with `source: architect` on a Blocked card also moves the card to `from`. A premise-check proposal's `reject` leaves the state, as today.
- The board server, in the cards plan, is what moves the card to Blocked when it stores such a proposal. This script does not.
- Gate rule G4 already covers `approve` and `reject`; nothing changes there.

- [ ] **Step 1: Write the failing tests** in `tests/test-premise-settle.sh`:

```
propose keeps the source:       file with source "architect", from "backlog" -> .proposal.source == "architect", .proposal.from == "backlog"
propose without a source:       stored proposal has no source and no from key
propose, from without source:   exit 2, nothing stored
propose, unknown source:        source "someone" -> exit 2
propose, bad from:              source "architect", from "done" -> exit 2
propose over a premise one:     card holds a proposal with no source; Architect propose -> exit 1, "card C7 already has a premise-check proposal", the stored proposal unchanged
propose replaces its own:       two Architect proposes -> the second is stored
approve returns to backlog:     Blocked card, Architect proposal from "backlog" -> state "backlog", Scope and acceptance replaced, premise.by "approve", proposal null
approve returns to ready:       from "ready" -> state "ready"
approve, premise proposal:      no source -> state "ready" (unchanged behaviour)
reject returns it:              Blocked card, Architect proposal from "backlog" -> state "backlog", proposal null, a line in premise-decisions.jsonl
reject, premise proposal:       no source -> state stays "blocked"
```

- [ ] **Step 2: Run** `bash plugins/fleet-board/tests/test-premise-settle.sh`. Expected: the Architect cases fail; the two unchanged-behaviour cases pass and are guards.
- [ ] **Step 3: Implement** in the `propose` filter and the `approve` and `reject` branches.
- [ ] **Step 4: Run** the suite, then `test-gate.sh`. Expected: `failed: 0`.
- [ ] **Step 5: Commit.**

## After the last task

- Run one real record end to end on this repository: make an epic by hand in a terminal with `epic.sh create`, set `epic` on a card that is about to merge, and read the log line and the posted report after it reaches Done. Compare the session's tokens in `fleet-board supervisor usage` with the `check_premise` lines; the spec's anti-goal is that the record costs no more.
- Import the cards plan: `/fleet-board:import-plan docs/specs/2026-11-18-epics-design.md docs/plans/2026-11-18-epics-cards.md`. Create the epic for those cards first, by hand, and give each card its id, so the rest of the build is the first change tracked as an epic.
- Move #464 to Won't do with a link to the spec, as the card itself asks.
