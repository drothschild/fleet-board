# fleet-board behavior specs: clean-room audit trail

The files in this directory are the behavior specs for the fleet-board role agents and the
reporting skill (Phase 5, Task 5), and the record of how they and the agent files authored
from them (Task 6) were produced.

Nothing listed as "authored" below was written or edited by the session executing the plan.
Each authored file was written by a separate, isolated `claude -p --bare` process whose
prompt named its only permitted input files. The executing session wrote the briefs, this
README, and ran the processes and the checks.

| File | Authored by |
|---|---|
| `implementor.md`, `reviewer.md`, `fixer.md`, `reporting.md` | Task 5 spec authors (below) |
| `briefs/spec-req-<role>.md` | the executing session (the author's brief, copied here unchanged after the run) |
| `README.md` | the executing session |
| `plugins/fleet-board/agents/{implementor,reviewer,fixer}.md`, `plugins/fleet-board/skills/reporting/SKILL.md` | Task 6 authors (below) |

- **Claude Code:** 2.1.284
- **Date:** 2026-09-28
- **Auth:** `--settings ~/.config/fleet-board/bare-settings.json` (an `apiKeyHelper`; `apiKeySource: apiKeyHelper` in every init event). The key never appears in any log or file here.

## Isolation

### Canonical command form (adopted variant)

Every authoring process ran as one Bash call, with the settings path as a separate statement
and a fresh empty `CLAUDE_CONFIG_DIR`:

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir <inputs dir> --output-format stream-json --verbose --max-turns 30 "<prompt>" > "$TMPDIR/fb-p5/<log>" 2>&1
```

Plain `--bare` on 2.1.284 still registers every installed user plugin; the empty
`CLAUDE_CONFIG_DIR` is what removes them (see `rehearsal-notes.md`, "Phase 5 bare-authoring
pre-flight").

### Pre-flight evidence (`bare-init.json`)

Re-run on 2026-09-28 with exactly the adopted form:

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --tools "Read,Edit" --output-format stream-json --verbose --max-turns 1 "Reply ok."
```

Init event fields `{plugins, tools, skills, slash_commands, agents, apiKeySource, claude_code_version}`:

```json
{"plugins":[{"name":"agents-md","path":"builtin","source":"agents-md@builtin"},{"name":"telemetry","path":"builtin","source":"telemetry@builtin"}],"tools":["Edit","Read"],"skills":["deep-research","design","design-sync","dataviz","artifact-diagramming","update-config","verify","debug","code-review","simplify","batch","fewer-permission-prompts","doctor","loop","claude-api","workflow-authoring","run","run-skill-generator"],"slash_commands":["deep-research","design","design-sync","dataviz","artifact-diagramming","update-config","verify","debug","code-review","simplify","batch","fewer-permission-prompts","doctor","loop","claude-api","workflow-authoring","run","run-skill-generator","agents","auto-mode-setup","autocompact","clear","color","compact","config","output-style","context","effort","fast","focus","heapdump","init","mcp","model","__remote-workflow","workflow-launch-exec","reload-plugins","reload-skills","rename","security-review","usage","insights","recap","goal","design-consent","design-revoke","list-agents","team-onboarding"],"agents":["claude","claude-code-guide","Explore","general-purpose","Plan","statusline-setup"],"apiKeySource":"apiKeyHelper","claude_code_version":"2.1.284"}
```

Result `ok`, cost $0.0068.

### Per-run assertion

The same assertion ran on the init event of **every** authoring run's stream-json log:

- `plugins` names are a subset of {`agents-md`, `telemetry`}
- `tools` sorted is exactly `["Edit","Read"]`
- no `skills` or `slash_commands` entry contains `:` (no plugin-namespaced primitive)
- the init event does not contain the forbidden plugin name (pattern built at run time)

The assertion was first shown to fail: the pre-flight log, with a fake plugin, a `Bash` tool
and a `p:s` skill injected, gave `ASSERT FAIL` with three failure lines.

A second check audited every `tool_use` in each log: each `Read` path is inside the staged
inputs directory (or the run's own output file), and each `Edit` targets only the run's
output file. Both results are recorded per run below.

### Committed init evidence (`evidence/`)

The init event of each authoring run is committed under [`evidence/`](evidence/), one file per
run: `spec-<name>[.r1].init.json` for Task 5 and `author-<name>[.r1].init.json` for Task 6
(the `.r1` files are the Revision 1 re-runs in the re-run log). Each holds only these fields
of the `system/init` event, extracted with jq from the run's stream-json log:
`plugins`, `tools`, `agents`, `skills`, `slash_commands`, `apiKeySource`,
`claude_code_version`. Fields that carry local paths (`cwd`, memory paths) are left out.
Before committing, the files were checked for `sk-ant` (no match), home-directory and temp
paths (no match) and the forbidden plugin name (no match), and every file passed the
per-run assertion above: built-in plugins only, tools `Edit` and `Read`, no namespaced
skill or command, `apiKeySource: apiKeyHelper`, Claude Code `2.1.284`.

Re-check any file with:

```bash
jq -e '([.plugins[].name] - ["agents-md","telemetry"] | length == 0)
       and .tools == ["Edit","Read"]
       and ([.skills[], .slash_commands[]] | all(contains(":") | not))' evidence/<run>.init.json
```

## Inputs (Task 5)

All permitted inputs were copied into one staging directory, `$TMPDIR/fb-p5/inputs/`, which
was the run's only `--add-dir`; the process cwd was this `specs/` directory (its output
location). sha256 prefixes of the staged copies:

| Staged file | Source | sha256 (16) |
|---|---|---|
| `design.md` | `docs/design-plans/2026-09-28-fleet-board.md` | `91f195dfe9f0b07a` |
| `hmb/AGENTS.md` | `~/Projects/HMBWorkout/AGENTS.md` | `01ac916c67fc4327` |
| `hmb/qa-artifacts/...` | `~/Projects/HMBWorkout/.worktrees/qa-artifacts/...` | listed below |
| `spec-req-<role>.md` | the brief, written by the executing session | listed per run |

### HMB input screening (Task 5 Step 1.4)

Screen: `grep -il <forbidden plugin name>` and `grep -E 'Skill tool|skills/|SKILL\.md|subagent_type'`
over `~/Projects/HMBWorkout/AGENTS.md` and every text file under
`~/Projects/HMBWorkout/.worktrees/qa-artifacts/`.

**Admitted** (0 hits on both screens; the file types the plan names as HMB process sources:
`AGENTS.md`, `QA-RUN.md`, `HUMAN-QA-20260915.md`, `EVIDENCE.md`, `HANDOFF-*.md`, `STATUS.md`):

| File (under `qa-artifacts/` unless noted) | sha256 (16) |
|---|---|
| `~/Projects/HMBWorkout/AGENTS.md` | `01ac916c67fc4327` |
| `issue376-comparison-20260915/STATUS.md` | `a4a4b4deeb471999` |
| `pr377-2f5dc26/EVIDENCE.md` | `ea3dcd17ea628bfc` |
| `pr377-2f5dc26/QA-RUN.md` | `8c943b3cf846df35` |
| `pr378-4f4368b/EVIDENCE.md` | `20997838f45ecf34` |
| `pr378-4f4368b/QA-RUN.md` | `70ea29a520f50f05` |
| `pr378-52bc853/QA-RUN.md` | `834445d82de1be77` |
| `pr378-6483f62/HUMAN-QA-20260915.md` | `2129b20a23ff7f4c` |
| `pr378-6483f62/QA-RUN.md` | `be38cdd07078e962` |
| `pr378-b104d61/HUMAN-QA-20260915.md` | `2fbdb42efc49e7e3` |
| `pr378-b104d61/QA-RUN.md` | `1cd31954fd9647e4` |
| `pr378-f1332d9/HUMAN-QA-20260915.md` | `539245f5b446a9a3` |
| `pr378-f1332d9/QA-RUN.md` | `15dd57d93c67a157` |
| `pr378-fafd716/EVIDENCE.md` | `b544cbd23cde70f6` |
| `pr378-fafd716/HANDOFF-20260915.md` | `0c157ffbb8ed5390` |
| `pr378-fafd716/QA-RUN.md` | `78f16749b0b6b77e` |
| `pr385-f007ea2/EVIDENCE.md` | `b20cdd5c578bb92d` |
| `pr385-f007ea2/QA-RUN.md` | `1f23f4d78c6f84f9` |
| `pr391-c79e989/QA-RUN.md` | `d18a6919e2ea593a` |
| `pr392-9c2c258/QA-RUN.md` | `805a1bdfe2393815` |

**Excluded:**

| File(s) | Reason |
|---|---|
| `pr378-6483f62/build.log` | contains the forbidden plugin name (2 lines) |
| `*/README.md` (10 files), `pr378-4f4368b/GITHUB-COMMENT.md`, `pr378-b104d61/wiring-mutations/test-template.txt` | clean on both screens, but not among the process-note files the plan names as sources (artifact indexes, a posted comment, a test template) |
| all other files (~11,700: app bundles, `.jpg`/`.png` screenshots, `.plist`, `.db`, `.log`, `.json`, `.zip`, simulator data) | binary or run output, not process notes |

The design document is a plan-named input. It mentions the forbidden plugin name only as
the subject of the clean-room rule; the author prompts forbid mentioning any third-party
plugin, and every authored file was grepped for the name afterwards (0 hits).

### Briefs

Each brief (`briefs/spec-req-<role>.md`) contains: the required section list; the role's
inputs, behavior, Must never list and AC ids from `phase_05.md` Task 5 Step 2; the phase
file's "Report shape" section verbatim; and the phase's acceptance-criteria excerpt
verbatim, except that the AC5.1 line's literal plugin name is replaced by
`<the forbidden plugin name>`.

## Task 5 runs: specs

Prompt (per role; `<role>` substituted, paths absolute at run time, shown here with
`$TMPDIR/fb-p5` and `<worktree>`):

```
You are writing a behavior specification. Read ONLY these files: $TMPDIR/fb-p5/inputs/spec-req-<role>.md (the brief), $TMPDIR/fb-p5/inputs/design.md (the design), $TMPDIR/fb-p5/inputs/hmb/AGENTS.md (HMB AGENTS.md), and these HMB QA notes: <the 19 admitted qa-artifacts files, each as $TMPDIR/fb-p5/inputs/hmb/qa-artifacts/<path>, comma-separated>. Do not read any other file. Write the spec to <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs/<role>.md following the section list in the brief. Specs describe behavior, not prompt wording. Do not quote or mention any third-party plugin. Cite no sources, no URLs, no attributions.
```

Command (cwd `specs/`):

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir "$TMPDIR/fb-p5/inputs" --output-format stream-json --verbose --max-turns 30 "$(cat "$TMPDIR/fb-p5/prompt-spec-<role>.txt")" > "$TMPDIR/fb-p5/spec-<role>.log" 2>&1
```

| Spec | Brief sha256 | Init sha256 | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `implementor.md` | `2304bacdf2c24653` | `45ae3594d037d45b` | PASS | PASS (23 reads, all staged inputs or own output) | 25 | 0.5653 | `1b6bad1a5c5cfcea` |
| `reviewer.md` | `af0aaf837b78b9ff` | `83973fc7406dffb8` | PASS | PASS (23 reads) | 25 | 0.5737 | `d3a95b5325807040` |
| `fixer.md` | `91a62fc7bed449e5` | `508c96d2fd14857b` | PASS | PASS (22 reads) | 25 | 0.5511 | `ccf7d29eaf6bb758` |
| `reporting.md` | `b09767a24a6ed107` | `12a176ffc3dde352` | PASS | PASS (22 reads) | 24 | 0.5620 | `0bd3f4ac6b728f64` |

Every init digest was identical apart from `session_id`:
`{"plugins":["agents-md","telemetry"],"tools":["Edit","Read"],"agents":["claude","claude-code-guide","Explore","general-purpose","Plan","statusline-setup"],"namespaced":[],"apiKeySource":"apiKeyHelper","claude_code_version":"2.1.284"}`.

**Review (Task 5 Step 5).** Each spec was read against its brief. Every brief requirement is
present in each spec; each spec has the six required sections and the Report shape
verbatim. No spec contains the forbidden plugin name, a URL, or an attribution phrase.
**Re-runs: none.**

Notes from the review (not defects against the brief, so no re-run):
- The reviewer spec adds a step "record the head SHA" before the acceptance map, so its
  numbering is one ahead of the brief's.
- The fixer spec writes its report temp file inside the worktree (never committed); the
  implementor spec writes it with `mktemp` outside the worktree. Both satisfy their Must
  never lists.
- The implementor spec's example `VERIFIED:` line uses an npm/jest-style single-file command;
  the agent uses the configured `commands.test_one`.

## Task 6 runs: agents and the reporting skill

Command (cwd `plugins/fleet-board/`; the only `--add-dir` is this `specs/` directory):

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs --output-format stream-json --verbose --max-turns 30 "$(cat "$TMPDIR/fb-p5/prompt-author-<name>.txt")" > "$TMPDIR/fb-p5/author-<name>.log" 2>&1
```

Agent prompt (`<role>`, `<model>`, `<color>` substituted; paths absolute at run time):

```
Read ONLY <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs/<role>.md and <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs/reporting.md. Write <worktree>/plugins/fleet-board/agents/<role>.md: a Claude Code agent file. Frontmatter exactly (replace only the description placeholder with one sentence you write):
---
name: <role>
description: <when the manager dispatches this role, and what it does>
model: <model>
color: <color>
tools: ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
---
The body is the prompt the <role> follows. Organize it as: principle (one paragraph), method (numbered, every spec behavior), report template (the exact shape from the reporting spec), what not to do (the spec's Must never list). The frontmatter description must say when the manager dispatches this role. The model value is a fallback; the manager passes the configured model at dispatch. Cite no sources, no URLs, no attributions. Do not mention any third-party plugin. Do not read any other file.
```

(implementor: `sonnet`/`green`; reviewer: `opus`/`red`; fixer: `sonnet`/`yellow`.)

Skill prompt:

```
Read ONLY <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs/reporting.md. Write <worktree>/plugins/fleet-board/skills/reporting/SKILL.md: a Claude Code skill file. Frontmatter exactly (replace only the description placeholder with text you write):
---
name: reporting
description: <Use when a fleet-board role agent (implementor, reviewer or fixer) is about to write its report ... state the trigger condition first, then what the skill gives>
user-invocable: false
---
Do not add any other frontmatter key (in particular no allowed-tools). The body is the instructions a fleet-board role agent follows when it writes its report. Organize it as: principle (one paragraph), method (numbered, every spec behavior), report template (the exact shape from the reporting spec, including every role section), what not to do (the spec's Must never list). Cite no sources, no URLs, no attributions. Do not mention any third-party plugin. Do not read any other file.
```

| Output | Inputs read | Prompt sha256 | Init sha256 | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|---|
| `agents/implementor.md` | `specs/implementor.md`, `specs/reporting.md` | `97526d58902f0c0f` | `964d687437f88c97` | PASS | PASS (2 reads) | 6 | 0.2366 | `03db96670a5fb5e2` |
| `agents/reviewer.md` | `specs/reviewer.md`, `specs/reporting.md` | `7533a3808b751b3b` | `a1a533f5db11c9f5` | PASS | PASS (2 reads) | 5 | 0.2524 | `dd70b50296ae35ac` |
| `agents/fixer.md` | `specs/fixer.md`, `specs/reporting.md` | `2326940fc1ab9b3f` | `d327ebbc9ccda80c` | PASS | PASS (2 reads) | 4 | 0.2069 | `2f51dcb91b257922` |
| `skills/reporting/SKILL.md` | `specs/reporting.md` | `f28a044b3eab544b` | `8e1ec345afae6eb3` | PASS | PASS (1 read) | 6 | 0.2135 | `e126c35501fb18ae` |

Every init digest was the same as in Task 5 (built-in plugins `agents-md` and `telemetry` only,
tools `["Edit","Read"]`, built-in agents only, no namespaced skill or command,
`apiKeySource: apiKeyHelper`, 2.1.284).

**Review.**
- Each agent's "What not to do" section carries its spec's Must never list; each method
  covers the spec's numbered behavior.
- Report templates: each agent's template, filled mechanically (placeholders replaced, one
  Out of scope item, one bug, role sections as the agent's rules describe), passes
  `parse-report.sh --role <role>` with exit 0 (implementor `done`, `pr: 7`; fixer
  `blocked`, `blocked_by: 41`, 2 resolutions; reviewer `findings`, mutation counts and a
  claim check).
- `bash plugins/fleet-board/tests/test-clean-room.sh`: `passed: 19   failed: 0`, with the
  spec-presence check active (3 × `spec exists`).
- `bash plugins/fleet-board/tests/test-parse-report.sh`: `passed: 94   failed: 0`.
- `grep -ri <forbidden plugin name> plugins/fleet-board`: no output, exit 1.
- Phase 1 runtime load check (`claude -p --plugin-dir plugins/fleet-board ... | jq '{agents, plugin_errors}'`):
  `fleet-board:fixer`, `fleet-board:implementor` and `fleet-board:reviewer` are in `agents`;
  `plugin_errors: null`.

**Re-runs: none.**

## Cost

Sum of `total_cost_usd` over the result events: pre-flight $0.0068; Task 5 specs $2.2522;
Task 6 authors $0.9094. Total **$3.1683** (9 runs).

## Re-run log

### Revision 1 (2026-09-28): fixer report location, clean worktree, example commands

**Why.** Two inconsistencies were found in the review above:
- The fixer spec had the report temp file written inside the worktree. It should go outside,
  as the implementor's does, and the worktree must be left clean.
- The implementor spec's example `VERIFIED:` line used an npm/jest single-file command
  (`npm test -- --runTestsByPath ...`). Every example must be `commands.test_one` with
  `{file}` replaced by a test path.

The reviewer spec, reporting spec, reviewer agent and reporting skill were grepped for
positive npm, jest or full-suite examples, and none were found. So only the implementor
and fixer were re-authored.

**Brief change.** A "Revision 1 requirements" section was appended to
`briefs/spec-req-implementor.md` and `briefs/spec-req-fixer.md`. Both got the
example-command rule. The fixer brief also got:
- the report temp file comes from `mktemp` outside the worktree;
- an explicit numbered behavior: `git -C <worktree> status --porcelain` prints nothing
  after the commits and push;
- a new Must never item: "leave untracked or modified files in the worktree".

The briefs in `briefs/` are the revised versions.
- Implementor brief sha256: `2304bacdf2c24653` → `51828a44184da262`.
- Fixer brief sha256: `91a62fc7bed449e5` → `45c61895e416551d`.

**Process.**
- The four outputs (`specs/implementor.md`, `specs/fixer.md`, `agents/implementor.md`,
  `agents/fixer.md`) were deleted before their runs, so each author wrote a fresh file.
  They are recoverable from git.
- The same prompt files and commands as above were used (Task 5 form for the specs,
  Task 6 form for the agents). Logs have the suffix `.r1.log`.
- The agents were re-authored after the specs, from the revised specs plus the unchanged
  `specs/reporting.md`.

| Output | Log | Init sha256 | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/implementor.md` | `spec-implementor.r1.log` | `06ab5ec5ec8fb83d` | PASS | PASS (23 reads) | 25 | 0.6041 | `a5852800a6a52c14` |
| `specs/fixer.md` | `spec-fixer.r1.log` | `e85365b759e17ebe` | PASS | PASS (22 reads) | 24 | 0.5990 | `89341fdb9a74a43f` |
| `agents/implementor.md` | `author-implementor.r1.log` | `6df54a83b5b6c473` | PASS | PASS (2 reads) | 6 | 0.2408 | `c8b32ba243afb856` |
| `agents/fixer.md` | `author-fixer.r1.log` | `c91a1a752d04c256` | PASS | PASS (2 reads) | 4 | 0.2110 | `9c372d4fcde701e8` |

The init digests were identical to the earlier runs apart from `session_id`.

**Checks after revision 1.**
- **Fixer outputs.** Both the spec and the agent now write the report with `mktemp` under
  `$TMPDIR` and never inside the worktree.
  - Each has a numbered "Leave the worktree clean" behavior (`status --porcelain` prints
    nothing), and the report states `Worktree clean: ...`.
  - Each has the Must never item "leave untracked or modified files in the worktree".
- **Example commands.** Every example command in both specs and both agents is now
  `node --test test/calc.test.js` (as `test_one` = `node --test {file}`). The fixer also has
  a fallback example that reads `git status --porcelain`.
- **Greps.**
  - Over the three agents and `skills/reporting/SKILL.md`, `npm test|jest` hits only the
    Must never items (`agents/implementor.md:197`, `agents/fixer.md:175`).
  - A bare `node --test` (not followed by a path) likewise appears only in the Must never
    items (`agents/implementor.md:198`, `agents/fixer.md:175`).
  - No positive example uses any of them.
- **Report templates.** Each agent's report template, filled mechanically, passes
  `parse-report.sh --role <role>` with exit 0.
  - implementor: `done`, `pr: 7`, 1 Out of scope item, 1 bug.
  - fixer: `blocked`, `blocked_by: 41`, 2 resolutions.
  - reviewer: unchanged, still exit 0.
- **Example reports.** The worked example reports now embedded in the two agents also pass:
  - implementor: `node --test test/calc.test.js -> 4`;
  - fixer: `blocked`, `node --test test/calc.test.js -> 9`.
- **Suites and load check.**
  - `test-clean-room.sh`: `passed: 19   failed: 0`.
  - `test-parse-report.sh`: `passed: 94   failed: 0`.
  - `grep -ri <forbidden plugin name>` over the plugin and this directory: no output.
  - Load check: `fleet-board:fixer`, `fleet-board:implementor` and `fleet-board:reviewer`
    load, with `plugin_errors: null`.

**Cost of revision 1:** $1.6549. **Running total, all 13 runs:** $4.8232.

### Revision 2 (2026-09-28, review cycle 1 round B): enforced report rules, I3, I5, D2

**Status: stopped, then resumed and completed (see "Revision 2, resumed" below).** The four briefs were revised and all four specs were re-authored once.
Two of those outputs (`reviewer.md`, `reporting.md`) had a defect and their re-run was cut
off by the API key running out of credit (`Credit balance is too low`, HTTP 400
`billing_error`). A one-turn probe with the pre-flight command confirmed it
(`is_error: true`, cost 0). `--bare` authenticates only through that key, and the plan
forbids a non-bare fallback, so the remaining authoring (the reviewer and reporting specs,
then all four Task 6 authors) waits for the key to be funded. The committed state is
consistent: `specs/implementor.md` and `specs/fixer.md` are the Revision 2 outputs;
`specs/reviewer.md`, `specs/reporting.md`, the three agents and the reporting skill are
still their Revision 1 (or original) author outputs, restored from git (`git checkout --`)
and not edited.

**Brief changes** (all four briefs; the committed `briefs/` are the Revision 2 versions):
- The "Report shape" section is replaced by the current one from `phase_05.md`, verbatim,
  with its Line rules and With `--role` rules.
- A new section "Enforcement: `parse-report.sh` error messages (Revision 2)" lists every
  rejection message `parse-report.sh` can print (taken from the script), states that a
  violating report is rejected and re-dispatched once, and names two parser pitfalls: no
  backtick inside the `VERIFIED:` command, and no `#<digits>` in `## PR` except the real PR
  number.
- A "Revision 2 requirements" section, which wins over everything above it:
  - every brief: the spec's Report section carries all of the above; role agents have no
    `Skill` tool (D2), so each role spec must carry everything needed for a valid report,
    and a role may run `parse-report.sh --role <role>` on its own report before posting;
  - implementor (I3): the blocked-before-any-test-or-PR path (e.g. no `## Acceptance`):
    Status `blocked`, an `[Important]` finding, `## For the card` saying what the card
    needs, `## PR` stating no PR exists with no `#<digits>`, and a `VERIFIED:` line from a
    real command that prints an integer relevant to the block (e.g.
    `gh issue view <n> --json body --jq .body | grep -c '^## Acceptance'` -> 0); two
    templates; Must never invent a PR number, test command or integer;
  - reviewer (I5): "modifying an existing test" includes lines **added** inside an existing
    test's body (`return;`, `t.skip()`, `.skip`/`.only`/`.todo`, `if (false)`, commented
    assertions); in round 2+ each such hunk is `[Critical]`, naming the file and quoting it;
    new test blocks are fine;
  - fixer (I5): never make any such change; Must never spells it out;
  - reporting (D2): the consumer is the Phase 6 manager (check a report with
    `parse-report.sh --role`, quote the rule, re-dispatch once, record a report error on a
    second rejection), with a rule table pairing every rejection message with its rule.
