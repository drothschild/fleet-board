#!/bin/bash
# GET /api/cards/<n> includes the card's hold, read from the running supervisor's snapshot holds.
# Reuses the real-service fixture of fixtures/supervisor/web_cases.py (a real Service on a socket,
# a real board-web.py process) and runs only the three hold cases.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/card-hold.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts:$plugin_dir/fixtures/supervisor" python3 - "$tmp" <<'PY'
import sys
import unittest

import web_cases as wc  # pops the temp dir off sys.argv, as web_cases does when run directly


class CardHold(wc.SupervisorWebContract):

    def test_card_detail_hold_has_reason_source_and_until_for_a_card_the_supervisor_holds(self):
        self.write_card(5)
        self.write_card(6)
        self.start_service()
        self.state.set_holds({"5": {"reason": "waiting on a rate limit", "source": "scheduler",
                                    "until": "2026-11-13T12:00:00Z"}})
        self.start_web()
        code, body = self.http("GET", "/api/cards/5")
        self.assertEqual(code, 200, body)
        self.assertEqual(body.get("hold"), {"reason": "waiting on a rate limit", "source": "scheduler",
                                            "until": "2026-11-13T12:00:00Z"})

    def test_card_detail_hold_is_null_for_a_card_the_supervisor_is_not_holding(self):
        self.write_card(5)
        self.write_card(6)
        self.start_service()
        self.state.set_holds({"5": {"reason": "r", "source": "planner", "until": None}})
        self.start_web()
        code, body = self.http("GET", "/api/cards/6")
        self.assertEqual(code, 200, body)
        self.assertIn("hold", body)
        self.assertIsNone(body["hold"])

    def test_card_detail_hold_is_null_when_no_supervisor_is_running(self):
        self.write_card(5)
        self.start_web()
        code, body = self.http("GET", "/api/cards/5")
        self.assertEqual(code, 200, body)
        self.assertIn("hold", body)
        self.assertIsNone(body["hold"])


names = [n for n in dir(CardHold) if n.startswith("test_card_detail_hold")]
result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(CardHold(n) for n in names))
sys.exit(0 if result.wasSuccessful() else 1)
PY
