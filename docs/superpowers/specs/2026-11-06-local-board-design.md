# Local web board with Start/Stop: design

Date: 2026-11-06. Status: approved in conversation, awaiting written review.

## Goal

GitHub rate limits throttle the fleet. Most of the GitHub traffic is the issue side: every
tick lists each column, reads each card and all its comments, and writes the manager note
and role reports as comments. This design moves the cards off GitHub into a local store and
puts a locally served web page in front of it, with Start and Stop for the headless run.
PRs stay on GitHub, so the PR-side calls (`gh pr view`, `gh pr list`, `gh api compare`,
pushes) remain.

Success looks like: a tick on a `local` board makes no `gh` call for cards, columns, notes
or comments; a person runs the board from a browser tab on their own machine; the fleet
keeps working when that tab and its server are closed.

## Decisions made in conversation

| Question | Decision |
|---|---|
| Card store | New `board.backend: local`; cards, notes and reports live in local files. PRs stay on GitHub. |
| What the page does | Create, edit and move cards (drag and drop), read notes and reports, Start and Stop the run. |
| Stop semantics | Graceful only: write `.fleet-board.stop`, the run ends after the current tick. No kill button. |
| Plan import | A Claude session running the import-plan skill groups the plan into cards. The mechanical `import-plan.sh parse` is not used by the page. |
| Visual | The plan is shown as a sheet of paper that splits into cards. |
| Active cards | A card a role agent is working on gets a distinct border and a pulsing dot. |
| Architecture | Thin Python 3 standard-library server over the existing `board-*.sh` scripts (approach A). Not a server that owns the store (B), not SQLite plus Node (C). |

## Store

A directory at `<repo root>/<board.dir>`, default `.fleet-board`. `FLEET_ROOT` already
resolves to the main checkout from any worktree (`fb_git_common_dir`), so role agents in
worktrees find the same store.

```
.fleet-board/
  next            next card number (integer, starts at 1)
  cards/<n>.json  one file per card
  active/<n>      marker: a role agent is working on card n (see Active cards)
```

A card file:

```json
{
  "number": 12,
  "title": "Add the settle step",
  "body": "## Why\n...\n## Acceptance\n- ...",
  "state": "in_review",
  "labels": ["needs-human-qa"],
  "created_at": "2026-11-06T18:02:11Z",
  "updated_at": "2026-11-06T19:40:03Z",
  "next_comment_id": 4,
  "comments": [
    {"id": 1, "author": "david", "body": "<!-- fleet-board:manager-note -->\n```json\n{...}\n```", "created_at": "..."},
    {"id": 2, "author": "david", "body": "## Report ...", "created_at": "..."}
  ]
}
```

- `state` is a canonical state name (`FB_STATES`, including `review_<name>` stage states).
  A file whose state is not canonical reads as `state: null` with a warning on stderr, the
  way the labels adapter treats a card with no state label.
- The manager note is a comment whose body starts with `FB_MARKER`, exactly as on GitHub,
  so `note.sh` and every consumer of the read shape are unchanged.
- Done and Won't Do are states, not closed issues. Nothing is ever deleted.
- `init` adds `<board.dir>/` to `.gitignore`. Removing that line and committing the board
  is allowed and supported: nothing in the fleet commits on the main checkout.
- Every write goes to a temp file in the same directory and is renamed into place, so a
  reader never sees a half-written card.

## Adapter: `scripts/adapters/local/`

Same verbs as the other backends. Each script sources `board-lib.sh` and uses `jq`.