- reviewer and reporting only, added after run r2 (see below): the Revision 1 example-command
  rule (every example is `commands.test_one` with a concrete test path; no `npm test`,
  jest or `--runTestsByPath` example).

Brief sha256 (16): implementor `51828a44184da262` → `bff19e310df3a475`; fixer
`45c61895e416551d` → `e08eb149a09e44bf`; reviewer `af0aaf837b78b9ff` → `4fc2672d8121a069`
(r2) → `72d905443223bc03` (r2b); reporting `b09767a24a6ed107` → `ab40eb686b0a9200` (r2) →
`4665d7933fcc0174` (r2b). Staged copies in `$TMPDIR/fb-p5/inputs/` were `cmp`-identical.

**Runs.** The Task 5 command and prompt files, unchanged (cwd `specs/`, only `--add-dir`
the staging dir, `--max-turns 30`). Each output was deleted before its run. Logs:
`$TMPDIR/fb-p5/spec-<role>.r2.log` and `.r2b.log`. Init evidence:
`evidence/spec-<role>.r2.init.json` and `evidence/spec-{reviewer,reporting}.r2b.init.json`
(checked: no `sk-ant`, no local path, no forbidden name; each passes the jq assertion
above).

| Output | Log | Init sha256 | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/implementor.md` | `spec-implementor.r2.log` | `102587620fafd82d` | PASS | PASS (23 reads, 1 edit: own output) | 25 | 0.7948 | `35b8ad559f260d1f` | **kept** |
| `specs/fixer.md` | `spec-fixer.r2.log` | `452090a85b371cae` | PASS | PASS (23 reads, 1 edit: own output) | 25 | 0.6693 | `144398433c218426` | **kept** |
| `specs/reviewer.md` | `spec-reviewer.r2.log` | `f891ed769bf2fa0f` | PASS | PASS (23 reads) | 26 | 0.7757 | — | discarded: example `VERIFIED:` used `npm test -- --runTestsByPath ...` |
| `specs/reporting.md` | `spec-reporting.r2.log` | `f120b3d6293b1ee5` | PASS | PASS (23 reads) | 25 | 0.7701 | — | discarded: four `npm test -- --runTestsByPath` examples in the rule table |
| `specs/reviewer.md` | `spec-reviewer.r2b.log` | `001e3f2244659dbc` | PASS | PASS (23 reads, 0 edits) | 24 | 0.4544 | — | **failed**: `Credit balance is too low`, no file written |
| `specs/reporting.md` | `spec-reporting.r2b.log` | `f68e6c3725e599be` | PASS | PASS (22 reads, 0 edits) | 23 | 0.2988 | — | **failed**: same |

The r2b logs begin with a CLI warning line (`no stdin data received in 3s`) before the
stream-json; it was stripped before the assertion. Future runs add `< /dev/null`.

**Review of the kept specs** (read, not edited):
- `implementor.md`: a numbered behavior, checked first, for the blocked-before-tests path,
  with every brief point; Template A (`done`) and Template B (blocked, `## PR` `No PR: ...`,
  ``VERIFIED: `gh issue view 7 --json body --jq .body | grep -c '^## Acceptance'` -> 0 ...``);
  the full Report shape with Line rules and With `--role`; the complete rejection-message
  list; the no-`Skill`-tool note; Must never includes inventing a PR number or test
  command and `#<digits>` in `## PR` without a PR.
- `fixer.md`: the I5 rule with every example (`return;`, `t.skip()`/`t.todo()`,
  `.skip`/`.only`/`.todo`, `if (false)`, commented assertions) in behavior and Must never;
  the full shape, rules and message list; the no-`Skill`-tool note.
- Both: no forbidden name, URL or attribution phrase; `npm test`/`node --test` without a
  path appear only in Must never.

**Cost of Revision 2 so far:** $3.7631 (six runs; the two failed runs were billed for the
turns before the credit ran out). **Running total, all 19 runs:** $8.5863.

**To finish Revision 2** (after the key is funded): re-run the reviewer and reporting spec
authors (the r2b briefs are staged and committed), then the four Task 6 authors; the
reporting author prompt changes for D2 (description: used when the fleet-board manager
checks or re-dispatches a role report, e.g. to quote the rule when a report fails
`parse-report.sh`; body: the manager's instructions), and the implementor author prompt
asks for both report templates. Then the template-parse checks, suites, load check and the
live re-runs.

### Revision 2, resumed (2026-09-28, after the key was funded)

Pre-flight (adopted form, `< /dev/null`): `Ok.`, `is_error: false`, $0.0050. Every run below
used `< /dev/null`. Each run's init evidence is in `evidence/` under the log's name; each
passes the jq assertion, with no `sk-ant`, local path or forbidden name.

**Specs.**

| Output | Log | Init sha256 | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/reviewer.md` | `spec-reviewer.r2c.log` | `d00e6ea70eb38273` | PASS | PASS (23 reads, own output) | 25 | 0.7911 | `b059edf2472dad52` | kept; later replaced by r2d |
| `specs/reporting.md` | `spec-reporting.r2c.log` | `4e77c74893b65fd8` | PASS | PASS (23 reads, own output) | 25 | 0.8512 | `d4d280c8341b27db` | **kept** |
| `specs/reviewer.md` | `spec-reviewer.r2d.log` | `18147ae337f2a08c` | PASS | PASS (12 reads, own output) | 15 | 0.6771 | `5bee56405e804a33` | **kept** (see the weak-test fix below) |

r2c review: `npm test`, `jest` and a bare `node --test` appear only in Must never
(`reviewer.md` Must never, `reporting.md` Must never); the full Report shape, Line rules,
With `--role` rules and rejection-message list are present in both; the reviewer spec has the
I5 rule with every example; the reporting spec is written for the manager (inputs, check,
exit 0/1/2 handling, one re-dispatch with the stderr and the rule quoted, a report error on
a second rejection, rule table, Must never).

**Task 6 author prompts (Revision 2).** Saved as `$TMPDIR/fb-p5/prompt-author-<name>.r2.txt`.
Changes from the Task 6 prompts above:
- agents: the body must carry the whole report contract, because the role has no Skill tool.
  The report part is the template(s) in the exact shape from the role spec's Report
  section, followed by its line rules, With `--role` rules, the complete rejection-message
  list and the pitfalls. `reporting.md` is background; the role spec wins. Every example test
  command is `commands.test_one` with one concrete file.
  - implementor: "both report templates the spec gives: the normal report (Status done,
    ## PR with #<number>) and the blocked-before-any-test-or-PR report (Status blocked,
    ## PR stating that no PR exists, a VERIFIED line counting what blocked it)".
  - reviewer: the template with every reviewer section and both skipped forms.
  - fixer: the template with `## PR` and `## Resolutions`, and the blocked form with a
    `Blocked by: #<n>` line.
- reporting skill (D2): the description placeholder now reads "Use when the fleet-board
  manager checks a role report (implementor, reviewer or fixer) with parse-report.sh, quotes
  a report rule to a role, or re-dispatches a role whose report parse-report.sh rejected
  ..."; the prompt states the consumer is the manager, not the role agents; the body is the
  manager's instructions (principle, method, reference with the shape, rules, message list,
  rule table and role points, what not to do). `name: reporting`, `user-invocable: false`,
  no other key.
- `.r2b` variants (fixer, and the reviewer re-author) append: "This session has no Write
  tool by design: create the file with the Edit tool (an empty old_string creates a new
  file), which is the intended way to write it." The first fixer run (`author-fixer.r2.log`)
  tried `Write`, got "No such tool available", and declined to create the file with `Edit`
  on its own ("that would get around a restriction someone set on purpose"); it wrote
  nothing.

| Output | Log | Init sha256 | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `agents/implementor.md` | `author-implementor.r2.log` | `c6b95e1645bf97ef` | PASS | PASS (2 reads) | 4 | 0.3945 | `273d4058ff40fb32` | **kept** |
| `agents/reviewer.md` | `author-reviewer.r2.log` | `483fca1fa404a5c0` | PASS | PASS (2 reads) | 6 | 0.4576 | `7b4776dce1931e06` | replaced by r2b |
| `agents/fixer.md` | `author-fixer.r2.log` | `5c2dc1d06130eda9` | PASS | PASS (2 reads, 0 edits) | 4 | 0.3675 | — | no file (see above) |
| `agents/fixer.md` | `author-fixer.r2b.log` | `a6ee8398e5981f55` | PASS | PASS (2 reads) | 4 | 0.3666 | `1d3618928e9c54bc` | **kept** |
| `skills/reporting/SKILL.md` | `author-reporting.r2.log` | `e0410b45fc0532af` | PASS | PASS (1 read) | 3 | 0.3395 | `16b113a75615f9f9` | **kept** |
| `agents/reviewer.md` | `author-reviewer.r2b.log` | `99a0f8587a2f93ce` | PASS | PASS (2 reads) | 5 | 0.4450 | `ca0f4d0d522bbe88` | **kept** (from spec r2d) |

