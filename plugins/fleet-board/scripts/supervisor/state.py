"""Live supervisor state, held in memory. The loop owns it and mutates it; the service thread reads
snapshots and applies `stop` (an immediate mode change), so every method takes one short lock and
`snapshot()` returns a deep copy that later mutation cannot change."""
import copy
import json
import threading
import time
from collections import deque
from dataclasses import dataclass, fields
from typing import Any, Optional

from . import markers, scopes

DUPLICATE_ADMISSION = 'card already active'  # begin() refuses a second action for a card; loop.py matches it
# The scope-free review actions: a card may run several of them together (never beside any other action).
REVIEWER_ACTIONS = frozenset(('start_review', 'review', 'review_stage'))
_PRIVATE = ('session', 'marker', 'pgid', 'work_column')     # Action fields kept out of the snapshot


@dataclass
class Action:
    card: int
    action: str
    column: str
    role: Optional[str]
    provider: str
    paths: list
    started_at: float
    started_mono: float
    session: Any = None
    kind: str = 'role'  # "role" | "script" | "merge"
    marker: Any = None  # the card's active marker path once a session or merge child was launched
    pgid: Any = None    # the process group this action owns; end() removes a marker naming it or no usable pgid
    stage: Any = None   # a review_stage action's stage name: one card's reviewers run together, one per stage
    work_column: Any = None  # the column the card is in while the role session runs; set in _launch and by the merge lane


def ledger_column(action):
    """The ledger's column for an action: where the card is while the work runs, not `column` (the card's state
    when the planner saw it, which a cancel restores)."""
    return action.work_column or action.column


# The token counts the budget limits count: cache reads are left out (owner decision, 0.27.0).
BUDGET_KEYS = ('input', 'output', 'cache_write')
BUDGET_LABEL = 'counted toward limits.max_tokens'
SNAPSHOT_EVENTS = 50   # the snapshot carries the newest of the 500 events kept