| Verb | Behavior |
|---|---|
| `read <n>` | Prints the shape the other adapters print: `number, title, url, state, body, labels, manager_note, manager_note_id, comments[{id,author,body,created_at}], item_id (null)`. `url` is `http://127.0.0.1:<board.port>/cards/<n>`. The note is the last marker comment whose author equals `fb_login`. Exit 1 when the card file is missing or unparsable. |
| `list <state>` | Reads every `cards/*.json`, keeps those whose `state` equals the argument, sorts by number, prints `[{number,title,url}]`. No truncation rule, since nothing is paginated. Exit 1 naming the file when any card file is unparsable (fail closed: a short column drops cards). `--allow-truncated` is accepted and ignored. |
| `move <n> <state>` | Takes `fb_lock n`, applies the Ready rule (`fb_has_acceptance` on the body, exit 1 otherwise), rewrites `state` and `updated_at`. Exit 0 without a write when the card is already there. |
| `create <title> <body-file> [--label L]...` | Takes a lock on `next` (same `mkdir` lock pattern as `fb_lock`), allocates the number, writes the card with `state` = `FB_CREATE_STATE` (default `backlog`), prints `{number, url}`. |
| `comment <n> <body-file>` | Under `fb_lock n`, appends `{id: next_comment_id, author: fb_login, body, created_at}`. |
| `note <n> <body-file>` | Under `fb_lock n`, replaces the body of the last marker comment by this author, or appends one; then removes `active/<n>` (see Active cards). |
| `cache-clear` | No-op, exit 0. |

A local-only helper, not part of the contract, used by the web server:

- `edit <n> <title-file> <body-file> <labels-json>`: under `fb_lock n`, re-reads the card
  and rewrites only `title`, `body`, `labels` and `updated_at`, never `comments` or
  `state`, so an agent's comment landing at the same moment is never lost.

### Identity

`fb_login` on the `local` backend prints `FLEET_BOARD_USER`, else `$USER`, with no `gh`
call. The note trust boundary becomes filesystem access: anyone who can write the store
can write anything, and the field validation in `note.sh get` still applies to every field
it checks today. `accept.sh` records that same identity, and `tick-plan.sh` compares
against it, so `accepted` works without `gh api user`.

### Active cards

The manager runs `worktree.sh create <n> ...` or `worktree.sh review <n> ...` immediately
before every role dispatch, and nothing else calls `worktree.sh` during a run
(`cleanup-done.sh` runs `remove` between ticks). After a role returns, the manager always
writes the note, whether the report was accepted (3.6) or the action failed (2.C.1).

- `worktree.sh create` and `worktree.sh review` write `<board.dir>/active/<n>` when the
  backend is `local` (an empty file; the directory is created as needed; a failure to
  write it is a warning, never an error).
- The local `note` verb removes `active/<n>`.
- The page shows a card as active only while its marker exists **and** a run is alive. A
  marker left behind by a killed tick stops counting the moment the run is gone. The
  server also deletes every marker when it observes the run go from alive to gone.

## Web server

### Launch

`scripts/board-web.sh [--repo DIR] [--port N]`:

1. `cd` to the repo root (as `fleet-board-run.sh` does), run `config.sh --check`, exit with
   its code on failure.
2. Refuse (exit 2) when `board.backend` is not `local`.
3. Refuse (exit 1) when `python3` is not on `PATH`, naming it.
4. `exec python3 "$HERE/board-web.py" --root <root> --port <port> --scripts "$HERE"`.

It runs in the foreground; Ctrl-C stops the page, never the fleet. `status.sh` prints its
path on a last line `Board page: <absolute path to board-web.sh>` after the
`Headless wrapper:` line, so the docs never write down an install path.

### Process

`scripts/board-web.py`: one file, Python 3.9+ standard library only (`http.server`,
`json`, `subprocess`, `pathlib`, `threading`). `ThreadingHTTPServer` bound to `127.0.0.1`
on `board.port` (default 8765; `--port` overrides). Static files are served from
`scripts/board-web/static/` (`index.html`, `board.css`, `board.js`). The server never
imports anything outside the standard library and never fetches anything from the network.

Mutating requests (`POST`, `PATCH`) must carry the header `X-Fleet-Board: 1` and an
`Origin` equal to the server's own origin (or no `Origin`, for curl); otherwise 403. This
stops a page in another tab from driving the board.

### API

Reads go straight to the store files. Writes run the same script an agent would, with
`cwd` = repo root, and return the script's stderr on a non-zero exit.

