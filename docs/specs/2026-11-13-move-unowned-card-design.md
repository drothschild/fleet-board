# Moving a card the supervisor does not own (card 314)

Status: design, 2026-11-13. Small change.

## Why

While a supervisor runs, the board page refuses to move any card that has an
`active/<n>` marker. `move_card` in `board-web.py` and the drawer lock from #308 both read "an
agent is working on it" as "a supervisor is running and the marker file exists", and both
make an exception for a stuck card. But `stuck_view` reports no findings while a supervisor
answers, so the exception can never apply. A card left with a dead marker can be moved only
after stopping the supervisor, or with `fleet-board supervisor stuck --release N`, which picks
the column itself.

A person should be able to move such a card from the page during a run, and the card should
then behave normally in the column they picked.

## Goals

- During a run, a card is locked on the page only while the supervisor owns it, or while
  a process outside the supervisor still runs on it.
- Moving any other marked card clears its leftovers (marker, dead lock, `stuck` note, plus
  the `stuck_released` exemption for a dirty worktree) and moves it to the chosen column.
- The page's lock and the endpoint agree.

## Non-goals

- No full stuck scan during a run. `stuck_view` keeps returning no findings while a
  supervisor answers.
- No new supervisor socket command.
- Git is never touched: no branch, worktree or PR is changed.

## Anti-goals

- A move must never let a merge run twice, or let two agents run on one card.

## Approaches

- **A. The board server checks ownership and cleans up (chosen).** It reads the
  supervisor's `status.active`, refuses owned cards, and runs `stuck.release`'s cleanup
  for the column the person picked. It reuses cleanup already proven in the CLI and adds
  no command. There is a small window: the supervisor could admit the card between the
  check and the move. An unmarked card has the same window today.
- **B. The supervisor does the move** through a new mutating socket command. This closes
  the window, but it needs request and revision binding, and the move behaves differently
  depending on whether a supervisor runs. Too much code for a narrow race.
- **C. Ask the supervisor's `stuck` command (319's idea).** This runs the full scan,
  including `git status` for every worktree, on each move or poll. It can exceed the
  board's 1 s probe, and the code deliberately avoids it during a run. Dropped.

## Design

**Ownership.** `owned = {a.card for a in status.active}` from the status the request
already reads, which is the same rule as `supervisor/cli.py`'s `_stuck`. While a
supervisor answers, a card's page `active` flag is `card in owned`, not "the marker
exists". With no supervisor running, the flag is false, as today.

**`move_card(n, state)`** while a supervisor answers (any phase, not only running):

1. If `n` is in `owned`: 409, with the current text ("an agent is working on card #n …").
2. If no marker exists for `n`: move as today, with no cleanup.
3. Otherwise, call `stuck.release(root, n, live_cards=owned, force=True, target=state)`,
   and map its `ValueError` to a 409 carrying the message. It refuses:
   - a live orphan: "a process outside the supervisor holds card #n" (the existing
     release text, with its `kill` hint);
   - a lock held by a running process;
   - a card in `merging` with `pending_merge` and no `merge_operation`. The message names
     `fleet-board supervisor stuck --release N`, which reads the PR before choosing.
     (my call)
4. If the repository run lock is held by a process that did not answer as this supervisor
   (another checkout's): 409, with the existing "a supervisor of another checkout holds
   the repository run lock (pid N)" text. (my call, matching the CLI's release)

**`stuck.release` gains `target=None`.** With `target`, the card moves to `target`
instead of the derived column. The merging branch still runs: an open or closed PR drops
the merge records, and a merged one records `merge_operation`. The other parts are
unchanged: the dirty-worktree exemption, the dead-lock removal, the `stuck` note cleared
and the marker removed. The CLI calls it without `target`, so its behavior is unchanged.

**The supervisor picks it up.** A card that `--ignore-stuck` kept out of admission comes
back once `_refresh_ignored`'s throttled `find` no longer reports it (`stuck.unresolved`),
so clearing is enough. No supervisor change is needed.

**The page.** No JavaScript change: the drawer lock and the tile drag already read
`src.active`, and `src.active` now means "owned". The 409 text is shown as today.

## Tests

- `test-board-web.sh`, with a stubbed status:
  - owned card → 409;
  - marked, unowned card with a dead pgid → 200; the card is in the chosen column, and
    marker, `stuck` note and dead lock are gone;
  - marked card whose pgid is alive and not owned → 409, naming the process group;
  - `merging` with `pending_merge` → 409, naming `stuck --release`;
  - unmarked card → moves as before.
- The `active` flag in `/api/board` and the card detail is true only for owned cards
  while a supervisor answers.
- `test-supervisor-stuck.sh`: `release(..., target=X)` moves to X; without `target` the existing
  cases are unchanged.

## Left to the builder

- Where `owned` is computed once per request, and the exact 409 wording beyond the
  texts named above.
- Whether `test-board-drawer-lock.sh` and `test-board-drag-active.sh` need a fixture update for the new `active` meaning.
