# Epics and the Architect: Cards Plan (built by the fleet)

> **For agentic workers:** This plan is the input to `/fleet-board:import-plan`. Each task is one card and one pull request. Steps are not given: the implementor works test-first from the card's acceptance.

**Goal:** Rename the chat role to Architect, make its conversations last and belong to epics, and give the board page, the Architect and the owner everything the epic record makes possible: creating cards in the conversation, plan changes, an epics view, sample layouts, attachments, a progress report and an export of the doc at the end.

**Architecture:** The board server (`scripts/board-web.py`) stays the only writer behind the page and writes only through contract scripts: `epic.sh` for epics, `board-create.sh`, `adapters/local/edit.sh` and `premise-settle.sh` for cards. A Claude Architect session hands things back by writing files into one outbox folder per conversation, which the server validates and files after each turn. The session itself never creates, moves or edits a card or an epic.

**Tech Stack:** Python 3 standard library (board server), plain JavaScript and CSS (board page), bash 3.2 + jq (scripts), plain-bash suites with the existing fakes (`fake-claude.sh`, `fake-gh.sh`) and the DOM harness (`tests/supervisor-ui.js`).

**Spec:** `docs/specs/2026-11-18-epics-design.md`. Read it and `plugins/fleet-board/CLAUDE.md` before any task.

**Built first, by hand:** `docs/plans/2026-11-18-epics-core.md`. Its interfaces are named under "From the core" below. Tasks 1 to 4 here need none of them and can be imported at once. Import the rest only after the core plan's last task has merged.

## Global Constraints

- All paths below are relative to `plugins/fleet-board/` unless they start with `docs/specs/`, `docs/plans/`, `plugins/` or `.claude-plugin/`, which are relative to the repository root. The plugin's own docs are `plugins/fleet-board/docs/`.
- One PR per task, test-first: the first commit holds only the failing test. Leave `plugins/fleet-board/.claude-plugin/plugin.json` and the fleet-board entry of the repo's `.claude-plugin/marketplace.json` alone; the merge lane bumps the version.
- Run only the suites the task names, then `bash plugins/fleet-board/tests/test-clean-room.sh`. Never the full suite.
- No file under `agents/` and no `skills/{reporting,status}/SKILL.md` is edited.
- The board server reads card and epic files directly and writes only through scripts. It never runs text that a session, a card, an epic or an outbox file supplies.
- The Architect session never creates, moves or edits a card or an epic. Everything it proposes becomes real only on the owner's click. No session output is ever written to an epic's `intent` except text the owner saw in a form and saved.
- A Claude Architect session may write only inside its conversation's `outbox/` folder. A codex Architect cannot write files; every feature that comes back through the outbox, and attachments, are Claude-only, and the page hides their controls for a codex conversation with the line `Not available with the codex Architect`.
- Every new write route requires the `X-Fleet-Board: 1` header and a local Origin, as POST and PATCH do today.
- HTML in a reply, a design, an intent or a log entry is shown as literal text. Only files under a sample's own route are served as HTML, and only with the sandbox policy Task 14 gives.
- An epic is written `E<id>` wherever a person reads it.
- A card is written `C<n>` in every string these tasks add that a person reads, on the page and in script output. `#<n>` alone, in new copy, always means a pull request. Task 20 changes the references the page and `status` already show; no task rewrites stored comments, role reports, branch names, JSON keys or a clean-room file.
- Bash 3.2, BSD and GNU tools. Python standard library only. No new dependencies, and no script or stylesheet loaded from another host.
- Nothing may assume this repository's test layout. Fixtures use the neutral example project the existing suites use.
- Each task updates the matching lines in `plugins/fleet-board/CLAUDE.md` and, where it changes what a person sees or configures, the README.

## From the core

These exist on `main` once the core plan has merged. Tasks name them under Consumes.

- `epic.sh create --title-file <f> [--intent-file <f>] [--design-file <f>] [--repo <r>]` prints `{"id": <id>}`.
- `epic.sh read <id>` prints `{id, title, state, repo, intent, design_rev, conversation, attention, exported, design, log, children, progress, effective_state}`; `children` are `{number, title, state, pr_url, repo, blocked_by, progress}`; `progress` is one of `waiting`, `ready`, `in_flight`, `blocked`, `done`, `dropped`. Exit 3 when the epic does not exist.
- `epic.sh list [--all]` prints `[{id, title, effective_state, progress, attention}]`.
- `epic.sh set-intent <id> <file>`, `set-state <id> open|closed`, `clear-attention <id> <index>`, `approve-design <id> <file>`.
- The folder `<board.dir>/epics/<id>/` with `epic.json`, `design.md`, `revisions/<rev>.md`, `log.jsonl`.
- Card field `epic`; `board-create.sh --epic <id>`; `adapters/local/edit.sh --epic <id>` (empty clears); `board-read.sh` and `board-list.sh` return `epic`; `import-plan.sh` passes a card's `epic`.
- A `rewrite` proposal with `source: "architect"` and `from: "backlog"|"ready"`; `premise-settle.sh approve` and `reject` return such a card to `from`.
- Gate rule G5: a session cannot run any `epic.sh` verb except `read`, `list`, `pending` and `report`.
- The `Epic` section the driver adds to a child card's role prompts.

## Before any task: re-check the plan against the code

This plan was written against `main` at `7f8ae3b9` on 2026-11-18. Before a card starts, the premise check compares it with the code; when a task below disagrees with `main`, the code wins and the card is rewritten. In particular:

- **#476** adds the proposal routes and buttons to the board page. Task 11 builds on them.
- **Tasks 1 to 3** rename things that every later task names. Later tasks use the new names.
- **`scripts/board-web.py` and `scripts/board-web/static/board.js`** are touched by most tasks, so the scheduler will run them one at a time. That is expected.

