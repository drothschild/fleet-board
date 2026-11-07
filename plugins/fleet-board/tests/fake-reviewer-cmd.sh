#!/usr/bin/env bash
# Run a scripted reply or side effect for one attempt of an offline review.
set -eu
dir="$1"
model="$2"
case_dir="$FAKE_REVIEWER_DIR"
attempt=1
if [ -f "$case_dir/attempt" ]; then
  attempt=$(($(cat "$case_dir/attempt") + 1))
fi
printf '%s\n' "$attempt" > "$case_dir/attempt"
printf '%s\n' "$dir" > "$case_dir/clone"
printf '%s\n' "$model" > "$case_dir/model"
pwd -P > "$case_dir/cwd"
printf '%s\n' "${TMPDIR:-}" > "$case_dir/tmpdir"
cat > "$case_dir/prompt.$attempt"
while IFS=' ' read -r action arg; do
  case "$action" in
    reply) cat "$case_dir/$arg" ;;
    write) printf 'changed\n' > "$arg" ;;
    commit) git add . && git -c user.name=Test -c user.email=test@example.com commit -qm mutant ;;
    pause) sleep "$arg" ;;
    sleep) exec sleep "$arg" ;;
    exit) exit "$arg" ;;
    push-pr-head) git -C "$FAKE_REVIEWER_SEED" push -q origin HEAD:refs/pull/7/head ;;
    '') ;;
    *) echo "unknown fake reviewer action: $action" >&2; exit 1 ;;
  esac
done < "$FAKE_REVIEWER_SCRIPT.$attempt"
