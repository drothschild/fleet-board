"""Test-only stand-in for the loop's handler: pause, resume and stop act on the State."""
import threading

from supervisor import errors


class StubHandler:
    def __init__(self, state):
        self.state = state
        self.stop_requested = threading.Event()
        self.stop_mode = None

    def request_stop(self, mode):
        self.stop_mode = mode
        self.stop_requested.set()

    def __call__(self, command):
        name = command.get("command")
        if name == "pause":
            self.state.pause(command.get("reason") or "paused by operator")
        elif name == "resume":
            self.state.resume()
        elif name == "stop":
            self.request_stop(command["mode"])
            return {"stopping": True, "mode": command["mode"]}
        else:
            raise errors.Invalid("unsupported command")
        return {"mode": self.state.mode, "revision": self.state.revision}
