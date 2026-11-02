#!/usr/bin/env bash
#
# run.sh - seeded-defect eval of the fleet-board reviewer.
#
# For each defect in defects/catalogue.tsv, N times: build a throwaway git repo whose
# PR (one commit on top of an empty base) is the fixture PR with that defect's patch
# applied, dispatch the reviewer agent on it with `claude -p` and a fresh
# CLAUDE_CONFIG_DIR, and record whether the report names the defect at Critical or
# Important (parse-result.sh). Prints a catch-rate table per defect class.
# Not --bare: it removes the Agent tool, so the reviewer could never be dispatched.
# A run counts only if the transcript shows the dispatch and the report has a
# ## Findings section; any other run is an error and is left out of the catch rate.
#
# Usage: run.sh [--runs N] [--mutation on|off] [--model NAME] [--defect ID]
#                [--out DIR] [--dry-run]
#   --runs N         runs per defect (default 3)
#   --mutation M     review.mutation given to the reviewer: on (default) or off
#   --model NAME     reviewer model (default opus)
#   --defect ID      only this catalogue id
#   --out DIR        where work repos, transcripts and results.tsv go
#                    (default: a new directory under $TMPDIR)
#   --dry-run        print the exact commands, run nothing, exit 0
#
# REAL RUNS COST MONEY. Auth for the isolated session comes from FB_ISOLATE_SETTINGS
# (default ~/.config/fleet-board/bare-settings.json, an apiKeyHelper settings file).
# Exit: 0 ok, 1 a run failed, 2 usage error.
#
# Portable: bash 3.2, git, jq, node (for the fixtures), claude.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/../.." && pwd)"
CAT="$HERE/defects/catalogue.tsv"
FIX="$HERE/fixture"
SETTINGS="${FB_ISOLATE_SETTINGS:-$HOME/.config/fleet-board/bare-settings.json}"

RUNS=3
MUTATION=on
MODEL=opus
ONLY=""
OUT=""
DRY=0

usage() { sed -n '3,25p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//' >&2; }
die_usage() { echo "run.sh: $*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runs)     [ "$#" -ge 2 ] || die_usage "--runs needs a value"; RUNS="$2"; shift 2 ;;
    --mutation) [ "$#" -ge 2 ] || die_usage "--mutation needs on or off"; MUTATION="$2"; shift 2 ;;
    --model)    [ "$#" -ge 2 ] || die_usage "--model needs a name"; MODEL="$2"; shift 2 ;;
    --defect)   [ "$#" -ge 2 ] || die_usage "--defect needs an id"; ONLY="$2"; shift 2 ;;
    --out)      [ "$#" -ge 2 ] || die_usage "--out needs a directory"; OUT="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage; die_usage "unknown flag: $1" ;;
  esac
done
case "$RUNS" in ''|*[!0-9]*|0) die_usage "--runs must be a positive integer, got: $RUNS" ;; esac
case "$MUTATION" in on|off) ;; *) die_usage "--mutation must be on or off, got: $MUTATION" ;; esac

if [ "$DRY" = 1 ]; then
  WORK="\$OUT/work"
else
  [ -n "$OUT" ] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/fb-eval.XXXXXX")"
  mkdir -p "$OUT/work" || die_usage "cannot create $OUT"
  WORK="$OUT/work"
fi

# The reviewer's inputs for one defect run, written to $1 (real runs only).
write_prompt() {
  local file="$1" repo="$2" pr="$3"
  {
    echo "Use the Agent tool to dispatch the fleet-board:reviewer agent with model \"$MODEL\" and exactly the prompt between the BEGIN and END lines, then print its final report verbatim."
    echo "BEGIN"
    echo "Review round 1 of a card. There is no GitHub PR and no board: do not call gh or board-comment.sh; your final reply is the report. The review worktree is $repo (branch pr, base branch main)."
    echo "Config: review.mutation=$([ "$MUTATION" = on ] && echo true || echo false), review.verify_claim=true, commands.test_one=\"bash {file}\", no typecheck, no lint."
    echo "The test file to run is the fixture's test/*.test.js; a single file runs with: bash test.sh (it runs each test file in turn)."
    echo
    echo "Card body:"
    cat "$FIX/$pr/card.md"
    echo
    echo "PR diff (git diff main..pr):"
    git -C "$repo" diff main..pr
    echo
    echo "Latest implementor report: Status done. All Acceptance items have passing tests. VERIFIED: bash test.sh -> every test passed."
    echo "END"
  } > "$file"
}