| Method and path | Does | Backed by |
|---|---|---|
| `GET /api/board` | `{states: [{key, name}], cards: [{number, title, state, labels, note: {round, pr, models, stage, action_failures}, active, updated_at}], run: <run status>}` | files; state order and names from `config.sh` + `fb_state_name` (one subprocess, cached until the config file's mtime changes) |
| `GET /api/cards/<n>` | the full card: body, comments, the manager note body, `url` of the PR when the note has `pr` | file |
| `POST /api/cards` `{title, body, labels, state?}` | create; `state` defaults to backlog | `board-create.sh`, then `board-move.sh` when `state` is given |
| `PATCH /api/cards/<n>` `{title?, body?, labels?}` | edit | `adapters/local/edit.sh` |
| `POST /api/cards/<n>/move` `{state}` | move | `board-move.sh` |
| `POST /api/cards/<n>/comments` `{body}` | comment as the page's user | `board-comment.sh` |
| `GET /api/run` | run status (below) plus the last 200 lines of the run log | pid file, out file, run log |
| `POST /api/run/start` | start a run | spawns the wrapper |
| `POST /api/run/stop` | graceful stop | touches `.fleet-board.stop` |
| `POST /api/import` `{plan, status}` | start a plan import session; returns `{import_id}` | `claude -p` |
| `GET /api/import/<id>` | `{state: running|ready|failed, elapsed_s, last_text, cards?, table?, error?}` | import dir |
| `POST /api/import/<id>/create` `{embed_docs: bool}` | create the previewed cards | `import-plan.sh` |

Errors: a script's non-zero exit is `409 {error: <stderr>}` for board writes and
`500 {error}` for anything else; the page shows the text in a toast and the board stays as
it was. A Python exception is `500` with the exception message and is logged to stderr.

### Run control

State lives under `$HOME/.fleet-board/web/<owner>-<name>/` (`FLEET_BOARD_LOG_DIR` moves
the parent, as for the wrapper): `run.pid`, `run.out` (the wrapper's stdout and stderr),
and `run.log` (the path the wrapper printed as its log, parsed from the first lines of
`run.out`).

- **Start** refuses (409) when a run is alive. Otherwise it removes a leftover
  `.fleet-board.stop`, clears `active/`, and spawns
  `bash <scripts>/fleet-board-run.sh --repo <root>` with `start_new_session=True`,
  stdin from `/dev/null`, stdout and stderr to `run.out`, and writes `run.pid`. The run
  survives the server quitting. The wrapper's own `FLEET_BOARD_*` environment is passed
  through unchanged. `FLEET_BOARD_RUN` names another wrapper script (tests use a fake).
- **Stop** touches `<root>/.fleet-board.stop`. The wrapper checks it before every tick, so
  the run ends after the current tick. The server never sends a signal.
- **Status** is computed on every request from the pid file (`os.kill(pid, 0)`):
  `idle` (no pid file or the pid is dead and `run.out` is empty), `running` (alive, no stop
  file), `stopping` (alive, stop file present), `stopped` (dead; the reason, tick count,
  hours and cost come from the wrapper's final `fleet-board-run: stopped: ...` line in
  `run.out`). The current tick number comes from the last `tick <n>` line of the run log.
  A restarted server reattaches by reading the pid file.

### Plan import

1. `POST /api/import` writes the plan text to
   `$HOME/.fleet-board/web/<owner>-<name>/imports/<timestamp>/plan.md` and starts, from the
   repo root, one headless session:

   ```
   claude -p --output-format stream-json --verbose \
     --permission-mode <headless.permission_mode> --max-turns <limits.max_turns> \
     [--plugin-dir $FLEET_BOARD_PLUGIN_DIR] \
     "/fleet-board:import-plan <plan.md> --preview <cards.json> [--status ready]"
   ```

   `FLEET_BOARD_CLAUDE` names the binary, as for the wrapper. The stream goes to
   `session.jsonl` in the import directory; the server reads it on each status request and
   reports the latest assistant text and elapsed time.
2. The import-plan skill (not clean-room; editable) gains `--preview <file>`: do Step 1
   (read), Step 2 (group) and Step 3 (dry run), write the cards file to the given path, print
   the dry-run table, and stop. It never asks to create and never creates in preview mode.
   The server treats the import as `ready` when the cards file exists and parses, and as
   `failed` when the process exits without it, carrying the last stderr or result text.
3. The page plays the animation and shows the preview row: title, acceptance count, labels,
   dependencies (from `depends_on` and the inferred `consumes`/`produces` links, resolved
   by `import-plan.sh --dry-run`, whose table the server also returns).
4. `POST /api/import/<id>/create` runs `import-plan.sh <cards.json> [--status ready]` with
   `y` on stdin, followed by `e` when `embed_docs` is true or `m` otherwise, which answers
   the script's missing-docs question. Its stdout (`Created #N` lines) is returned; a
   non-zero exit returns the stderr and creates nothing further.
5. `import-plan.sh` gains a `local` backend case: create through `board-create.sh` with the
   card's labels and `FB_CREATE_STATE=<status>`, print `Created #N`. The card linter runs
   as it does for the other backends.

## Page

Plain HTML, CSS and JavaScript, no build step, no network fetches, so it works offline.
It polls `GET /api/board` every three seconds and `GET /api/run` every three seconds while
a run is alive, otherwise every fifteen.

### Board view

- One column per state in `states` order: Backlog, Ready, In Progress, In Review, any
  `Review: <stage>` columns, Human QA, Blocked, Done, Won't Do. Done and Won't Do are
  collapsed to a count with a toggle to expand.
- A card shows `#n`, title, labels, review round, PR number as a link to GitHub, and the
  models, the fields `status.sh` prints. An active card has an accent border and a pulsing
  dot.
- Cards drag between columns (HTML5 drag and drop). Each card also has a "Move to" menu,
  for keyboards and for moves the drag misses. A refused move (for example to Ready without
  `## Acceptance`) shows the script's message and the card snaps back.
- A "New card" button opens the drawer empty.

### Card drawer

Opened by clicking a card: `#n` and title (editable), body (a textarea with a rendered
markdown preview), labels (a token input), state menu, PR link, comments rendered as
markdown in order, the manager note collapsed (pretty-printed JSON), and a comment box.
Save runs `PATCH`. Edits of a card that an agent is working on are allowed; the helper's
lock makes them safe.

### Header

Run state pill (`idle`, `running · tick 4`, `stopping`, `stopped: nothing-dispatchable`),
Start (enabled when not alive), Stop (enabled when running), cost and hours from the
wrapper's final line when stopped, and a toggle for a log tail panel showing the last 200
lines of the run log.

### Import view

A text area for the plan (paste, or drop a `.md` file), a Backlog/Ready choice, and
"Group with Claude". While the session runs: elapsed time and the latest assistant text.
On `ready`: the sheet of paper holding the plan text folds and splits into one card per
entry; the cards fan out into a preview row. Then "Create N cards" with an
"embed referenced doc sections" toggle (default on). On `failed`: the error, and nothing
is created.

### Markdown

A small in-page renderer: headings, paragraphs, ordered and unordered lists, code fences
and inline code, emphasis, links, and HTML comments hidden. Output is built with DOM
calls, never `innerHTML` from card text, so a hostile card body cannot script the page.

## Changes elsewhere

| File | Change |
|---|---|
| `scripts/config.sh` | accept `local`; new keys `board.dir` (string, default `.fleet-board`, relative to the repo root, must not be absolute or contain `..`) and `board.port` (integer 1024–65535, default 8765). `board.repo` stays required. `project_number` is required only for `github-projects`, as now. |
| `scripts/config-defaults.json` | the two new keys |
| `scripts/board-lib.sh` | `fb_default_name` for `local`: the Projects human names, and `Review: <stage>`; `fb_login` local identity |
| `scripts/init.sh` | `--backend local`: write config, create `board.dir` and `cards/`, write `next`, add `<board.dir>/` to `.gitignore` when not already ignored, skip label creation, keep the `gh` scope check (PRs) |
| `scripts/review-stages.sh setup` | `local`: nothing to create, exit 0 |
| `scripts/deps.sh` | `#n` on `local` reads `cards/<n>.json` (state `done` means met; a missing file is a failed lookup); `owner/repo#n` through `gh` as now |
| `scripts/import-plan.sh` | the `local` case above |
| `scripts/worktree.sh` | the active marker on `create` and `review` |
| `scripts/status.sh` | the `Board page:` line |
| `hooks/gate.sh` | add `local` to the policy/backend case at line 761; the Projects item lookups (873, 965) return as for `github-labels` |
| `skills/import-plan/SKILL.md` | `--preview` |
| `skills/init/SKILL.md` | offer Local as a third backend |
| `README.md`, `docs/config.md`, `docs/overnight.md`, `docs/gates.md` | the config rows, a "Local board" section (install, launch, Start/Stop, import), the gate residual |
| `plugins/fleet-board/CLAUDE.md` | backends line; the active-marker contract |
| `docs/design.md` | one tradeoff section: a local store gives up the card-as-durable-shared-state property for freedom from rate limits |
| `.claude-plugin/plugin.json`, `marketplace.json` | 0.13.0 |

The clean-room files (`agents/*.md`, `skills/{reporting,tick,run,status}/SKILL.md`) are
not touched.

## Residuals and known limitations

- **Gate.** Raw writes into `board.dir` (`jq ... > .fleet-board/cards/3.json`, `mv`,
  `sed -i`) bypass the gate, which is a text check on board commands. Listed in
  `docs/gates.md` as a residual, not claimed as covered.
- **Role prompts.** The clean-room role prompts give `gh issue view <n> --json body` as the
  example command for re-reading a card. On a local board that reads an unrelated GitHub
  issue with the same number in `board.repo`. The manager passes the card body inline, so
  this only arises when a role chooses that example. Listed in the README known issues
  until a re-author pass replaces the example.
- **Trust boundary.** The note's author check is a filesystem boundary, not a login.
- **PRs still cost GitHub calls.** A tick still reads PR state for every in-flight card.

## Error handling

- Adapter: unparsable card file fails `read` (exit 1) and the whole `list` (exit 1,
  naming the file); a missing store exits 1 saying to run `/fleet-board:init`; lock
  timeouts as today (`FLEET_BOARD_LOCK_WAIT`).
- Server: port in use is reported by `board-web.sh` with the port number (exit 1); a
  wrapper that exits at once shows `stopped` with its first stderr lines; a pid file whose
  process is gone is `stopped` or `idle` as above; a failed import shows its error and
  creates nothing; a request body that is not JSON or lacks a required field is 400.
- Concurrency: the page's edit helper and the agents' comment and note writes all take the
  per-card lock; the page never writes a card file directly.

## Testing

Plain-bash suites under `plugins/fleet-board/tests/`, each proven able to fail before it
is trusted (break the script, watch the assertion fail, restore it):

- `test-board-local.sh`: the six verbs and `edit` against a temp repo; the Ready refusal;
  atomic write (a reader during a write sees old or new, never partial); eight concurrent
  `comment` calls lose nothing; `note` replaces rather than appends; `note` clears the
  active marker; `list` fails closed on a corrupt file; `fb_login` with and without
  `FLEET_BOARD_USER`.
- `test-config.sh`, `test-init.sh`, `test-gate.sh`, `test-deps.sh`, `test-import-plan.sh`,
  `test-review-stages.sh`, `test-worktree.sh`, `test-status.sh`: new `local` cases.
- `test-board-web.sh`: starts `board-web.py` on a free port against a temp repo with the
  local backend and drives the API with `curl`: board JSON with state order, create, edit,
  move and refused move, the CSRF header check, Start with `FLEET_BOARD_RUN` pointing at a
  fake wrapper (records its arguments, prints a log path, waits for the stop file), Stop
  creating the stop file, status transitions, import with `FLEET_BOARD_CLAUDE` pointing at
  `fake-claude.sh` producing a cards file, and create.
- `test-readme-claims.sh` and `test-version.sh` keep passing; `test-clean-room.sh` must
  pass since no clean-room file changes.
- The page itself (layout, drag and drop, the animation) is verified by hand in the
  browser during implementation, with screenshots in the PR. Not automated.

## Out of scope

Card deletion, attachments, search, server push, authentication, remote access,
migration of existing GitHub cards to the local store, and any change to the clean-room
role prompts.
