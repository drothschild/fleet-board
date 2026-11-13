#!/bin/bash
# An expired login is a provider failure: it never charges the card, pauses admissions until resume, and
# supervisor status shows the message and the `claude auth login` advice.
set -eu
unset CDPATH
plugin_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-auth.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
trap 'rm -rf "$tmp" "$FLEET_BOARD_SOCKET_DIR"' EXIT
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$plugin_dir/scripts" python3 - "$plugin_dir" "$tmp" <<'PY'
import sys
import time
import unittest

plugin, tmp = sys.argv[1], sys.argv.pop()
sys.path.insert(0, plugin + '/fixtures/supervisor')
sys.argv.append(tmp)
import loop_cases as lc  # noqa: E402
from supervisor import cli, roles  # noqa: E402

MSG = ('Failed to authenticate: this login reached its time limit and cannot be renewed. '
       'Run `claude auth login` to sign in again')
FAIL = {'report': MSG, 'post': False, 'exit': 1, 'is_error': True, 'subtype': 'success'}


class Roles(unittest.TestCase):
    def test_a_success_result_with_is_error_and_failed_to_authenticate_is_a_provider_failure_not_a_card_failure(self):
        text = 'Failed to authenticate: this login reached its time limit'
        self.assertEqual(roles.classify(1, '', True, text, subtype='success'), 'provider')
        self.assertEqual(roles.classify(0, '', True, text, subtype='success'), 'provider')
        for other in ('Invalid API key', 'Please run /login'):
            self.assertEqual(roles.classify(1, '', True, other, subtype='success'), 'provider')


class Auth(lc.LoopCase):
    def health(self):
        return self.b.state.snapshot()['provider_health'].get('claude')

    def test_three_such_sessions_on_one_card_charge_it_nothing(self):
        self.b.plans(FAIL, FAIL, FAIL)
        self.start()
        for n in (1, 2, 3):
            self.until(lambda: self.count() == n, what='session %d' % n)
            self.until(self.health, what='unhealthy after session %d' % n)
            self.until(lambda: self.mode() == 'paused', what='admissions paused')
            if n < 3:
                self.b.state.resume()
                self.sup.wake('test')
        time.sleep(1.5)
        self.assertEqual((self.count(), self.mode()), (3, 'paused'), 'nothing starts again before resume')
        note = self.b.note()
        self.assertEqual(note.get('implementor_attempts') or 0, 0)
        self.assertEqual(note.get('action_failures') or 0, 0)
        self.assertEqual(self.b.card(12)['state'], 'in_progress', 'the card is not moved to Blocked')

    def test_the_provider_is_unhealthy_with_the_message_and_nothing_starts_until_resume(self):
        self.b.plans(FAIL, {'report': 'implementor-ok'})
        self.start()
        health = self.until(self.health, what='the provider to be marked unhealthy')
        self.assertIn('Failed to authenticate', health['reason'])
        self.assertIn('claude auth login', health['reason'])
        time.sleep(2.5)
        self.assertEqual(self.count(), 1, 'no new session before resume (backoff alone would have retried)')
        self.assertIsNotNone(self.health())
        self.b.state.resume()
        self.sup.wake('test')
        self.until(lambda: self.count() == 2, what='a session after resume')
        self.until(lambda: self.b.note().get('pr') == 12, what='the card to finish')
        self.sup.request_stop('drain')
        self.finished()


class Status(unittest.TestCase):
    def test_supervisor_status_prints_the_unhealthy_provider_with_the_message(self):
        out = cli._human_status({'mode': 'running', 'root': '/r', 'pid': 1, 'active': [],
                                 'provider_health': {'claude': {'reason': MSG, 'failures': 1}}})
        self.assertIn('claude', out)
        self.assertIn('Failed to authenticate', out)
        self.assertIn('claude auth login', out)


if __name__ == '__main__':
    suite = unittest.TestSuite()
    for case in (Roles, Auth, Status):
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(case))
    sys.exit(0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1)
PY
