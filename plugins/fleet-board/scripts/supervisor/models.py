"""Validation helpers shared by the durable supervisor store."""
import json


def canonical_json(value):
    """Serialize protocol values without non-finite numbers or unstable ordering."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
