# Card premise check: design

Date: 2026-11-15
Status: draft, awaiting the owner's approval
Source: brainstorm from `docs/retros/2026-11-15-operator-session-learnings.md` (sections 3 and 4)
Related cards: #464 (epics, a separate design), #469 (follow-up drafting, covered here)

## Intent

The owner wants to start the supervisor with a dozen Ready cards, leave for four hours, and
come back to most cards merged and the rest blocked with a clear question. Today that fails
because cards block at unpredictable moments and each block needs a person to investigate
before they can answer.

Roles have posted about 90 blocked reports over the board's history. About 40 of them were
knowable before any session started: the card asked for something already on main, or
needed code from a pull request that had not merged, or described code that had since
moved. Of the cards that blocked this way, 20 ended in Done and 13 in Won't do. Each one
cost an implementor session and then the owner's time to confirm what the implementor
found.

A worse case leaves no blocked report. #286, #287 and #288 sat in Ready describing a note
shape, a scheduler rule and a test file that no longer existed. An operator caught them by
reading them. An implementor that does not recognise a card as stale builds it against the
wrong assumptions, and that is one source of the long review loops.

Follow-up cards that roles file have the same problem at birth. Eight of them in one day
needed rework or closing: already fixed, a duplicate of work in flight, or one line with no
testable acceptance.

This design checks a card's premise before it starts, and settles what the check finds
without a person wherever that is safe.

## Goals

- A card whose ground has moved since it was written is checked against current main before
  an implementor starts on it.
- A card that only needs another card first gets that dependency and waits, with no person
  involved.
- A card that is already built reaches the owner as a one-step confirmation, with evidence
  the supervisor produced itself.
- A card that needs rewriting reaches the owner as one specific proposal to approve or edit.
- A follow-up a role files becomes a card that could be built as filed, or is closed as a
  duplicate or as already fixed.
- A follow-up that is a demonstrated bug can go to Ready on its own, up to a cap per run. The
  owner can turn that off so every follow-up waits in Backlog.

## Non-goals

