"""Live supervisor state, held in memory. The loop owns it and mutates it; the service thread reads
snapshots and applies `stop` (an immediate mode change), so every method takes one short lock and
`snapshot()` returns a deep copy that later mutation cannot change."""
import copy
import threading
import time
from collections import deque
from dataclasses import dataclass, fields
from typing import Any, Optional

from . import markers, scopes

DUPLICATE_ADMISSION = 'card already active'  # begin() refuses a second action for a card; loop.py matches it
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
    work_column: Any = None  # the column the card is in while the role or script works (after the action's move)


def ledger_column(action):
    """The ledger's column for an action: where the card is while the work runs, not `column` (the card's state
    when the planner saw it, which a cancel restores)."""
    return action.work_column or action.column


class State:
    def __init__(self, run_id, clock=time.time):
        self.run_id = run_id
        self.clock = clock
        self.mode = 'running'
        self.pause_reason = None
        self.revision = 0
        self.active = {}
        self.reservations = {}
        self.lane = None
        self.provider_health = {}
        self.run_tokens = {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0, 'total': 0,
                           'unknown': 0, 'partial': False}
        self.card_tokens = {}   # card -> known tokens spent in this run (not part of the snapshot)
        self.events = deque(maxlen=500)
        self._sequence = 0
        self._lock = threading.RLock()

    def _bump(self):
        self.revision += 1

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
            self._bump()

    def stop(self):
        """Enter the terminal 'stopping' mode at once; pause() and resume() cannot leave it."""
        with self._lock:
            if self.mode != 'stopping':
                self.mode = 'stopping'
                self.pause_reason = None
                self._bump()

    def begin(self, action):
        with self._lock:
            if action.kind not in ('role', 'script', 'merge'):
                raise ValueError('invalid action kind')
            if action.card in self.active:
                raise ValueError(DUPLICATE_ADMISSION)
            if action.kind == 'merge' and self.lane is not None:
                raise ValueError('merge lane taken')
            self.active[action.card] = action
            if action.kind == 'merge':
                self.lane = action
            self._bump()

    def end(self, card):
        """End the card's action. Its active marker goes too, unless it names another process group: a marker naming
        the action's own pgid, or no usable pgid, is removed when the action ends."""
        with self._lock:
            action = self.active.pop(card)
            if self.lane is action:
                self.lane = None
            self._bump()
        markers.clear(action.marker, action.pgid)
        return action

    def reserve(self, card, paths):
        """Reserve `paths` for `card`; they must already be `scopes.normalize()` output."""
        with self._lock:
            for owner, held in self.reservations.items():
                if owner != card and scopes.overlap(paths, held):
                    return owner
            held = set(self.reservations.get(card, ())) | set(paths)
            # Union like the store did; '' (whole repo) absorbs everything.
            self.reservations[card] = [''] if '' in held else sorted(held)
            self._bump()
            return None

    def release(self, card):
        with self._lock:
            self.reservations.pop(card, None)
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
            if card is not None:
                self.card_tokens[card] = self.card_tokens.get(card, 0) + sum(
                    counts.get(k) or 0 for k in ('input', 'output', 'cache_write', 'cache_read'))
            self._bump()

    def event(self, type, **payload):
        with self._lock:
            self._sequence += 1
            self.events.append({'sequence': self._sequence, 'type': type, 'at': self.clock(), 'payload': payload})
            self._bump()
            return self._sequence

    @staticmethod
    def _action_dict(action):
        if action is None:
            return None
        # Not asdict(): it deep-copies, and a live session handle is not copyable.
        return {f.name: getattr(action, f.name) for f in fields(action) if f.name not in _PRIVATE}

    def snapshot(self):
        with self._lock:
            return copy.deepcopy({
                'run_id': self.run_id,
                'mode': self.mode,
                'pause_reason': self.pause_reason,
                'revision': self.revision,
                'active': {card: self._action_dict(a) for card, a in self.active.items()},
                'lane': self._action_dict(self.lane),
                'provider_health': self.provider_health,
                'run_tokens': self.run_tokens,
            })
