"""Typed supervisor errors and the ONE classifier that turns an exception into a wire code.

Errors are typed where they are raised. The classifier looks only at the exception's type,
never at its message, so a ValueError whose text happens to say "revision" or "unavailable"
is an ordinary invalid request. Every entry point (the control socket handler, the
in-process envelope) goes through error_envelope().

The typed errors subclass the builtin they always were (ValueError, RuntimeError,
PermissionError), so existing `except` clauses and tests keep working.
"""
import logging

log = logging.getLogger("supervisor.errors")

INTERNAL_MESSAGE = "internal error"


class SupervisorError(Exception):
    code = "internal"


class StaleRevision(SupervisorError, ValueError):
    """The request was bound to a revision the state has moved past."""
    code = "stale_revision"


class UncertainWriter(SupervisorError, RuntimeError):
    """An unresolved shutdown leaves a writer that may still be active."""
    code = "uncertain_writer"


class Disabled(SupervisorError, RuntimeError):
    """supervisor.enabled is false: the control API is read-only."""
    code = "disabled"


class Unauthenticated(SupervisorError, PermissionError):
    """The peer could not be authenticated as the owning user."""
    code = "unauthenticated"


class Invalid(SupervisorError, ValueError):
    """The request is malformed or not allowed in the current state."""
    code = "invalid"


class Unavailable(SupervisorError, RuntimeError):
    """The supervisor could not answer right now."""
    code = "unavailable"


def classify(exc):
    """{"code", "message"} for an exception. Internal errors get a generic message and are
    logged server-side with their detail."""
    if isinstance(exc, SupervisorError) and not type(exc) is SupervisorError:
        return {"code": exc.code, "message": str(exc)[:300]}
    if isinstance(exc, PermissionError):
        return {"code": "unauthenticated", "message": str(exc)[:300]}
    if isinstance(exc, TimeoutError):
        return {"code": "unavailable", "message": str(exc)[:300]}
    if isinstance(exc, (ValueError, TypeError)):
        return {"code": "invalid", "message": str(exc)[:300]}
    log.error("internal supervisor error: %s: %s", type(exc).__name__, exc,
              exc_info=(type(exc), exc, exc.__traceback__))
    return {"code": "internal", "message": INTERNAL_MESSAGE}


def error_envelope(exc, current=None):
    """The wire reply for a failed request. A stale revision carries the current state
    (current is a callable returning it)."""
    error = classify(exc)
    if error["code"] == "stale_revision":
        try:
            error["current"] = current() if callable(current) else None
        except Exception:  # noqa: BLE001 - the state read must not hide the conflict
            error["current"] = None
    return {"ok": False, "error": error}