Review of 2026-11-25 (on #530), for Task 20: `## Depends on` has three parsers, not one. Besides `fl_split_body` and `parse-report.sh`, `deps.sh parse` (used by tick-plan and lint) and `board-web.py`'s `depends_on` accept only `#n` and `owner/repo#n`. Task 20 must change all four, or a `- C4` bullet gets `blocked_by` with a lint warning and a wrong page view.

## Review Focus

1. **A conversation whose stored provider session is gone** (the provider pruned it, or the owner moved machines). Expected: the turn starts a new session seeded with the stored transcript, the owner sees one line saying so, and nothing is lost. (Task 5.)
2. **An outbox file that is not what its name claims** (a card draft that is not JSON, a sample that is 40 MB, a path with `..`, a symlink out of the folder). Expected: it is dropped, named in the turn, and nothing is filed or served. (Tasks 10 and 14.)
3. **The owner clicks Create twice, or two tabs create the same draft.** Expected: one card. (Task 10.)
4. **A sample that tries to reach the board** (a `fetch` of `/api/board`, a form posting to `/api/cards`, a top-level navigation to `/`). Expected: the browser refuses each under the response's policy, and the server refuses a write whatever the browser does. (Task 14.)
5. **An epic with zero children, or with children in a repository the page cannot link to.** Expected: the list, the epic page and the report render it with no error and no broken link. (Tasks 7 and 13.)

---

## Task 1: The Architect's config keys and persona path

Why: the chat role and the scheduler are both called "the planner". The owner asked for a name that does not collide. This task renames what a config file and the premise check see.

Files:
- `scripts/config-defaults.json`
- `scripts/config.sh`
- `skills/planner/references/persona.md` (moved to `skills/architect/references/persona.md`)
- `scripts/board-web.py`
- `scripts/supervisor/driver.py`
- `tests/test-planner-config.sh`
- `tests/test-planner-persona.sh`
- `tests/test-planner-persona-paths.sh`
- `tests/test-planner-persona-no-card-edits.sh`
- `fixtures/supervisor/driver_cases.py`
- `plugins/fleet-board/docs/config.md`

Interfaces:
- Produces: config keys `architect.{persona, persona_append, provider, model}`, with the defaults and the validation `planner.*` has today.
- Produces: `planner.*` is still read when `architect.*` is absent, key by key, with one warning per run: `fleet-board: warning: planner.<key> is now architect.<key>`. When both are set, `architect.*` wins.
- Produces: the persona at `skills/architect/references/persona.md`. Its first heading is `# Architect persona` and it calls the role the Architect. Its working rules are unchanged except the name.
- Produces: the premise check's prompt label `Card-writing rules` in place of `Planner's working rules`, reading the new path.

Test steps:
- `config.sh` prints `architect.provider` as `claude` and `architect.model`, `architect.persona` and `architect.persona_append` as null by default, and prints no `planner` key.
- A config that sets only `planner.model: opus` yields `architect.model` `opus` and one stderr line `fleet-board: warning: planner.model is now architect.model`.
- A config that sets both `planner.model: opus` and `architect.model: sonnet` yields `architect.model` `sonnet`.
- `architect.provider: gemini` is refused with the message `planner.provider` gets today, naming `architect.provider`.
- The board server's `resolve_persona` returns the text of `skills/architect/references/persona.md` when no persona is configured.
- A configured `architect.persona` file is used in place of the shipped one, and `architect.persona_append` is appended to it.
- No file exists at `skills/planner/references/persona.md`.
- The premise check's prompt holds the heading `## Card-writing rules` followed by the persona's working rules, and does not hold `Planner's working rules`.
- With the persona file deleted from the plugin, the premise check's prompt has no `Card-writing rules` section and the driver records one event naming the missing path.

## Task 2: The Architect in the usage ledger and the supervisor's output

Why: usage is reported under "planner", which now means only the scheduler.

Files:
- `scripts/supervisor/usage.py`
- `scripts/supervisor/cli.py`
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `fixtures/supervisor/usage_cases.py`
- `fixtures/supervisor/web_cases.py`
- `tests/supervisor-ui.js`
- `tests/test-board-web.sh`
- `README.md`

Interfaces:
- Consumes: nothing from Task 1.
- Produces: ledger kind `architect`. `usage.KINDS` accepts `card`, `architect` and `planner`; a `planner` line is read as an `architect` line. No stored line is rewritten.
- Produces: new chat turns are written with `kind: "architect"` and `action: "architect"`; an import preview keeps `action: "import_preview"` with `kind: "architect"`.
- Produces: the key `architect` in place of `planner` in `usage.summary`, in `GET /api/usage`, and in the not-running `GET /api/supervisor` reply.
- Produces: the line `architect:` in `fleet-board supervisor usage`, and the label `Architect:` on the page's token strip.

Test steps:
- A ledger holding one `kind: "planner"` line and one `kind: "architect"` line gives an `architect` total equal to their sum in `usage.summary`.
- `usage.summary` has no `planner` key.
- A ledger line with `kind: "architect"` passes the ledger's validation; a line with `kind: "other"` is rejected as today.
- A finished chat turn appends a line with `kind` `architect` and `action` `architect`.
- A finished import preview appends a line with `kind` `architect` and `action` `import_preview`.
- `GET /api/usage` returns the total under `architect` and has no `planner` key.
- `fleet-board supervisor usage` prints a line starting `architect:` and no line starting `planner:`.
- The token strip shows `Architect: ` followed by the total.
- Card and column totals are unchanged by a ledger that mixes both kinds.

## Task 3: The Architect on the page, in the routes and in the test names

Why: the page, the API and the suites still say Planner.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/index.html`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/board.css`
- `tests/test-board-planner-chat.sh` and the other `tests/test-board-planner-*.sh` suites (renamed to `test-board-architect-*.sh`)
- `tests/test-planner-*.sh` (renamed to `test-architect-*.sh`)
- `tests/fake-claude.sh`
- `README.md`

Interfaces:
- Consumes: `architect.*` config (Task 1); ledger kind `architect` (Task 2).
- Produces: routes `POST /api/architect`, `POST /api/architect/<id>/messages`, `POST /api/architect/<id>/draft`, `GET /api/architect/<id>`, with the behaviour the `/api/planner` routes have today. The `/api/planner` routes are removed.
- Produces: new conversations are stored under `<state dir>/architect/<id>/`. Folders already under `<state dir>/planner/` are left where they are and are not read.
- Produces: `FLEET_BOARD_TEST_ARCHITECT_ID`; `FLEET_BOARD_TEST_PLANNER_ID` is still read when the new one is unset.
- Produces: page copy: the button and panel heading `Architect`, the busy line `Architect is replying`, and `## Architect` as the assistant heading in a drafted plan.

Test steps:
- `POST /api/architect` returns an id and creates `<state dir>/architect/<id>/` with mode 700.
- `POST /api/planner` returns 404.
- `GET /api/architect/<id>` returns `{id, turns, running}` for a conversation with one finished turn.
- With `FLEET_BOARD_TEST_ARCHITECT_ID=abc` the new conversation's id is `abc`; with only `FLEET_BOARD_TEST_PLANNER_ID=abc` set it is also `abc`.
- The page's chat button and the panel heading read `Architect`, and the page holds no visible text `Planner`.
- While a reply is running the panel shows `Architect is replying`.
- A plan drafted from a conversation titles assistant turns `## Architect`.
- The README section on the chat is headed by the word Architect and names the `architect.*` keys.
- No file under `tests/` is named `test-board-planner-*` or `test-planner-*`, and every renamed suite passes.

## Task 4: Chat replies render as markdown

Why: the Architect's replies are shown as raw text, so lists, headings and code are hard to read. Card comments already render markdown.

Files:
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/board.css`
- `tests/supervisor-ui.js`
- `tests/test-board-architect-chat-ui.sh`

Interfaces:
- Consumes: the page's existing `md(text)` function.
- Produces: `renderTurns` renders an assistant turn through `md()` inside an element with the classes `pl-turn md`; a user turn stays plain text.

Test steps:
- An assistant turn `**bold** and a list:\n- one\n- two` renders a `strong` element and a list with two items.
- An assistant turn holding a fenced code block renders a `pre` element with the code as its text.
- An assistant turn holding `<img src=x onerror=alert(1)>` renders that text literally and creates no `img` element.
- A user turn `**not bold**` renders the asterisks as text and no `strong` element.
- An assistant turn whose text starts with `[error]` renders as plain text with the error class it has today.
- A link in an assistant turn opens in a new tab with `rel` `noopener`.

## Task 5: Conversations last and are listed

Why: a conversation is lost when the chat closes, so the owner cannot return to the discussion that shaped a change.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `scripts/board-web/static/board.css`
- `tests/test-board-architect-conversations.sh`
- `tests/supervisor-ui.js`

Interfaces:
- Consumes: the `/api/architect` routes and store (Task 3).
- Produces: `meta.json` gains `title` (the first 60 characters of the first user turn, on one line), `created_at`, `updated_at` and `epic` (an id or null).
- Produces: `GET /api/architect` returns `[{id, title, updated_at, epic, running}]`, newest first, for conversations under `<state dir>/architect/` and, once Task 6 exists, under epics.
- Produces: `POST /api/architect/<id>/delete` removes a conversation that has no epic; 409 `conversation belongs to E<id>` for one that has.
- Produces: `resume_or_seed`: a turn resumes the stored provider session. When the provider reports that session unknown, the server starts a new session whose prompt begins with the stored transcript under the line `Earlier in this conversation:`, stores the new session id, and adds the system line `The earlier session could not be resumed; continuing from the saved transcript.` to the conversation.
- The page no longer warns that closing the chat loses the conversation.

Test steps:
- After one turn `meta.json` holds a `title` equal to the first 60 characters of the user's message with newlines turned into spaces.
- `GET /api/architect` lists two conversations newest first, each with `id`, `title`, `updated_at`, `epic` and `running`.
- Reopening a listed conversation shows its earlier turns and a new message continues it.
- `POST /api/architect/<id>/delete` removes the conversation's folder and it leaves the list.
- Deleting a conversation whose `meta.json` names epic 1 returns 409 with `conversation belongs to E1` and removes nothing.
- When the fake provider answers a resume with "no such session", the next turn's prompt starts with `Earlier in this conversation:` followed by the stored turns, and `meta.json` holds the new session id.
- That turn adds the line `The earlier session could not be resumed; continuing from the saved transcript.` to the conversation exactly once.
- Closing the chat panel with a conversation open shows no warning that it will be lost.
- A `delete` request without the `X-Fleet-Board` header is refused.

## Task 6: Draft cards creates an epic and attaches the conversation

Why: nothing links the cards a conversation produced back to it, and a multi-card change has no record.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `skills/import-plan/SKILL.md`
- `scripts/import-plan.sh`
- `tests/test-board-import-epic.sh`
- `tests/test-import-plan.sh`

Interfaces:
- Consumes: `epic.sh create`, `epic.sh read`, card field `epic`, `import-plan.sh` passing `epic` (core); conversations with `meta.json` (Task 5).
- Produces: the import's `meta.json` gains `conversation` (an id or null).
- Produces: `cards.json` may carry a top-level `epic` object `{title, intent, design}`, drafted by the import session when the file holds two or more cards. `skills/import-plan/SKILL.md` gains the step that writes it from the spec or the conversation, in `--preview` mode only (the board page runs the skill with `--preview`; drafting is not creating). A cards file with one card has none. Only the board server creates the epic from it; neither the skill nor `import-plan.sh` runs `epic.sh create`.
- Produces: `skills/import-plan/SKILL.md` gains `--epic <id>`, which puts that existing id on every card; the skill never creates an epic (G5 blocks it in a session) and, when the owner wants a new one, tells them to make it on the board page or in a terminal and rerun with its id.
- Produces: `PATCH /api/import/<id>/epic` with `{title?, intent?, design?, enabled?}` edits the proposed epic; `enabled: false` makes the import create plain cards.
- Produces: `POST /api/import/<id>/create`, when the epic is enabled: runs `epic.sh create`, gives every card that id, creates the cards, writes the conversation's id into `epic.json` as `conversation`, moves the conversation's folder to `<board.dir>/epics/<id>/conversation/`, and sets `epic` in its `meta.json`. The reply gains `epic: <id>`.
- Produces: an import started from an existing epic's conversation creates its cards in that epic and proposes no new one.
- If creating the cards fails after the epic was made, the epic is left with no children and the reply names it, so the owner can retry or close it.

Test steps:
- An import whose cards file holds two cards returns a preview with an `epic` object holding a non-empty `title`, `intent` and `design`.
- An import whose cards file holds one card returns a preview with `epic` null.
- `PATCH /api/import/<id>/epic` with a new `intent` changes the intent shown by `GET /api/import/<id>`.
- Creating an import of two cards with the epic enabled makes one epic whose `intent` is the edited text and two cards whose `epic` is its id.
- The created epic's `conversation` is the id of the conversation the draft came from.
- After the create, the conversation's folder is at `<board.dir>/epics/<id>/conversation/` and no longer under the server's state directory.
- `GET /api/architect/<id>` still returns that conversation's turns after the move.
- Creating with `enabled: false` makes two cards with no `epic` and no epic folder.
- An import started with the import form (no conversation) and two cards creates an epic whose `conversation` is null.
- An import drafted from the conversation of epic 1 creates its cards with `epic` 1 and makes no second epic.
- When creating the cards fails after the server's `epic.sh create` succeeded, the reply is an error that names `E<id>` and the epic exists with no children.
- `/fleet-board:import-plan --epic 1` creates its cards with `epic` 1; `--epic 9` with no E9 stops before anything is created; the skill text names no `epic.sh create` step.

## Task 7: The epics list and the epic page

Why: the owner needs one place that shows every card of a change with its pull request, order and state, and the design as it stands.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/index.html`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/board.css`
- `tests/test-board-epics-page.sh`
- `tests/supervisor-ui.js`
- `README.md`

Interfaces:
- Consumes: `epic.sh list|read|create|set-intent|set-state|clear-attention` (core); `stacked_on` from the server's card summary.
- Produces: page routes `/epics` and `/epics/<id>`, served by `index.html` like `/cards/<n>`.
- Produces: `GET /api/epics[?all=1]` returns `epic.sh list` rows. `GET /api/epics/<id>` returns `epic.sh read` with each child's `url`, `pr_url` and `stacked_on` added; 404 `no such epic: E<id>`.
- Produces: `POST /api/epics` `{title, intent}` (creates an empty epic), `PATCH /api/epics/<id>` `{intent?, state?}`, `POST /api/epics/<id>/attention/<index>/clear`.
- Produces: `GET /api/epics/<id>/revisions/<rev>` returns that revision's text as plain text; 404 when there is none.
- The list shows each open epic's title, a bar split by progress state with a count for each, and a flag when `attention` is not empty; complete and closed epics appear behind a toggle. A New epic control opens a form with a title and an intent.
- The epic page shows, in order: the title and effective state; the intent with an Edit control; the design rendered as markdown with `revision <n>` and a menu of earlier revisions; the children as a table (number, title, state, progress, pull request link, depends on, stacked on); the as-built log, newest first, each entry with its card, what was built, its decisions and departures, and a mark on `unrecorded` and `skipped` entries; the attention entries, each with a Clear button.
- An epic with no children shows `No cards yet` in place of the table and an empty bar.
- The owner should see a sample layout of both views before this card is built; the card's Why names where it is kept.

Test steps:
- `GET /api/epics` returns one row per open epic with `id`, `title`, `effective_state`, `progress` and `attention`.
- `GET /api/epics?all=1` also returns a closed epic.
- `GET /api/epics/1` returns the intent, the design, the log and the children, each child with `url` and `stacked_on`.
- `GET /api/epics/9` returns 404 with `no such epic: E9`.
- `POST /api/epics` with a title and an intent creates an epic with no children and returns its id.
- `PATCH /api/epics/1` with a new intent changes `intent` in `epic.json` and leaves `design.md` byte for byte.
- `PATCH /api/epics/1` with `state` `closed` removes the epic from the default list.
- `POST /api/epics/1/attention/0/clear` removes the first attention entry.
- `GET /api/epics/1/revisions/1` returns the text of `revisions/1.md` as plain text, and revision 7 returns 404.
- The list renders a bar whose segments match the epic's progress counts.
- The epic page renders the design through `md()` and shows `revision 2` for an epic at revision 2.
- The children table links each child to `/cards/<n>` and shows its pull request link when it has one.
- A child whose `repo` differs from `board.repo` links to that repository's pull request.
- An `unrecorded` log entry is shown with the text `not recorded`.
- An epic with no children renders `No cards yet` and raises no script error.
- Each new write route is refused without the `X-Fleet-Board` header.

## Task 8: Cards show and set their epic

Why: on the board, a card gives no sign that it is part of a larger change, and existing cards cannot be gathered into an epic.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `scripts/board-web/static/board.css`
- `tests/test-board-card-epic.sh`
- `tests/supervisor-ui.js`

Interfaces:
- Consumes: card field `epic`, `adapters/local/edit.sh --epic` (core); `GET /api/epics` (Task 7).
- Produces: the card summary and detail from the server carry `epic` as `{id, title}` or null. A card naming an epic that cannot be read carries `{id, title: null}`.
- Produces: `PATCH /api/cards/<n>` accepts `epic` (an id, or null to clear), passed to `edit.sh --epic`.
- Produces: the create-card form accepts `epic`.
- The tile shows `E<id>` as a chip; the drawer shows `E<id> <title>` linking to `/epics/<id>` and a picker listing open epics plus `None`.
- The board has an epic filter: `/?epic=<id>` shows only that epic's cards, and the epic page's children table links to it.

Test steps:
- `GET /api/board` gives a card with `epic` 1 the value `{id: 1, title: <the epic's title>}`.
- A card with no epic has `epic` null in the summary and the detail.
- A card whose epic folder is missing has `epic` `{id: 9, title: null}` and the tile shows `E9`.
- `PATCH /api/cards/<n>` with `epic` 1 sets the card's `epic` to 1.
- `PATCH /api/cards/<n>` with `epic` null removes the card's `epic` key.
- `PATCH /api/cards/<n>` with `epic` 9 returns an error holding `epic E9 does not exist` and changes nothing.
- Changing a card's epic from the drawer leaves its `premise` stamp unchanged.
- The drawer shows `E1` with the epic's title as a link to `/epics/1`.
- Creating a card from the form with an epic chosen sets its `epic`.
- Loading `/?epic=1` renders only cards whose epic is 1, in their columns.

## Task 9: An epic's conversation knows the epic and the other epics

Why: to discuss a change to the plan, the Architect needs what was actually built and where this change sits among the others.

Files:
- `scripts/board-web.py`
- `skills/architect/references/persona.md`
- `tests/test-board-architect-epic-context.sh`
- `tests/test-architect-persona.sh`

Interfaces:
- Consumes: `epic.sh read|list` (core); a conversation's `epic` in `meta.json` (Tasks 5 and 6).
- Produces: `epic_context(id)` in `board-web.py`. For a conversation with an epic, each turn's prompt holds, after the board context, a block `Epic context (JSON):` with:
  - `epic`: `{id, title, intent, design, design_rev, log}`;
  - `children`: each with `number`, `title`, `state`, `progress`, `pr`, `scope` (the card's Scope text), `acceptance`, `depends_on`, `stacked_on` and `proposal` (its kind, or null);
  - `other_epics`: for every other open epic, `{id, title, intent_summary, open_scope_paths, depends}`, where `intent_summary` is the first paragraph of its intent, `open_scope_paths` the Scope paths of its children not in `done` or `wont_do`, and `depends` the pairs `{child, on}` where a child of one epic has the other's card in `blocked_by`.
- Produces: `POST /api/epics/<id>/conversation` opens the epic's conversation, creating one (with `epic` set, stored under the epic) when `epic.json` has none.
- Produces: a persona section `## Working in an epic` telling the Architect to treat the as-built log as fact over the design where they differ, to say which cards a proposed change touches by number, and to say when a change collides with or waits on another epic.
- A conversation with no epic gets no such block.

Test steps:
- A turn in the conversation of epic 1 has a prompt holding `Epic context (JSON):` followed by JSON whose `epic.intent` and `epic.design` equal the stored ones.
- That JSON's `epic.log` holds one entry per line of `log.jsonl`.
- Each child in the JSON carries its Scope text, its acceptance items and its `progress`.
- A child holding a rewrite proposal has `proposal` `rewrite`.
- With a second open epic, `other_epics` has one entry with that epic's `id`, `title` and the first paragraph of its intent.
- `other_epics[].open_scope_paths` leaves out the paths of a child that is in `done`.
- A child of epic 2 blocked by a card of epic 1 appears in `depends` as `{child: <n>, on: <m>}`.
- A closed epic does not appear in `other_epics`.
- A turn in a conversation with no epic has no `Epic context` block.
- `POST /api/epics/1/conversation` for an epic with no conversation creates one under `<board.dir>/epics/1/conversation/` and records its id in `epic.json`.
- A second `POST /api/epics/1/conversation` returns the same id.
- The shipped persona holds the heading `## Working in an epic`.

## Task 10: The outbox, and creating cards in the conversation

Why: the owner should be able to create a card in an epic from inside the conversation, without running the whole conversation through the import.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `scripts/board-web/static/board.css`
- `skills/architect/references/persona.md`
- `tests/test-board-architect-outbox.sh`
- `tests/test-board-architect-card-drafts.sh`
- `tests/test-architect-persona-no-card-edits.sh`
- `tests/supervisor-ui.js`
- `README.md`

Interfaces:
- Consumes: conversations (Task 5); the epic of a conversation (Task 6); `board-create.sh --epic`, `card-lint.sh --body-file`, `fb_card_has_scope_paths` (existing and core).
- Produces: `<conversation dir>/outbox/`, made by the server before each Claude turn. The Claude argv gains `Write` in `--tools` and the allow rules `Write(//<outbox>/**)` and `Edit(//<outbox>/**)`, the pattern the import preview uses for its own folder. Nothing else becomes writable. A codex conversation gets no outbox.
- Produces: `collect_outbox(conversation)`, run when a turn ends. It takes regular files directly inside the outbox (no subfolder, no symlink, a name matching `^[a-z0-9][a-z0-9._-]*$`, at most 2 MiB each and 20 files a turn), hands each to the handler for its name, and empties the folder. A file no handler takes, or one a handler rejects, is dropped and listed in the turn's `dropped` as `{name, reason}`.
- Produces: the handler for `card-*.json`: `{title, why, scope: [<string>], acceptance: [<string>], depends_on: [<int>], labels: [<string>]}`. An accepted file becomes a draft `{draft_id, ...fields, created: null}` stored in the conversation's `drafts.json`, and the turn gains `drafts: [<draft_id>]`.
- Produces: `GET /api/architect/<id>` returns each turn's `drafts` (the full objects) and `dropped`.
- Produces: `PATCH /api/architect/<id>/drafts/<draft_id>` edits a draft that is not yet created.
- Produces: `POST /api/architect/<id>/drafts/<draft_id>/create` `{state: "backlog"|"ready"}`: builds the body as the import does (`## Why`, `## Scope`), runs the card linter and the Scope path check, then `board-create.sh` with the acceptance, the dependencies, the labels and the conversation's epic when it has one. It stores the new number in the draft's `created`, and appends the system line `Created C<n>: <title>` to the conversation, which the next turn's prompt includes. A second create of the same draft returns the first number and creates nothing.
- Produces: `POST /api/architect/<id>/drafts/create-all` `{state}` creates every draft of the conversation not yet created, in the order given, and stops at the first failure, reporting what it created.
- The offer to make an epic after a second card is Task 19.
- Produces: persona text. The rule `You never create, move or edit cards` stays. It gains: when the owner asks for a card, or a change needs one, write one `card-<slug>.json` per card to the outbox in the shape above and say in the reply what it is for; the owner creates it.
- The chat shows a draft as a card preview with each field editable in place, a Backlog or Ready choice, and a Create button; a turn with several shows a Create all. A created draft shows `C<n>` as a link and no button.

Test steps:
- A Claude turn's argv holds `Write` in `--tools` and allow rules for the conversation's outbox only.
- A codex turn's argv is unchanged and no outbox folder is made.
- A valid `card-a.json` in the outbox after a turn appears in that turn's `drafts` with a `draft_id` and `created` null, and the outbox is empty afterwards.
- An outbox file that is not valid JSON is dropped with the reason `not valid JSON` and appears in `dropped`.
- A `card-a.json` whose `scope` names no repository path is dropped with the reason `Scope names no repository path`.
- A `card-a.json` with an empty `acceptance` is dropped with the reason `acceptance is empty`.
- A file named `notes.txt` is dropped with the reason `not a kind the board accepts`.
- A symlink in the outbox pointing outside it is dropped and the file it points to is not read.
- A file in a subfolder of the outbox is dropped.
- A 3 MiB file is dropped with the reason `larger than 2 MiB`.
- `PATCH` on a draft changes its `title`, and the next `GET` returns the new title.
- `PATCH` on a created draft returns 409.
- Creating a draft in the conversation of epic 1 makes a card whose `epic` is 1, whose acceptance and `blocked_by` are the draft's, and whose state is the one chosen.
- Creating a draft in a conversation with no epic makes a card with no `epic`.
- Creating a draft whose acceptance holds `verify on a device` returns the linter's `manual-check` line and creates no card.
- Creating the same draft twice returns the same number both times and the board has one such card.
- After a create, the conversation holds the line `Created C<n>: <title>` and the next turn's prompt contains it.
- `create-all` with three drafts whose second fails the linter creates the first, reports the failure of the second, and leaves the third uncreated.
- The shipped persona holds the sentence `You never create, move or edit cards` and names `card-<slug>.json`.
- The chat renders a draft with a Create button, and a created draft with a link to `/cards/<n>` and no button.

## Task 11: The Architect proposes card rewrites

Why: when the plan changes, the owner needs to see which cards must change and approve each rewrite, without the fleet rewriting what was asked for unseen.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `skills/architect/references/persona.md`
- `tests/test-board-architect-rewrites.sh`
- `tests/supervisor-ui.js`

Interfaces:
- Consumes: `collect_outbox` and its handlers (Task 10); a proposal with `source: "architect"` and `from`, and `premise-settle.sh propose|approve|reject` (core); the proposal routes and buttons of #476; `fl_default_head` through `premise.sh`.
- Produces: the outbox handler for `rewrite-<n>.json`: `{card: <n>, scope: <string>, acceptance: [<string>], summary: <string>}`. For an accepted file the server builds `{kind: "rewrite", source: "architect", from: <the card's state>, head: <the default branch's head>, scope, acceptance, summary}`, runs `premise-settle.sh propose <n> <file>`, moves the card to Blocked with `board-move.sh`, and comments `Waiting for a person: approve this rewrite from the Architect?` followed by the summary and the current and proposed Scope and acceptance.
- A file is dropped, with the reason shown in the turn, when: the card does not exist; its state is not `backlog` or `ready` (`C<n> is <state>; only a Backlog or Ready card can be rewritten`); it has a pull request (`C<n> has a pull request`); it already holds a premise-check proposal (`C<n> already has a premise-check proposal`); the proposed Scope names no repository path; the default head cannot be read.
- A second `rewrite-<n>.json` for a card that holds an Architect proposal replaces it and posts no second move.
- Produces: the turn's `rewrites: [{card, summary}]`, shown in the chat as a line per card linking to the card, where #476's Approve and Reject buttons act on it.
- Approving returns the card to the column it came from; that is `premise-settle.sh`'s behaviour for this kind of proposal and needs no code here.
- Produces: persona text: to change an existing card, write `rewrite-<n>.json` with the whole new Scope and acceptance and one paragraph on why; never for a card that has a pull request, which the Architect names to the owner instead.

Test steps:
- A valid `rewrite-12.json` for a Backlog card stores a proposal with `source` `architect`, `from` `backlog` and a 40-hex `head`.
- That card is then in Blocked; its note's `blocked_from` is not written (`note.sh` accepts no `backlog` value), and the proposal's `from` is `backlog`.
- The card gains one comment starting `Waiting for a person: approve this rewrite from the Architect?` that holds the summary.
- The turn's `rewrites` holds `{card: 12, summary}`.
- Approving the proposal through the page's route returns the card to Backlog with the proposed Scope and acceptance.
- Rejecting it returns the card to Backlog with its Scope and acceptance unchanged.
- A `rewrite-12.json` for a Ready card stores `from` `ready`, and approving returns the card to Ready.
- A `rewrite-12.json` for a card in In Review is dropped with `C12 is in_review; only a Backlog or Ready card can be rewritten` and the card is unchanged.
- A `rewrite-12.json` for a Ready card with a `pr_url` is dropped with `C12 has a pull request`.
- A `rewrite-12.json` for a card holding a premise-check proposal is dropped with `C12 already has a premise-check proposal` and that proposal is unchanged.
- A `rewrite-99.json` for a card that does not exist is dropped.
- A second `rewrite-12.json` replaces the stored proposal, leaves the card Blocked with the proposal's `from` still `backlog`, and adds no second move.
- A proposed Scope naming no path is dropped with `Scope names no repository path`.
- The chat renders one line per rewrite linking to `/cards/<n>`.

## Task 12: The Architect proposes a design, and the owner approves it

Why: a change to the plan often changes the design itself, and only the owner should decide that the epic's doc changes outside a merge.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/board.css`
- `skills/architect/references/persona.md`
- `tests/test-board-architect-design.sh`
- `tests/supervisor-ui.js`

Interfaces:
- Consumes: `collect_outbox` (Task 10); `epic.sh approve-design`, `epic.sh read` (core); the conversation's epic (Task 6).
- Produces: the outbox handler for `design.md`: accepted only in a conversation with an epic, non-empty, at most 200 KiB. It is stored as `<conversation dir>/design-proposals/<pid>.md` with `{pid, base_rev, status: "open"}`, and the turn gains `design_proposal: <pid>`. In a conversation with no epic it is dropped with `this conversation has no epic`.
- Produces: `GET /api/architect/<id>/design/<pid>` returns `{pid, status, base_rev, current_rev, text, current}` so the page can show both.
- Produces: `POST /api/architect/<id>/design/<pid>/approve`: when the epic's `design_rev` still equals `base_rev`, runs `epic.sh approve-design <epic> <file>` and marks the proposal `approved`; otherwise 409 `the design changed since this was proposed (revision <a>, now <b>)` and nothing is written. `POST .../reject` marks it `rejected`.
- The chat shows the proposed design rendered beside the current one, with the changed lines marked, and Approve and Reject buttons; a settled proposal shows its outcome and no buttons.
- Produces: persona text: to change the design, write the whole new design to `design.md` in the outbox, never a patch, and never restate the intent in it.

Test steps:
- A `design.md` in the outbox of an epic's conversation appears as the turn's `design_proposal` with status `open` and `base_rev` equal to the epic's `design_rev`.
- A `design.md` in a conversation with no epic is dropped with `this conversation has no epic`.
- An empty `design.md` is dropped.
- `GET` on the proposal returns the proposed text and the epic's current design.
- Approving an open proposal raises the epic's `design_rev` by one, makes `design.md` the proposed text, and keeps the old text under `revisions/`.
- Approving leaves `log.jsonl` and `intent` unchanged.
- Approving when the epic's revision has moved returns 409 naming both revisions and leaves `design.md` unchanged.
- Rejecting marks the proposal `rejected` and leaves the epic unchanged.
- Approving a rejected proposal returns 409.
- The chat renders Approve and Reject for an open proposal and neither for an approved one.

## Task 13: Where epics touch, and the progress report

Why: the owner wants to see where an epic sits among the others and to produce a progress report on request.

Files:
- `scripts/epic.sh`
- `scripts/adapters/local/epic-lib.sh`
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `tests/test-epic-report.sh`
- `tests/test-board-epics-page.sh`
- `README.md`

Interfaces:
- Consumes: the epic folder and `epic.sh read` (core); the scheduler's Scope path parsing (`fb_card_scope_paths`) and `scripts/path-glob.jq`; `supervisor.scope_ignore`.
- Produces: `epic.sh relations <id>` prints `{touches: [{epic, paths: [..]}], waits_on: [{epic, child, on}], waited_on_by: [{epic, child, on}]}` over open epics. Two epics touch when a child of each that is not `done` or `wont_do`, in the same repository, names overlapping Scope paths after `supervisor.scope_ignore` is dropped, with a directory path covering its descendants. `waits_on` lists this epic's children whose `blocked_by` names a card of another epic that is not `done`.
- Produces: `epic.sh report <id>` prints markdown, with no session: the title and effective state; the first paragraph of the intent; one line of counts per progress state; a table of children (number, title, state, pull request link); `Blocked` with each blocked child and its latest `Waiting for a person:` comment line; `Waiting` with each waiting child and the cards it waits on; `Departures` from the as-built log by card; `Other epics` from `relations`. A section with nothing in it prints `None.`.
- Produces: `GET /api/epics/<id>/relations` and `GET /api/epics/<id>/report` (plain text). `GET /api/epics` rows gain `touches` and `waits_on` as lists of epic ids.
- The epics list shows `touches E<id>` and `waits on E<id>` on a row; the epic page shows them with the shared paths, and a Report button that shows the report with a Copy control.
- Gate rule G5 already allows `report`; `relations` is read-only and is added to the verbs it allows.

Test steps:
- Two open epics with a child each naming `src/a.js` give `relations` a `touches` entry naming the other epic and that path.
- A child naming the directory `src/` and another epic's child naming `src/deep/b.js` touch.
- Children naming the same path in different repositories do not touch.
- A path matching `supervisor.scope_ignore` does not make two epics touch.
- A child in `done` is left out of the comparison.
- A child blocked by a card of epic 2 that is in Ready appears in `waits_on` with `epic` 2; once that card is `done` it does not.
- `report` for an epic prints its title, its effective state and the first paragraph of its intent.
- `report` prints a count line whose numbers equal the epic's progress counts.
- `report` lists a blocked child with the text of its latest `Waiting for a person:` comment.
- `report` lists each departure from the log under the card that made it.
- `report` for an epic with no children prints `None.` under each list and exits 0.
- `report 9` exits 3.
- `GET /api/epics/1/report` returns the same text as `epic.sh report 1`.
- The epics list row shows `touches E2` when the two epics touch.
- A Bash command `epic.sh relations 1` is allowed by the gate inside a session.

## Task 14: Sample layouts and drawn graphics

Why: the owner wants to see a layout while a change is being shaped, instead of reading a description of a screen.

Files:
- `scripts/board-web.py`
- `scripts/epic.sh`
- `scripts/adapters/local/epic-lib.sh`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/board.css`
- `skills/architect/references/persona.md`
- `tests/test-board-samples.sh`
- `tests/test-epic.sh`
- `tests/supervisor-ui.js`
- `README.md`

Interfaces:
- Consumes: `collect_outbox` (Task 10); the epic folder (core); conversations under an epic (Task 6).
- Produces: outbox handlers for `sample-<slug>.html` and `sample-<slug>.svg`, at most 1 MiB each. An accepted file is stored as `<conversation dir>/samples/<sid>/index.html` or `image.svg` with `meta.json` `{sid, title, kind: "html"|"svg", made_at, head, chosen: false}`; `title` is the document's `<title>`, else the slug; `head` is the default branch's head or null. The turn gains `samples: [<sid>]`.
- Produces: `GET /samples/<conversation id>/<sid>/` serves the file with these headers and no others that weaken them: `Content-Security-Policy: sandbox allow-scripts; default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:`, `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`. An SVG is served as `image/svg+xml` under the same policy. Any other path under `/samples/` is 404.
- Produces: `CONTENT_TYPES` gains `.svg`, `.png`, `.jpg`, `.jpeg`, `.webp` and `.gif`.
- Produces: the header and Origin check now also applies to PUT and DELETE requests.
- Produces: `POST /api/architect/<id>/samples/<sid>/choose` `{chosen: true|false}`. For a conversation with an epic it runs `epic.sh choose-sample <epic> <sid> [--clear]`, which records the sample in `<epic dir>/samples/<sid>/` (a copy of the file and its `meta.json` with `chosen`) or removes it. In a conversation with no epic the choice is kept in the conversation and carried into the epic when one is made.
- Produces: `epic.sh read` gains `samples: [{sid, title, kind, made_at, head}]`, the chosen ones.
- The chat shows each sample of a turn as a link that opens `/samples/<conversation>/<sid>/` in a new tab, several side by side as `Option A`, `Option B`, each with a Choose control. The epic page (Task 7's page) lists chosen samples with their date and the short commit they were made at.
- Produces: persona text: when a layout is in question, write one self-contained file per option, `sample-<slug>.html` with its CSS inline or `sample-<slug>.svg`, with no network resource, and say what each option trades off.

Test steps:
- A `sample-a.html` in the outbox appears in the turn's `samples` and is stored with a `meta.json` whose `kind` is `html` and whose `chosen` is false.
- A sample whose document has `<title>Checkout</title>` gets the title `Checkout`; one with none gets its slug.
- A `sample-a.svg` is stored with `kind` `svg`.
- A 2 MiB sample is dropped with the reason `larger than 1 MiB`.
- `GET /samples/<conversation>/<sid>/` returns the file with a `Content-Security-Policy` header that starts `sandbox allow-scripts` and holds `default-src 'none'`.
- That response carries `X-Content-Type-Options: nosniff`.
- The policy holds no `connect-src`, `form-action` or `frame-src` source, and does not hold `allow-same-origin`.
- `GET /samples/<conversation>/../../epic.json` returns 404.
- `GET /samples/<conversation>/<unknown sid>/` returns 404.
- A POST to `/api/cards` carrying `Origin: null` is refused.
- A DELETE and a PUT without the `X-Fleet-Board` header are refused.
- A `.png` file under the static directory is served as `image/png`.
- Choosing a sample in an epic's conversation copies it under `<board.dir>/epics/<id>/samples/<sid>/` and `epic.sh read` lists it.
- Clearing the choice removes it from `epic.sh read`.
- A sample chosen before the epic existed is listed by `epic.sh read` after the conversation is attached to the epic.
- `epic.sh choose-sample` run inside a session is blocked by the gate.
- The chat renders two samples of one turn as `Option A` and `Option B`, each a link with `target` `_blank` and `rel` `noopener`.

## Task 15: A card links to its samples

Why: a chosen layout should reach the implementor and the reviewer of the card that builds it, not only the plan.

Files:
- `scripts/board-create.sh`
- `scripts/adapters/local/create.sh`
- `scripts/adapters/local/edit.sh`
- `scripts/adapters/local/read.sh`
- `scripts/adapters/local/local-lib.sh`
- `scripts/import-plan.sh`
- `scripts/supervisor/driver.py`
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `tests/test-card-samples.sh`
- `fixtures/supervisor/driver_cases.py`

Interfaces:
- Consumes: the epic's chosen samples and `epic.sh read .samples` (Task 14); the card's `epic` and the driver's `Epic` prompt section (core); card drafts (Task 10).
- Produces: card field `samples`: a list of sample ids of the card's epic, or absent. `board-create.sh --sample <sid>` (repeatable) and `adapters/local/edit.sh --samples-json <json>`; a sample id that is not a chosen sample of the card's epic, or any sample on a card with no epic, is refused (exit 2, `sample <sid> is not a chosen sample of E<id>`). `board-read.sh` returns `samples` (a list, empty when absent).
- Produces: a card draft and an import card may carry `samples`; both pass them through.
- Produces: the driver's `Epic` section for the implementor, the reviewer and the fixer gains `Samples`, one line per sample: its title and the absolute path of its file under the epic. A sample that no longer exists is left out with one event.
- Produces: `PATCH /api/cards/<n>` accepts `samples`; the drawer lists the card's samples as links and offers the epic's chosen samples to add.

Test steps:
- `board-create.sh --epic 1 --sample s1` for a chosen sample stores `samples` `["s1"]` and `board-read.sh` returns it.
- `board-create.sh --epic 1 --sample nope` exits 2 with `sample nope is not a chosen sample of E1` and creates no card.
- `board-create.sh --sample s1` with no epic exits 2.
- `edit.sh --samples-json '[]'` removes the card's samples.
- A card with no `samples` key reads as an empty list.
- A card draft carrying `samples` creates a card with them.
- An implementor prompt for a card with one sample holds a `Samples` line with the sample's title and an absolute path that exists.
- A reviewer prompt for the same card holds the same line.
- A card whose sample folder was removed gets a prompt with no line for it and the driver records one event.
- A card with an epic and no samples gets an `Epic` section with no `Samples` heading.
- `PATCH /api/cards/<n>` with `samples` sets them, and the drawer shows each as a link to its sample.

## Task 16: The owner attaches pictures

Why: the owner wants to hand the Architect a screenshot or a sketch to work from.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `scripts/board-web/static/board.css`
- `tests/test-board-attachments.sh`
- `tests/supervisor-ui.js`
- `README.md`

Interfaces:
- Consumes: conversations (Task 5); the Claude argv of a turn (Task 10).
- Produces: `POST /api/architect/<id>/attachments?name=<file name>` with the raw bytes as the body and a `Content-Type` of `image/png`, `image/jpeg`, `image/webp` or `image/gif`. This route reads its body itself, up to 5 MiB; the JSON dispatcher's 1 MiB cap and parser do not apply to it. It checks the first bytes against the declared type, stores the file as `<conversation dir>/attachments/<aid>.<ext>` (the extension from the type, never from the name) and returns `{aid, name, bytes}`.
- Produces: `POST /api/architect/<id>/messages` accepts `attachments: [<aid>]`. The turn stores them, the prompt gains a line per attachment, `Attached image: <absolute path>`, and the Claude argv gains `Read(//<attachments dir>/**)`. An unknown `aid` is a 400.
- Produces: `GET /api/architect/<id>/attachments/<aid>` serves the image with its stored type, `X-Content-Type-Options: nosniff` and `Content-Disposition: inline`.
- The chat has an attach control and shows each attachment of a turn as a thumbnail. A codex conversation shows no attach control.
- A conversation that moves under an epic takes its attachments with it.

Test steps:
- Posting PNG bytes with `Content-Type: image/png` returns an `aid` and stores a `.png` file in the conversation's `attachments/`.
- Posting 6 MiB returns 413 and stores nothing.
- Posting text bytes with `Content-Type: image/png` returns 400 with `the file is not a PNG`.
- Posting with `Content-Type: image/svg+xml` returns 415.
- A file name `../../x.png` does not change where the file is stored.
- The route is refused without the `X-Fleet-Board` header.
- A message sent with one `aid` has a prompt holding `Attached image: ` followed by the stored file's absolute path.
- That turn's argv holds a read rule for the conversation's attachments folder.
- A message naming an unknown `aid` returns 400.
- `GET` on an attachment returns the bytes with `Content-Type: image/png` and `X-Content-Type-Options: nosniff`.
- The stored turn lists its attachments, and the chat renders a thumbnail for each.
- A codex conversation's page has no attach control and its message route refuses `attachments` with `Not available with the codex Architect`.
- After a conversation is attached to an epic, its earlier attachment is still served.

## Task 17: Export the epic's doc at the end

Why: when a change is finished, the owner wants its design and what was built merged into the repository as one document.

Files:
- `scripts/epic.sh`
- `scripts/adapters/local/epic-lib.sh`
- `scripts/config-defaults.json`
- `scripts/config.sh`
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `tests/test-epic-export.sh`
- `tests/test-config.sh`
- `tests/test-board-epics-page.sh`
- `plugins/fleet-board/docs/config.md`
- `README.md`

Interfaces:
- Consumes: the epic folder, `epic.sh read` (core); chosen samples (Task 14); `epic.sh report`'s children table (Task 13).
- Produces: config `epics.export_dir` (a repository-relative path with no `..`, default `docs/epics`; `config.sh` refuses anything else with `epics.export_dir must be a path inside the repository`).
- Produces: `epic.sh export <id>`. It needs no session and runs only git and `gh`:
  1. fetches the default branch and makes or refreshes a worktree on the branch `epic/<id>-<slug>-doc`, cut from the default branch's head, where `<slug>` is the title lowercased to `[a-z0-9-]`, at most 40 characters;
  2. writes `<export_dir>/<created date>-<slug>.md` holding, in order: the title; `Intent`; `Design` (the current design, with its revision number); `As built` (each log entry by card, with its pull request link, decisions and departures, and a line for each `unrecorded` or `skipped` one); `Cards` (the children table); `Samples` (a link to each chosen sample, copied to `<export_dir>/<created date>-<slug>/<sid>.<ext>`);
  3. commits, pushes, and opens a pull request titled `E<id>: <title> (design record)` when none is open for the branch;
  4. stores `exported: {pr_url, branch, at}` in `epic.json` and prints it.
  A second run updates the same branch and pull request. Nothing is written to `epic.json` when the push or the pull request fails. Exit 1 on a failure, 3 when the epic does not exist.
- Produces: `POST /api/epics/<id>/export`, which runs it and returns `exported`. The epic page shows an Export doc button, marked as suggested when the effective state is `complete`, and the pull request link once exported.
- The pull request has no card. The owner reviews and merges it. The file is under `docs/`, so no version bump applies.
- `epic.sh export` inside a session is blocked by gate rule G5.

Test steps:
- `config.sh` prints `epics.export_dir` as `docs/epics` by default.
- `epics.export_dir: ../out` is refused with `epics.export_dir must be a path inside the repository`.
- `export 1` creates the branch `epic/1-<slug>-doc` from the default branch's head and one file `docs/epics/<date>-<slug>.md` on it.
- The file holds the epic's intent under `Intent` and the current design under `Design` with its revision number.
- The file lists each log entry under `As built` with the card number and its pull request link.
- An `unrecorded` log entry appears as a line saying the card was not recorded.
- The file's `Cards` table has one row per child.
- A chosen sample is copied beside the file and linked from `Samples`.
- A fake `gh` records one `pr create` whose title is `E1: <title> (design record)`.
- `epic.json`'s `exported` holds the pull request URL and the branch after a successful run.
- A second `export 1` after the design changed pushes a new commit to the same branch and calls `pr create` zero more times.
- When the push fails, `export` exits 1 and `exported` stays null.
- `export 9` exits 3.
- A configured `epics.export_dir` of `doc/records` puts the file under `doc/records/`.
- `POST /api/epics/1/export` returns the stored `exported` object.
- The epic page shows the Export doc button for an open epic and the pull request link for an exported one.

## Task 18: Status and the docs

Why: epics and the Architect have to be visible outside the board page and documented for someone setting the board up.

Files:
- `scripts/status.sh`
- `tests/test-status.sh`
- `tests/test-readme-claims.sh`
- `README.md`
- `plugins/fleet-board/docs/config.md`
- `CLAUDE.md`

Interfaces:
- Consumes: `epic.sh list` (core); everything the earlier tasks added.
- Produces: `status.sh` prints, after the columns, a section `Epics` with one line per open epic: `E<id> <title> · <done>/<total> done · <in flight> in flight · <blocked> blocked`, followed by ` · needs attention` when the epic has an attention entry. With no open epic the section is not printed. `status.sh` makes one `epic.sh list` call and none when `<board.dir>/epics` does not exist.
- Produces: a README section `Epics` covering what an epic is, how one is made (Draft cards, the New epic control, the offer after a second card), how the design is revised when a child merges, the as-built log, the conversation, samples and attachments, the report, the export, and what a session can and cannot change. A README section `The Architect` replaces the chat's section.
- Produces: `plugins/fleet-board/docs/config.md` rows for `architect.*`, `models.architect_record`, `epics.record` and `epics.export_dir`.
- Produces: the epic record's contract in the plugin's `CLAUDE.md`: the folder, `epic.json`'s keys, the `epic.sh` verbs and exit codes, the `record_epic` action and its failure rule, the outbox and the kinds it accepts, and gate rule G5.
- `skills/status/SKILL.md` is clean-room and is not edited; the section reaches the user because the skill prints what `status.sh` prints.

Test steps:
- `status.sh` on a board with one open epic of three children, one done and one in progress, prints `E1 <title> · 1/3 done · 1 in flight · 0 blocked` under an `Epics` heading.
- An epic with an attention entry prints the same line ending ` · needs attention`.
- A closed epic is not printed.
- A board with no open epic prints no `Epics` heading.
- A store with no `epics` directory prints as before and `epic.sh` is not called.
- The README holds the headings `Epics` and `The Architect`.
- The README's Gates section names rule G5.
- `plugins/fleet-board/docs/config.md` documents `architect.model`, `models.architect_record`, `epics.record` and `epics.export_dir` with their defaults.
- `test-readme-claims.sh` passes with a claim added for each new config key's default.

## Task 19: The offer to make an epic after a second card

Why: a conversation that produces a single card has no epic. When it goes on to produce a second, the owner should be offered one, as Draft cards offers one for two or more.

Files:
- `scripts/board-web.py`
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `tests/test-board-architect-epic-offer.sh`
- `tests/supervisor-ui.js`

Interfaces:
- Consumes: card drafts and their create route (Task 10); `epic.sh create`, `adapters/local/edit.sh --epic` (core); attaching a conversation to an epic (Task 6).
- Produces: in a conversation with no epic, the reply to a draft's create gains `offer_epic: true` when two or more cards have now been created from that conversation and the offer has not been declined. The page then shows `Make these an epic?` with Yes and No.
- Produces: `POST /api/architect/<id>/epic-offer/draft` runs one Architect turn that returns a proposed title, intent and design for the cards created so far, shown in a form the owner edits. `POST /api/architect/<id>/epic-offer/accept` `{title, intent, design}` runs `epic.sh create`, sets `epic` on every card created from the conversation, and attaches the conversation to the epic as Task 6 does. `POST /api/architect/<id>/epic-offer/decline` stores `epic_offer: "declined"` in `meta.json`.
- The intent that is stored is the text the owner saved in the form, never the session's draft unseen.

Test steps:
- In a conversation with no epic, the reply to the first create has no `offer_epic`.
- The reply to the second create has `offer_epic` true.
- In the conversation of an epic, no create reply has `offer_epic`.
- `epic-offer/draft` returns a non-empty `title`, `intent` and `design`.
- `epic-offer/accept` with an edited intent creates an epic whose intent is the edited text.
- After accept, both cards created from the conversation have that epic's id in `epic`.
- After accept, the conversation's folder is under the epic and the epic's `conversation` is its id.
- After `epic-offer/decline`, the reply to a third create has no `offer_epic`.
- `epic-offer/accept` in a conversation that already has an epic returns 409.
- The page shows `Make these an epic?` after the second create and not after the first.

## Task 20: Cards are shown as C and their number

Why: epics are written `E<id>`, and `#<n>` is used for both cards and pull requests, so `#530` and `#464` cannot be told apart. The owner asked for cards to be written `C<n>` the way epics are written `E<id>`. This is a display and input change only; it needs nothing from the core and can be built at any time.

Files:
- `scripts/board-web/static/board.js`
- `scripts/board-web/static/index.html`
- `scripts/status.sh`
- `scripts/adapters/local/local-lib.sh`
- `scripts/parse-report.sh`
- `tests/test-board-card-refs.sh`
- `tests/supervisor-ui.js`
- `tests/test-status.sh`
- `tests/test-board-local.sh`
- `tests/test-parse-report.sh`
- `README.md`

Interfaces:
- Produces: on the board page, every card reference the page itself builds is `C<n>`: the tile, the drawer's heading, `depends on`, `stacked on`, the stuck banner, hold and wait reasons the page composes, and the import preview's dependency column. A pull request stays `#<n>` or `PR #<n>`.
- Produces: `status.sh` prints a card's line starting `C<n>` and writes `stacked on C<parent>`; a pull request on the line stays `PR #<n>`.
- Produces: input in both forms. `fl_split_body`'s dependency reference accepts `C<n>` and `<repo>C<n>` wherever it accepts `#<n>` and `<repo>#<n>`, with the same bad-reference rule for trailing text. `parse-report.sh` accepts `C<n>` beside `#<n>` in the checker's `## Card` section.
- Not changed: the text of stored comments and role reports (the page shows a comment as it was written), plan reasons and comments the supervisor writes, branch names (`fleet/<n>-<slug>`), every JSON key and value, the gate's messages, and every file under `agents/` and `skills/{reporting,status}/`. `skills/status/SKILL.md` is clean-room and prints what `status.sh` prints, so it shows the new form without an edit.
- Card numbers typed into the page's own inputs (the dependency editor) accept `12`, `#12` and `C12`.

Test steps:
- A tile for card 12 shows `C12` and does not show `#12`.
- The drawer's heading for card 12 starts `C12`.
- A card depending on card 4 shows `depends on C4` in the drawer.
- A stacked card shows `stacked on C7`.
- A card with a pull request shows the pull request as `#530` beside `C12`.
- A comment whose text holds `#12` is rendered with `#12` unchanged.
- `status.sh` prints card 12's line starting `C12`.
- `status.sh` prints `stacked on C7` for a stacked card and `PR #530` for its pull request.
- A body whose `## Depends on` section holds `- C4` yields `blocked_by` `[4]`.
- A body whose `## Depends on` section holds `- #4` still yields `blocked_by` `[4]`.
- A dependency line `- C4 and more text` is refused as a bad dependency line, as `- #4 and more text` is.
- A dependency line `- other/repoC4` for a repository that is not this board's stays in the body as an outside dependency.
- A checker report whose `## Card` section holds `C12` parses with `card` 12.
- A checker report whose `## Card` section holds `C12 C13` is rejected with the message two `#` references get today.
- Typing `C4` into the drawer's dependency editor adds card 4.
- No file under `agents/`, `skills/reporting/` or `skills/status/` is changed by this card, and `test-clean-room.sh` passes.