**Weak-test fix (reviewer, found live).** Live run `review-survivor-20260928-182015` failed
(`passed: 3   failed: 2`). The reviewer followed its r2c spec, which said "a test whose name
matches an item but whose assertions do not check it does not count as a mapping", so it
marked both items `UNMAPPED` and made no mutant (`killed: 0 survived: 0 invalid: 0`): no
survivor, no Critical, against AC3.5. The brief got a final Revision 2 item: a test that
**exercises** an item maps to it even with a weak assertion; the mutation step judges the
assertion; `UNMAPPED` only when no test exercises the item; the old rule must not be
written. Brief sha256 `72d905443223bc03` → `9df0c64c7e6ae084`. Spec re-authored (r2d),
then the reviewer agent (r2b). Both contain the new mapping rule and, in their Must never
lists, "mark an item UNMAPPED because its mapped test's assertion is weak".

**Checks on the final files.**
- Frontmatter: exactly as prompted (implementor sonnet/green, reviewer opus/red, fixer
  sonnet/yellow, tools without Skill; reporting `name`, `description`, `user-invocable:
  false`, no `allowed-tools`). Each agent states it has no Skill tool.
- `npm test`, `jest` and a bare `node --test`: in each agent and the skill, only under
  "What not to do".
- Report templates through `parse-report.sh --role <role>`, all exit 0:
  - implementor: normal template (`done`, `pr: 12`, 1 Out of scope, 1 bug); the
    blocked-before-tests template (`blocked`, `pr: null`, `VERIFIED` `gh issue view 7 --json
    body --jq .body | grep -c '^## Acceptance'` -> 0); the generic shape filled mechanically
    (`done`, `pr: 7`).
  - reviewer (r2b): the template filled (`findings`, 2 map lines, mutation counts, claim
    check); the same with both skipped forms; the two worked examples (`findings` with a
    survivor; `clean` with both toggles off).
  - fixer: the `done` template filled (`pr: 7`, 1 resolution); the blocked template filled
    (`blocked`, `blocked_by: 41`, 3 resolutions); the two worked examples (`done`;
    `blocked`, `blocked_by: 9`).
- `test-clean-room.sh` `passed: 23   failed: 0`; `test-parse-report.sh` `passed: 200
  failed: 0`; `test-plugin-interaction-scan.sh` `passed: 30   failed: 0`;
  `grep -ri <forbidden name> plugins/fleet-board`: no output.
- Load check: `fleet-board:fixer`, `fleet-board:implementor`, `fleet-board:reviewer`;
  `plugin_errors: null`.

**Cost of the resumed runs:** $4.6950 (pre-flight plus 9 runs). **Revision 2 total:**
$8.4581. **Running total, all authoring runs and probes:** $13.2813.

## Phase 6: manager and the tick, run and status skills

Same rules as above: every file listed here as authored was written by an isolated
`claude -p --bare` process; the executing session wrote the briefs and this log, ran the
processes and the checks, and edited none of the outputs.

| File | Authored by |
|---|---|
| `manager.md`, `tick.md`, `run.md`, `status.md` | Phase 6 Task 6 / Task 7 spec authors (below) |
| `briefs/spec-req-{manager,tick,run,status}.md` | the executing session (copied here unchanged; `cmp`-identical to the staged copies) |
| `plugins/fleet-board/agents/manager.md`, `plugins/fleet-board/skills/{tick,run,status}/SKILL.md` | Phase 6 Task 8 authors (below) |

- **Claude Code:** 2.1.284. **Date:** 2026-09-28. **Auth:** the same `apiKeyHelper` settings file.
- **Staging:** `$TMPDIR/fb-p6/inputs/` holds `design.md` (sha256 `91f195dfe9f0b07a`, the same design as Phase 5), `reporting.md` (a copy of `specs/reporting.md`, `d4d280c8341b27db`), and the four briefs. It was each spec run's only `--add-dir`; cwd was this `specs/` directory.
- **Every run** used the adopted form with `< /dev/null`, and the author prompt ends with the Edit-creates-files sentence from Revision 2 (`.r2b`).

### Decision D3 (orchestrator, 2026-09-28): the manager gets the `Skill` tool

The plan's manager frontmatter listed no `Skill` tool, but Phase 5 decision D2 rescoped the
reporting skill to the manager, so without `Skill` it would be unreachable. The manager's
tools are therefore `["Agent", "Skill", "Read", "Write", "Bash", "Grep", "Glob"]`, and the
brief (and so the spec and agent) states three rules: the only skill the manager may invoke is
`fleet-board:reporting`; it never invokes any other skill; it never dispatches any agent
other than `fleet-board:implementor`, `fleet-board:reviewer` and `fleet-board:fixer`.
Recorded in `phase_06.md` Task 8 as well.

### Briefs (Tasks 6 and 7)

- **`spec-req-manager.md`:** the section list; Purpose, Inputs, the D3 tool rules; the facts
  the manager must carry about running commands (repo-root working directory, literal card/PR
  numbers in gated commands and what the gate blocks, `--repo`, a per-tick temp dir,
  `note.sh merge` only, foreground dispatch, `subagent_type` and explicit `model`, the report
  text without tool metadata, per-dispatch token counts); `phase_06.md` Task 6's procedure and
  action table verbatim, each followed by clarifications that match the implemented scripts
  (`worktree.sh review` JSON, `verify-main.sh` output and exit 1, `file-followups.sh` exit
  codes and partial output, `pending_followups` shape and the no-PR case, the `fix` sequence,
  `blocked_findings` shape, blocked-without-`blocked_by`, the tick report's warnings and cost
  rules); the Must never list plus D3 and further prohibitions; the example-command rule; the
  role inputs from the three role specs; the board contract scripts and the header
  documentation of `note.sh`, `tick-plan.sh`, `worktree.sh`, `verify-main.sh`,
  `file-followups.sh`, `estimate-cost.sh` and `needs-human-qa.sh`, verbatim; the phase file's
  "Manager note schema" and "Tick plan" sections, verbatim; the AC ids and excerpt, verbatim.
- **`spec-req-{tick,run,status}.md`:** the section list (Purpose, Trigger with a proposed
  description, Inputs, Required behavior, Must never, Output, Acceptance criteria); shared
  facts (scripts at `<this skill's base directory>/../../scripts/`, `config.sh` exit codes,
  no config means `/fleet-board:init`, frontmatter without `allowed-tools`, the wrapper's
  last-line parse, the example-command rule); the plan's "Descriptions must trigger from plain
  English" block **verbatim**, plus "starts with Use when, names fleet-board, says what it is
  not for (how fleet-board works, its gate hook, config, setup)"; the plan's requirements for
  the skill verbatim, then clarifications (tick: exit 4/5/2, start time, one foreground
  `fleet-board:manager` dispatch with explicit `models.manager`, verbatim printing and no
  invented `dispatchable:` line, one tick only; run: `config.sh limits.tick_interval`, stop
  file, `fleet-board:tick` through the Skill tool, a missing stop signal stops the loop, sleep
  in chunks of at most 540 s with a 600000 ms Bash timeout, the summary and `stopped:` lines;
  status: `status.sh` output and exit codes, when `--all` applies, the `Headless wrapper:`
  line always last, read-only).

### Task 6 and Task 7 runs: specs

Prompt (per spec; `<name>` substituted, paths absolute at run time):

```
You are writing a behavior specification. Read ONLY these files: $TMPDIR/fb-p6/inputs/spec-req-<name>.md (the brief), $TMPDIR/fb-p6/inputs/design.md (the design)[, $TMPDIR/fb-p6/inputs/reporting.md (the reporting spec) — manager only]. Do not read any other file. Write the spec to <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs/<name>.md following the section list in the brief. Specs describe behavior, not prompt wording. Do not quote or mention any third-party plugin. Cite no sources, no URLs, no attributions. This session has no Write tool by design: create the file with the Edit tool (an empty old_string creates a new file), which is the intended way to write it.
```

Command (cwd `specs/`):

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; cd <specs dir>; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir "$TMPDIR/fb-p6/inputs" --output-format stream-json --verbose --max-turns 30 "$(cat "$TMPDIR/fb-p6/prompt-spec-<name>.txt")" < /dev/null > "$TMPDIR/fb-p6/spec-<name>.log" 2>&1
```

Checks per run (a script in the executing session's scratchpad): the per-run isolation
assertion above; the path audit (every `Read` is a staged input or the run's own output,
every `Edit` targets the run's own output, no other tool); the result event; the output's
sha256; and the init evidence written to `evidence/spec-<name>.init.json` (the same seven
fields), grepped for `sk-ant`, `/Users/`, `/var/folders`, `/private/` and the forbidden name
(no match). The checker was shown to fail first: a copy of `spec-tick.log` with `Bash` added
to `tools`, a foreign plugin name, and a wrong allow-list gave `isolation: FAIL`,
`path audit: FAIL` (2 bad reads, 1 bad edit) and exit 1.

| Spec | Brief sha256 | Prompt sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|---|
| `manager.md` | `0821ba756e925c5c` | `17cea3123486aeda` | `80c6543768e3aba9` | PASS | PASS (3 reads, 1 edit) | 5 | 0.7128 | `f6e72ea19cb1f99b` | **kept** |
| `tick.md` | `07eadc77a3370865` | `af94b8b967f04c28` | `80c6543768e3aba9` | PASS | PASS (2 reads, 1 edit) | 4 | 0.2164 | `933b7539aab7f16b` | **kept** |
| `run.md` | `463bdb69fbcc2920` | `4c8e4e4b19780b0e` | `80c6543768e3aba9` | PASS | PASS (2 reads, 2 edits) | 5 | 0.2908 | `a49b636139e4299a` | **kept** |
| `status.md` | `5978e7cd0e9f0d11` | `750927c96ebdf5a7` | `80c6543768e3aba9` | PASS | PASS (2 reads, 3 edits) | 6 | 0.2480 | `1e22229d83680daa` | **kept** |

All four init events were identical apart from `session_id`: built-in plugins `agents-md` and
`telemetry` only, tools `["Edit","Read"]`, built-in agents only, no namespaced skill or
command, `apiKeySource: apiKeyHelper`, 2.1.284. Every `Edit` targeted the run's own output
(the run, status and manager authors edited their file after creating it).

**Review (read against the briefs, not edited).**
- `manager.md`: D3 in T1–T3 and Must never; command facts C1–C8; step 1 to 5 with the
  complete action table and every clarification (2.4–2.18, 3.1–3.9); the role inputs; the
  tick report shape, rules and an example ending `dispatchable: true`; the 15 AC ids with
  their text. `npm test`, jest and a bare `node --test` appear only in Must never. No forbidden
  name, URL or attribution.
- `tick.md`, `run.md`, `status.md`: every plan requirement and clarification; a Trigger
  section whose requirements carry every phrase from the plan's plain-English block and a
  proposed description (tick names "run a tick", "process the board", "work the board once",
  "what's next on the board" and the one-tick default; run names "run the fleet", "work the
  board until done", "keep going", processing until nothing is left; status names where cards
  stand, what the fleet is doing, "board status", "what's in Human QA"); each says it is not
  for questions about how fleet-board works. No `npm`, jest, forbidden name or URL.

**Re-runs: none** (for the specs).

### Task 8 runs: the manager agent and the three skills

Command (cwd `plugins/fleet-board/`; the only `--add-dir` is this `specs/` directory; the
empty `skills/{tick,run,status}/` directories were created beforehand with `mkdir -p`):

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; cd <plugin dir>; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir <worktree>/docs/implementation-plans/2026-09-28-fleet-board/specs --output-format stream-json --verbose --max-turns 30 "$(cat "$TMPDIR/fb-p6/prompt-author-<name>.txt")" < /dev/null > "$TMPDIR/fb-p6/author-<name>.log" 2>&1
```

Manager prompt (paths absolute at run time):

```
Read ONLY <specs>/manager.md and <specs>/reporting.md. Write <plugin>/agents/manager.md: a Claude Code agent file. Frontmatter exactly (replace only the description placeholder with one sentence you write):
---
name: manager
description: <when the fleet-board tick skill dispatches this agent, and what it does>
model: sonnet
color: blue
tools: ["Agent", "Skill", "Read", "Write", "Bash", "Grep", "Glob"]
---
The body is the prompt the manager follows. Organize it as: principle (one paragraph), inputs, method (numbered, every behavior in the manager spec, including the complete action table and every clarification, the report-reconciliation steps and the note upkeep), tick report template (the exact shape from the spec), what not to do (the spec's Must never list). manager.md wins over reporting.md on any conflict; reporting.md is background for checking role reports. Keep every rule about tools: the only skill the manager may invoke is fleet-board:reporting, it never invokes any other skill, and it never dispatches any agent other than fleet-board:implementor, fleet-board:reviewer and fleet-board:fixer. The model value is a fallback; the tick skill passes the configured model at dispatch. Every example test command is a single test file (for example node --test test/calc.test.js); npm test, jest and a bare node --test may appear only in what not to do. Cite no sources, no URLs, no attributions. Do not mention any third-party plugin. Do not read any other file. This session has no Write tool by design: create the file with the Edit tool (an empty old_string creates a new file), which is the intended way to write it.
```

Skill prompt (`<name>` = `tick`, `run`, `status`):

```
Read ONLY <specs>/<name>.md. Write <plugin>/skills/<name>/SKILL.md: a Claude Code skill file. Frontmatter exactly (replace only the description placeholder with text you write):
---
name: <name>
description: <the skill's trigger description, meeting every requirement in the spec's Trigger section; start with "Use when">
user-invocable: true
---
Do not add any other frontmatter key (in particular no allowed-tools). The body is the instructions Claude follows when this skill is invoked. Organize it as: principle (one paragraph), locating the scripts (the plugin's scripts are at <this skill's base directory>/../../scripts/, with the real base directory substituted; never an install path), method (numbered, every behavior in the spec), output (exactly what the spec says to print), what not to do (the spec's Must never list). Every example test command, if any, is a single test file; never npm test or jest. Cite no sources, no URLs, no attributions. Do not mention any third-party plugin. Do not read any other file. This session has no Write tool by design: create the file with the Edit tool (an empty old_string creates a new file), which is the intended way to write it.
```

| Output | Inputs read | Prompt sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|---|
| `agents/manager.md` | `specs/manager.md`, `specs/reporting.md` | `f13a68ba635b4eaa` | `f803724519ac69a5` | PASS | PASS (2 reads, 1 edit) | 4 | 0.4831 | `7bbf1a2b30779b99` | **kept** |
| `skills/tick/SKILL.md` | `specs/tick.md` | `ea505094cd5409e0` | `f803724519ac69a5` | PASS | PASS (1 read, 1 edit) | 3 | 0.1459 | `26c877597ea07fed` | **kept** |
| `skills/run/SKILL.md` | `specs/run.md` | `8abb25ac9e99faf9` | `f803724519ac69a5` | PASS | PASS (1 read, 1 edit) | 3 | 0.1627 | `607506d57700d8b1` | **kept** |
| `skills/status/SKILL.md` | `specs/status.md` | `94db5afdf03a26ba` | `f803724519ac69a5` | PASS | PASS (1 read, 1 edit) | 3 | 0.1470 | `b5a77bf3eef48751` | **kept** |

Init evidence: `evidence/author-{manager,tick,run,status}.init.json` (same checks as above,
no match). The four init digests were identical apart from `session_id`; they differ from
the spec runs' digest only in `cwd` (checked with a key-by-key jq diff of the two init
events: `cwd` is the only differing key), so the plugins, tools, agents, skills and commands
are the same.

**Checks on the final files.**
- Frontmatter parses as YAML. manager: `name`, `description`, `model: sonnet`, `color: blue`,
  `tools: ["Agent", "Skill", "Read", "Write", "Bash", "Grep", "Glob"]` (D3). Skills: exactly
  `name`, `description`, `user-invocable: true`; no `allowed-tools`. Description lengths:
  tick 819, run 843, status 778 characters.
- Each skill locates scripts through `<base directory>/../../scripts/`; no install path.
- `agents/manager.md` carries the D3 rules (method 0.2, 0.3 and What not to do), the whole
  action table and clarifications, reconciliation, note upkeep, the tick report template and
  the Must never list. `npm test`, jest and a bare `node --test` appear only in What not to do
  (line 269); the only other `node --test` is the single-file example on line 26.