- Epics: a home for a plan, its progress and a persistent planner conversation. That is its
  own design (#464). This design should leave room for it and not depend on it.
- Checking cards that already have a pull request. Review covers those.
- Changing the implementor, reviewer or fixer prompts. They are clean-room files and
  re-authoring them costs API spend. The implementor's own "cannot start" rules stay as a
  second line of defence.
- Fitting the board to this repository's own habits. Fleet-board is built with itself, but
  the check must work for projects whose tests, repros and bugs look nothing like these.
- Fixing main going red, review loops, the test-change handoff, or plugin version lag. Each
  is a later design from the same brainstorm.

## Anti-goals

These would make the work a failure even if it runs:

- The fleet closes a card whose intent is unmet because a weak acceptance happened to pass.
- The fleet rewrites what the owner asked for without the owner seeing it.
- The fleet generates its own work with no ceiling.
- The check costs more session time than the blocks it prevents.
- Any card is closed on a session's claim alone.

## Constraints

- `agents/*.md` files are clean-room authored. A new file there needs an isolated authoring
  run and API spend, or a named exception in `clean-room-manifest.txt`.
- The supervisor runs outside any permission rules. It must not run a command that a
  session or a card supplies as free text (see #449 for the same class of hole).
- Scripts run under `/bin/bash` 3.2 with BSD and GNU tools.
- The planner is one jq decision table in `scripts/tick-plan.sh`, tested by six suites under
  `tests/test-tick-plan-*.sh`. A new action belongs in that table and in the suite for its
  area.
- This repository disables some config paths the plugin ships with, and bugs have hidden
  behind them (retro section 6). The premise check must be on in this repository.

## Approaches

Three were considered.

**A. Settle only after an implementor blocks.** A short read-only session runs when an
implementor blocks before a PR exists, and returns a verdict the supervisor acts on. It
costs a session only for the roughly 1 in 5 cards that block. It still pays for the
implementor session that found the problem, and it misses a stale card the implementor
builds anyway.

**B. Check the premise before a card starts.** The same session runs before the first
start. Each card carries the commit it was written or last checked against, and the check
runs only when files the card names have changed on main since then. It catches stale cards
before they are built and wastes no implementor session. It costs a session for every card
whose ground moved, including ones that turn out fine.

**C. Have the implementor report a typed reason.** No new session; the supervisor acts on
the block report. It is the cheapest to run. It needs the clean-room implementor prompt
re-authored, and it closes cards on the word of the session that failed to build them.

**The owner picked B.** It is the only one that stops a stale card being built, and the
commit stamp also covers drift that comes from outside a card's own plan.

## Design

### 1. The stamp

Every card records the commit of the default branch it was last known to agree with, and
when. A card gets a stamp:

- when it is created, by any route (`board-create.sh`, `import-plan.sh`, the board page,
  `file-followups.sh`);
- when a person edits its Scope or acceptance;
- when a person moves it into Ready from any other column. This is how the owner says
  "this card is fine, build it" after disagreeing with a verdict, and how a reopened card
  is taken at the owner's word. (My call.)
- when a premise check returns `go`;
- when the owner approves a proposed rewrite.

A move the supervisor makes never stamps a card.

A card with no stamp (every card that exists today) is treated as needing a check.

### 2. When a check runs

The planner already decides that a Ready card may `start`. Before that, it asks whether the
card's ground has moved: does any file changed on the default branch between the card's
stamp and the current head match a path the card names?

- The paths a card names are its Scope paths, as `tick-plan.sh` already parses them, plus
  any path written in backticks in its acceptance items. The second part is there because
  #408 moved a test file that cards named in acceptance and not in Scope. (My call.)
- No match: the card starts as it does today. No session runs.
- A match, no stamp, or a stamp commit git no longer has: the planner plans a new action,
  `check_premise`, in place of `start`.

This comparison is plain git with no session.

A card that needs a check never starts unchecked. If the session fails or its report is
rejected, the card waits with the reason "premise check failed" and the check is planned
again. Each failure counts toward the card's existing `action_failures` limit; at the limit
the card moves to Blocked with a comment saying the check could not run and that moving the
card back to Ready starts it without one. So a broken check session costs a few retries per
card and then asks a clear question; it neither lets stale cards through nor holds the
board silently. (My call.)

`check_premise` reserves no Scope, like the reviewer actions, and takes one slot.

### 3. The check session

A headless, read-only session on a checkout of the current default branch. It gets the
card, the list of open cards with their pull requests and branches, and the planner
persona's working rules (`skills/planner/references/persona.md`), which already say how a
good card is written.

It posts one fixed-shape report on the card, checked by `parse-report.sh` under a new role,
with exactly one verdict:

| Verdict | Meaning | What the report must carry |
|---|---|---|
| `go` | The card agrees with main and can be built | nothing more |
| `needs` | The card needs code that only an open card will add | that card's number |
| `built` | Every acceptance item already holds on main | for each acceptance item, the command the session ran and what it printed |
| `stale` | The card describes code that has moved, or is partly built | a full proposed Scope and acceptance, and one paragraph on what changed |

The session has a shell on the same footing as the reviewer: the same permission mode and
tool limits, working in a throwaway checkout of the default branch, running whatever it
needs (tests, a repro) and changing nothing. The owner decided this on 2026-11-15. The
reasons:

- a repro or an acceptance check can be any command, and the board must work for projects
  where it is not "run this test file" (an app build, a request to a local server, a
  script);
- a session runs under a permission mode that screens what it executes, and the supervisor
  runs under none, so the session is the more guarded place to run a command a role wrote;
- the commands come from fleet roles that already had a shell, and the session takes no
  outside content and gets no added allow rules, so this is not the #449 case.

The supervisor itself never executes a command taken from a card or a report.

The model comes from a new config key, default `sonnet`. (My call.)

The prompt is a template shipped beside the supervisor's other default prompts, not a file
under `agents/`, so it is not a clean-room primitive. (My call; the alternative is a
clean-room agent file and an authoring run.)

### 4. What the supervisor does with each verdict

**`go`.** Stamp the card at the current head. The next plan starts it.

**`needs #n`.** Accepted only when #n is a card on this board that is on its way to being
built (Ready, In Progress, In Review, a review stage, Merging or Human QA) and does not
itself depend on this card, directly or through other cards. Then add #n to the card's
`blocked_by` and leave the card in Ready, where the existing dependency gate makes it wait.
Post one comment saying so. No person is involved.

Any other #n (Backlog, Blocked, closed, missing, or a cycle) would leave the card waiting
with nobody asked. Handle it as `stale` with no proposal, and name #n and its state in the
question. (My call.)

**`built`.** The fleet never closes a card on its own.

- The report gives a command and its output for every acceptance item: the card moves to
  Blocked with one comment that starts "Waiting for a person: close as already built?" and
  lists each acceptance item with the command run and its result. The owner confirms with
  one command or one button on the board page, which moves the card to Done with a label
  marking it as closed by the premise check. Moving the card back to Ready instead builds
  it.
- An acceptance item with no command and output: the card is handled as `stale` with no
  proposal.

The owner decided this on 2026-11-15, reversing an earlier choice to let the fleet close
alone. Which command proves which acceptance item is the session's claim, and where a test
file is a whole suite that claim is weak. Each confirmation and each rejection is recorded,
so the record can later show whether the verdicts are reliable enough to close without a
person. Confirming is a person's act and is gated like approving a rewrite (below).

**`stale`.** The proposal is stored on the card and the card moves to Blocked with one
comment that starts "Waiting for a person:", states what changed in a sentence, and shows
the proposed Scope and acceptance next to the current ones. The owner then does one of:

- approve it: one command, and one button on the board page, replaces the card's Scope and
  acceptance with the proposal, stamps the card and moves it to Ready;
- edit the card by hand and move it to Ready, which stamps it;
- move it to Won't do.

A `stale` verdict with no usable proposal blocks the card the same way with the session's
paragraph as the question.

Approving a proposal is a person's act. The gate hook blocks the approve command inside any
Claude session, as it already blocks moving a card out of Human QA; the terminal and the
board page are the two ways to approve. The gate is a text check, so this is added to its
documented residuals and not claimed as airtight. (My call.)

### 5. Seeing what the check did

Every verdict is one line in the supervisor's event log and shows in `supervisor status`:
the card, the verdict, and what the supervisor did. Cards closed as already built carry the
label above, so they can be listed without reading the whole Done column.

### 6. Follow-ups that roles file

Roles keep writing one-line entries in their reports, so no role prompt changes.
`file-followups.sh` keeps filing each entry mechanically into Backlog, marked as awaiting a
draft. That is also the fallback: if drafting fails, the card stays as it is filed today.

The planner then plans a drafting pass for each such card. It is the same session as the
premise check, in a second mode, with the filing role's report entry and the whole board
(every state, since #374 duplicated #361) as extra input. It returns one of:

| Verdict | What the supervisor does |
|---|---|
| duplicate of #n | Move the card to Won't do with a comment linking #n |
| already fixed on main | Move the card to Won't do with a comment naming the commit or test that shows it |
| drafted | Write the Why, Scope and acceptance onto the card, run the card lint, stamp it |

A drafted card stays in Backlog unless all of these hold, in which case it goes to Ready:

- the entry came from a role's `Bugs found:` list, not `Out of scope:`;
- the drafting session ran the repro on current main, whatever form the repro takes, and
  reports the command and output showing it fail. A wrong claim here costs one wasted
  start, which is why the session's word is enough for this and not for closing a card;
- the card lint passes;
- fewer than the cap of follow-ups have gone to Ready in this supervisor run;
- config allows it.

Config:

- a new key for whether bug follow-ups may go to Ready on their own (the default) or every
  drafted follow-up waits in Backlog. `followups.status` keeps its present meaning and is
  not reused. (My call; the owner asked for "the option to have things go to the backlog"
  and did not say where the switch lives.)
- the cap per supervisor run, default 5. (My call on the number.)

Not a follow-up for this purpose: the "main is red" card that `verify-main.sh` files. It
goes straight to Ready as it does today, with no drafting and outside the cap.

### 7. Turning it off

One config switch disables the premise check and the drafting pass together, for a project
that does not want the session cost. It is on by default and on in this repository.

With the switch off, `file-followups.sh` files exactly as it does today, with
`followups.status` deciding the column. That mechanical path is kept and stays tested,
since it is also the fallback when drafting fails.

## How we will know it worked

From `.fleet-board/usage.jsonl` and the cards' comments, after a week of runs:

- blocked reports that say the acceptance already exists, or that a dependency is unmerged,
  fall to near zero;
- the share of role-filed follow-ups that a person has to rewrite or close falls well below
  the eight out of eight seen on 2026-11-14;
- total session time spent on premise checks is less than the implementor time the old
  blocks cost. If it is not, raise the bar for when a check runs.

## Testing

- Offline suites with the existing fakes: the stamp on each creation route, the
  moved-ground comparison, each verdict's handling, the supervisor's own test run before a
  close, the cap, and both config settings. A planner scenario goes in the tick-plan suite
  for its area.
- One live behavioural scenario for the check session, run only when the owner asks, since
  it costs usage.
- Each suite is shown to fail before it is trusted.

## Left to the builder

- Field names, the report's exact sections, the script and module layout.
- How the default-branch checkout for the session and the supervisor's test runs is made
  and cleaned up.
- How the board page shows a proposal and the approve button.
- How the work splits into PR-sized cards.
- The docs changes.
