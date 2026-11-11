"""Live supervisor state, held in memory. Single-threaded by design: the loop owns it."""
import time
from collections import deque
from dataclasses import dataclass, fields
from typing import Any, Optional

from . import scopes


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
        self.run_tokens = {}
        self.events = deque(maxlen=500)
        self._sequence = 0

    def _bump(self):
        self.revision += 1

    def pause(self, reason):
        self.mode = 'paused'
        self.pause_reason = reason
        self._bump()

    def resume(self):
        self.mode = 'running'
        self.pause_reason = None
        self._bump()

    def begin(self, action):
        if action.kind not in ('role', 'script', 'merge'):
            raise ValueError('invalid action kind')
        if action.card in self.active:
            raise ValueError('card already active')
        if action.kind == 'merge' and self.lane is not None:
            raise ValueError('merge lane taken')
        self.active[action.card] = action
        if action.kind == 'merge':
            self.lane = action
        self._bump()

    def end(self, card):
        action = self.active.pop(card)
        if self.lane is action:
            self.lane = None
        self._bump()
        return action

    def reserve(self, card, paths):
        """Reserve `paths` for `card`; they must already be `scopes.normalize()` output."""
        for owner, held in self.reservations.items():
            if owner != card and scopes.overlap(paths, held):
                return owner
        held = set(self.reservations.get(card, ())) | set(paths)
        # Union like the store did; '' (whole repo) absorbs everything.
        self.reservations[card] = [''] if '' in held else sorted(held)
        self._bump()
        return None

    def release(self, card):
        self.reservations.pop(card, None)
        self._bump()

    def event(self, type, **payload):
        self._sequence += 1
        self.events.append({'sequence': self._sequence, 'type': type, 'at': self.clock(), 'payload': payload})
        self._bump()
        return self._sequence

    @staticmethod
    def _action_dict(action):
        if action is None:
            return None
        # Not asdict(): it deep-copies, and a live session handle is not copyable.
        return {f.name: getattr(action, f.name) for f in fields(action) if f.name != 'session'}

    def snapshot(self):
        return {
            'run_id': self.run_id,
            'mode': self.mode,
            'pause_reason': self.pause_reason,
            'revision': self.revision,
            'active': {card: self._action_dict(a) for card, a in self.active.items()},
            'lane': self._action_dict(self.lane),
            'provider_health': {k: dict(v) for k, v in self.provider_health.items()},
            'run_tokens': dict(self.run_tokens),
        }