- `grep -ri <forbidden name> plugins/fleet-board`: no output. No URL in any of the four files.
- `tests/test-clean-room.sh`: `CLEAN_ROOM_SKILLS` is now `reporting tick run status` (the
  manager is covered by the agents loop). Result `passed: 43   failed: 0` (8 × `spec exists`).
  With `SPECS_DIR` pointed at an empty temp dir it fails: `passed: 35   failed: 8`, including
  `agents/manager.md`, `skills/tick`, `skills/run` and `skills/status` `spec exists`.
- `tests/test-parse-report.sh`: `passed: 205   failed: 0`. `tests/test-plugin-interaction-scan.sh`:
  `passed: 30   failed: 0`.
- Phase 1 runtime load check (`claude -p --plugin-dir plugins/fleet-board --model haiku
  --max-turns 1 "Reply ok."` in an empty temp dir): agents `fleet-board:fixer`,
  `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`; skills and slash
  commands `fleet-board:init`, `fleet-board:run`, `fleet-board:status`, `fleet-board:tick`;
  `plugin_errors: null`.
- Plain-English trigger check (Task 8 Step 4): 15/15 as expected, recorded in
  `rehearsal-notes.md` under "Phase 6 trigger check".

**Re-runs: none.**

### Phase 6 cost

Sum of `total_cost_usd` over the Phase 6 authoring runs (API key): Task 6 and 7 specs
$1.4680; Task 8 authors $0.9387. Total **$2.4067** (8 runs). **Running total, all authoring
runs and probes (Phases 5 and 6):** $15.6880.

Not authoring, reported separately (normal login, `apiKeySource: none`, so these are the
CLI's reported costs, not API-key charges): load check $0.0769; trigger check $2.2206
(15 runs).

### Phase 6 Revision 1 (2026-09-28, Task 9): explicit `run_in_background: false`

**Cause.** In the Task 9 Step 2 run (`$TMPDIR/fb-p6/behavioral/default-20260928-205130`), the
manager's implementor Agent call omitted `run_in_background`. The runtime ran the agent in the
background, and the manager handed back an `INCOMPLETE` tick report with the dispatch
unreconciled. The spec said "foreground only" but not how. The other 15 role dispatches
passed `false` explicitly. The user decided to re-author.

**Brief change** (`briefs/spec-req-manager.md`, the "Waiting for dispatches" fact, one
sentence added): every role Agent call passes `run_in_background: false` explicitly, never
omitted, with the observed cause. Restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). The
other inputs are unchanged (`design.md` `91f195dfe9f0b07a`, `reporting.md`
`d4d280c8341b27db`).

**Budget check before each run.** The running total was $16.11. Estimates: spec $0.80, then
agent $0.50, both under $50.

**Runs.** Same prompts (`prompt-spec-manager.txt` `17cea3123486aeda`,
`prompt-author-manager.txt` `f13a68ba635b4eaa`) and the same adopted command forms as above,
with `< /dev/null`. Each output was deleted before its run. The checker was re-proven to fail
first: a copy of the original `spec-manager.log` with `Bash` added to `tools`, checked
against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` and exit 1. Logs:
`$TMPDIR/fb-p6/spec-manager.r1.log` and `author-manager.r1.log`. Evidence:
`evidence/spec-manager.r1.init.json` and `evidence/author-manager.r1.init.json`. Both pass
the re-check filter above, and a grep for `sk-ant`, home and temp paths, and the forbidden
name found no match.

| Output | Brief sha256 | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `536fc7d0f5716d71` | PASS | PASS (3 reads, 1 edit) | 5 | 0.7363 | `73655a9668f6f77d` | **kept** |
| `agents/manager.md` | (spec above) | PASS | PASS (2 reads, 1 edit) | 4 | 0.5596 | `02cbd496136c4a13` | **kept** |

**Checks.**
- The spec states the rule in 0.12, 3.3 (re-dispatch) and Must never. The agent states it in
  0.12, 3.3 and What not to do.
- The frontmatter is unchanged: `model: sonnet`, `color: blue`, and the D3 tools list.
- `npm test`, jest and a bare `node --test` appear only in What not to do. There is no URL
  and no forbidden name.
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 1 cost:** $1.2959. **Running total, all authoring runs and probes (Phases 5 and
6):** $16.9839.

### Phase 6 Revision 2 (2026-09-28, Task 9): `finish` removes nothing; status names `cleanup-done.sh`

**Cause.** In both round-2 merge-auto attempts, Claude Code's auto-mode classifier denied the manager's `worktree.sh remove` in `finish` as irreversible local destruction, and denied the note write after it. The user decided that the wrapper does the cleanup, using the new `scripts/cleanup-done.sh` (`phase_06.md` Task 5a).

**Brief changes.**
- `spec-req-manager.md`:
  - The `finish` row is now `board-move.sh N done`, then a best-effort `note.sh merge` of `state: done`. A denied or failed write is a warning, not a failure.
  - The `finish` clarification was rewritten to match.
  - Must never gains: never run `worktree.sh remove`, never delete a worktree or directory.
  - The `worktree.sh remove` interface is marked as never called by the manager.
- `spec-req-status.md`: a read-only check for leftover worktrees of done cards. It uses `board-list.sh done`, `config.sh worktrees.dir`, and entries named `<n>-*`. The skill prints the cards and the exact `bash <abs scripts>/cleanup-done.sh` command before the `Headless wrapper:` line, and never runs the command itself.

Both briefs were restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical).

**Runs.** The prompts and command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before each run: the running total plus the estimate had to stay under $50. The same checker (isolation assertion and path audit) ran on every log. Logs: `$TMPDIR/fb-p6/{spec,author}-{manager,status}.r2.log`. Evidence: `evidence/{spec,author}-{manager,status}.r2.init.json`. All four pass the re-check filter with `apiKeySource: apiKeyHelper`, and a grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `e7586b02cb69041a` | PASS | PASS (3 reads, 1 edit) | 5 | 0.6774 | `28625d8597380c9b` | **kept** |
| `agents/manager.md` | (spec above) | PASS | PASS (2 reads, 1 edit) | 4 | 0.5341 | `fdf314f0ce1ebb88` | **kept** |
| `specs/status.md` | `d93115dcb839aacc` | PASS | PASS (2 reads, 2 edits) | 5 | 0.2551 | `59b706e5628b719d` | **kept** |
| `skills/status/SKILL.md` | (spec above) | PASS | PASS (1 read, 1 edit) | 3 | 0.1698 | `328ff52ca83b31c3` | **kept** |

**Checks.**
- `agents/manager.md`: `finish` is two steps (table row and 2.10). The note write is best-effort (4.3). What not to do forbids `worktree.sh remove` and deleting any worktree. `run_in_background: false` is kept (0.11). The frontmatter is unchanged (D3 tools).
- `skills/status/SKILL.md`:
  - Frontmatter is `name`, `description` (796 characters) and `user-invocable` only.
  - The leftover check is method step 5, and the `cleanup-done.sh` command uses the absolute scripts dir.
  - What not to do forbids running it. `Headless wrapper:` is still the last line.
- No URL, forbidden name, `npm test` or jest outside What not to do.
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.
- Status trigger re-check: `What's the fleet-board status?` gave `fleet-board:status` 3 of 3 times (`$TMPDIR/fb-p6/trigger/status-r2-*.jsonl`, normal login).

**Revision 2 cost:** $1.6364. **Running total, all authoring runs and probes (Phases 5 and 6):** $18.6203.


### Phase 6 Revision 3 (2026-09-29, review cycle 1): plan-card branch and worktree; explicit foreground tick dispatch

**Cause.** The Phase 6 code review found two agent-side defects.
- **C1.** The manager's `continue_implementor` and `fix` took the branch and worktree from `note.*`. A card with no note branch (dragged to In Progress by hand, a failed note write after `start`'s board move, or a rejected note) made `worktree.sh create N null null` fail, so the action was skipped, `implementor_attempts` never grew, the plan never reached `block`, and the card stayed dispatchable forever.
- **I3.** The tick skill did not require `run_in_background: false` on its manager dispatch (the same gap Revision 1 closed for role dispatches).

**Brief changes.**
- `spec-req-manager.md`:
  - The `continue_implementor` and `fix` rows and clarifications: the branch and worktree are always the plan card's, merged into the note. `continue_implementor` merges `implementor_attempts + 1` before `worktree.sh create`, so a failed create still counts and the attempt limit ends in `block`. A failed or refused `note.sh merge` means no worktree command and no dispatch, with a warning.
  - `to_human_qa` and the fixer's inputs use the plan card's worktree.
  - Step 1a: `file_pending`'s PR falls back to the plan card's `pr`; the plan emits `file_pending` only when a PR is known (the review cycle 1 `tick-plan.sh` change).
  - The script headers (`note.sh`, `tick-plan.sh`, `worktree.sh`, `verify-main.sh`, `needs-human-qa.sh` changed) and the phase plan's "Manager note schema" and "Tick plan" sections were re-copied verbatim by a script (checked first to reproduce the Revision 2 block from the Revision 2 sources, apart from the one hand annotation on `worktree.sh remove`, which was re-applied).
- `spec-req-tick.md`: the manager dispatch passes `run_in_background: false` explicitly, with the reason.

Both briefs were restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). `design.md` (`91f195dfe9f0b07a`) and `reporting.md` (`d4d280c8341b27db`) are unchanged.

**Runs.** The prompts (`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`, `prompt-spec-tick.txt` `af94b8b967f04c28`, `prompt-author-tick.txt` `ea505094cd5409e0`) and the adopted command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before each run. The checker was re-proven to fail first: a copy of `spec-manager.r2.log` with `Bash` and a foreign plugin injected into the init event, checked against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` (3 bad reads, 1 bad edit) and exit 1. Logs: `$TMPDIR/fb-p6/{spec,author}-{manager,tick}.r3.log`. Evidence: `evidence/{spec,author}-{manager,tick}.r3.init.json`; all four pass the re-check filter with `apiKeySource: apiKeyHelper`, and a grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `563d12f3fa828c3c` | `80c6543768e3aba9` | PASS | PASS (3 reads, 1 edit) | 5 | 0.7722 | `475e8fa3cd510548` | **kept** |
| `agents/manager.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (2 reads, 1 edit) | 4 | 0.6164 | `aa598ff80b9a942d` | **kept** |
| `specs/tick.md` | `3cbbb8d698ee086c` | `80c6543768e3aba9` | PASS | PASS (2 reads, 1 edit) | 4 | 0.2361 | `bf9b41c544258ba3` | **kept** |
| `skills/tick/SKILL.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (1 read, 2 edits) | 4 | 0.1480 | `c0377386b5911b83` | **kept** |

The init digests equal the earlier Phase 6 spec and author digests.

**Checks.**
- `agents/manager.md`, Method section 6 ("Execute the card actions"): item 1 (branch and worktree from the plan card, with the three ways a card lacks a note branch), item 4 (`continue_implementor` counts the attempt first: one merge of `implementor_attempts` (0 when null) + 1, `branch`, `worktree` before `worktree.sh create`), the `fix` sequence (merge, create, then the fixer), and the refused-merge rule. `run_in_background: false` is kept (section 3, item 1, and What not to do). The frontmatter is unchanged: `model: sonnet`, `color: blue`, the D3 tools list.
- `skills/tick/SKILL.md`: method step 8 passes `run_in_background: false` explicitly, with the reason; What not to do forbids leaving it out. Frontmatter is `name`, `description` (832 characters) and `user-invocable: true` only.
- `npm test`, jest and a bare `node --test` appear only in What not to do. No URL, no forbidden name (`grep -ri` over the plugin: no output).
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 3 cost:** $1.7727. **Running total, all API-key charges:** ~$20.82.

### Phase 6 Revision 4 (2026-09-29, review cycle 2): `fix` blocks the card when its worktree cannot be created

**Cause.** The Phase 6 review cycle 2 found that a `fix` whose `worktree.sh create` fails keeps the card dispatchable forever: the fixer is not dispatched, the round does not change, and no counter grows, so the plan gives `fix` again on every tick. It is reachable after `worktrees.dir` changes or the repo moves: `note.sh` reads the old worktree as null, the plan gives the new default path, and `git worktree add` fails because the branch is still checked out at the old path.

**Brief changes** (`spec-req-manager.md` only):
- The `fix` row points at its clarification, and the clarification now makes a failed `worktree.sh create` terminal for the card this tick: no fixer, no round change, no reviewer; `board-move.sh N blocked`; `note.sh merge` with `blocked_findings` = `[{"severity":"Important","text":"worktree setup failed: <first stderr line>"}]` and no `blocking_pr`; a `board-comment.sh` comment explaining it; a tick-report warning `#N: worktree setup failed: <line>`.
- It says the rule applies to `fix` only: `continue_implementor` is bounded by its attempt count, and `start_review`/`review` use a detached `<n>-review` checkout that cannot collide with a branch checked out elsewhere, so a failed `worktree.sh review` stays a warning.
- The script headers (`worktree.sh`, `tick-plan.sh`, `verify-main.sh` changed in this cycle) were re-copied verbatim by a script. The script was first checked to reproduce the Revision 3 block from the Revision 3 sources, apart from the one hand annotation on `worktree.sh remove`, which was re-applied.

The brief was restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). `design.md` (`91f195dfe9f0b07a`) and `reporting.md` (`d4d280c8341b27db`) are unchanged. The tick skill was not re-authored.

**Runs.** The prompts (`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`) and the adopted command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before the runs. The checker was re-proven to fail first: a copy of `spec-manager.r3.log` with `Bash` and a foreign plugin injected into the init event, checked against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` (3 bad reads, 1 bad edit), `output: MISSING` and exit 1. Logs: `$TMPDIR/fb-p6/{spec,author}-manager.r4.log`. Evidence: `evidence/{spec,author}-manager.r4.init.json`; both pass the re-check filter with `apiKeySource: apiKeyHelper`, and the checker's grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `3a098de246dbc315` | `80c6543768e3aba9` | PASS | PASS (3 reads, 1 edit) | 5 | 0.7620 | `e75e68c7b8b1e986` | **kept** |
| `agents/manager.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (2 reads, 1 edit) | 4 | 0.6026 | `12751c68e718ab19` | **kept** |

The init digests equal the earlier Phase 6 spec and author digests.

