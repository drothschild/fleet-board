# Epics and the Architect: design

Date: 2026-11-18
Status: approved by the owner on 2026-11-18
Build: hybrid. Cards 3, 7 and 8 of the split and the `premise-settle.sh` part of 10b are
built by hand in a session; the other cards go to the board.
Source: plan card #464, the operator session retro of 2026-11-15 (section 3), and a
brainstorm with the owner on 2026-11-18
Related: `docs/specs/2026-11-15-card-premise-check-design.md` (cards #470 to #478; #476 is
in review, #477 blocked and #478 in Ready as of this date),
`docs/specs/2026-11-13-stacked-prs-design.md`, `docs/specs/2026-11-14-multi-repo-board-design.md`

Lines marked **(My call)** are decisions the author made, not the owner. Everything else in
"Design" was decided by the owner in the brainstorm.

## Intent

A change that takes two or more cards has no home today. The board page's chat produces a
plan and its cards, and after that:

- nothing shows the cards of one change together, with their pull requests, order and state;
- the design that the cards were cut from is a file under `docs/specs/` that goes stale as
  the cards are built (#286, #287 and #288 were written against decisions #285, #382 and
  #397 had already changed);
- the conversation that produced the plan is lost when the chat closes, so changing the plan
  later starts from nothing.

The owner wants one record per multi-card change, called an **epic**, that:

1. keeps track of and organizes the cards and pull requests that make up the change;
2. holds a design doc that stays true as the children merge;
3. keeps the conversation that shaped the change, so the owner can return to it to discuss
   changes to the plan and see which cards need changing, see where this epic sits among the
   other epics, and compile a progress report.

The owner also wants the chat itself improved: it can show sample layouts and drawn graphics
while a change is being shaped, it can read pictures the owner attaches, its replies render
as formatted markdown, and it gets a name that does not collide with "the planner", which
in this codebase also means the scheduler in `scripts/tick-plan.sh`.

Catching stale cards is **not** the epic's purpose. #464 was written with that purpose, and
the premise check has since taken it over. The epic feeds the premise check; it does not
replace it.

## Goals

- Every card of a multi-card change links to one epic, and the epic shows each child with
  its state, pull request, dependencies and stacking.
- The epic's design is revised when each child merges, by a session, with no person
  involved. The epic's intent is changed only by the owner.
- Every merge leaves an as-built entry on the epic: what the child built, the decisions it
  made, and where it departed from the design.
- The conversation that produced an epic is kept with it and can be reopened at any time,
  with the epic's current doc, children and as-built log in front of the session.
- From that conversation the owner can get proposed rewrites for the cards a plan change
  touches, each one to approve or reject, and can create new cards in the epic.
- The owner can see every open epic, its progress, and where two epics touch the same files
  or wait on each other.
- A progress report for an epic can be produced on request.
- The chat can produce sample layouts (HTML and CSS) and drawn graphics (SVG), and can read
  images the owner attaches.
- Chat replies render as formatted markdown.
- The chat role is called the Architect everywhere a person or a config file sees it.
- When an epic finishes, its doc is merged into the repository as one pull request.

## Non-goals

- Detecting stale cards. The premise check does that.
- Nested epics, or a card that belongs to more than one epic.
- Syncing epics to GitHub milestones, projects or issues.
- Painted or photographic images. Neither Claude nor codex produces them.
- Keeping the epic's doc in git while the work is in flight (approach C below).
- Making an epic required. A single card with no epic works exactly as it does today.
- Building the multi-repo board. An epic records a home repository so that design is not
  blocked, and nothing more.

## Anti-goals

These would make the work a failure even if it runs:

- A session changes the epic's intent, or a card's Scope or acceptance, without the owner
  seeing and approving it.
- A card that merged cannot reach Done because the epic's record step failed.
- The record step costs more than a premise check does. The measure is the usage ledger:
  the median tokens of `record_epic` lines should not exceed the median of `check_premise`
  lines. This is watched in `supervisor usage`, not asserted by a test. **(My call.)**
- A sample layout the Architect wrote can call the board's API or read the board page.
- The design doc is revised by hand in practice because the automatic revision is not
  trusted. (A doc kept by hand is the thing that went stale.)

## Constraints

- `agents/*.md` files are clean-room authored. This design adds no file there. New session
  prompts are templates under `scripts/supervisor/defaults/`, as the premise check's is.
- The supervisor runs under no permission rules and must never execute text a session or a
  card supplies.
- Scripts run under `/bin/bash` 3.2 with BSD and GNU tools.
- The scheduler is one jq decision table in `scripts/tick-plan.sh`, tested by the seven
  `tests/test-tick-plan-*.sh` scenario suites. A new action belongs in that table. The
  table's general rule moves a card to Blocked when its `action_failures` reach the limit,
  and a card in Human QA or Done is not planned at all today.
- `hooks/gate.sh` rule G4 stops a Claude session from running `premise-settle.sh approve`,
  `confirm` or `reject`. Any new command that approves something on the owner's behalf needs
  the same rule.
- The usage ledger rejects a line with keys outside `usage.py`'s fixed `KEYS`, and accepts
  only the kinds in `KINDS`.
- The board server binds 127.0.0.1 and checks the Host header on every request. It requires
  the `X-Fleet-Board: 1` header and a local Origin on POST and PATCH only: GET is checked
  for Host alone, and PUT and DELETE are dispatched with no header or Origin check. It
  serves only `.html`, `.css` and `.js` today, parses every POST and PATCH body as JSON
  with a 1 MiB cap, and sets no Content-Security-Policy.
- Multi-repo is partly built. A card has a `repo` field checked against `board.repos`, the
  scheduler reads another repository's pull requests and config, and Scope reservations are
  per repository. The driver still works only in the home repository.
- The codex chat runs read-only and returns only its reply, so it cannot write files.

## Approaches

Three were considered for where an epic lives.

**A. A record of its own in the board's store.** A folder per epic beside the cards holds
the record, the design doc, the as-built log, and the samples and attachments. Cards gain an
`epic` field. Revising the doc at a merge is a file write. It spans repositories. The doc is
not in git.

**B. A card with a kind.** An epic is a card marked `epic`. It gets a number, comments and a
place on the board for free. Every reader of cards (the Ready gate, the scheduler's table,
lint, the premise check) must learn to skip it, and intent, design, log and samples fit
badly in one card body.

**C. The doc in the repository, the record in the store.** The doc is versioned and
reviewable. Every merge then needs a second change to the default branch, two children
merging close together conflict on one file, and a multi-repo epic has no natural home.

**The owner picked A with one piece of C:** the epic lives in the store while the work is in
flight, and its doc is merged into the repository once, at the end. B fails on fit. C makes
every merge slower to keep a file in git that nobody reads until the end.

## Design

### 1. The epic record

An epic is a folder in the board's store, `<board.dir>/epics/<id>/`:

| File | Holds |
|---|---|
| `epic.json` | `id`, `title`, `state`, `repo`, `intent`, `design_rev`, `conversation`, `attention`, `created_at`, `updated_at`, `exported` |
| `design.md` | the current design |
| `revisions/<rev>.md` | every earlier design, one file per revision |
| `log.jsonl` | the as-built log, one line per merged child |
| `conversation/` | the Architect conversation (section 3) |
| `samples/<sid>/` | one sample layout or graphic, with a `meta.json` |
| `attachments/` | images the owner attached |

- `id` comes from a counter of its own, `<board.dir>/epics/next`, allocated the way card
  numbers are. An epic is shown as `E<id>` so it never reads as a card number. **(My call.)**
- `state` is `open`, `complete` or `closed`. Only `open` and `closed` are stored;
  `complete` is worked out each time the epic is read, so it cannot go stale. (Settled in
  the plan.) It becomes `complete` when the epic has at
  least one child, every child is in Done or Won't do, and every merged child has a log
  line (section 2). The owner can close an epic at any time. A new child reopens a complete
  epic. **(My call.)**
- `intent` is markdown: what the change is for, with its goals, non-goals and anti-goals.
  Only the owner changes it, through the epic page or `epic.sh`. The one way session text
  reaches it is the import preview (section 3), where the owner sees the draft, edits it
  and saves it. After that the Architect may suggest wording in the chat, and only the
  owner's own edit stores it. **(My call.)**
- `repo` is the home repository, defaulting to `board.repo` and checked the way a card's
  `repo` is.
- `attention` is a list of `{reason, card, at}`. Section 2 adds to it. The owner clears an
  entry from the epic page. **(My call.)**
- The epic does not list its children. A child is any card whose `epic` field is this id, so
  the two cannot disagree. **(My call.)**
- Writes to an epic take a lock per epic, built on `fb_lock_acquire`.

**The card field.** A card gains `epic`: an epic id or null. `board-create.sh --epic`,
`adapters/local/edit.sh --epic` and `import-plan.sh` set it, validated against the epics
that exist. `board-read.sh` returns it. Setting or changing it does not stamp the card.

**The script.** One script, `scripts/epic.sh`, owns the folder: `create`, `read`, `list`,
`set-intent`, `set-state`, `clear-attention`, `record` (section 2), `approve-design`
(section 4), `choose-sample` (section 7), `report` (section 6) and `export` (section 8).
The board server reads epic files directly and writes only through this script, as it does
for cards.

The plans add three more verbs: `pending` (merged children not yet recorded), `fail` (the
record's failure counter) and `relations` (section 6).

The gate refuses every verb except the read-only ones (`read`, `list`, `pending`, `report`,
`relations`) inside a Claude session, the
way rule G4 refuses the premise approvals. The supervisor and the board server are not
sessions, so they can run them. Without this, any role with a shell could rewrite the
design its siblings are given. **(My call.)**

### 2. The doc is revised at each merge

When a card with an `epic` has merged and reached Done, the scheduler plans a new action,
`record_epic`, for it.

- **When.** For a card in Done that has an `epic`, a merged pull request, and no line for
  it in the epic's log. The log is the one record of what has been recorded; the card's
  note holds nothing for this, so the scheduler reads no Done card's note. A Done child
  whose pull request was closed without merging gets a `skipped` log line and no session.
  The step can be turned off with `epics.record`. (Settled in the plan.) The record runs after the card is finished, so it
  never sits between a merge and its after-merge steps and never holds the merge lane. It
  also covers a child that a person merged from Human QA or moved to Done by hand, which
  the merged rows of the table never see. This is a new set of cards for the scheduler to
  read, since Done cards are not planned today. **(My call. An earlier draft put the record
  before `after_merge`; the loop starts after-merge work directly when a merge ends, so a
  row in front of it would race it.)**
- **One at a time.** At most one `record_epic` runs per epic, so two children that merge
  together are recorded in turn and the second sees the first's revision. It takes one slot
  and reserves no Scope. **(My call.)**
- **The session.** Headless, on a detached checkout of the default branch that it does not
  change, like the premise check. The role is `architect`, mode `record`. The model comes
  from a new key, `models.architect_record`, default `sonnet`. **(My call.)** The prompt
  template is `scripts/supervisor/defaults/epic-record-prompt.md`.
- **What it is given.** The card, its role reports (the implementor, fixer and reviewer
  comments), the merged pull request and merge commit, the epic's intent, current design and
  as-built log, and the epic's children that have no pull request yet, with their Scope and
  acceptance. It is also given the path of one file to write a revised design to.
- **What it returns.** One fixed-shape report, checked by `parse-report.sh --role architect
  --mode record` and posted on the card. It keeps the sections every role report has
  (`## Findings`, `## For the card`, one `VERIFIED:` line) and adds:

| Section | Content |
|---|---|
| `## Status` | `recorded` or `no_change` |
| `## Built` | a short account of what the child built |
| `## Decisions` | decisions the child made that its siblings rely on |
| `## Departures` | where the child departed from the design, or `none` |
| `## Design` | `revised` or `unchanged` |
| `## Intent` | `holds`, or one paragraph on how what was built contradicts the intent |
| `## Affects` | numbers of sibling cards whose Scope or acceptance the decisions or departures contradict, or `none` |

  The revised design itself goes in the file, not in the report. A design has its own `## `
  headings, which the report parser would read as sections, and the whole design would
  otherwise be posted as a card comment at every merge. `revised` with a missing or empty
  file is a rejected report. **(My call.)**
- **What the supervisor does with it.** Under the epic's lock, `epic.sh record` appends one
  line to `log.jsonl` (`card`, `pr`, `merge_commit`, `at`, `built`, `decisions`,
  `departures`, `design_rev`). With `revised`, the current `design.md` is copied to
  `revisions/`, the new one is written and `design_rev` goes up by one. The log line and
  the design are written together or not at all, and the write is refused when the design
  revision moved while the session ran. Anything other than `holds` under `## Intent` adds
  an `attention` entry to the epic.
- **Affected siblings.** Each card named under `## Affects` that is a child of the same epic
  and has no pull request yet has its premise stamp cleared and is marked for a recheck,
  so the premise check runs before it starts. A person moving a marked Backlog card into
  Ready does not re-stamp it (today `move.sh` re-stamps every such move); the premise
  check removes the mark when it stamps the card. A person's edit of the marked card does
  not re-stamp it either, and every stamp write (a `go` verdict, an approved proposal)
  removes the mark. The mark is the owner's decision of
  2026-11-25. This covers a decision that is not visible in the files a card names.
  **(My call.)**
- **Failure.** A failed or rejected session counts on a counter of its own, kept in the
  epic's folder, not on `action_failures`, whose limit would move a Done card to Blocked.
  After three failures the supervisor appends a log line marked `unrecorded` with the card
  and pull request and adds an `attention` entry to the epic; the log line is what stops
  the record being planned again. The card stays in Done throughout. **(My call.)**

The session never changes the intent. If what was built contradicts the intent, it says so
under `## Intent` and the epic is flagged for the owner.

### 3. The Architect and its conversations

**The name.** The chat role is renamed from Planner to **Architect** everywhere a person or
a config file meets it: the page, the README, `skills/planner/` (to `skills/architect/`),
the `planner.*` config keys (to `architect.*`), the `/api/planner` routes, the ledger kind,
and the tests named for the chat. "Planner" keeps one meaning afterwards: the scheduler.

- An existing `.fleet-board.yml` keeps working: `planner.*` keys are read when `architect.*`
  is absent, with a warning. **(My call.)**
- The usage ledger accepts both kinds and reports old `planner` lines under the Architect's
  total. Old lines are not rewritten. **(My call.)**
- The premise check's prompt section "Planner's working rules" becomes "Card-writing rules".
  The driver reads the persona file by path for that section and treats a missing file as
  no rules, so the rename must move that path in the same change or the premise check
  silently loses its rules.
- Below the visible surface the rename also covers: the `planner` key in `/api/supervisor`,
  `/api/usage` and the usage summary; the `planner:` line of `supervisor usage`; the state
  directory `planner/` (new conversations go under `architect/`, old folders are left
  where they are); `FLEET_BOARD_TEST_PLANNER_ID` (the old name is still read); and the
  `test-board-planner-*` and `test-planner-*` suites. **(My call.)**

**Conversations persist.** A conversation is kept until the owner deletes it, and the page
lists them: conversations attached to an epic are opened from that epic, and conversations
with no epic yet appear in the Architect panel.

- A conversation starts where it does today, under the board server's state directory.
- "Draft cards" works as it does today, with two changes: the import carries the
  conversation's id, and the preview offers an epic. When the import will create two or more
  cards, the preview shows a proposed epic title, intent and design, drafted by the import
  session from the conversation. The owner edits them there. Creating the cards creates the
  epic, sets `epic` on each card, and moves the conversation into the epic's
  `conversation/` folder. The owner can untick the epic and create plain cards. **(My
  call.)**
- A conversation opened from an existing epic can draft more cards into that epic.
- An import from the board page's import form, without a conversation, offers an epic the
  same way and leaves its `conversation` empty. The owner can start one from the epic page
  later.
- The `/fleet-board:import-plan` skill runs in a Claude session, where G5 blocks
  `epic.sh create`, so it never makes an epic. It attaches cards only to an epic that
  already exists, by id; to start one, it tells the owner to make it on the board page or
  in a terminal first. The owner's decision of 2026-11-25.
- The epics list has a New epic control that makes an empty epic from a title and an
  intent, and the card drawer can set or clear a card's epic. That is how existing cards
  are gathered into one. **(My call.)**
- A turn resumes the stored session. When the provider no longer has that session, the
  server starts a new one and gives it the stored transcript, so a conversation survives
  whatever the provider keeps. **(My call.)**

**What a turn is given.** Today every turn gets the whole board as JSON. A turn in an epic's
conversation also gets:

- the epic's intent, current design and as-built log;
- each child with its state, pull request, Scope, acceptance, dependencies, stack parent and
  any open proposal;
- for every other open epic: its title, the first paragraph of its intent, the Scope paths
  of its children that are not Done, and any dependency between a child of that epic and a
  child of this one.

That is what lets the Architect say which cards a plan change touches and where this epic
sits among the others.

**Replies render as markdown.** Assistant turns are rendered with the `md()` function that
card comments already use. User turns stay plain text. HTML in a reply stays literal text,
as it does in comments.

### 4. Changing the plan from the conversation

The Architect still edits no card. It proposes, and the owner approves.

- **How a session hands something back.** A session may write only into its conversation's
  `outbox/` folder, the same narrow allowance the import preview already has for its own
  folder. After a turn the server reads the outbox, validates each file, files it, and
  empties the folder. Anything it does not recognise is dropped and named in the turn.
  **(My call. In the brainstorm I said writes would stay denied and the session would return
  content in its reply. An outbox is sturdier for whole HTML files and is a pattern the
  import already uses.)**
- **Card rewrites.** The Architect writes one proposal per card: a full Scope and
  acceptance and a paragraph on why. The server stores it as the card's `proposal`, kind
  `rewrite`, with a new key `source: architect` and `head` set to the default branch's
  head at that moment. It records the column the card was in as the proposal's `from` (not the note's
  `blocked_from`, which `note.sh` limits to supervisor states) and moves the card to Blocked, as a premise-check question does, so the supervisor cannot start the
  card while the proposal waits. All of this is **(my call)** and needs
  `premise-settle.sh` changed, since today `propose` drops unknown keys and `approve`
  always moves the card to Ready:
  - `propose` keeps `source`.
  - `approve` on a proposal with `source: architect` returns the card to the proposal's `from`,
    so a Backlog card goes back to Backlog. A premise-check proposal still goes to Ready.
  - The owner approves or rejects. There is no edit of a proposal, here or for the premise
    check. To change one, the owner asks the Architect for a revised proposal, which
    replaces it, or rejects it and edits the card by hand.
  - A card in Backlog or Ready can get a proposal.
  - A card that already holds a premise-check proposal cannot. The Architect is told, and
    the owner settles that one first.
  - A card with a pull request cannot. The Architect says so and names the card, and the
    owner decides what to do with work already in flight.
- **New cards.** The owner can create a card from inside the conversation, without leaving
  it for the import. When the owner asks for a card, or the Architect sees that a plan
  change needs one, the Architect writes a card draft to the outbox: title, why, Scope,
  acceptance, dependencies and labels, and any samples it links to.
  - The chat shows the draft as a card preview with the fields editable in place, a choice
    of Backlog or Ready, and a Create button. Several drafts in one turn are shown
    together, each with its own button, and a Create all.
  - Create runs the same checks the import runs (the card linter and the Scope path check)
    and then `board-create.sh` with the conversation's epic. The new card is stamped as any
    created card is. A draft that fails a check shows the reason beside it and creates
    nothing.
  - The created card's number is written back into the conversation, so later turns can
    refer to it and depend on it.
  - The Architect still creates nothing itself. The owner's click is the creation. **(My
    call. It keeps the rule that the fleet does not make its own work without the owner
    seeing it.)**
  - A conversation that produces a single card has no epic: the preview creates a plain
    card. The owner confirmed this.
  - When a conversation with no epic creates its second card this way, the chat offers to
    make an epic of the cards it has created, with a title, intent and design drafted for
    the owner to edit, as the import preview does. The owner can decline and keep plain
    cards. **(My call.)**
  - "Draft cards" stays for turning a whole conversation into a plan of several cards at
    once, which is also what creates an epic (section 3).
- **Design changes.** The Architect writes a proposed design. The chat shows it with what
  changed and an Approve button. Approving runs `epic.sh approve-design`, which makes it
  the next revision. **(My call.)**
- **Closing a card** the plan no longer needs is the owner's move on the board. The
  Architect names the card and the reason.

### 5. The epic feeds the premise check and the roles

- The premise check session for a child card is also given the epic's intent, current
  design and as-built log. A `stale` rewrite then keeps to what the plan is for.
- The implementor, reviewer and fixer prompts for a child card gain one section, `Epic`,
  with the intent, the current design and the paths of any samples the card links to
  (section 7). The section is added where the supervisor builds the prompt. No file under
  `agents/` changes. **(My call. The risk is that the clean-room agent files do not mention
  the section and a role ignores it. Verify this behaviourally; if roles ignore it,
  re-authoring those files is a separate decision with its own spend.)**

### 6. Progress, other epics and the report

**Progress** is computed from the children each time and never stored. A child is one of:

| Shown as | Card state |
|---|---|
| waiting | Backlog, or Ready with an unmet dependency |
| ready | Ready with nothing unmet |
| in flight | In Progress, In Review, a review stage, Merging, Human QA |
| blocked | Blocked, including one waiting on a proposal |
| done | Done |
| dropped | Won't do |

**Other epics.** Two open epics **touch** when a child of each that is not Done names
overlapping Scope paths in the same repository, using the overlap rule the scheduler
already has. Pull request links in the list, the report and the export use each card's own
repository. One epic **waits
on** another when a child's `blocked_by` names a card of the other. Both are computed, shown
on the epics list and the epic page, and given to the Architect.

**The report.** `epic.sh report <id>` prints markdown with no session: the intent's first
paragraph, a count per progress state, each child with its state and pull request link,
what is blocked and on what, the departures from the as-built log, and the epics it touches
or waits on. The epic page has a Report button that shows it. The owner can ask the
Architect to write a narrative around it in the conversation. **(My call: the figures come
from a script so a report cannot misstate them.)**

### 7. Samples and attachments

**Samples.** While a change with a visible side is being shaped, the Architect can write
sample layouts (one HTML file with its CSS inline) and drawn graphics (SVG) to its outbox.

- The chat shows each sample as a link that opens it in a new tab. Several samples in one
  turn are shown together as options.
- The owner marks one as chosen. Chosen samples appear on the epic page. The others stay in
  the conversation.
- Each sample's `meta.json` records its title, when it was made and the commit of the
  default branch at that time.
- A card can link to samples of its epic through a new field, `samples`, a list of sample
  ids. The import preview and the card editor set it, and section 5 carries the paths to
  the roles. **(My call.)**
- A conversation with no epic yet keeps its samples in its own folder. They move with it
  when the epic is created.

**Serving a sample.** Samples are served from their own route with
`Content-Security-Policy: sandbox allow-scripts` and a policy that allows inline style and
script, `data:` images, and no network requests. The sandbox gives the sample an opaque
origin and no network, so it can neither read the board page nor call the API. That
protection is the policy and the sandbox alone: the server checks Origin only on POST and
PATCH, so a GET from a sample would not be refused by it. As part of this work the server
applies the header and Origin check to PUT and DELETE as well, and deleting a conversation
uses a checked method. **(My call.)** The server's content types grow to cover `.svg`,
`.png`, `.jpg`, `.webp` and `.gif`.

**Attachments.** The owner can attach images to a turn: PNG, JPEG, WebP or GIF, up to 5 MiB
each, sent as raw bytes to a new route with the same Host, Origin and header checks as other
writes. **(My call on the types and the limit.)** The server's dispatcher parses every body
as JSON under a 1 MiB cap today, so this route needs its own body handling. The file is
stored with the conversation, the turn's prompt names its path, and the session's read
allowance is widened to that one folder.

**Providers.** Everything that comes back through the outbox (card drafts, card rewrites,
design proposals and samples) and attachments are built for the Claude provider, because the codex
chat cannot write files. A codex Architect keeps the conversation, the epic context and
Draft cards, and the page hides the other controls and says why. **(My call.)**

### 8. Export at the end

When an epic becomes `complete`, the epic page offers **Export doc**. The owner can also run
it earlier.

- `epic.sh export <id>` is plain git and `gh`, with no session. It makes a branch from the
  default branch of the epic's home repository, writes one file,
  `<epics.export_dir>/<date>-<slug>.md` (default `docs/epics`), and opens a pull request.
- The file holds the intent, the final design, the as-built log, each child with its pull
  request link, and the chosen samples, which are copied beside it.
- The pull request's URL is stored in `epic.json` as `exported`. Exporting again updates the
  same branch.
- The export has no card. The owner reviews and merges the pull request. **(My call. The
  alternative is a card that carries the export through the fleet's review, which spends
  review sessions on a generated document.)**
- A session cannot run `export`; the gate refuses it like the other owner-only commands.
  **(My call.)**

### 9. The board page

- **Epics list** (`/epics`): each open epic with its title, a progress bar by state, an
  attention flag, and the epics it touches or waits on. Complete and closed epics sit behind
  a toggle. A New epic control sits here.
- **Epic page** (`/epics/<id>`): the intent with an Edit control; the design, rendered, with
  its revision number and a way to read earlier revisions; the children as a table with
  state, pull request, dependencies and stack parent; the as-built log; chosen samples; and
  buttons for the conversation, Report and Export doc.
- **Cards.** A card with an epic shows `E<id>` and its title on the board and in the drawer,
  linking to the epic page. The board can be filtered to one epic.
- **The chat.** Markdown replies, the conversation list, sample links, the attach control,
  and Approve on a proposed design.

### 10. How cards and epics are written

The owner decided this on 2026-11-18, after the design was approved.

An epic is written `E<id>` and a card `C<n>`, so `#<n>` alone always means a pull request.
This is scoped to what a person reads and types:

- **Shown as `C<n>`** on the board page, in `fleet-board status`, and in every string the
  epics work adds (the epic page, the report, the export, the Architect's chat, new plan
  reasons, events and errors).
- **Accepted in both forms** wherever a person, the Architect or a role writes a card
  reference that a script reads: a `## Depends on` bullet, a report's `## Card` or
  `## Affects` section, the page's dependency editor.
- **Unchanged underneath.** Stored comments and role reports keep the text they were
  written with, and the page shows a comment as written, because inside free text a card
  cannot be told from a pull request. Branch names, JSON, the gate's messages, the strings
  the supervisor already writes, and the clean-room files keep `#<n>`.

A full rename was considered and set aside: 40 scripts write the old form, 127 test and
fixture files assert on it, and five clean-room files use it and could only be changed by
re-authoring them.

### 11. Status and docs

`fleet-board status` gains a short epics section: each open epic with its counts. The README
and `plugins/fleet-board/docs/config.md` document epics, the Architect, the new config keys and the renamed
ones. The plugin's `CLAUDE.md` gains the epic record's contract.

## Suggested split

The rename and the markdown rendering do not depend on epics and can go first.

| # | Card | Needs |
|---|---|---|
| 1 | Rename the chat role to Architect | |
| 2 | Chat replies render as markdown | |
| 3 | The epic record, `epic.sh`, and the card's `epic` field | |
| 4 | Conversations persist and are listed | 1 |
| 5 | Draft cards creates an epic and attaches the conversation | 3, 4 |
| 6 | Board page: epics list, epic page, card links, progress | 3 |
| 7 | `record_epic` for a merged child in Done: scheduler row, session, report, log and revision | 3 |
| 8 | Affected siblings are re-checked; the premise check and roles receive the epic | 7 |
| 9 | An epic's conversation is given the epic and the other epics | 5, 7 |
| 10 | The outbox, and new cards created from the conversation | 9 |
| 10b | Card rewrite proposals and design proposals | 10 |
| 11 | Touches and waits-on between epics; the report | 6 |
| 12 | Samples: outbox files, sandboxed serving, chosen, the card's `samples` field | 10 |
| 13 | Attachments | 4 |
| 14 | Export at the end | 6, 7 |
| 15 | Status and docs | all |

## Left to the builder

- Function and file layout inside `epic.sh`, and whether it needs an adapter file under
  `scripts/adapters/local/`.
- The exact outbox file names and shapes, provided each kind is validated before it is
  filed.
- The exact wording of the record prompt and the import session's epic draft.
- How the epic page and epics list are laid out. The owner should see a sample before the
  page is built.
- How the conversation list is ordered and how a conversation is deleted.

## Open

- #476 (the board page's Approve and Close buttons for a proposal) is in review, #477 is
  blocked and #478 is in Ready. Card 10b builds on the proposal buttons, so it waits for
  #476.
