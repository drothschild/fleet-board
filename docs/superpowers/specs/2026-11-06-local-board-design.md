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
| Card store | Local only (updated 2026-11-07: the GitHub backends and `board.backend` are gone); cards, notes and reports live in local files. PRs stay on GitHub. |
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
  "body": "Why the card exists, in prose.",
  "acceptance": ["rejects an empty plan", "prints one line per card"],
  "blocked_by": [9, 11],
  "pr_url": "https://github.com/acme/toy/pull/41",
  "pr_url_source": "note",
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

- `acceptance` is a list of single-line testable items; `blocked_by` is a list of card
  numbers on this board (a missing card, or the card itself, is refused on write, exit 2;
  a dependency that is not a card here stays in the body as a prose line
  `Depends on (outside this board): <ref>`); `pr_url` is the card's PR, with `pr_url_source`
  `note` (mirrored from the manager note's `pr`), `person` (set in the drawer) or null.
  A body written with `## Acceptance` and `## Depends on` sections is split into the
  fields (`fl_split_body`: first real heading wins, none inside a code fence), so plans
  written the old way still import. `body` holds the prose only; `read` returns it as stored.
  `migrate-card-fields.sh [--dry-run]` gives an older store the fields.
- `state` is a canonical state name (`FB_STATES`, including `review_<name>` stage states).
  A file whose state is not canonical reads as `state: null` with a warning on stderr.
- The manager note is a comment whose body starts with `FB_MARKER`, exactly as on GitHub,
  so `note.sh` and every consumer of the read shape are unchanged.
- Done and Won't Do are states, not closed issues. Nothing is ever deleted.
- `init` adds `<board.dir>/` to `.gitignore`. Removing that line and committing the board
  is allowed and supported: nothing in the fleet commits on the main checkout.
- Every write goes to a temp file in the same directory and is renamed into place, so a
  reader never sees a half-written card.

## Adapter: `scripts/adapters/local/`

The contract verbs (this is the only adapter). Each script sources `board-lib.sh` and uses `jq`.

| Verb | Behavior |
|---|---|
| `read <n>` | Prints: `number, title, url, state, body, acceptance, blocked_by, pr_url, labels, manager_note, manager_note_id, comments[{id,author,body,created_at}], item_id (null)`. `url` is `http://127.0.0.1:<board.port>/cards/<n>`. The note is the last marker comment whose author equals `fb_login`. Exit 1 when the card file is missing or unparsable. |
| `list <state>` | Reads every `cards/*.json`, keeps those whose `state` equals the argument, sorts by number, prints `[{number,title,url}]`. No truncation rule, since nothing is paginated. Exit 1 naming the file when any card file is unparsable (fail closed: a short column drops cards). `--allow-truncated` is accepted and ignored. |
| `move <n> <state>` | Takes `fb_lock n`, applies the Ready rule (`fb_card_has_acceptance`: a non-empty `acceptance` field, exit 1 otherwise), rewrites `state` and `updated_at`. Exit 0 without a write when the card is already there. |
| `create <title> <body-file> [--label L]... [--state S] [--acceptance-file F] [--blocked-by N]...` | Takes a lock on `next` (same `mkdir` lock pattern as `fb_lock`), allocates the number, splits the body into the fields (the flags win over the body), refuses a `--blocked-by` that is missing, writes the card with `state` = `FB_CREATE_STATE` (default `backlog`), prints `{number, url}`. |
| `comment <n> <body-file>` | Under `fb_lock n`, appends `{id: next_comment_id, author: fb_login, body, created_at}`; then removes `active/<n>` only for a validated role report (see Active cards). |
| `note <n> <body-file>` | Under `fb_lock n`, replaces the body of the last marker comment by this author, or appends one, and mirrors the note's `pr` into `pr_url` (`pr_url_source: note`; `pr: null` clears a note-sourced URL; a `person` URL is kept unless the note names a different PR; an unparsable note leaves `pr_url` unchanged and warns). |
| `cache-clear` | No-op, exit 0. |

Local-only helpers, not part of the contract:

- `edit <n> [--title-file F] [--body-file F] [--labels-json J] [--acceptance-file F] [--blocked-by-json J] [--pr-url U]` (the web server): under `fb_lock n`,
  re-reads the card and rewrites only `title`, `body`, `labels`, `acceptance`, `blocked_by`, `pr_url` and `updated_at`, never
  `comments` or `state` (a `blocked_by` ref the edit adds must exist and not be the card; refs already stored are kept unchecked), so an agent's comment landing at the same moment is never lost.
- `label <n> add|remove <label>` (`review-stages.sh route`): under `fb_lock n`, re-reads
  the card and adds or removes one label, rewriting only `labels` and `updated_at`.
- `fl_find_title <title> open|closed [days]` in `local-lib.sh` (the follow-up and P0
  de-duplication): the card whose title equals `<title>` case-insensitively, lowest number
  first. `open` is any state but `done` and `wont_do`; `closed` is `done` or `wont_do`
  with `updated_at` (else `created_at`) within `days` (default 30). An unparsable card file
  fails the search (exit 1).

### Identity

`fb_login` prints `FLEET_BOARD_USER`, else `$USER`, else
`id -un`, with no `gh` call, and exits 1 when all three are empty (the server's
`local_user()` follows the same order with `getpass.getuser()` and raises when empty). The note trust boundary becomes filesystem access: anyone who can write the store
can write anything, and the field validation in `note.sh get` still applies to every field
it checks today. `accept.sh` records that same identity, and `tick-plan.sh` compares
against it, so `accepted` works without `gh api user`.

### Active cards

The manager runs `worktree.sh create <n> ...` or `worktree.sh review <n> ...` immediately
before every role dispatch, and nothing else calls `worktree.sh` during a run
(`cleanup-done.sh` runs `remove` between ticks). After a role returns, the manager always
writes the note, whether the report was accepted (3.6) or the action failed (2.C.1).

- `worktree.sh create` and `worktree.sh review` write `<board.dir>/active/<n>`
  (an empty file; the directory is created as needed; a failure to
  write it is a warning, never an error). That covers the implementor (`start`,
  `continue_implementor`), the fixer (`fix`), the reviewer (`start_review`, `review`) and
  an agent-backed stage reviewer (`review_stage`), so a card lights up in In Progress, In
  Review and any `Review: <stage>` column alike.
- A provider-backed stage gets no `worktree.sh` call: the manager runs `stage-review.sh`
  instead. So `stage-review.sh` writes the same marker when it starts and removes it on
  exit (an `EXIT` trap).
- The local `comment` verb removes `active/<n>` for role reports only. Every role ends by
  posting its report with `board-comment.sh`. The local adapter recognizes the report format
  with `parse-report.sh`. The manager posts no comment between `worktree.sh` and the
  dispatch. The `note` verb leaves the marker alone: on `start` the manager writes the note
  after `worktree.sh create` and before the dispatch, so a note that cleared the marker
  would leave the implementor's whole first run unlit. A provider stage's report is posted
  the same way and its `EXIT` trap removes the marker on every other exit.
- `fleet-board-run.sh` removes every `<board.dir>/active/*` marker after each tick's
  session exits, whatever the outcome (a failure is a warning), so a
  role that crashed without a report does not stay lit into the next tick.
- The web route always posts ordinary comments, so they leave the card's active marker in place.
- The page shows a card as active only while its marker exists **and** a run is alive. A
  marker left behind by a killed tick stops counting the moment the run is gone. The
  server also deletes every marker when it observes the run go from alive to gone.

## Web server

### Launch

`scripts/board-web.sh [--repo DIR] [--port N]`:

1. `cd` to the repo root, the directory holding the git common dir (as `board-lib.sh`
   resolves `FLEET_ROOT`, so from a linked worktree the page shows the store the scripts
   write), run `config.sh --check`, exit with its code on failure.
2. Refuse (exit 1) when `python3` is not on `PATH`, naming it.
3. `exec python3 "$HERE/board-web.py" --root <root> --port <port> --scripts "$HERE"`.

It runs in the foreground; Ctrl-C stops the page, never the fleet. It lives in the same
directory as `fleet-board-run.sh`, whose absolute path `/fleet-board:status` prints on its
last line (that line comes from the clean-room status skill and must stay last), so the
docs say "the `board-web.sh` beside the wrapper" and never write down an install path.

### Process

`scripts/board-web.py`: one file, Python 3.9+ standard library only (`http.server`,
`json`, `subprocess`, `pathlib`, `threading`). `ThreadingHTTPServer` bound to `127.0.0.1`
on `board.port` (default 8765; `--port` overrides). Static files are served from
`scripts/board-web/static/` (`index.html`, `board.css`, `board.js`). The server never
imports anything outside the standard library and never fetches anything from the network.

Every request must carry `Host: 127.0.0.1:<port>` or `Host: localhost:<port>` (the bound
port); any other Host is 403, reads included, so a page on a name that resolves to
127.0.0.1 (DNS rebinding) cannot read the board. Mutating requests (`POST`, `PATCH`) must
also carry the header `X-Fleet-Board: 1` and an `Origin` equal to the server's own origin
(or no `Origin`, for curl); otherwise 403. This stops a page in another tab from driving
the board.

### API

Reads go straight to the store files. Writes run the same script an agent would, with
`cwd` = repo root, and return the script's stderr on a non-zero exit.

| Method and path | Does | Backed by |
|---|---|---|
| `GET /api/board` | `{states: [{key, name}], cards: [{number, title, state, labels, note: {round, pr, models, stage, action_failures}, active, updated_at}], run: <run status>}` | files; state order and names from `config.sh` + `fb_state_name` (one subprocess, cached until the config file's mtime changes) |
| `GET /api/cards/<n>` | the full card: body, comments, the manager note body, `url` of the PR when the note has `pr` | file |
| `POST /api/cards` `{title, body, labels, state?}` | create; `state` defaults to backlog. Always created in backlog and then moved, so `state: ready` obeys the Acceptance rule; a refused move is `409` naming the created card | `board-create.sh`, then `board-move.sh` when `state` is not backlog |
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

- **Run lock.** `fleet-board-run.sh` holds `<LOG_DIR>/<owner>-<name>.lock` (`LOG_DIR` =
  `$FLEET_BOARD_LOG_DIR`, else `$HOME/.fleet-board/runs`) for its whole life, holding the
  same two lines as `run.pid` (the pid, then `ps -o lstart=` under `LC_ALL=C TZ=UTC`). It
  refuses to start (exit 1, `another run holds <lock> (pid N)`) while the lock names a live
  pid with that start time, and removes the lock in its `EXIT` trap. The server computes the
  same path and treats a live lock as an alive run, so a wrapper started from a terminal or
  launchd is seen: Start is refused, Stop works, status shows its pid.
- **Start** refuses (409, naming the pid) when a run is alive (its own `run.pid` or the run
  lock). Otherwise it removes a leftover
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
  A run alive only through the run lock reports the lock's pid and nothing from `run.out`,
  which describes an older run. When a stopped run's `run.out` has no `stopped:` line (the
  wrapper exited at once, for example a config error or the run lock), status carries
  `out_tail`, the first and last lines of `run.out` (at most 20), which the page shows in
  the pill's title and the log panel.
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
5. `import-plan.sh` creates cards: create through `board-create.sh` with the
   card's labels and `FB_CREATE_STATE=<status>`, print `Created #N`. The card linter runs
   (card fields from the plan's acceptance and dependencies).

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
  dot, in whichever column it sits: an implementor on an In Progress card, a reviewer on an
  In Review card, a stage reviewer (agent or provider) on a `Review: <stage>` card, and a
  fixer on an In Review card during a `fix` action all light the card.
- Cards drag between columns (HTML5 drag and drop). There is no per-card move menu;
  keyboard users change a card's state from the state select in its drawer. A refused move
  (for example to Ready without `## Acceptance`) shows the script's message and the card
  snaps back.
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

As built, after the local-only revision (2026-11-07). The first version of this table
added `local` beside the GitHub backends; those are gone.

| File | Change |
|---|---|
| `scripts/config.sh` | keys `board.dir` (string, default `.fleet-board`, relative to the repo root, no `..`, not absolute) and `board.port` (integer 1024-65535, default 8765); `board.repo` stays required. `board.backend`, `board.project_number` and `board.project_owner` are removed: `config.sh` exits 5 naming each, and pointing at `import-github.sh` |
| `scripts/config-defaults.json` | the two keys above; no `backend` |
| `scripts/board-lib.sh` | `fb_default_name`: `Backlog`, `Ready`, `In Progress`, `In Review`, `Human QA`, `Blocked`, `Done`, `Won't Do` and `Review: <stage>`; `fb_login` local identity; `fb_card_has_acceptance` |
| `scripts/adapters/` | only `local/`; the `github-labels` and `github-projects` adapters, `cards.sh` and `migrate-to-local.sh` are deleted |
| `scripts/init.sh` | no `--backend`: writes the config, creates `board.dir` and `cards/`, writes `next`, adds `<board.dir>/` to `.gitignore` when not already ignored, keeps the `gh` scope check (PRs) |
| `scripts/import-github.sh` | new, read only: copies a GitHub labels board, or a Projects board with `--project N [--owner LOGIN]`, into the store (`--repo`, `--dry-run`, `--force`) |
| `scripts/migrate-card-fields.sh` | new: moves an older local store's `## Acceptance` and `## Depends on` body sections into the card fields, and `pr_url` from the manager note |
| `scripts/review-stages.sh` | `setup`: nothing to create, exit 0; `route` adds a stage label with `adapters/local/label.sh` |
| `scripts/file-followups.sh` | duplicates found with `fl_find_title`; follow-up cards created with an `acceptance` field and `blocked_by`; comments through `board-comment.sh`; PR comments stay on GitHub |
| `scripts/verify-main.sh` | the open P0 card found with `fl_find_title` |
| `scripts/lint.sh`, `scripts/card-lint.sh`, `scripts/deps.sh`, `scripts/tick-plan.sh`, `scripts/status.sh`, `scripts/human-qa-handoff.sh`, `hooks/gate.sh` | read `acceptance` and `blocked_by` from the card; a blocker is a card on this board (met when Done) |
| `scripts/fleet-board-run.sh` | the run lock; clears `active/*` after each tick's session |
| `scripts/import-plan.sh` | creates local cards, acceptance and blockers as fields |
| `scripts/worktree.sh`, `scripts/stage-review.sh`, `adapters/local/comment.sh` | the active marker |
| `skills/import-plan/SKILL.md`, `skills/init/SKILL.md`, `skills/lint/SKILL.md` | `--preview`; local-only setup and the optional GitHub import; card fields |
| `README.md`, `docs/config.md`, `docs/overnight.md`, `docs/gates.md` | local-only setup, card fields, migration and import, upgrade order, the run lock, the gate residuals (raw writes into `board.dir`; `curl` against the page's API) |
| `plugins/fleet-board/CLAUDE.md` | the local store contract; the active-marker contract |
| `docs/design.md` | the local-only, first-class-fields tradeoff |
| `.claude-plugin/plugin.json`, `marketplace.json` | 0.13.0 for the local backend; 0.16.0 for the local-only revision |

The clean-room files (`agents/*.md`, `skills/{reporting,tick,run,status}/SKILL.md`) were
re-authored in the local-only revision to read the card's fields (Revision 23 in `specs/README.md`).

## Residuals and known limitations

- **Gate.** Raw writes into `board.dir` (`jq ... > .fleet-board/cards/3.json`, `mv`,
  `sed -i`) bypass the gate, which is a text check on board commands. Listed in
  `docs/gates.md` as a residual, not claimed as covered. So is `curl` against the page's
  API while the page runs (for example `POST /api/cards/<n>/move` out of Human QA): the
  gate classifies `curl` only against the GitHub API.
- **Role prompts.** Resolved: the re-authored role prompts read `board-read.sh <n>` and no longer cite `gh issue view`.
- **Trust boundary.** The note's author check is a filesystem boundary, not a login.
- **PRs still cost GitHub calls.** A tick still reads PR state for every in-flight card.

## Error handling

- Adapter: unparsable card file fails `read` (exit 1) and the whole `list` (exit 1,
  naming the file); a missing store exits 1 saying to run `/fleet-board:init`; lock
  timeouts as today (`FLEET_BOARD_LOCK_WAIT`).
- Server: port in use is one line, `board-web: port N is in use` (exit 1, no traceback);
  `board-web.sh --port` outside 1024-65535 is a usage error (exit 2); a wrapper that exits
  at once shows `stopped` with its output (`out_tail`); a pid file whose
  process is gone is `stopped` or `idle` as above; a failed import shows its error and
  creates nothing; a request body that is not JSON or lacks a required field is 400.
- Concurrency: the page's edit helper and the agents' comment and note writes all take the
  per-card lock; the page never writes a card file directly.

## Testing

Plain-bash suites under `plugins/fleet-board/tests/`, each proven able to fail before it
is trusted (break the script, watch the assertion fail, restore it):

- `test-board-local.sh`: the six verbs and `edit` against a temp repo; the Ready refusal;
  atomic write (a reader during a write sees old or new, never partial); eight concurrent
  `comment` calls lose nothing; `note` replaces rather than appends; report comments clear the
  active marker, and ordinary comments and notes leave it; `list` fails closed on a corrupt file; `fb_login` with and without
  `FLEET_BOARD_USER`.
- `test-config.sh`, `test-init.sh`, `test-gate.sh`, `test-deps.sh`, `test-import-plan.sh`,
  `test-review-stages.sh`, `test-worktree.sh`, `test-stage-review.sh`: new `local` cases.
- `test-board-web.sh`: starts `board-web.py` on a free port against a temp repo with the
  local store and drives the API with `curl`: board JSON with state order, create, edit,
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
migration of existing GitHub cards to the local store (added later as the read-only `import-github.sh`), and any change to the clean-room
role prompts.