**Checks.**
- `agents/manager.md` 4.4 ("`fix` blocks the card when its worktree cannot be created"): the five steps (no fixer, round or reviewer; `board-move.sh N blocked`; the `blocked_findings` entry with no `blocking_pr`; the comment; the warning) and the `fix`-only scope. 4.3 (`continue_implementor` counts the attempt first) and 1.12 (`run_in_background: false`) are kept. The frontmatter is unchanged: `model: sonnet`, `color: blue`, the D3 tools list.
- The spec author listed additions not stated in the brief; all but one were already in the Revision 3 spec. The new one, 0.11 "Step order" (a failed step ends the card's action for the tick unless the action says otherwise), is consistent with the brief.
- `npm test`, jest and a bare `node --test` appear only in What not to do (the one other `node --test` is the single-file example in 1.18). No URL, no forbidden name (`grep -ri` over the plugin: no output).
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 4 cost:** $1.3646. **Running total, all API-key charges:** ~$22.18.

### Phase 6 Revision 5 (2026-09-29, review cycle 3): one setup-failure counter for every action

**Cause.** Three review cycles found actions whose failed setup step left the card in place and dispatchable forever: `continue_implementor` (cycle 1), `fix` (cycle 2) and, in cycle 3, `start` and a persistent `worktree.sh review` failure. The orchestrator chose a generic bound instead of another per-action rule. The note gains `setup_failures` and `last_setup_error` (`note.sh`), and `tick-plan.sh` blocks a ready, in_progress or in_review card once `setup_failures >= review.max_rounds`, after `file_pending` and before the table.

**Brief changes** (`spec-req-manager.md` only):
- A new clarification, "Setup failures (every action)": a setup step is `worktree.sh create` (`start`, `continue_implementor`, `fix`) or `worktree.sh review` (`start_review`, `review`, `fix` after the fixer), including a `worktrees.setup` failure they report. On a non-zero exit, `note.sh merge` with `setup_failures` + 1 and `last_setup_error` = the first stderr line, a tick-report warning `#N: setup failed (<k> of <max>): <line>`, and nothing more for the card this tick. After a successful setup step, both are reset when set (folded into the action's next merge when it has one). The manager never blocks a card itself for a setup failure; the plan does.
- It replaces the Revision 4 rule that blocked the card on the first failed `worktree.sh create` in `fix`; `fix` now only counts. The wording that a failed `worktree.sh review` "stays a warning and is retried next tick" was removed: no setup failure is assumed to be transient.
- `block` for a setup failure (reason starting `setup failed `): `blocked_findings` = `[{"severity":"Important","text":"<reason>"}]`, and the same merge resets the counter, so a card a person moves back by hand is not re-blocked on the next tick. `unblock` resets both keys too.
- The script headers (`note.sh`, `tick-plan.sh`, `worktree.sh` changed) and the phase plan's "Manager note schema" and "Tick plan" sections were re-copied verbatim by the same script. It was first run with `--check`: the only differences were this cycle's changes and the one hand annotation on `worktree.sh remove`, which was re-applied.

The brief was restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). `design.md` (`91f195dfe9f0b07a`) and `reporting.md` (`d4d280c8341b27db`) are unchanged. The tick skill was not re-authored.

**Runs.** The prompts (`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`) and the adopted command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before the runs (~$22.18 of $50). The checker was re-proven to fail first: a copy of `spec-manager.r4.log` with `Bash` and a foreign plugin injected into the init event, checked against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` (3 bad reads, 1 bad edit), `output: MISSING` and exit 1. Logs: `$TMPDIR/fb-p6/{spec,author}-manager.r5.log`. Evidence: `evidence/{spec,author}-manager.r5.init.json`; both pass the re-check filter with `apiKeySource: apiKeyHelper`, and the checker's grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `733b8ccd7948a83d` | `80c6543768e3aba9` | PASS | PASS (3 reads, 1 edit) | 5 | 0.7515 | `647d4ec8076657cd` | **kept** |
| `agents/manager.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (2 reads, 1 edit) | 4 | 0.5608 | `9a2cb562cbbed04f` | **kept** |

The init digests equal the earlier Phase 6 spec and author digests.

**Checks.**
- `agents/manager.md` 5.3 and 5.4 (setup steps; counting: merge `setup_failures` + 1 and `last_setup_error`, the warning, nothing more for the card, the plan blocks, reset after success), 5.5 (`block` for a setup failure: `blocked_findings` from the reason, counter reset, no `blocking_pr`, the comment), the `fix` sequence (a failed create is counted; `fix` never blocks the card itself), the `unblock` row (both keys reset), and 2.11 (a failed step stops the card's action, with setup failures counted). No trace of the Revision 4 `worktree setup failed` block. 4.3's `continue_implementor` attempt counting and `run_in_background: false` (2.7, the role list, What not to do) are kept. The frontmatter is unchanged: `model: sonnet`, `color: blue`, the D3 tools list.
- `npm test`, jest and a bare `node --test` appear only in What not to do. Two other `node --test` mentions are single-file: the example `commands.test_one` value `node --test {file}` (new in this revision, a per-file template) and `node --test test/calc.test.js`. No URL, no forbidden name (`grep -ri` over the plugin: no output).
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 5 cost:** $1.3123. **Running total, all API-key charges:** ~$23.49.

### Phase 6 Revision 6 (2026-09-29, review cycle 4): one action-failure counter for every failure

**Cause.** Review cycle 4 found that the Revision 5 bound covered only failed setup steps: an action that fails for any other reason (a role report rejected twice, a failed `gh`, board or script call, a gate block, a refused merge) still left the card dispatchable forever. The user chose one generic counter. `note.sh` renames `setup_failures`/`last_setup_error` to `action_failures`/`last_action_error` (an old note's keys are read under the new names), and `tick-plan.sh` blocks a ready, in_progress or in_review card once `action_failures >= review.max_rounds`, reason `no progress after <n> attempts: <last_action_error>`, after `file_pending` and before the table.

**Brief changes** (`spec-req-manager.md` only):
- "Action failures (every action; review cycles 3 and 4)" replaces "Setup failures". It defines **progress** per action (for example `start`: the card is in `in_progress` and an implementor report was accepted; `review`: an accepted reviewer report recorded as `last_review`; `fix`: an accepted fixer report and `round` + 1; `mark_ready`: the PR is ready; `merge`: the PR merged; `verify_main`: `main_check` recorded; `to_human_qa`, `block`, `unblock`, `finish`: the card moved). At the end of each action, no progress for any reason merges `action_failures` + 1 and a one-line `last_action_error` (for a double rejection, `<role> report rejected twice: <line>`) and warns `#N: <action> made no progress (<k> of <max>): <line>`; progress merges `action_failures: 0`, `last_action_error: null`, folded into the note-upkeep merge. `skip`, `wait` and unlisted actions are not counted. `continue_implementor` keeps `implementor_attempts` too.
- The action-failure `block`, `unblock` and `finish` reset the counter; the action-failure `block` also sets `blocking_pr: null` (reviewer Minor 1).
- `to_human_qa` moves the card to `human_qa` first and posts the "What to check in Human QA" comment only after the move succeeds, and not when the card already has a comment with that heading (reviewer Minor 2).
- The setup-only wording of Revision 5 is gone. Step 3.4 (a report rejected twice) and step 4 (note upkeep) point at the counter.
- The script headers (`note.sh`, `tick-plan.sh` changed) and the phase plan's "Manager note schema" and "Tick plan" sections were re-copied verbatim by the same script. It was first run with `--check`: the only differences were this cycle's changes and the one hand annotation on `worktree.sh remove`, which was re-applied.

The brief was restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). `design.md` (`91f195dfe9f0b07a`) and `reporting.md` (`d4d280c8341b27db`) are unchanged. The tick skill was not re-authored.

**Runs.** The prompts (`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`) and the adopted command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before the runs (~$23.49 of $50). The checker was re-proven to fail first: a copy of `spec-manager.r5.log` with `Bash` and a foreign plugin injected into the init event, checked against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` (3 bad reads, 1 bad edit) and exit 1. One author attempt was stopped by the executing session two reads in, before any edit, because it had been started from `specs/` without the `--add-dir` of the adopted author form; its log has no result event (kept as `author-manager.r6.aborted.log`; cost booked as at most $0.50), and the run below used the adopted form. Logs: `$TMPDIR/fb-p6/{spec,author}-manager.r6.log`. Evidence: `evidence/{spec,author}-manager.r6.init.json`; both pass the re-check filter with `apiKeySource: apiKeyHelper`, and a grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `e4f299a0aaafa295` | `80c6543768e3aba9` | PASS | PASS (3 reads, 1 edit) | 5 | 0.8345 | `1e092f2ddcb59579` | **kept** |
| `agents/manager.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (2 reads, 1 edit) | 4 | 0.6463 | `c8da4c56618e8e7b` | **kept** |

The init digests equal the earlier Phase 6 spec and author digests.

**Checks.**
- `agents/manager.md`: the action table (`block` with the action-failure reset and `blocking_pr: null`; `to_human_qa` moving first and posting the comment once; `unblock` and `finish` resetting both keys), "Action failures (every action)" (progress per action, the rule's five points, the warning form, the `block` comment), the double rejection counted in step 3.4, and the note-upkeep merge carrying the outcome. No trace of `setup_failures`, `last_setup_error` or "setup failed". 4.3's `continue_implementor` attempt counting and `run_in_background: false` (G10, What not to do) are kept. The frontmatter is unchanged: `model: sonnet`, `color: blue`, the D3 tools list.
- `npm test`, jest and a bare `node --test` appear only in What not to do; the one other `node --test` is the single-file example `node --test test/calc.test.js`. No URL, no forbidden name (`grep -ri` over the plugin: no output).
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 6 cost:** $1.4808, plus at most $0.50 for the stopped attempt. **Running total, all API-key charges:** ~$25.47 (booked with the stopped attempt at $0.50).

### Phase 6 Revision 7 (2026-09-29, review cycle 5): bounded block and unblock; `blocking_pr` cleared first

**Cause.** Review cycle 5 found two actions the Revision 6 bound did not end. A `block` whose `board-move.sh N blocked` fails leaves the card in its column, so `action_failures` rises past `review.max_rounds` and the plan gave `block` on every tick; and a `blocked` card was exempt, so an `unblock` that kept failing was retried forever. `tick-plan.sh` now gives `block` for `max <= k < 2*max`, `skip` with the warning `#N: could not be blocked after <k> attempts: <error>; fix the board and move the card by hand` for `k >= 2*max`, and `skip` with the warning `#N: unblock made no progress after <k> attempts: <error>; move the card by hand` for a blocked card with `k >= max`. Minor 1: the action-failure `block` reset the counter and cleared `blocking_pr` in one merge after the move, so a failed merge after a successful move left a stale `blocking_pr`.

**Brief changes** (`spec-req-manager.md` only):
- "Action failures (every action; review cycles 3, 4 and 5)" states the plan's three rules and the resulting bound (at most `2 * max` actions in a row without progress, `max` when blocked; `file_pending` first and not bounded by them), replacing "no action can keep a card dispatchable forever".
- The plan's two new skips are not actions: no board, note or counter write, no comment; the plan warning goes into `Warnings:`.
- The action-failure `block` runs `note.sh merge {"blocking_pr": null}` first, then `board-move.sh N blocked` (a failure is counted), then, only after the move succeeds, the merge with `blocked_findings`, `action_failures: 0` and `last_action_error: null`. The `block` table row says so.
- The script headers (`note.sh`, `tick-plan.sh` changed) and the phase plan's "Manager note schema" and "Tick plan" sections were re-copied verbatim by the same script, first run with `--check`: the only differences were this cycle's changes and the hand annotation on `worktree.sh remove`, which was re-applied.

The brief was restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). `design.md` (`91f195dfe9f0b07a`) and `reporting.md` (`d4d280c8341b27db`) are unchanged. The tick skill was not re-authored.

**Runs.** The prompts (`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`) and the adopted command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before the runs (~$25.47 of $50). The checker was re-proven to fail first: a copy of `spec-manager.r6.log` with `Bash` and a foreign plugin injected into the init event, checked against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` (3 bad reads, 1 bad edit), `output: MISSING` and exit 1. Logs: `$TMPDIR/fb-p6/{spec,author}-manager.r7.log`. Evidence: `evidence/{spec,author}-manager.r7.init.json`; both pass the re-check filter with `apiKeySource: apiKeyHelper`, and the checker's grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `78976e70b4fade67` | `80c6543768e3aba9` | PASS | PASS (4 reads, 3 edits) | 8 | 0.8890 | `6df9b7e7d8a80068` | **kept** |
| `agents/manager.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (2 reads, 2 edits) | 5 | 0.6715 | `7ecf1a195b9009ac` | **kept** |

The init digests equal the earlier Phase 6 spec and author digests.

**Checks.**
- `agents/manager.md`: 2.D states the three plan rules and the bound; 2.D.1 says the two skips are not actions and lists both warnings; 2.D.4 runs the action-failure `block` as `blocking_pr: null` first, then the move (a failure is counted, the counter never reset before the move succeeds), then the reset merge; the `block` row points there. `to_human_qa` (move first, one comment), `unblock` and `finish` resets, and `run_in_background: false` (G10, What not to do) are kept. The frontmatter is unchanged: `model: sonnet`, `color: blue`, the D3 tools list.
- `npm test`, jest and a bare `node --test` appear only in What not to do; the one other `node --test` is the single-file example `node --test test/calc.test.js`. No URL, no forbidden name (`grep -ri` over the plugin: no output).
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 7 cost:** $1.5605. **Running total, all API-key charges:** ~$27.03.

### Phase 6 Revision 8 (2026-09-29, review cycle 6): the skip warnings name the reset command

**Cause.** Review cycle 6 found that the two plan warnings said only "move the card by hand", which does not work: a hand move does not reset `action_failures`, so a card at `2*max` stays skipped in any column, and a blocked card skipped at `max` that a person moves to ready is blocked again. `note.sh` gained `reset-failures <n>` (a merge of `{"action_failures": 0, "last_action_error": null}` with no patch file), and both warnings now end with the exact command: `#N: could not be blocked after <k> attempts: <error>; fix the board, move the card by hand, then run: bash <scripts>/note.sh reset-failures N` and `#N: unblock made no progress after <k> attempts: <error>; move the card by hand, then run: bash <scripts>/note.sh reset-failures N`, with `<scripts>` the absolute scripts dir (single-quoted when it holds a shell character). Minor: the blocked-card bound fired when no unblock was due (no `blocking_pr`, or one not merged), giving a false "unblock made no progress" warning; it now applies only when `blocking_pr` is set and merged.

**Brief changes** (`spec-req-manager.md` only):
- "Action failures (every action; review cycles 3 to 6)": a blocked card whose `unblock` is due gets `skip` at `max`; any other blocked card is a plain `skip` (`blocked`), no warning, whatever its count.
- "The plan's skips for this reason are not actions": quotes both warnings with the reset command; `Warnings:` lists them verbatim; the manager never runs the command itself.
- "Note writes": the manager uses neither `note.sh put` nor `note.sh reset-failures`.
- The script headers (`note.sh`, `tick-plan.sh` changed) and the phase plan's "Manager note schema" and "Tick plan" sections were re-copied verbatim by the same script, first run with `--check`: the only differences were this cycle's changes and the hand annotation on `worktree.sh remove`, which was re-applied.

The brief was restaged to `$TMPDIR/fb-p6/inputs/` (`cmp`-identical). `design.md` (`91f195dfe9f0b07a`) and `reporting.md` (`d4d280c8341b27db`) are unchanged. The tick skill was not re-authored (it passes the manager's report through; the plan warnings reach it inside that report).

**Runs.** The prompts (`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`) and the adopted command forms are the same as above, with `< /dev/null`. Each output was deleted before its run. The budget was checked before the runs (~$27.03 of $50). The checker was re-proven to fail first: a copy of `spec-manager.r7.log` with `Bash` and a foreign plugin injected into the init event, checked against a wrong allow-list, gave `isolation: FAIL`, `path audit: FAIL` (4 bad reads, 3 bad edits), `output: MISSING` and exit 1. Logs: `$TMPDIR/fb-p6/{spec,author}-manager.r8.log`. Evidence: `evidence/{spec,author}-manager.r8.init.json`; both pass the re-check filter with `apiKeySource: apiKeyHelper`, and the checker's grep for `sk-ant`, home and temp paths, and the forbidden name found no match.

| Output | Brief sha256 | Init sha256 (without session_id) | Isolation | Path audit | Turns | Cost (USD) | Output sha256 | Outcome |
|---|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `29808b4d729e5cbd` | `80c6543768e3aba9` | PASS | PASS (4 reads, 1 edit) | 6 | 0.8353 | `662f9f4fba08fa08` | **kept** |
| `agents/manager.md` | (spec above) | `f803724519ac69a5` | PASS | PASS (2 reads, 1 edit) | 4 | 0.6822 | `54c8e3b5b6166724` | **kept** |

The init digests equal the earlier Phase 6 spec and author digests.

**Checks.**
- `agents/manager.md`: 2.C.1 states the plan rules with the narrowed blocked-card rule; 2.C.2 quotes both warnings with the reset command, lists them verbatim under `Warnings:` and says the manager never runs it; 0.11 and What not to do forbid `note.sh put` and `note.sh reset-failures`. The action-failure `block` (`blocking_pr: null` first, then the move, then the reset), `to_human_qa` (move first, one comment), the `unblock` and `finish` resets, and `run_in_background: false` (G10, What not to do) are kept. The frontmatter is unchanged: `model: sonnet`, `color: blue`, the D3 tools list.
- `npm test`, jest and a bare `node --test` appear only in What not to do; the other `node --test` mentions are single-file examples. No URL, no forbidden name (`grep -ri` over the plugin: no output).
- `tests/test-clean-room.sh`: `passed: 43   failed: 0`.

**Revision 8 cost:** $1.5175. **Running total, all API-key charges:** ~$28.55.

## Phase 8 Revision (2026-09-30): per-dispatch report paths

**Status: partly done.** The manager spec and agent were re-authored. The implementor,
reviewer, fixer and reporting specs, and the three role agents and the reporting skill, were
**not** re-authored; see "Not run" below. Their briefs carry the revision, so the briefs are
ahead of those outputs until they are run.

**Cause (found live in Phase 8).** Role agents wrote their report to a temp file made with
`mktemp`, then ran `parse-report.sh` and `board-comment.sh` in later Bash calls. Shell state
does not persist between Bash calls, so an implementor lost the path, guessed it by listing the
system temp directory sorted by time, took another concurrent process's file (a manager note
for a card in a different repo) and posted it on its card. `board-comment.sh` now refuses
manager-note bodies (`bf0466a`), but a role could still post any other foreign file.

**Brief changes.**
- `spec-req-manager.md`, "Revision 9 requirements": for every role dispatch (including the
  re-dispatch after a rejected report) the manager picks
  `<tick dir>/report-<card>-<role>-<attempt>.md` inside the tick's `mktemp -d` directory,
  unique per dispatch, and passes it as `Report file: <absolute path>`. It does not create,
  read or delete that file; it reads the report from the final reply as before, into its own
  check file with a different name. Must never: a dispatch without the line, a shared path, a
  path outside the tick dir.
- `spec-req-{implementor,reviewer,fixer}.md`, "Revision 3 requirements": write the report to
  exactly the `Report file:` path; run `parse-report.sh` and `board-comment.sh` on that literal
  path; never create an own report temp file when one is given; without the line, `mktemp`
  plus write, check and post in ONE Bash call; never list, glob, search or sort a temp
  directory, or read, post or pass to a script a file not written in this dispatch (other than
  the named inputs); a new Must never item for the temp-directory search. Fixer: the one file
  allowed outside the worktree is that report file. Implementor: the blocked-before-tests
  report uses the same rule.
- `spec-req-reporting.md`, "Revision 3 requirements": the reporting spec describes where a
  role's report file lives (its Required behavior 1 says "a temp file"), so the same rule was
  added, plus the manager's side (a new path for the re-dispatch, its own check file, two
  Must never items).

Brief sha256 (16): manager `29808b4d729e5cbd` → `5a86896fc3cbb170`; implementor
`bff19e310df3a475` → `661008db047bd1b9`; reviewer `9df0c64c7e6ae084` → `1abcf98c91882efe`;
fixer `e08eb149a09e44bf` → `33e4e89f133051a2`; reporting `4665d7933fcc0174` →
`7c66f335a4d99e78`.

**Staging.** `$TMPDIR/fb-p6/inputs/` was rebuilt: the manager brief (`cmp`-identical to
`briefs/`), `reporting.md` (a copy of `specs/reporting.md`, `d4d280c8341b27db`, unchanged)
and `design.md`. The working-tree design document has changed since Phase 6 (`5ce8ee35c1d54f0a`,
commits `230f4a0` and `d2d17f7`), so the staged copy was taken from commit `d2e205b`, which has
the recorded `91f195dfe9f0b07a`. The rebuilt prompt files hash to the recorded values:
`prompt-spec-manager.txt` `17cea3123486aeda`, `prompt-author-manager.txt` `f13a68ba635b4eaa`.

**Claude Code 2.1.285.** The CLI updated from 2.1.284. Its built-in plugins are now named
`cc-plugin-agents-md` and `cc-plugin-telemetry` (`path: builtin`, source `...@builtin`). The
literal assertion (names a subset of {`agents-md`, `telemetry`}) gave `isolation: FAIL` on
`spec-manager.r9.log` for that reason alone. The assertion was widened to accept those two
names only when `path` is `builtin` and `source` ends in `@builtin`. With `plugins` and
`claude_code_version` removed, both r9 evidence files are byte-identical (`jq -S`, `cmp`) to
the r8 ones: same tools, agents, skills and slash commands, no namespaced entry. Re-check:

```bash
jq -e '([.plugins[].name] - ["agents-md","telemetry","cc-plugin-agents-md","cc-plugin-telemetry"] | length == 0)
       and all(.plugins[]; .path == "builtin")
       and .tools == ["Edit","Read"]
       and ([.skills[], .slash_commands[]] | all(contains(":") | not))' evidence/<run>.init.json
```

**Runs.** The adopted command form with `< /dev/null` (run from a script file holding exactly
that command); each output was deleted before its run; the budget was checked before each run
($28.55 + $0.90 and $29.39 + $0.70, both under $50). The checker was re-proven to fail first: a
copy of `spec-manager.r9.log` with `Bash` and a foreign plugin injected into the init event,
checked against a wrong allow-list and a missing output, gave `isolation: FAIL`,
`path audit: FAIL` (3 bad reads, 1 bad edit), `output: MISSING` and exit 1. Logs:
`$TMPDIR/fb-p6/{spec,author}-manager.r9.log`. Evidence: `evidence/{spec,author}-manager.r9.init.json`;
both pass the re-check above with `apiKeySource: apiKeyHelper`, and the checker's grep for
`sk-ant`, home and temp paths and the forbidden name found no match.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `spec-manager.r9.log` | `61ab2deff1770a83` | PASS (widened for 2.1.285; literal: FAIL on the plugin names) | PASS (4 reads: brief twice, design, reporting; 1 edit) | 6 | 0.8393 | `7552e7dcab0048ab` |
| `agents/manager.md` | `author-manager.r9.log` | `c5dc9185503e1956` | PASS (same) | PASS (2 reads, 2 edits) | 5 | 0.6681 | `d16ce7b3037e9e09` |

The init digests differ from the Phase 6 ones only through the plugin names and version.

**Not run: the role specs, the reporting spec, and everything authored from them.** Their
Task 5 form stages HMB's `AGENTS.md` and 19 QA notes. Hashing and staging them was denied by
Claude Code's auto-mode classifier (PII data handling), so the documented inputs could not be
rebuilt. Not run: `specs/{implementor,reviewer,fixer,reporting}.md`,
`agents/{implementor,reviewer,fixer}.md`, `skills/reporting/SKILL.md`. Until they are, the
manager passes a `Report file:` line that the role agents do not yet act on: the roles keep
their old `mktemp` behavior.

**Checks.**
- `Report file:` appears in the spec (G13, G15, R1–R3, 3.3, Must never) and the agent (1.13,
  1.15, 2.1–2.3, 6.3, What not to do). `ls -t`, `/var/folders` and `find .*tmp` appear in
  neither.
- The frontmatter is unchanged apart from the description: `model: sonnet`, `color: blue`, the
  D3 tools list.
- `tests/test-clean-room.sh` `passed: 79   failed: 0`; `test-parse-report.sh` `passed: 205
  failed: 0`; `test-tick-plan.sh` `passed: 218   failed: 0`.
- Load check (normal login, `--model haiku --max-turns 1`): agents `fleet-board:fixer`,
  `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`; skills
  `fleet-board:init`, `run`, `status`, `tick`; `plugin_errors: null`.
- **Drift (regression risk).** A read-only comparison against the Revision 8 files found
  dropped rules beyond the report-path change, in both the spec and the agent:
  re-dispatches and the post-fix reviewer no longer counted against `limits.concurrency`; a
  failed `board-cache-clear.sh` no longer a warning; "the manager never picks another action"
  gone; the `<pr>` fallback to `note.pr` gone; the `skip`/`wait` no-note-write exemption gone;
  the Must never on temp files inside the repo or a worktree gone; the `fix` table row no
  longer says `round` + 1 only after an accepted `done` report (its clarification still does).
  The agent also lost its embedded 33-row rejection-message rule table: it now quotes rules
  "from the rule table in the `fleet-board:reporting` skill", which it "may" invoke.
  A re-dispatch's "same inputs plus a new `Report file:` line" does not say to drop the
  attempt-1 line.

**Cost of this revision:** $1.5074. **Running total, all API-key charges:** ~$30.06.

## Phase 8 Revision B (2026-09-30): role reports written, checked and posted in one call (minimal edit)

**Status: done.** The three role specs, the reporting spec, the three role agents and the
reporting skill now say that a role writes its report to a temp file, checks it with
`parse-report.sh` and posts it with `board-comment.sh` in ONE Bash call, and must never list,
glob, search or sort a temp directory or use a file it did not write in this dispatch. The
manager is unchanged.

**Revert of the manager r9.** The Revision 9 manager re-author above drifted: it dropped rules
unrelated to the report path (listed under "Drift" in the previous section). The user decided to
revert it. Commits `4933f1a` and `a635924` restore `specs/manager.md` and `agents/manager.md`
byte-identical to Revision 8 (`435b2e4`); `git diff 435b2e4 HEAD --stat` on both files prints
nothing. The manager brief's Revision 9 section is kept and marked "Withdrawn 2026-09-30". The
`evidence/{spec,author}-manager.r9.init.json` files stay as the record of those runs. The
manager therefore passes no `Report file:` line, so the rule here is role-side only.

**Recorded process deviation (user-approved): in-place edit instead of regeneration.** Every
earlier revision deleted the output and had an isolated author write a fresh file. Here an
isolated `claude -p --bare` process **edited each existing authored file in place**, changing
only what the rule requires. Why:
- full regeneration drifted (the manager r9 run lost unrelated rules), and
- the role and reporting specs' Task 5 form stages HMB's `AGENTS.md` and 19 QA notes, which
  Claude Code's auto-mode classifier refused to stage (PII), so those specs could not be
  regenerated from their documented inputs.

No HMB input was staged or read. The executing session still wrote none of the authored files.

**Brief changes.** In `spec-req-{implementor,reviewer,fixer,reporting}.md` the body of the
"Revision 3 requirements" section (heading kept) was replaced by the one-call rule and the new
Must never item, stating that it supersedes the earlier `Report file:` version. Brief sha256
(16): implementor `661008db047bd1b9` → `b559e8300180074a`; reviewer `1abcf98c91882efe` →
`a347d6f8d3ce5c5c`; fixer `33e4e89f133051a2` → `5df5aca1e1d08b3c`; reporting
`7c66f335a4d99e78` → `6e73973679b939da`; manager `5a86896fc3cbb170` → `4d65bdc6c700075f` (the
withdrawn note only). The briefs were not inputs to these runs.

**Inputs.** One requirement file, `edit-req.md` (sha256 `2d2e1362fdd99024`), written by the
executing session, holding exactly the rule and the instruction "Edit this file in place.
Change only the passages about writing, checking and posting the report file, and add the
Must-never item. Do not rephrase, reorder, or remove anything else." Each run had its own
staging directory `$SCRATCH/revb/inputs-<run>/` as its only `--add-dir`, holding a copy of
`edit-req.md`; for the agent and skill runs it also held a copy of the already-edited spec
(`spec-<name>.md`) so the agent and its spec agree. The file being edited is the run's output,
read and edited in place (cwd `specs/` for the specs, `plugins/fleet-board/` for the agents and
the skill, as in Tasks 5 and 6).

**Prompt** (per run; paths absolute at run time; the bracketed parts only in the agent/skill
runs and the reporting runs respectively):

```
Read ONLY <inputs>/edit-req.md (the requirement), <target> (the file to edit)[ and <inputs>/spec-<name>.md (the already-edited behavior spec this file is written from; make this file agree with it on the report rule)]. Edit <target> in place with the Edit tool, following the requirement exactly: change only the passages about writing, checking and posting the report file, and add the Must-never item to the list of things the role must never do.[ In this file the role side is described where it says what a role does with its report (the temp file); the file's Must never list belongs to the manager, so state the Must-never item where the role side is described.] Keep every other line byte-identical; do not rephrase, reorder, or remove anything else. Do not read any other file. Cite no sources, no URLs, no attributions. Do not mention any third-party plugin.
```

**Command.** The adopted form, from a script file holding exactly it, with `< /dev/null`:

```bash
FB_BARE_SETTINGS=~/.config/fleet-board/bare-settings.json; CLAUDE_CONFIG_DIR="$(mktemp -d)" claude -p --bare --settings "$FB_BARE_SETTINGS" --model opus --tools "Read,Edit" --permission-mode acceptEdits --add-dir "$SCRATCH/revb/inputs-<run>" --output-format stream-json --verbose --max-turns 30 "$(cat "$SCRATCH/revb/prompt-<run>.rb.txt")" < /dev/null > "$SCRATCH/revb/<run>.rb.log" 2>&1
```

**Checker.** The Revision 9 checker, with the isolation assertion widened for 2.1.285's
`cc-plugin-*` built-in names (only with `path: builtin` and a source ending `@builtin`). The
path audit allows reads of the staged inputs and the output, and edits of the output only. It
was re-proven to fail first: a copy of `spec-implementor.rb.log` with `Bash` and a foreign
plugin injected into the init event, checked against a wrong allow-list and a missing output,
gave `isolation: FAIL` (bad plugins, bad tools), `path audit: FAIL (5 bad)`, `output: MISSING`
and exit 1. Claude Code 2.1.285. Budget checked before each run (~$30.06 at the start; each run
$0.11–$0.21).

**Minimality check.** After each run, `git diff` of the output was read hunk by hunk: every hunk
concerns writing, checking or posting the report file, or is the new Must never item. No run
needed a re-run.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/implementor.md` | `spec-implementor.rb.log` | `b7ec68b848bb0513` | PASS (widened) | PASS (2 reads, 3 edits) | 6 | 0.1355 | `b68ace4f28d0519b` |
| `specs/reviewer.md` | `spec-reviewer.rb.log` | `685cd3b81917672d` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1160 | `f29ba9747433c1bb` |
| `specs/fixer.md` | `spec-fixer.rb.log` | `c8156670b8955758` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1131 | `25c80563f57ccb9b` |
| `specs/reporting.md` | `spec-reporting.rb.log` | `0a2d70a55af3bf93` | PASS (widened) | PASS (2 reads, 1 edit) | 4 | 0.1342 | `18060c5f38892b25` |
| `agents/implementor.md` | `author-implementor.rb.log` | `18136806aeb02cb3` | PASS (widened) | PASS (3 reads, 3 edits) | 7 | 0.2097 | `d3231226aa33f543` |
| `agents/reviewer.md` | `author-reviewer.rb.log` | `acdec0a7742f7515` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1968 | `2fd7c5dada10d927` |
| `agents/fixer.md` | `author-fixer.rb.log` | `3a5aeb7341d34a9f` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1802 | `97aed1e25ff335d4` |
| `skills/reporting/SKILL.md` | `author-reporting.rb.log` | `c3327e6b48a70d72` | PASS (widened) | PASS (3 reads, 1 edit) | 5 | 0.2036 | `fcb46733dc7d6522` |

Prompt sha256 (16): spec-implementor `654f81b4e3ce6609`, spec-reviewer `34b7a26c24149f64`,
spec-fixer `12a994fbbbb92ac8`, spec-reporting `4cd30797c7226b2c`, author-implementor
`68e7dbb666d721ca`, author-reviewer `72b114c0ed708a58`, author-fixer `a9a3f760bd365666`,
author-reporting `46d06c10279ed829`.

Evidence: `evidence/{spec,author}-{implementor,reviewer,fixer,reporting}.rb.init.json`. All
eight pass the 2.1.285 re-check filter above with `apiKeySource: apiKeyHelper`; the checker's
grep for `sk-ant`, home and temp paths and the forbidden name found no match.

**Review notes (not defects against the rule, so no re-run).**
- The fixer spec and agent (step 14) allow the report file "at a path it chooses itself or one
  created with `mktemp`", while their unchanged Must never still names "the report temp file
  made with `mktemp`" as the one file outside the worktree. Both forms keep the path in the one
  call; a hand-picked path is not guaranteed unique.
- The reporting spec and skill have no role-side Must never list (theirs is the manager's), so
  the item was added inline as a bold "Must never:" sentence in the item that describes the role.
- The implementor's Method step 1 and its blocked-before-tests report ("the usual route") were
  not edited; they refer to step 11, which now carries the one-call rule.

**Checks.**
- `grep -nE 'ls -t|/var/folders|find .*tmp'` over the three role agents and the reporting skill:
  one hit each, inside the new Must never item (`implementor.md:286`, `reviewer.md:353`,
  `fixer.md:277`, `SKILL.md:19` in its inline "Must never:" sentence).
- Each role agent's report template, filled mechanically, passes `parse-report.sh --role <role>`
  with exit 0: implementor Template A (`done`, `pr: 12`) and Template B (`blocked`, 1 finding);
  reviewer (`findings`, 3 findings); fixer blocked form (`blocked`, `pr: 12`, `blocked_by: 41`).
  The templates were not changed by the edits.
- `tests/test-clean-room.sh` `passed: 79   failed: 0`; `tests/test-parse-report.sh` `passed: 205
  failed: 0`.
- Load check (normal login, `--model haiku --max-turns 1`, `apiKeySource: none`): agents
  `fleet-board:fixer`, `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`;
  skills `fleet-board:init`, `run`, `status`, `tick`; `plugin_errors: null`.
- `git diff 435b2e4 HEAD --stat -- plugins/fleet-board/agents/manager.md
  docs/implementation-plans/2026-09-28-fleet-board/specs/manager.md` prints nothing.
- `grep -ril <forbidden plugin name> plugins/fleet-board specs/evidence`: no output, exit 1.

**Cost of this revision:** $1.2891 (8 runs). **Running total, all API-key charges:** ~$31.35.

## Phase 8 Revision B2 (2026-09-30): fixer report file from `mktemp` only

**Status: done.** User decision on the first Revision B review note: the fixer's report file is
created with `mktemp` only. Behavior 14 in `specs/fixer.md` and step 14 in
`plugins/fleet-board/agents/fixer.md` no longer allow "a path it chooses itself" (a hand-picked
path is not unique, so two concurrent fixers could collide); the file is created with `mktemp`
(so it lands under `$TMPDIR`) and its literal path stays in the same Bash call as the check and
the post. Nothing else changed.

**Brief.** `spec-req-fixer.md` gained a "Revision 3b requirements" section stating this; sha256
(16) `5df5aca1e1d08b3c` → `3a9f862e3a2f407e`. The brief was not an input to the runs.

**Method.** Same as Revision B: an isolated `claude -p --bare` process edited each file in place,
the same command form, the same checker (widened isolation assertion and path audit), Claude Code
2.1.285. The single requirement file `edit-req.md` (sha256 `8824e7c65758a371`) says to change
only item 14 and remove the chosen-path alternative. The agent run also read the already-edited
spec as `spec-fixer.md`. Prompt: as in Revision B, with the instruction narrowed to "change only
item 14 so the report file is created with mktemp only, removing the alternative of a path chosen
by the role". Budget checked before each run (~$31.35 at the start).

**Minimality check.** Each `git diff` is one hunk, one changed line: item 14 loses "either at a
path it chooses itself or one" (spec) / "either at a path you choose yourself or one" (agent).
No re-run was needed.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/fixer.md` | `spec-fixer.rb2.log` | `0c4b988b5ac26164` | PASS (widened) | PASS (2 reads, 1 edit) | 4 | 0.0863 | `23a6befa33ed01cf` |
| `agents/fixer.md` | `author-fixer.rb2.log` | `723d05ad819c207f` | PASS (widened) | PASS (3 reads, 1 edit) | 5 | 0.1506 | `54cece90a5701b8a` |

Prompt sha256 (16): spec-fixer `2e255d3992fea85b`, author-fixer `bc19a7e53e8e82b3`.

Evidence: `evidence/{spec,author}-fixer.rb2.init.json`, both `apiKeySource: apiKeyHelper`; the
checker's grep for `sk-ant`, home and temp paths and the forbidden name found no match.

**Checks.**
- `grep -n "chooses\|choose yourself"` over both fixer files: no output, exit 1.
- The fixer report template, filled mechanically (blocked form), passes `parse-report.sh --role
  fixer` with exit 0 (`blocked`, `pr: 12`, `blocked_by: 41`, 1 finding).
- `tests/test-clean-room.sh`: `passed: 79   failed: 0`.

**Cost of this revision:** $0.2369 (2 runs). **Running total, all API-key charges:** ~$31.59.

## Phase 8 Revision B3 (2026-09-30): implementor, reviewer and reporting report file from `mktemp` only

**Status: done.** User decision, as for the fixer in Revision B2: the implementor, the reviewer
and the reporting spec and skill create the report file with `mktemp` only. After Revision B
they said a role writes its report to "a temp file" and offered `mktemp` only as "an
equivalent form" / "an equally acceptable form"; the implementor and reviewer also placed the
file "for example with `mktemp`". That allows a hand-picked, non-unique name. Now the file is
created with `mktemp` (so it lands under `$TMPDIR`) and its literal path stays in the same Bash
call as the check and the post; the former alternative sentence is the only form. Nothing else
changed: the Must never items, the report templates and the manager's own temp file are
untouched.

**Briefs.** `spec-req-{implementor,reviewer,reporting}.md` each gained a "Revision 3b
requirements" section stating this. Sha256 (16): implementor `b559e8300180074a` →
`20bca44778227ce0`; reviewer `a347d6f8d3ce5c5c` → `e640eac0047c19df`; reporting
`6e73973679b939da` → `6bec88050d2d7760`. The briefs were not inputs to the runs.

**Method.** Same as Revisions B and B2: an isolated `claude -p --bare` process edited each file
in place, the same command form, the same checker (widened isolation assertion and path audit),
Claude Code 2.1.285. One requirement file `edit-req.md` (sha256 `08ae434d6bc75059`) says to
change only the sentences about where or how the role's report file is created, and not to touch
the manager's temp file, the Must never items or the templates. The agent and skill runs also
read the already-edited spec as `spec-<name>.md`. Prompt: as in Revision B, with the instruction
narrowed to "change only the wording about how the role's report file is created, so it is
created with mktemp only and its literal path stays in the same Bash call as the check and the
post, removing every alternative form or path". Budget checked before each run (~$31.59 at the
start).