# Build the throwaway repo: empty base on main, one PR commit on branch pr.
build_repo() {
  local repo="$1" pr="$2" patch="$3"
  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=eval@example.invalid -c user.name=eval commit -q --allow-empty -m base
  git -C "$repo" checkout -q -b pr
  cp -R "$FIX/$pr/." "$repo/"
  rm -f "$repo/card.md"
  (cd "$repo" && git apply "$HERE/defects/$patch") || return 1
  git -C "$repo" add -A
  git -C "$repo" -c user.email=eval@example.invalid -c user.name=eval commit -q -m "PR: $pr"
}

# True when the stream-json transcript $1 shows a dispatch of the reviewer agent.
reviewer_dispatched() {
  jq -e 'select(.type == "assistant") | .message.content[]?
    | select(.type == "tool_use" and .input.subagent_type? == "fleet-board:reviewer")' "$1" >/dev/null 2>&1
}

RESULTS="${OUT:+$OUT/results.tsv}"
[ "$DRY" = 1 ] || : > "$RESULTS"
failed=0

while IFS="$(printf '\t')" read -r id class pr patch pattern; do
  [ -z "$id" ] && continue
  case "$id" in \#*) continue ;; esac
  [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  n=1
  while [ "$n" -le "$RUNS" ]; do
    repo="$WORK/$id-$n"
    prompt="$WORK/$id-$n.prompt"
    cmd="cd $repo && CLAUDE_CONFIG_DIR=\"\$(mktemp -d)\" claude -p --settings $SETTINGS --plugin-dir $PLUGIN_DIR --model $MODEL --permission-mode bypassPermissions --max-turns 80 --output-format stream-json --verbose \"\$(cat $prompt)\" </dev/null"
    if [ "$DRY" = 1 ]; then
      echo "# defect=$id class=$class pr=$pr run=$n/$RUNS mutation=$MUTATION model=$MODEL"
      echo "$cmd"
    else
      echo "[eval] $id run $n/$RUNS" >&2
      if ! build_repo "$repo" "$pr" "$patch"; then
        echo "[eval] could not build $id" >&2; failed=1; n=$((n + 1)); continue
      fi
      write_prompt "$prompt" "$repo" "$pr"
      cfg="$(mktemp -d "${TMPDIR:-/tmp}/fb-eval-cfg.XXXXXX")"
      (cd "$repo" && CLAUDE_CONFIG_DIR="$cfg" claude -p --settings "$SETTINGS" \
        --plugin-dir "$PLUGIN_DIR" --model "$MODEL" --permission-mode bypassPermissions \
        --max-turns 80 --output-format stream-json --verbose "$(cat "$prompt")" \
        > "$WORK/$id-$n.jsonl" 2> "$WORK/$id-$n.stderr" </dev/null)
      rm -rf "$cfg"
      jq -r 'select(.type == "result") | .result // empty' "$WORK/$id-$n.jsonl" > "$WORK/$id-$n.report.md" 2>/dev/null
      cost="$(jq -r 'select(.type == "result") | .total_cost_usd // 0' "$WORK/$id-$n.jsonl" 2>/dev/null | tail -1)"
      [ -n "$cost" ] || cost=0
      if reviewer_dispatched "$WORK/$id-$n.jsonl" && grep -q '^## Findings' "$WORK/$id-$n.report.md"; then
        verdict="$(bash "$HERE/parse-result.sh" "$WORK/$id-$n.report.md" "$id")"
      else
        echo "[eval] $id run $n: reviewer not dispatched, or no ## Findings in the report" >&2
        verdict=error; failed=1
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$class" "$n" "$MODEL" "$MUTATION" "$verdict" "$cost" >> "$RESULTS"
    fi
    n=$((n + 1))
  done
done < "$CAT"

[ "$DRY" = 1 ] && exit 0

echo
echo "| class | model | mutation | caught | runs | catch rate | cost (USD) |"
echo "|---|---|---|---|---|---|---|"
LC_ALL=C awk -F'\t' '
  { seen[$2] = 1; if ($6 != "error") runs[$2]++; if ($6 == "caught") c[$2]++; cost[$2] += $7; m[$2] = $4; mu[$2] = $5 }
  END {
    for (k in seen) {
      rate = runs[k] ? sprintf("%.0f%%", 100 * c[k] / runs[k]) : "n/a"
      printf "| %s | %s | %s | %d | %d | %s | %.2f |\n", k, m[k], mu[k], c[k], runs[k], rate, cost[k]
    }
  }
' "$RESULTS" | sort
echo
errored="$(awk -F'\t' '$6 == "error" { n++ } END { print n + 0 }' "$RESULTS")"
[ "$errored" = 0 ] || echo "$errored run(s) errored and are left out of the catch rate; see the .report.md and .jsonl files in $WORK"
echo "Per-run results: $RESULTS"
exit "$failed"
