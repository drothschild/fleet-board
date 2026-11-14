#!/usr/bin/env bash
#
# A merger `attention` moves the card from Merging to Blocked, waiting for a person (card 279):
# the driver's move and comment, the planner's way out of Blocked, and the board move's note upkeep.
# Offline: fake gh, local board.
#
# Usage: bash plugins/fleet-board/tests/test-merger-attention-blocked.sh

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/store-sync.sh"
PLUGIN="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$PLUGIN/scripts/tick-plan.sh"
SCRIPTS="$PLUGIN/scripts"
TICK="$PLUGIN/fixtures/gh/tick"
unset FLEET_BOARD_CONFIG FAKE_GH_DELAY FLEET_BOARD_LOCK_WAIT || true

PASS=0
FAIL=0
CLEANUP_DIRS=()
ORIG_PATH="$PATH"
cleanup() { for d in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

# --- driver tests (python, real local board, fake merger sessions) -----------------------------------------
echo "driver"
DRIVER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/merger-attention.XXXXXX")
FLEET_BOARD_SOCKET_DIR=$(mktemp -d /tmp/fbt.XXXXXX)
export FLEET_BOARD_SOCKET_DIR
CLEANUP_DIRS+=("$DRIVER_TMP" "$FLEET_BOARD_SOCKET_DIR")
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PLUGIN/scripts" python3 - "$PLUGIN" "$DRIVER_TMP" <<'PY'
import sys
import unittest
from pathlib import Path

PLUGIN, BASE = sys.argv[1], sys.argv[2]
sys.path.insert(0, str(Path(PLUGIN) / 'fixtures' / 'supervisor'))
sys.argv = [sys.argv[0], BASE]
import merging_cases as mc  # noqa: E402


class Attention(mc.MergerFlow):
    def waiting_comment(self):
        comments = [c for c in self.b.comments(12) if c.startswith('Waiting for a person:')]
        self.assertEqual(len(comments), 1, comments)
        return comments[0]

    def test_a_refusal_mode_merger_reporting_attention_leaves_the_card_in_blocked_with_blocked_from_merging_and_one_waiting_for_a_person_comment_naming_the_reason(self):
        self.merger('refused', self.refused(), 'merger-refusal-attention')
        self.assertEqual(self.b.card(12)['state'], 'blocked')
        note = self.b.note(12)
        self.assertEqual((note['state'], note['blocked_from']), ('blocked', 'merging'))
        self.assertTrue(note['merger']['reason'])
        self.assertIn(note['merger']['reason'], self.waiting_comment())

    def test_an_after_merge_merger_reporting_attention_does_the_same_and_the_comment_says_to_move_the_card_to_merging_or_done(self):
        self.merger('merged', mc.MERGED, 'merger-after-merge-attention')
        self.assertEqual(self.b.card(12)['state'], 'blocked')
        note = self.b.note(12)
        self.assertEqual((note['state'], note['blocked_from']), ('blocked', 'merging'))
        comment = self.waiting_comment()
        self.assertIn(note['merger']['reason'], comment)
        self.assertIn('Merging', comment)
        self.assertIn('after-merge steps again', comment)
        self.assertIn('Done', comment)


def suite():
    names = unittest.TestSuite()
    for name in ('test_a_refusal_mode_merger_reporting_attention_leaves_the_card_in_blocked_with_blocked_from_merging_and_one_waiting_for_a_person_comment_naming_the_reason',
                 'test_an_after_merge_merger_reporting_attention_does_the_same_and_the_comment_says_to_move_the_card_to_merging_or_done'):
        names.addTest(Attention(name))
    return names


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=1).run(suite())
    sys.exit(0 if result.wasSuccessful() else 1)
PY
rc=$?
if [ "$rc" -eq 0 ]; then pass "driver tests"; else fail "driver tests" "python exit $rc"; fi

# --- planner tests -----------------------------------------------------------------------------------------
echo "planner"
VROOT="$(mktemp -d)"
CLEANUP_DIRS+=("$VROOT")
CLEAN_LR='"last_review":{"round":1,"sha":"abc1234","critical":0,"important":0,"findings":[]}'
BASE_NOTE='"branch":"fleet/12-add-subtract","pr":34,"round":1'