**Minimality check.** Each `git diff` was read hunk by hunk. Every hunk is report-file creation
wording: implementor behavior/step 1 ("in the system temp directory (for example with
`mktemp`)" → "with `mktemp`, so it lands under `$TMPDIR`") and 11 (the one-call bullet; "An
equivalent form is acceptable" → "This is the only form"); reviewer behavior 9 / step 10 ("for
example to a file created with `mktemp`" → "created with `mktemp`") and behavior 10 / step 11
(the "equally acceptable form" sentence folded into the one-call sentence); reporting spec and
skill item 1 ("a temp file" → "a file it creates with `mktemp`"; "An equivalent form is also
acceptable" → "This is the only form"). No other hunk appeared, so no re-run was needed.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/implementor.md` | `spec-implementor.rb3.log` | `ce7889184fb8fb1c` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1297 | `f7558154d4214b6b` |
| `specs/reviewer.md` | `spec-reviewer.rb3.log` | `a05cb0cc99cf8ea5` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1058 | `2495315a55b9550e` |
| `specs/reporting.md` | `spec-reporting.rb3.log` | `4df4468df4548b70` | PASS (widened) | PASS (2 reads, 1 edit) | 4 | 0.1073 | `d7bcc37d70cb4ee0` |
| `agents/implementor.md` | `author-implementor.rb3.log` | `1af1842d4ca3d516` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1885 | `b365e01d6c4b401a` |
| `agents/reviewer.md` | `author-reviewer.rb3.log` | `f88763d480c8438f` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1896 | `d58029196f30f74e` |
| `skills/reporting/SKILL.md` | `author-reporting.rb3.log` | `56de5a93dca8359e` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1941 | `2d76107d7a993347` |

Prompt sha256 (16): spec-implementor `48fc5ea158a30f03`, spec-reviewer `e8ae5f4e6a3030c3`,
spec-reporting `0a26ea27ebd17632`, author-implementor `500095f77852256e`, author-reviewer
`d2c2b34c23655383`, author-reporting `763a7d6782e65fe7`.

Evidence: `evidence/{spec,author}-{implementor,reviewer,reporting}.rb3.init.json`, all
`apiKeySource: apiKeyHelper`; the checker's grep for `sk-ant`, home and temp paths and the
forbidden name found no match.

**Checks.**
- `grep -nE "equivalent form|equally acceptable|choose"` over the six files: no output, exit 1.
  `grep -nE "for example (with|to a file created with) .mktemp"` over the implementor and
  reviewer spec and agent: no output, exit 1.
- Report templates filled mechanically pass `parse-report.sh --role <role>` with exit 0:
  implementor Template A (`done`, `pr: 12`), Template B (`blocked`, 1 finding); reviewer
  (`findings`, 3 findings). The templates were not changed by the edits.
- `tests/test-clean-room.sh` `passed: 79   failed: 0`; `tests/test-parse-report.sh` `passed: 205
  failed: 0`.
- Load check (normal login, `--model haiku --max-turns 1`, `apiKeySource: none`): agents
  `fleet-board:fixer`, `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`;
  `plugin_errors: null`.

**Cost of this revision:** $0.9150 (6 runs). **Running total, all API-key charges:** ~$32.50.

## Phase 8 Revision C (2026-10-02): report body written with the Write tool; Must-never scoped to temp files

**Status: done.** Fixes two code review findings against Revision B:

- **I1 (reproduced).** Revision B had a role build its report inside a Bash heredoc
  (`f=$(mktemp) && cat > "$f" <<'EOF' ... EOF && parse-report ... && board-comment ...`).
  `hooks/gate.sh` lexes the whole Bash command text, heredoc body included, as commands, so a
  report quoting a gated command (a finding that mentions `gh pr merge`, `gh issue edit` or
  `board-move.sh N <state>`) is blocked with exit 2 and cannot be posted.
- **M4.** The Must-never sentence "Never read, post, or pass to any script a file you did not
  write in this dispatch, other than the inputs the dispatch names" literally forbids normal work
  (reading the worktree's source, running its tests).

The three role specs, the reporting spec, the three role agents and the reporting skill now say:
(a) run `mktemp` in a Bash call and note the absolute path it prints; (b) write the report to
exactly that path with the Write tool, never inside a Bash command (no heredoc, `echo`, `printf`
or `cat`); (c) check and post in ONE Bash call naming that literal path:
`bash <scripts dir>/parse-report.sh --role <role> <path> && bash <scripts dir>/board-comment.sh <card number> <path>`;
(d) if the check fails, fix the file with Edit or Write and repeat (c). The temp-directory
Must-never item is now "never list, glob, search or sort any temp directory (...), and never post
or pass to a board script any file other than the report file created with `mktemp` in this
dispatch". The heredoc example (fixer behavior/step 16) is gone. The three role agents'
frontmatter `tools` already include `Write`; no frontmatter changed. The manager is unchanged.

**Briefs.** `spec-req-{implementor,reviewer,fixer,reporting}.md` each gained a "Revision 3c
requirements" section stating this. Sha256 (16): implementor `20bca44778227ce0` →
`82429d624c438a05`; reviewer `e640eac0047c19df` → `bbd6174295d4d340`; fixer `3a9f862e3a2f407e` →
`47944a130f996ab9`; reporting `6bec88050d2d7760` → `9f971d9765de1200`. The briefs were not inputs
to the runs.

**Method.** As in Revisions B, B2 and B3: an isolated `claude -p --bare` process edited each
file in place, with the same command form. One requirement file `edit-req.md` (sha256
`723e55c02d24e885`) states the procedure (a)–(d), the new Must-never wording, and "do not touch"
the templates, the manager's temp file, the frontmatter and the other Must-never items. The agent
and skill runs also read the already-edited spec as `spec-<name>.md`. Prompt: as in Revision B,
with the instruction narrowed to "change only the passages about creating, writing, checking and
posting the role's report file (the report is written with the Write tool to the path mktemp
printed, then checked and posted in one Bash call naming that literal path; no heredoc), and
replace the temp-directory Must-never item with the scoped wording". Claude Code 2.1.288. Budget
checked before each run (~$32.50 at the start).

**Checker.** The Revision B checker, with the isolation assertion widened again: 2.1.288 adds a
third built-in plugin, `cc-plugin-plugin-authoring`, so the plugin rule no longer lists names and
is only "every plugin has `path: builtin` and a source ending `@builtin`" (the names are printed
per run). Tools exactly `Edit`,`Read`, no namespaced skill or command, no forbidden name,
`apiKeySource: apiKeyHelper`, and the path audit are unchanged. Re-proven to fail first: the
`spec-reviewer.rb3.log` init event with a foreign plugin (`path: /x/foreign`) and `Bash`
injected, checked against a wrong allow-list and a missing output, gave `isolation: FAIL` (bad
plugins, bad tools), `path audit: FAIL (4 bad)`, `output: MISSING`, exit 1; the unmodified log
gave `isolation: PASS`, exit 0.

**Minimality check.** Each `git diff` was read hunk by hunk. Every hunk is either the report-file
procedure (implementor behavior/step 11 and its Enforcement paragraph; reviewer behavior 10 /
step 11; fixer behaviors/steps 14–16; reporting spec items 1–2 and skill item 1) or the
temp-directory Must-never item. No template, frontmatter or other line changed, so no re-run was
needed.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/implementor.md` | `spec-implementor.rc.log` | `edd1c9b5d8b3d52f` | PASS (widened) | PASS (2 reads, 3 edits) | 6 | 0.1542 | `4883204e612fe186` |
| `specs/reviewer.md` | `spec-reviewer.rc.log` | `35cdd0fa90e2b416` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1147 | `fecee5a8140737c3` |
| `specs/fixer.md` | `spec-fixer.rc.log` | `83061cd8caab4ccd` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1125 | `9a3deed8acc0d325` |
| `specs/reporting.md` | `spec-reporting.rc.log` | `e23b0d1a00d2ea8a` | PASS (widened) | PASS (2 reads, 2 edits) | 5 | 0.1286 | `ebbe3d612980b5ef` |
| `agents/implementor.md` | `author-implementor.rc.log` | `bb6fd9a293b511cd` | PASS (widened) | PASS (3 reads, 3 edits) | 7 | 0.1799 | `b13ece13c866749c` |
| `agents/reviewer.md` | `author-reviewer.rc.log` | `7428a1ca724a3003` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1655 | `cf3a9ef93021d984` |
| `agents/fixer.md` | `author-fixer.rc.log` | `119d18deb49e33d4` | PASS (widened) | PASS (3 reads, 2 edits) | 6 | 0.1551 | `d26cfb7f2a00d458` |
| `skills/reporting/SKILL.md` | `author-reporting.rc.log` | `afe83a0df7465cdc` | PASS (widened) | PASS (3 reads, 1 edit) | 5 | 0.1856 | `f580b5c115c568ef` |

Prompt sha256 (16): spec-implementor `3ac6fe0dbd89fa21`, spec-reviewer `e0ee46aea06651d0`,
spec-fixer `76207da2b14de150`, spec-reporting `e2516b3c6be78b5a`, author-implementor
`7eccb18bd88216a4`, author-reviewer `4bb1e1c43d022465`, author-fixer `7462c03b8225fa7b`,
author-reporting `b64cc8e837c1bfca`.

Evidence: `evidence/{spec,author}-{implementor,reviewer,fixer,reporting}.rc.init.json`, all
Claude Code `2.1.288`, `apiKeySource: apiKeyHelper`, plugins `cc-plugin-agents-md`,
`cc-plugin-telemetry`, `cc-plugin-plugin-authoring` (all `builtin`), tools `Edit`,`Read`; the
checker's grep for `sk-ant`, home and temp paths and the forbidden name found no match. Note:
the README's older re-check command (names subset of {`agents-md`,`telemetry`}) does not accept
these files; use the builtin-path rule above.

**Gate proof** (the reviewer's probe directory with a `.fleet-board.yml` naming only
`board.repo`, so `merge.policy` is the default `human`). A report file made with `mktemp` and
written with the Write tool holds `## Findings` and
`- [Important] deploy.sh runs gh pr merge 42 without checks`. `hooks/gate.sh` on a Bash payload
whose command is exactly the step (c) form naming that literal path
(`bash /x/parse-report.sh --role reviewer <path> && bash /x/board-comment.sh 12 <path>`): exit 0,
no stderr. The old heredoc form with the same report text: exit 2,
`fleet-board gate: merge.policy is human; merges happen in the GitHub UI`.

**Checks.**
- Over the eight files: `<<'EOF'`, `cat > "$f"`, `did not write in this dispatch` and
  `whole write, check and post`: no output, exit 1 each. `heredoc` appears only inside the
  sentence forbidding it.
- Report templates filled mechanically pass `parse-report.sh --role <role>` with exit 0:
  implementor Template A (`done`, `pr: 12`) and Template B (`blocked`, 1 finding); reviewer
  (`findings`, 3 findings); fixer blocked form (`blocked`, `pr: 12`, `blocked_by: 41`).
- `tests/test-clean-room.sh` `passed: 79   failed: 0`; `tests/test-parse-report.sh` `passed: 205
  failed: 0`.
- Load check (normal login, `--model haiku --max-turns 1`, `apiKeySource: none`): agents
  `fleet-board:fixer`, `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`;
  `plugin_errors: null`.
- `git diff 435b2e4 HEAD --stat` on the manager spec and agent prints nothing.

**Open observation (not changed here).** In this harness the Write tool refused to write the
empty file `mktemp` had just created ("File has not been read yet. Read it first before writing
to it.") until it was Read once. A role following step (b) may hit the same refusal and recover
by reading the empty file first; the procedure does not say so. **Resolved** in Phase 8 Revision
C2 below: the procedure now says so.

**Cost of this revision:** $1.1961 (8 runs). **Running total, all API-key charges:** ~$33.70.

## Phase 8 Revision D (2026-10-02): manager writes temp files with the Write tool only

**Status: done.** In a live run on the shipped manager (Revision 8), the manager wrote role
reports and other temp files with Bash heredocs (`cat > $T/rev1.md <<'EOF' ...`), although its
rule 0.10 "Temp files" already said to write them with the `Write` tool. `hooks/gate.sh` lexes
the whole Bash command text, heredoc body included, as commands, so a role report or a comment
quoting a card's Acceptance that mentions a gated command (`gh pr merge`, `gh issue edit`,
`board-move.sh N <state>`) would be blocked at the manager's check or post step (code review
finding I1, the manager side; the roles were fixed in Revision C).

