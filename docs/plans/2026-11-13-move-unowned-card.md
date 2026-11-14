# Move a card the supervisor does not own: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a supervisor runs, the board page can move a marked card the supervisor does not own. The move clears the card's leftovers first.

**Architecture:** `stuck.release` gains a `target` column. The board server's `move_card` decides
ownership from the supervisor's `status.active` and, for a marked card the supervisor does not own,
calls `stuck.release(..., force=True, target=state)` in place of a bare `board-move.sh`. The card's
page `active` flag means "owned by the supervisor" while one answers.

**Tech Stack:** Python 3 (`scripts/supervisor/stuck.py`, `scripts/board-web.py`), with
plain-bash test wrappers.

**Spec:** `docs/specs/2026-11-13-move-unowned-card-design.md`

## Global Constraints

- Git is never touched by the move: no branch, worktree or PR change.
- No new supervisor socket command, and no full `stuck.find` scan while a supervisor answers.
  The per-card `find(cards={n})` inside `release` is allowed.
- The CLI `fleet-board supervisor stuck --release N` keeps its behavior: it calls `release`
  with no `target`.
- Bump `plugins/fleet-board/.claude-plugin/plugin.json` and the fleet-board entry in
  `.claude-plugin/marketplace.json` (patch) above `origin/main`, in the implementation commit.
- Run only the suites named here, plus `bash plugins/fleet-board/tests/test-clean-room.sh` and
  `bash plugins/fleet-board/tests/test-version-bumped.sh`.

## Replaced test (owner decision, 2026-11-13)

