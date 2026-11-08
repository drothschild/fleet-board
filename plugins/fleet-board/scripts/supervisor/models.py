"""Validation helpers shared by the durable supervisor store."""
import json
from dataclasses import dataclass


def canonical_json(value):
    """Serialize protocol values without non-finite numbers or unstable ordering."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


@dataclass(frozen=True)
class StopEvidence:
    """Trusted in-process containment observation, never a worker-supplied value."""
    domain_id: str
    job_id: str
    attempt_id: str
    generation: int
    boot_id: str
    pid: int
    started_at: str
    nonce: str
    kind: str