Rule 0.10 in `specs/manager.md` and `agents/manager.md` keeps its text and gains three bullets:
the file's content never goes inside a Bash command (no heredoc, `echo`, `printf` or `cat`)
because the gate reads Bash command text; write each file with the `Write` tool and pass only
its path to the script; if the `Write` tool refuses a file that has not been read (for example
one just made by `mktemp`), read it once and write it again. Both Must-never lists gain one item
after "Write temp files inside the repo or inside any worktree": "Put a temp file's content
inside a Bash command (heredoc, `echo`, `printf` or `cat`) instead of writing it with the Write
tool." Nothing else changed; the frontmatter is unchanged.

**Brief.** `spec-req-manager.md` gained a "Revision 9b requirements" section after the withdrawn
Revision 9 note; sha256 (16) `4d65bdc6c700075f` → `0dc297cf4530b5f6`. The brief was not an
input to the runs.

**Method.** As in Revisions B to C, a minimal in-place edit (the Revision 9 full re-author
drifted and was withdrawn): an isolated `claude -p --bare` process edited each file with the same
command form and the Revision C checker (builtin-path isolation rule, tools exactly
`Edit`,`Read`, path audit). One requirement file `edit-req.md` (sha256 `683b2b1fa7643b5d`) states
the rule 0.10 addition, the optional Must-never item and "do not touch" for everything else. The
agent run also read the already-edited spec as `spec-manager.md`. Prompt: as in Revision B, with
the instruction narrowed to "change only rule 0.10 "Temp files" (keep its existing text and add
...), and optionally add the one Must-never item". Claude Code 2.1.288. Budget checked before the
runs (~$33.70 of $50).