class State:
    def __init__(self, run_id, clock=time.time):
        self.run_id = run_id
        self.clock = clock
        self.mode = 'running'
        self.pause_reason = None
        self.revision = 0
        self.active = {}        # card -> its first running action
        self._also = {}         # card -> its further running reviewer actions (see REVIEWER_ACTIONS)
        self._retired = {}      # card -> {marker, pgids} of the card's reviewers that already ended
        self.reservations = {}
        self.reservation_ancestors = {}   # card -> the cards it is stacked on
        self.reservation_repos = {}   # card -> repo of its reservation ('' or absent: the home repo)
        self.lane = None
        self.provider_health = {}
        self.holds = {}   # card number (str) -> {reason, source, until}: why the last cycle held each card back
        self.run_tokens = {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0, 'total': 0,
                           'unknown': 0, 'partial': False}
        # The token budget (limits.max_tokens, limits.max_tokens_per_card) counts input + output + cache_write;
        # cache reads are recorded and shown (run_tokens, the ledger) but not counted. The snapshot carries it as
        # run_budget {tokens, partial, cap, label}.
        self.run_budget = 0
        self.budget_unknown = 0   # actions with an unknown count among BUDGET_KEYS (an unknown cache read is not)
        self.budget_cap = None    # limits.max_tokens as the loop last read it (None: no limit)
        self.card_tokens = {}   # card -> known budget tokens spent in this run
        self.events = deque(maxlen=500)
        self.event_log = None   # path of supervisor.log: each event is appended to it as one JSON line
        self.attention = {}     # card number (str) -> {reason, at}: cards that wait for a person
        self.queue = {'ready': None, 'waiting': None}   # the last planning cycle: cards that could start, cards held
        self.global_cap = None  # limits.concurrency as the loop last read it
        self.last_plan = None   # the last board-wide pass: {ended_at (epoch seconds), seconds}
        self._sequence = 0
        self._lock = threading.RLock()

    def _bump(self):
        self.revision += 1

    def set_holds(self, holds):
        """Replace the held-card map with the last cycle's (a card admitted since is no longer in it)."""
        with self._lock:
            if holds != self.holds:
                self.holds = holds
                self._bump()

    def set_queue(self, ready, waiting):
        with self._lock:
            queue = {'ready': ready, 'waiting': waiting}
            if queue != self.queue:
                self.queue = queue
                self._bump()

    def set_last_plan(self, ended_at, seconds):
        with self._lock:
            self.last_plan = {'ended_at': ended_at, 'seconds': seconds}
            self._bump()

    def set_global_cap(self, cap):
        with self._lock:
            if cap != self.global_cap:
                self.global_cap = cap
                self._bump()

    def set_attention(self, card, reason):
        """Mark `card` as needing a person; it stays until an action begins for the card."""
        with self._lock:
            self.attention[str(card)] = {'reason': reason, 'at': self.clock()}
            self._bump()

    def clear_attention(self, card):
        with self._lock:
            if self.attention.pop(str(card), None) is not None:
                self._bump()

    def pause(self, reason):
        with self._lock:
            if self.mode == 'stopping':
                return
            self.mode = 'paused'
            self.pause_reason = reason
            self._bump()

    def resume(self):
        with self._lock:
            if self.mode == 'stopping':
                return
            self.mode = 'running'
            self.pause_reason = None
            for name in [n for n, h in self.provider_health.items() if h.get('auth')]:
                del self.provider_health[name]
            self._bump()

    def stop(self):
        """Enter the terminal 'stopping' mode at once; pause() and resume() cannot leave it."""
        with self._lock:
            if self.mode != 'stopping':
                self.mode = 'stopping'
                self.pause_reason = None
                self._bump()

    def actions_for(self, card):
        """Every running action of `card`: the first, then its further reviewer actions."""
        with self._lock:
            first = self.active.get(card)
            return ([first] if first is not None else []) + list(self._also.get(card, ()))

    def all_actions(self):
        with self._lock:
            return [a for card in list(self.active) for a in self.actions_for(card)]

    def begin(self, action):
        with self._lock:
            if action.kind not in ('role', 'script', 'merge'):
                raise ValueError('invalid action kind')
            running = self.actions_for(action.card)
            if running and not (action.action in REVIEWER_ACTIONS
                                and all(a.action in REVIEWER_ACTIONS for a in running)):
                raise ValueError(DUPLICATE_ADMISSION)
            if action.kind == 'merge' and self.lane is not None:
                raise ValueError('merge lane taken')
            if running:
                self._also.setdefault(action.card, []).append(action)
            else:
                self.active[action.card] = action
            self.attention.pop(str(action.card), None)
            if action.kind == 'merge':
                self.lane = action
            self._bump()

    def end(self, card, action=None):
        """End `action` (default: the card's first one). The card's active marker goes with its last action, unless
        it names another process group: a marker naming the action's own pgid, one of its ended siblings' pgids,
        or no usable pgid, is removed then; while a reviewer still runs the marker stays."""
        with self._lock:
            running = self.actions_for(card)
            if action is None and running:
                action = running[0]
            if action is None or action not in running:
                raise KeyError(card)
            rest = [a for a in running if a is not action]
            if rest:
                self.active[card] = rest[0]
                if rest[1:]:
                    self._also[card] = rest[1:]
                else:
                    self._also.pop(card, None)
                kept = self._retired.setdefault(card, {'marker': None, 'pgids': set()})
                kept['marker'] = kept['marker'] or action.marker
                if action.pgid is not None:
                    kept['pgids'].add(action.pgid)
            else:
                self.active.pop(card, None)
                self._also.pop(card, None)
            retired = None if rest else self._retired.pop(card, None)
            if self.lane is action:
                self.lane = None
            self._bump()
        if not rest:
            marker = action.marker or (retired or {}).get('marker')
            markers.clear(marker, action.pgid, also=(retired or {}).get('pgids') or ())
        return action

    def reserve(self, card, paths, ignore=None, exempt=(), repo=None, home_repo=None, ancestors=()):
        """Reserve `paths` for `card`; they must already be `scopes.normalize()` output.

        `ignore` is `supervisor.scope_ignore`: matching paths are dropped from both sides
        before the overlap check, as the scheduler does. Owners in `exempt` (a stacked
        child's ancestors) are not overlap-checked. A missing `repo` (the card's, or a held
        reservation's) is `home_repo`; with no `home_repo` it matches every repo."""
        with self._lock:
            mine = scopes.drop_ignored(paths, ignore)
            for owner, held in self.reservations.items():
                if owner != card and owner not in exempt \
                        and card not in self.reservation_ancestors.get(owner, ()) \
                        and scopes.same_repo(repo, self.reservation_repos.get(owner), home_repo) \
                        and scopes.overlap(mine, scopes.drop_ignored(held, ignore)):
                    return owner
            held = set(self.reservations.get(card, ())) | set(paths)
            # Union like the store did; '' (whole repo) absorbs everything.
            self.reservations[card] = [''] if '' in held else sorted(held)
            if ancestors:
                self.reservation_ancestors[card] = tuple(ancestors)
            else:
                self.reservation_ancestors.pop(card, None)
            if repo:
                self.reservation_repos[card] = repo
            else:
                self.reservation_repos.pop(card, None)
            self._bump()
            return None

    def release(self, card):
        with self._lock:
            self.reservations.pop(card, None)
            self.reservation_repos.pop(card, None)
            self.reservation_ancestors.pop(card, None)
            self._bump()

    def set_health(self, provider, entry):
        """Mark `provider` unhealthy: entry is {"until", "reason", "failures"}."""
        with self._lock:
            self.provider_health[provider] = dict(entry)
            self._bump()

    def clear_health(self, provider):
        with self._lock:
            if self.provider_health.pop(provider, None) is not None:
                self._bump()

    def add_tokens(self, counts, card=None):
        """Add one action's counts (input, output, cache_write, cache_read; None is unknown, never zero) to
        this run's totals, kept in memory so the run limit never reads the ledger."""
        with self._lock:
            run = self.run_tokens
            for key in ('input', 'output', 'cache_write', 'cache_read'):
                run[key] = run.get(key, 0) + (counts.get(key) or 0)
            run['unknown'] = run.get('unknown', 0) + (1 if any(counts.get(k) is None for k in (
                'input', 'output', 'cache_write', 'cache_read')) else 0)
            run['total'] = sum(run[k] for k in ('input', 'output', 'cache_write', 'cache_read'))
            run['partial'] = run['unknown'] > 0
            budget = sum(counts.get(k) or 0 for k in BUDGET_KEYS)
            self.run_budget += budget
            if any(counts.get(k) is None for k in BUDGET_KEYS):
                self.budget_unknown += 1
            if card is not None:
                self.card_tokens[card] = self.card_tokens.get(card, 0) + budget
            self._bump()

    def set_budget_cap(self, cap):
        """Record limits.max_tokens for the status (None or a non-positive value: no limit)."""
        cap = cap if isinstance(cap, (int, float)) and not isinstance(cap, bool) and cap > 0 else None
        with self._lock:
            if cap != self.budget_cap:
                self.budget_cap = cap
                self._bump()

    def event(self, type, **payload):
        with self._lock:
            self._sequence += 1
            entry = {'sequence': self._sequence, 'type': type, 'at': self.clock(), 'payload': payload}
            self.events.append(entry)
            self._bump()
            if self.event_log:
                try:
                    with open(self.event_log, 'a') as log:
                        log.write(json.dumps(entry, default=str) + '\n')
                except OSError:
                    pass   # the log is a convenience; an event must never fail the loop
            return self._sequence

    @staticmethod
    def _action_dict(action):
        if action is None:
            return None
        # Not asdict(): it deep-copies, and a live session handle is not copyable.
        out = {f.name: getattr(action, f.name) for f in fields(action) if f.name not in _PRIVATE}
        out['log'] = getattr(action.session, 'log_path', None)   # the session's .jsonl path; null without a session
        return out

    def _with_action_dicts(self, card):
        return [self._action_dict(a) for a in self._also.get(card, ())]

    def _with_also(self, card, action):
        entry = self._action_dict(action)
        also = self._with_action_dicts(card)
        if also:
            entry['also'] = also   # the card's further reviewer actions
        return entry

    def snapshot(self):
        with self._lock:
            return copy.deepcopy({
                'run_id': self.run_id,
                'mode': self.mode,
                'pause_reason': self.pause_reason,
                'revision': self.revision,
                'active': {card: self._with_also(card, a) for card, a in self.active.items()},
                'lane': self._action_dict(self.lane),
                'provider_health': self.provider_health,
                'holds': self.holds,
                'events': list(self.events)[-SNAPSHOT_EVENTS:],
                'attention': self.attention,
                'queue': self.queue,
                'last_plan': self.last_plan,
                'limits': {'concurrency': self.global_cap},
                'run_tokens': self.run_tokens,
                'run_budget': {'tokens': self.run_budget, 'partial': self.budget_unknown > 0, 'cap': self.budget_cap,
                               'label': BUDGET_LABEL},
            })