# scenario <name> <issue json> <pr json> <listing label> <listing json> <note json> [extra route line]
scenario() {
  local name="$1" d="$VROOT/$1"
  mkdir -p "$d"
  jq -c -n --argjson note "$6" '[{id:555,user:{login:"fleet-bot"},created_at:"2026-09-28T00:01:00Z",
    body:("<!-- fleet-board:manager-note -->\n### fleet-board manager note\n\n```json\n" + ($note | tojson) + "\n```\n")}]' > "$d/comments.json"
  {
    echo "api user	0	$TICK/../labels/user.json"
    echo "api repos/acme/toy/issues/12	0	$2"
    echo "api --paginate repos/acme/toy/issues/12/comments	0	$d/comments.json"
    echo "pr view 34 --repo acme/toy --json isDraft,state,mergedAt,statusCheckRollup,headRefOid	0	$3"
    echo "pr view 34 --repo acme/toy --json files*	0	$TICK/common/files-plain.json"
    for s in ready in_progress in_review merging blocked; do
      if [ "$s" = "$4" ]; then echo "issue list --repo acme/toy --label fleet:$s *	0	$5"
      else echo "issue list --repo acme/toy --label fleet:$s *	0	$TICK/common/empty.json"; fi
    done
    [ -n "${7:-}" ] && echo "$7"
  } > "$d/routes"
  REPO="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO")
  git init -q "$REPO"
  git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name T
  printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\nhuman_qa_paths: ["src/components/**"]\nmerge:\n  policy: auto\n' > "$REPO/.fleet-board.yml"
  git -C "$REPO" add .fleet-board.yml; git -C "$REPO" commit -q -m initial
  FAKE_GH_DIR="$(mktemp -d)"; CLEANUP_DIRS+=("$FAKE_GH_DIR")
  mkdir -p "$FAKE_GH_DIR/bin"; ln -s "$SCRIPT_DIR/fake-gh.sh" "$FAKE_GH_DIR/bin/gh"
  PATH="$FAKE_GH_DIR/bin:$ORIG_PATH"; FAKE_GH_ROUTES="$d/routes"
  export FAKE_GH_DIR FAKE_GH_ROUTES PATH
  cd "$REPO"
  store_sync
  PLAN="$(bash "$SCRIPT" 2>/dev/null)"
}
plan_field() { jq -r --argjson n "$1" ".cards[] | select(.number == \$n) | .$2" <<<"$PLAN"; }

scenario to-in-review "$TICK/common/issue-12-in_review.json" "$TICK/common/pr-34-open-green.json" in_review \
  "$TICK/common/list-in_review-12.json" "{\"state\":\"blocked\",\"blocked_from\":\"merging\",\"reviewed_stages\":[\"documentation\",\"blast_radius\"],$BASE_NOTE,$CLEAN_LR}"
assert_eq "a card moved from Blocked to In Review with an open PR, a clean review at the current head and green checks plans merge" \
  "$(plan_field 12 action)" "merge"

scenario to-merging "$TICK/common/issue-12-merging.json" "$TICK/common/pr-34-merged.json" merging \
  "$TICK/common/list-merging-12.json" \
  "{\"state\":\"blocked\",\"blocked_from\":\"merging\",$BASE_NOTE,$CLEAN_LR,\"merged_pr\":34,\"main_check\":{\"commit\":\"def5678\",\"ok\":true,\"results\":[]}}"
assert_eq "a card moved from Blocked to Merging whose PR is merged plans after_merge" \
  "$(plan_field 12 action)" "after_merge"

jq -c '.labels = [{name:"fleet:blocked"}]' "$TICK/common/issue-12-merging.json" > "$VROOT/issue-12-blocked.json"
jq -c '[.[0] | .number = 12 | .labels = [{name:"fleet:blocked"}]]' "$TICK/common/list-blocked-20.json" > "$VROOT/list-blocked-12.json"
scenario blocked-from-merging "$VROOT/issue-12-blocked.json" "$TICK/common/pr-34-merged.json" blocked \
  "$VROOT/list-blocked-12.json" "{\"state\":\"blocked\",\"blocked_from\":\"merging\",$BASE_NOTE,\"blocking_pr\":41}" \
  "pr view 41 --repo acme/toy --json state,mergedAt	0	$TICK/common/pr-41-merged.json"
assert_eq "a Blocked card with blocked_from merging is never planned for an automatic unblock" \
  "$(plan_field 12 action)" "skip"

# --- board move ----------------------------------------------------------------------------------------------
echo "move"
REPO="$(mktemp -d)"; CLEANUP_DIRS+=("$REPO")
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name T
printf 'board:\n  repo: acme/toy\nworktrees:\n  dir: .fw\n' > "$REPO/.fleet-board.yml"
git -C "$REPO" add .fleet-board.yml; git -C "$REPO" commit -q -m initial
mkdir -p "$REPO/.fleet-board/cards"; echo 13 > "$REPO/.fleet-board/next"
jq -n '{number: 12, title: "T", body: "b", state: "blocked", labels: [], next_comment_id: 1, comments: [],
  acceptance: ["x"], blocked_by: [], created_at: "2026-01-01T00:00:00Z"}' > "$REPO/.fleet-board/cards/12.json"
unset FLEET_BOARD_USER; export FLEET_BOARD_USER=tester
PATCH="$REPO/patch.json"
printf '%s' '{"state":"blocked","blocked_from":"merging","merger":{"mode":"refusal","status":"attention","reason":"r","head":"abc1234"},"merge_refusal":{"pr":34,"head":"abc1234","reason":"r"},"merge_retry":{"pr":34,"head":"abc1234","after":"2026-01-01T00:00:00Z"},"pr":34}' > "$PATCH"
( cd "$REPO" && bash "$SCRIPTS/note.sh" merge 12 "$PATCH" >/dev/null 2>&1 )
( cd "$REPO" && bash "$SCRIPTS/board-move.sh" 12 in_review >/dev/null 2>&1 )
NOTE="$(cd "$REPO" && bash "$SCRIPTS/note.sh" get 12 2>/dev/null)"
assert_eq "moving a card out of Blocked clears merger, merge_refusal and merge_retry in its note" \
  "$(jq -c '[.merger, .merge_refusal, .merge_retry]' <<<"$NOTE")" "[null,null,null]"
assert_eq "the move kept the rest of the note" "$(jq -r '.pr' <<<"$NOTE")" "34"

echo "-----------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