**Minimality check.** Each `git diff` has exactly two hunks: the three bullets under 0.10 and the
one Must-never item. Both files `4 ++++`, no deletion. No re-run was needed.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/manager.md` | `spec-manager.rd.log` | `9d9f5bf24fe6f072` | PASS (builtin rule) | PASS (2 reads, 2 edits) | 5 | 0.1373 | `7b2fcd694a3ea960` |
| `agents/manager.md` | `author-manager.rd.log` | `4613e3f1dbadcd96` | PASS (builtin rule) | PASS (3 reads, 2 edits) | 6 | 0.2385 | `5c19cfd7932527f7` |

Prompt sha256 (16): spec-manager `0e3cf0c93a7e27bd`, author-manager `832ed790fdc52304`.

Evidence: `evidence/{spec,author}-manager.rd.init.json`, both Claude Code `2.1.288`,
`apiKeySource: apiKeyHelper`, plugins `cc-plugin-agents-md`, `cc-plugin-telemetry`,
`cc-plugin-plugin-authoring` (all `builtin`), tools `Edit`,`Read`; the checker's grep for
`sk-ant`, home and temp paths and the forbidden name found no match.

**Checks.**
- `git diff --stat b5e1609 HEAD` on the two files: 2 files changed, 8 insertions.
- `agents/manager.md` 0.10 (lines 58–61) names the `Write` tool in the rule text and two new bullets.
- `grep -ril <forbidden plugin name> plugins/fleet-board specs/evidence`: no output, exit 1.
- `tests/test-clean-room.sh` `passed: 79   failed: 0`; `tests/test-tick-plan.sh` `passed: 218
  failed: 0`.
- Load check (normal login, `--model haiku --max-turns 1`, `apiKeySource: none`): agents
  `fleet-board:fixer`, `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`;
  skills `fleet-board:init`, `run`, `status`, `tick`; `plugin_errors: null`.

**Cost of this revision:** $0.3758 (2 runs). **Running total, all API-key charges:** ~$34.08.

## Phase 8 Revision C2 (2026-10-02): roles read once, then write, when the Write tool refuses the mktemp file

**Status: done.** Fixes code review cycle 2, Minor 1. Since Revision C a role runs `mktemp`, then
writes its report to that path with the Write tool. In Claude Code the Write tool refuses an
existing file that has not been read ("File has not been read yet"), and `mktemp` creates the
file, so a role may hit that refusal and fall back to a heredoc (blocked by the gate when the
report quotes a gated command) or to a self-chosen path. The manager got the recovery instruction
in Revision D (`agents/manager.md` rule 0.10); the roles did not. This resolves the Revision C
"Open observation".

The three role specs, the reporting spec, the three role agents and the reporting skill each gain
one sentence, right after the step that writes the report with the Write tool, in the file's own
voice: "If the Write tool refuses the file because it has not been read, read it once with the
Read tool and write it again (still never a heredoc, `echo`, `printf` or `cat`, and never a
different path)." (third person: "it reads it once ... and writes it again"). Where the step is a
bullet (implementor and reviewer, spec and agent) the sentence is a new bullet below it; where it
is inside a numbered item (fixer item 14, reporting spec item 1, reporting skill item 1) it is
inserted after the sentence forbidding a heredoc. Nothing else changed: no template, frontmatter,
Must-never item or Enforcement paragraph.

**Briefs.** `spec-req-{implementor,reviewer,fixer,reporting}.md` each gained a "Revision 3d
requirements" section stating this. Sha256 (16): implementor `82429d624c438a05` →
`5647801c0383a087`; reviewer `bbd6174295d4d340` → `17a5d7aca30c43fe`; fixer `47944a130f996ab9` →
`6b217f36b3e6a11d`; reporting `9f971d9765de1200` → `977c31a84973da3e`. The briefs were not inputs
to the runs.

**Method.** As in Revisions B to D: an isolated `claude -p --bare` process edited each file in
place, with the same command form and the Revision C checker (builtin-path isolation rule, tools
exactly `Edit`,`Read`, no namespaced skill or command, no forbidden name,
`apiKeySource: apiKeyHelper`, path audit). One requirement file `edit-req.md` (sha256
`da82c04fcb72d36d`) states the one sentence in both voices, where it goes (new bullet, or inline
after the heredoc sentence), "once only" (not in the check-and-post step, an Enforcement paragraph
or the Must-never list) and "do not touch" for everything else. The agent and skill runs also
read the already-edited spec as `spec-<name>.md`. Prompt: as in Revision B, with the instruction
narrowed to "add only the one sentence, right after the step that writes the report with the
Write tool". Claude Code 2.1.288. Budget checked before the runs (~$34.08 of $50).

**Minimality check.** Each `git diff` has exactly one hunk. Bullet form (implementor and reviewer
spec and agent): `1 +`, no deletion. Inline form (fixer spec and agent, reporting spec and skill):
one line replaced, and `git diff --word-diff=porcelain` shows only the added sentence. For all
eight files, removing the sentence from the new file reproduces the HEAD file byte for byte. No
re-run was needed.

| Output | Log | Init sha256 (without session_id) | Isolation assert | Path audit | Turns | Cost (USD) | Output sha256 |
|---|---|---|---|---|---|---|---|
| `specs/implementor.md` | `spec-implementor.rc2.log` | `67848a72ccbb8e05` | PASS (builtin rule) | PASS (2 reads, 1 edit) | 4 | 0.0858 | `c5a1c3d903386f26` |
| `specs/reviewer.md` | `spec-reviewer.rc2.log` | `9ef62de9c89b9be2` | PASS (builtin rule) | PASS (2 reads, 1 edit) | 4 | 0.0777 | `f22ceadef2160eba` |
| `specs/fixer.md` | `spec-fixer.rc2.log` | `f8911ebd4a26662b` | PASS (builtin rule) | PASS (2 reads, 1 edit) | 4 | 0.0695 | `bca051f7db0a6903` |
| `specs/reporting.md` | `spec-reporting.rc2.log` | `465cc04816fcb7e5` | PASS (builtin rule) | PASS (2 reads, 1 edit) | 4 | 0.0841 | `87ff29065e52415a` |
| `agents/implementor.md` | `author-implementor.rc2.log` | `d19ee7828a741720` | PASS (builtin rule) | PASS (3 reads, 1 edit) | 5 | 0.1346 | `3244f3a7c89636b9` |
| `agents/reviewer.md` | `author-reviewer.rc2.log` | `1c73ab24c0167f06` | PASS (builtin rule) | PASS (3 reads, 1 edit) | 5 | 0.1369 | `5fca329a826e7e44` |
| `agents/fixer.md` | `author-fixer.rc2.log` | `4a5218bb1679f539` | PASS (builtin rule) | PASS (3 reads, 1 edit) | 5 | 0.1163 | `b7f6d4a41ddec2c3` |
| `skills/reporting/SKILL.md` | `author-reporting.rc2.log` | `4a6e9ece9a681cd7` | PASS (builtin rule) | PASS (3 reads, 1 edit) | 5 | 0.1432 | `2229ebb859f5e64d` |

Prompt sha256 (16): spec-implementor `e2d08feca2853169`, spec-reviewer `d33487144cea8d57`,
spec-fixer `2219b2f60d4435a1`, spec-reporting `e36975cfbf8c0f2a`, author-implementor
`b8b1c95e9f88b226`, author-reviewer `2d834ea682c2ec2a`, author-fixer `fe6e04e6b10812dd`,
author-reporting `a2d29ef164e1509f`.

Evidence: `evidence/{spec,author}-{implementor,reviewer,fixer,reporting}.rc2.init.json`, all
Claude Code `2.1.288`, `apiKeySource: apiKeyHelper`, plugins `cc-plugin-agents-md`,
`cc-plugin-telemetry`, `cc-plugin-plugin-authoring` (all `builtin`), tools `Edit`,`Read`; the
checker's grep for `sk-ant`, home and temp paths and the forbidden name found no match.

**Checks.**
- `grep -c 'has not been read'` on each of the eight files: 1.
- Report templates filled mechanically pass `parse-report.sh --role <role>` with exit 0:
  implementor Template A (`done`, `pr: 12`) and Template B (`blocked`, 1 finding), both
  re-extracted from the edited agent one line lower and byte-identical to the Revision C fills;
  reviewer (`findings`, 3 findings); fixer blocked form (`blocked`, `pr: 12`, `blocked_by: 41`).
- `grep -ril <forbidden plugin name> plugins/fleet-board specs/evidence specs/briefs`: no output,
  exit 1.
- `tests/test-clean-room.sh` `passed: 79   failed: 0`; `tests/test-parse-report.sh` `passed: 205
  failed: 0`.
- Load check (normal login, `--model haiku --max-turns 1`, `apiKeySource: none`): agents
  `fleet-board:fixer`, `fleet-board:implementor`, `fleet-board:manager`, `fleet-board:reviewer`;
  skills `fleet-board:init`, `run`, `status`, `tick`; `plugin_errors: null`.

**Cost of this revision:** $0.8481 (8 runs). **Running total, all API-key charges:** ~$34.93.

### Revision (2026-10-09, issue #3): `models.escalation`

**Cause.** Escalation could only switch implementor and fixer to `models.reviewer`. The new key `models.escalation` names another model (null keeps the reviewer's).

**Spec and brief changes** (hand edits to the text, since `design.md` is not in this repo): `manager.md` item 4.3 and AC6.2, and `briefs/spec-req-manager.md` (Models paragraph and AC6.2), now name the escalation model.

**Runs.** Two isolated `claude -p --bare` runs (`--model opus --tools "Read,Edit"`, fresh empty `CLAUDE_CONFIG_DIR`, `apiKeySource: apiKeyHelper`, no MCP servers, same command form as Task 8, reading only the files named in the prompt).
1. A full re-author of `agents/manager.md` from `specs/manager.md` and `specs/reporting.md` (4 turns, $0.6637). **Discarded**: it reworded about 160 lines unrelated to the change.
2. A minimal edit: the run read `specs/manager.md` and `agents/manager.md` and changed only the sentence in 4.3 (4 turns, $0.2138). **Kept.**

`tests/test-clean-room.sh`: `passed: 79   failed: 0`. **Revision cost:** $0.8775. **Running total, all API-key charges:** ~$35.81.

### Revision (2026-10-09, issue #4): config parsed with `yq`

**Cause.** `config.sh` now converts `.fleet-board.yml` with mikefarah/yq v4 instead of the YAML-subset parser, so exit 4 means invalid YAML or a missing `yq`.

**Spec and brief changes** (hand edits): `tick.md` item 3 and `briefs/spec-req-tick.md` (config exit codes).

**Run.** One isolated `claude -p --bare` run (`--model opus --tools "Read,Edit"`, fresh empty `CLAUDE_CONFIG_DIR`, `apiKeySource: apiKeyHelper`, no MCP servers) read `specs/tick.md` and `skills/tick/SKILL.md` and changed only the phrase after "Exit 4 means" in step 3 (4 turns, $0.0547). **Kept.**

`tests/test-clean-room.sh`: `passed: 79   failed: 0`. **Revision cost:** $0.0547. **Running total, all API-key charges:** ~$35.87.

### Revision 10 (2026-10-10, PR #17): temp file names a subagent may write

**Cause (observed live).** In an HMBWorkout tick, Claude Code's `Write` tool refused the manager's temp files with "Subagents should return findings as text, not write report files". Claude Code refuses any subagent `Write` whose base name matches `^(REPORT|SUMMARY|FINDINGS|ANALYSIS).*\.md$` (case-insensitive). The manager chose its own names inside its `mktemp -d` directory and picked report-style `.md` names. Two fixer reports were never checked or reconciled (no round bump, no reviewer). The failures were not counted either, because counting needs a note-patch file. The next tick would have re-dispatched the same fixers. The role agents were not affected: they already take their report names from `mktemp`.

**Script changes (not clean-room, test-first):** `tick-plan.sh` plans `review` instead of `fix` when the PR head moved past `last_review.sha` (prefix compare), and `note.sh fail <n> <error>` counts a failure with no patch file. A new lint, `tests/test-write-names.sh`, fails when an agent, skill, spec or brief names a file the guard refuses that does not exist in the repo.

**Spec and brief changes** (hand edits):
- `manager.md`: 0.10 (names from `mktemp <temp dir>/fb.XXXXXX`, why, and one retry at a fresh name after a refused write), 0.11 (the `note.sh fail` exception), 2.C.4 item 1 (count with `note.sh fail` when the counting patch file cannot be written), and two Must never items.
- `briefs/spec-req-manager.md`: a "Revision 10 requirements" section, `note.sh fail` in the note.sh interface, and the withdrawn Revision 9 example path renamed from a guard-matching report name to `fb.Xy34Zq`. That section stays withdrawn.
- Brief sha256 (16): `fdb629a26f458447` → `ce442ac3854a95a6`. Spec: `9bf693b6c34a2c64` → `fb360676344f154d`.

**Run.** One isolated in-place edit of `agents/manager.md`, in the Revision b form:
- Settings: `--model opus --tools "Read,Edit" --permission-mode acceptEdits`, fresh empty `CLAUDE_CONFIG_DIR`, `apiKeySource: apiKeyHelper`, no MCP servers, cwd `plugins/fleet-board/`, `< /dev/null`, Claude Code 2.1.296, `claude-opus-5-5`.
- Inputs: the staging dir (its only `--add-dir`) held `edit-req.md` (sha256 `c623062cd9819b00`) and a copy of the edited spec as `spec-manager.md` (`fb360676344f154d`). Prompt sha256 `d5537e8f0cff9c56`.
- Isolation: only built-in `cc-plugin-*@builtin` plugins, tools `Edit` and `Read`.
- Path audit: 3 reads (the two inputs and the target) and 5 edits, all of the target.
- 9 turns, $0.2749. Evidence: `evidence/author-manager.r10.init.json` (sha256 `3d9ef3fe8d63c87c`), with no key and no local path.

**Minimality check.** The diff has 5 hunks, each one a requirement item: the two 0.10 bullets, the 0.11 sentence, the 2.C.4 bullet, and the two Never lines. No unrelated line changed; the frontmatter is unchanged (`model: sonnet`, `color: blue`, the D3 tools). `agents/manager.md` sha256 `e2a04d5581581fb9` → `9c3dcfc1a2418805`. **Kept.**

`tests/test-clean-room.sh`: `passed: 79   failed: 0`. `tests/test-write-names.sh`: `passed: 5   failed: 0`. **Revision cost:** $0.2749. **Running total, all API-key charges:** ~$36.14.
