# version-lib.sh - which version keys a branch bumped, for supervisor.version_files.
# Sourced by tick-plan.sh and update-branch.sh so both use one rule. Needs jq,
# git and the text of path-glob.jq + versions.jq in $VL_JQ.
#
# A key K of file F counts as changed by the branch when one of the branch's own
# non-merge commits (git log --no-merges <base>..<head> -- F) changed K against
# that commit's first parent. Merges of the base, earlier or lingering, never
# count, and no merge base is needed, so a merge cannot hide the branch's bump.

# vl_files <dir> <base-ref> <head-rev>: the files the branch's own non-merge commits touch
vl_files() {
  git -C "$1" log --no-merges --format= --name-only "$2..$3" -- | sort -u
}

# vl_changes <dir> <base-ref> <head-rev> <file> <tmpdir>: prints the versions.jq
# vr_raise list for <file> at <head-rev> (keys the branch changed whose head value
# is not strictly above <base-ref>'s), or [] when the file is missing on either side
# or is not JSON. Exit 1 when git cannot list the commits.
vl_changes() {
  local d="$1" b="$2" h="$3" f="$4" t="$5" commits c
  commits="$(git -C "$d" log --no-merges --format=%H "$b..$h" -- "$f")" || return 1
  [ -n "$commits" ] || { echo '[]'; return 0; }
  git -C "$d" show "$h:$f" > "$t/vl-head.json" 2>/dev/null || { echo '[]'; return 0; }
  git -C "$d" show "$b:$f" > "$t/vl-base.json" 2>/dev/null || { echo '[]'; return 0; }
  jq -e 'type == "object" or type == "array"' "$t/vl-head.json" "$t/vl-base.json" >/dev/null 2>&1 || { echo '[]'; return 0; }
  printf '[]\n' > "$t/vl-changed.json"
  for c in $commits; do
    git -C "$d" show "$c:$f" > "$t/vl-after.json" 2>/dev/null || printf 'null\n' > "$t/vl-after.json"
    git -C "$d" show "$c^:$f" > "$t/vl-parent.json" 2>/dev/null || printf 'null\n' > "$t/vl-parent.json"
    jq -e . "$t/vl-after.json" >/dev/null 2>&1 || printf 'null\n' > "$t/vl-after.json"
    jq -e . "$t/vl-parent.json" >/dev/null 2>&1 || printf 'null\n' > "$t/vl-parent.json"
    jq -c --slurpfile a "$t/vl-after.json" --slurpfile p "$t/vl-parent.json" \
      "$VL_JQ"' (. + vr_diff_paths($a[0]; $p[0])) | unique' "$t/vl-changed.json" > "$t/vl-changed.new" || return 1
    mv "$t/vl-changed.new" "$t/vl-changed.json"
  done
  jq -c --slurpfile k "$t/vl-changed.json" --slurpfile s "$t/vl-base.json" "$VL_JQ"' vr_raise($k[0]; $s[0])' "$t/vl-head.json"
}