The case `busy` in `test-board-web.sh` ("move returns 409 when the run is alive, active/<n>
exists and the card is not stuck") encodes the old rule, "a marker means an agent works on
it". The owner approved the new rule: owned means listed in `status.active`. Task 2 rewrites
that case so card 1 appears in the stubbed `status.active`. Its three assertions and their
names stay: 409, the error text, and the unchanged state. The `stuck` case (findings from
`stuck_view`) stays and still passes, because its card has a marker the supervisor does not
own. This rewrite is not a weakened test.

## Review Focus

1. A marker naming a live process group that the supervisor does not own (an agent started
   by hand) must stay unmovable. Task 2: `live`.
2. A card in Merging with an unrecorded `pending_merge` must never be moved by the page,
   because a merge could run twice. Task 1:
   `test_release_with_a_target_refuses_an_unrecorded_pending_merge`; Task 2: `pending`.
3. A paused or stopping supervisor still owns its active cards. The check must not depend on
   `run_alive`. Task 2: `paused`.
4. A refused move changes nothing: the marker, note and state stay. Task 2: `live` checks
   that the marker survives.
5. With no supervisor answering, a move behaves exactly as before: no `release` call, and
   the marker is left alone. Task 2: `norun`.

---

### Task 1: `stuck.release` takes a target column

**Files:**
- Modify: `plugins/fleet-board/scripts/supervisor/stuck.py` (`release`)
- Test: `plugins/fleet-board/fixtures/supervisor/stuck_cases.py` (class `Release`), run by
  `plugins/fleet-board/tests/test-supervisor-stuck.sh`

**Interfaces:**
- Produces: `release(root, card, run=..., gh=None, run_argv=..., force=False, live_cards=frozenset(), target=None) -> None`.
  With `target` (a canonical state string) the card is moved to `target` instead of the
  derived column. All other effects are unchanged. It raises `ValueError` as before, and
  also in the new case below.

- [ ] **Step 1: Write the failing tests** in class `Release`:

```python
def test_release_with_a_target_moves_there_and_clears_the_leftovers(self):
    self.b.seed(12, 'in_progress')
    self.b.put_note({'stuck': {'kind': 'marker', 'detail': 'd', 'at': 't'}})
    self.marker(12)
    dead = self.lock(12, dead_pid())
    stuck.release(self.root, 12, force=True, target='backlog')
    self.assertEqual(self.b.card(12)['state'], 'backlog')
    self.assertFalse((self.active / '12').exists())
    self.assertFalse(dead.exists())
    self.assertIsNone(self.b.note(12).get('stuck'))

def test_release_with_a_target_refuses_an_unrecorded_pending_merge(self):
    self.b.seed(12, 'merging')
    self.b.put_note({'pr': 34, 'pending_merge': {'operation_key': 'k', 'pr': 34, 'head_sha': 'a' * 40}})
    self.marker(12)
    with self.assertRaisesRegex(ValueError, r'fleet-board supervisor stuck --release 12'):
        stuck.release(self.root, 12, gh=self.gh_state('OPEN'), force=True, target='in_review')
    self.assertEqual(self.b.card(12)['state'], 'merging')
    self.assertTrue((self.active / '12').exists(), 'a refused release changes nothing')

def test_release_with_a_target_refuses_a_live_orphan(self):
    self.b.seed(12, 'in_progress')
    self.owned_marker(12, self.group())
    with self.assertRaisesRegex(ValueError, r'live process group'):
        stuck.release(self.root, 12, force=True, target='ready')
    self.assertEqual(self.b.card(12)['state'], 'in_progress')
```

- [ ] **Step 2: Run them and see them fail**

Run: `bash plugins/fleet-board/tests/test-supervisor-stuck.sh`
Expected: the first two fail. `release` does not accept `target`, so they fail with a
`TypeError`. The third may fail the same way.

- [ ] **Step 3: Implement `target`** in `release`. Before any write, when `target is not None`
  and the note has a dict `pending_merge` and no `merge_operation`, raise
  `ValueError('card #%d has a merge in flight; run fleet-board supervisor stuck --release %d, which reads the PR first' % (card, card))`.
  Otherwise compute the patch exactly as today, then use `target` in place of the derived
  column when it is given. A merged merging card with `target` still records
  `merge_operation`.

- [ ] **Step 4: Run them and see them pass**

Run: `bash plugins/fleet-board/tests/test-supervisor-stuck.sh`
Expected: every case passes, the existing `Release` cases included.

- [ ] **Step 5: Commit** the test first (failing), then the implementation, as two commits.

### Task 2: the move endpoint and the `active` flag use ownership

**Files:**
- Modify: `plugins/fleet-board/scripts/board-web.py`: `move_card`, `is_active` and its two
  callers (the board list around line 880 and the card detail around line 897)
- Test: `plugins/fleet-board/tests/test-board-web.sh`, the case "the move endpoint refuses a
  card an agent is working on, unless it is stuck"

**Interfaces:**
- Consumes: `supervisor_stuck.release(root, n, live_cards=owned, force=True, target=state)`
  from Task 1. `supervisor_stuck.run_lock_holder(run_lock_path(cfg))` exists already.
- Produces: `owned_cards(status) -> set[int]`, the `card` of each dict in
  `status.get("active")`, or an empty set when `status` is None.
  `is_active(dir, n, alive)` becomes `is_active(n, owned) -> bool` (`n in owned`). Both
  callers pass `owned_cards(status)` for the status they already read.

- [ ] **Step 1: Rewrite the test harness and add cases.** In the Python block, `attempt`
  takes `status`: `None`, or a dict with `phase`, `desired_mode`, `active` and `pid`. Stub
  `m.supervisor_status = lambda: status`, and stub
  `m.supervisor_stuck.run_lock_holder = lambda path: other_pid` (default `None`). Drop the
  `m.run_alive` stub. The cases:
  - `busy`: card 1, status `active: [{"card": 1}]`, marked. Expect 409, "agent is working
    on", and state `backlog`, with the same three assertion names as today.
  - `nomarker`: card 2, status running with `active: []`, no marker. Expect 200.
  - `norun`: card 3, status `None`, marked. Expect 200, and the marker still exists.
  - `stuck`: card 4, status running with `active: []`, marked (empty marker). Expect 200,
    state `ready`, and the marker gone.
  - `live`: card 5, status running with `active: []`, and a marker
    `{"pgid": <pgid of a sleep 60 started with start_new_session=True>, "supervisor_pid": 1}`.
    Expect 409 with "live process group" in the text, and the marker still exists. Kill the
    group at the end.
  - `pending`: card 6, in `merging` with a note holding `pending_merge`, status running with
    `active: []`, marked. Expect 409 with "stuck --release 6" in the text.
  - `paused`: card 1 again, status `phase: "paused"` with `active: [{"card": 1}]`. Expect 409.
  - `other`: card 2, marked, status running with `active: []` and `pid: 111`, with
    `run_lock_holder` returning `222`. Expect 409 with "another checkout" in the text.

  Seed card 6's note with `bash $SCRIPTS/note.sh merge 6 <file>`. Then add assertions for
  `/api/board`: with status `active: [{"card": 1}]` and markers on cards 1 and 3, card 1 has
  `active: true` and card 3 has `active: false`.

- [ ] **Step 2: Run them and see them fail**

Run: `bash plugins/fleet-board/tests/test-board-web.sh`
Expected: `stuck` (marker not removed), `live`, `pending`, `paused`, `other` and the
`active` flag assertions fail. `busy`, `nomarker` and `norun` pass.

- [ ] **Step 3: Implement.** `move_card`:
  1. `status = supervisor_status()`.
  2. If `status` is None, move with `board-move.sh` as today.
  3. `owned = owned_cards(status)`. If `n in owned`, return 409 with today's text, whether or
     not a marker exists.
  4. If the card has no `active/<n>` marker, move with `board-move.sh` as today.
  5. If `run_lock_holder(...)` is not None and differs from `status.get("pid")`, return 409
     with "a supervisor of another checkout holds the repository run lock (pid N)".
  6. Otherwise call `release` under the same exclusion `board_write` uses, and map its
     `ValueError` to `ApiError(409, str(exc))`.

  Remove the `stuck_of` lookup from `move_card`; `board_extras` keeps it for the page.

- [ ] **Step 4: Run them and see them pass**

Run: `bash plugins/fleet-board/tests/test-board-web.sh`, then
`bash plugins/fleet-board/tests/test-board-drawer-lock.sh` and
`bash plugins/fleet-board/tests/test-board-drag-active.sh`.
Expected: all pass. The two drawer suites feed `active` directly, so they need no change.
If one fails, fix the fixture, not the assertion.

- [ ] **Step 5: Bump both manifests, then commit** the test first, then the implementation.
