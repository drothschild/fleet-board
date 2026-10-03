#!/usr/bin/env bash
# fleet-board gate: PreToolUse(Bash). Exit 2 blocks. Inert without .fleet-board.yml.
#
# Gates (the phase 4 "Gate rules"):
#   G1  no Bash command moves a card out of human_qa (board-move, gh issue edit,
#       gh project item-edit/-archive/-delete, gh label edit/delete of a state
#       label, raw label/Status API writes)
#   G2  gh pr merge: blocked under merge.policy human; under auto, never --admin,
#       never without an explicit PR, never a draft, never with checks that are
#       not green; raw merges blocked
#   G3  board-move N ready needs a '## Acceptance' section on the card
#
# A block is exit 2 with one line on stderr. Within the shapes it recognizes,
# the hook never lets a real call through: when a gated command is present and
# the hook cannot tell what it does (a variable or substitution where a card,
# label, PR, state or directory belongs), or cannot read the board or PR state
# in time, the command is blocked. Each shape is judged in the directory it
# will run in (the payload cwd, or the target of a cd before it); a directory
# without .fleet-board.yml makes it inert. Commands without a gated keyword
# exit 0 after one jq call, without reading the config or touching the
# network. Nothing is ever printed on stdout.
#
# Subagent calls (payloads with agent_id/agent_type) are treated exactly like
# manager calls; the hook never looks at those fields. The hook runs with the
# session's environment, so a gh lookup without -R resolves the repo the same
# way the gated gh command will.
set -uo pipefail
SESSION_CDPATH="${CDPATH:-}" # the gated command's cd follows it (see track_cd)
unset CDPATH # the hook's own cd must not follow CDPATH (it would also echo the path)
exec >/dev/null

# block REASON: the lexer's $SUB placeholder is shown as $(...)
block() { local m="$1"; m="${m//\$SUB/\$(...)}"; printf 'fleet-board gate: %s\n' "$m" >&2; exit 2; }

# pattern_match PATTERN: sets PAT_GH to 1 when PATTERN (a word with a glob or
# a brace expansion) may expand to gh, and PAT_MOVE to 1 when it may expand
# to board-move or board-move.sh, or to 2 when only to move.sh (an adapter's).
# A brace group is taken as matching anything (* in its place); matching
# ignores case, as for literal command words.
pattern_match() {
  local p="$1"
  PAT_GH=0; PAT_MOVE=0
  case "$p" in *'{'*'}'*) p="${p%%\{*}*${p##*\}}" ;; esac
  p="${p##*/}"
  [ -n "$p" ] || return 0
  shopt -s nocasematch
  case gh in $p) PAT_GH=1 ;; esac
  case move.sh in $p) PAT_MOVE=2 ;; esac
  case board-move in $p) PAT_MOVE=1 ;; esac
  case board-move.sh in $p) PAT_MOVE=1 ;; esac
  shopt -u nocasematch
}

# glob_hits TEXT: TEXT (the command flattened as for the keyword filter) has
# a word with $ in it, or a word that may expand to board-move or move.sh and
# something that may be a card number (a digit, or a word of only # ? * { }
# , . [ ] -; see card_like). A command without a gated keyword can only make a
# shape through such words: a pattern that expands to gh still needs a gated
# group and verb (pr merge, issue edit, ...), which are keywords.
glob_hits() {
  local w hit=0 card=0 IFS=$' \t\n;&|()<>`'
  case "$1" in *[0-9]*) card=1 ;; esac
  set -f
  for w in $1; do
    case "$w" in
      *'$'*) set +f; return 0 ;;
      *[!#?*{},.\[\]-]*) ;;
      *) card=1 ;;
    esac
    case "$w" in
      *[\*\?\[]*|*'{'*[,.]*'}'*)
        [ $hit = 1 ] && continue
        pattern_match "$w"
        [ "$PAT_MOVE" = 0 ] || hit=1 ;;
    esac
  done
  set +f
  [ $hit = 1 ] && [ $card = 1 ]
}

# One jq call reads the payload and applies the keyword filter. Its text is
# the command without backslash-newlines, quote and backslash characters, in
# lower case (macOS runs GH as gh). It prints "K" and the command for a Bash
# call that contains a gated keyword or uses $'...' quoting. Otherwise, when
# the text has a glob or brace expansion, it prints "G", the text, US and the
# command: a pattern such as board-mov?.sh can be a gated command word
# without spelling a keyword, and glob_hits decides in bash whether the
# command needs the full parse. Else it prints nothing. The filter uses
# literal split/join, not regular expressions, and not bash's ${var//...},
# which is quadratic in bash 3.2.
# A payload that is not JSON, or a missing jq, gives no command and exit 0:
# there is no Bash command to read. Every fleet-board script requires jq.
US=$'\037' # field separator of the lexer output and of the SHAPES lines
PAYLOAD="$(cat)" || exit 0
OUT="$(jq -r '
  ([39] | implode) as $q
  | (if .tool_name == "Bash" then (.tool_input.command // "" | tostring) else "" end) as $c
  | ($c | split("\\\n") | join("") | split($q) | join("") | split("\"") | join("")
        | split("\\") | join("") | ascii_downcase) as $f
  | if ($f | contains("board-move") or contains("gh") or contains("merge") or contains("move.sh")
           or contains("graphql") or contains("label") or contains("edit") or contains("item-"))
       or ($c | contains("$" + $q))
    then "K" + $c
    elif ($f | contains("?") or contains("*") or contains("[")
               or (contains("{") and (contains(",") or contains(".."))))
    then "G" + ($f | split("\u001f") | join(" ")) + "\u001f" + $c
    else "" end' <<<"$PAYLOAD" 2>/dev/null)" || exit 0
case "$OUT" in
  K*) CMD="${OUT#K}" ;;
  G*) glob_hits "${OUT%%$US*}" || exit 0; CMD="${OUT#*$US}" ;;
  *) exit 0 ;;
esac
[ -n "$CMD" ] || exit 0

MAX_CHARS=65536    # longest command the hook parses
MAX_SHAPES=32      # most gated commands in one call
MAX_WORDS=4000     # most words after one gated command word
MAX_DIRS=16        # most directories one command may run in
[ ${#CMD} -le $MAX_CHARS ] \
  || block "command is too long to check (${#CMD} characters, limit $MAX_CHARS); blocking to be safe"

CWD="$(jq -r '.cwd // ""' <<<"$PAYLOAD" 2>/dev/null)" || exit 0
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$(cd "$HOOKS/../scripts" && pwd)"
NL=$'\n'

# --- parsing -----------------------------------------------------------------
# gate-lex.awk turns the command into scoped segments of shell words (see its
# header). SHAPES holds one line per recognized shape; fields are separated by $US:
#   move    N STATE
#   edit    NUMS NUM-UNKNOWN LABEL-UNKNOWN SEGMENT-TEXT
#   item    ITEM-ID
#   merge   ARG ADMIN REPO EXTRA-REFS XARGS (1 when xargs may supply words)
#   label   NAME-UNKNOWN SEGMENT-TEXT
#   opaque  REASON          (a gated command the hook cannot read)
#   rawstate
#   rawmerge
# SHAPE_DIRS[k] lists the directories shape k may run in (one per line), and
# SHAPE_DYN[k] names the command that made its directory unknowable, if any.
SHAPES=()
SHAPE_DIRS=()
SHAPE_DYN=()
TOK=()
NTOK=0
JOINED=""
OPEN=0     # an xargs earlier in the segment may append words to a command
API=0      # a gh api or curl call is present
API_DIRS=""
API_DYN=""
WRITE=0    # a word that makes a gh api or curl call a write is present
PM=0       # the previous word was -X/--method/--request
LOW=""     # the flattened command, from the lexer
CUR_DIRS=""
CUR_DYN=""
# per-scope directory state, indexed by the lexer's scope number
SDIRS=()
SDYN=()
SCMP=()    # open compound commands per scope (see track_cd)
BR=0       # { words in the current segment
CDSEEN=0   # the command changes directory somewhere (cd, pushd, popd, ...)
DEFER=0    # the command defines a function or a trap: its body runs later
PUSHED=0   # a pushd with a directory filled the directory stack
ENVCD=0    # a cd depends on HOME, CDPATH or the directory stack
ENVRISK=0  # the command may set HOME, CDPATH or DIRSTACK
ASG=0      # the current segment has a builtin that assigns variables
# Closers cannot be trusted when the lexer reads text as commands that the
# shell does not: here-documents, [[ ]] and comments (see track_cd). The
# lexer also reports those it finds in decoded text ($'\x23'), and a [[ word
# sets it in the main loop.
NOPOP=0
case "$CMD" in *'<<'*|*'[['*|'#'*|*[[:space:]\;\&\|\(\)]'#'*) NOPOP=1 ;; esac

# is_dyn WORD: the shell expands WORD at run time (a variable, a substitution,
# a glob or a brace/tilde expansion), so the hook cannot know its value
is_dyn() { case "$1" in *[\$\`\*\?\[\{\~]*) return 0 ;; esac; return 1; }

# issue_ref TOKEN: sets REF to the issue number TOKEN names (14, #14, or an
# issue URL), or to ""
issue_ref() {
  REF="${1#\#}"
  case "$REF" in */issues/*) REF="${REF##*/}" ;; esac
  case "$REF" in ''|*[!0-9]*) REF="" ;; esac
}

# pr_ref TOKEN: sets REF to TOKEN when it names a PR by number or URL, else ""
pr_ref() {
  REF="${1#\#}"
  case "$REF" in */pull/*) REF="${REF##*/}" ;; esac
  case "$REF" in ''|*[!0-9]*) REF="" ;; *) REF="$1" ;; esac
}

add_shape() {
  [ ${#SHAPES[@]} -lt $MAX_SHAPES ] \
    || block "too many board or merge commands in one call (more than $MAX_SHAPES); run them separately"
  SHAPES+=("$1")
  SHAPE_DIRS+=("${2:-$CUR_DIRS}")
  SHAPE_DYN+=("${3-$CUR_DYN}")
}

# words_ok K WHAT: the words from K on are few enough to check; else records
# an opaque shape and fails
words_ok() {
  [ $((NTOK - $1)) -le $MAX_WORDS ] && return 0
  add_shape "opaque${US}too many words after $2 to check (limit $MAX_WORDS); blocking to be safe"
  return 1
}

# parse_move I: board-move[.sh] N STATE (also an adapter's move.sh N STATE)
# After xargs no word can be trusted, even a literal card and state: xargs
# may append more, and -I/-J may name any literal (-I 13 board-move.sh 13
# done moves the card read from stdin), so the move is opaque.
parse_move() {
  local n="${TOK[$1+1]:-}" st="${TOK[$1+2]:-}"
  if [ "$OPEN" = 1 ]; then
    add_shape "opaque${US}could not verify the card or state of board-move under xargs; blocking to be safe"
    return 0
  fi
  if [ -z "$st" ]; then
    # fewer than two words: board-move.sh refuses that, unless a word the
    # hook cannot read supplies the rest
    is_dyn "$n" || return 0
    n="${n:-\$ARGS}"; st='$ARGS'
  fi
  add_shape "move$US$n$US$st"
}

# parse_issue_edit K: gh issue edit N... [--add-label L,...] [--remove-label L,...]
# Recorded only when a label flag is present: other edits never move a card.
parse_issue_edit() {
  local k=$1 t v nums="" numdyn=0 lf=0 labdyn=0
  words_ok "$k" "gh issue edit" || return 0
  [ "$OPEN" = 1 ] && { lf=1; labdyn=1; numdyn=1; }
  while [ $k -lt $NTOK ]; do
    t="${TOK[k]}"; v=""
    case "$t" in
      --add-label|--remove-label) lf=1; v="${TOK[k+1]:-}"; k=$((k + 1)) ;;
      --add-label=*|--remove-label=*) lf=1; v="${t#*=}" ;;
      -t|--title|-b|--body|-F|--body-file|-m|--milestone|-R|--repo|--add-assignee|--remove-assignee|--add-project|--remove-project)
        k=$((k + 1)) ;;
      -*) ;;
      *)
        if is_dyn "$t"; then numdyn=1
        else issue_ref "$t"; [ -n "$REF" ] && nums="$nums $REF"
        fi ;;
    esac
    [ -n "$v" ] && is_dyn "$v" && labdyn=1
    k=$((k + 1))
  done
  [ "$lf" = 1 ] || return 0
  [ -n "$nums" ] || numdyn=1
  add_shape "edit$US$nums$US$numdyn$US$labdyn$US$JOINED"
}

# parse_item K: gh project item-edit|item-archive|item-delete ... --id ITEM ...
# Without a readable --id the item is unknown (recorded empty).
parse_item() {
  local k=$1 t id=""
  words_ok "$k" "gh project" || return 0
  while [ $k -lt $NTOK ]; do
    t="${TOK[k]}"
    case "$t" in
      --id) id="${TOK[k+1]:-}"; k=$((k + 1)) ;;
      --id=*) id="${t#--id=}" ;;
    esac
    k=$((k + 1))
  done
  add_shape "item$US$id"
}

# parse_merge K GLOBAL-REPO: gh pr merge [ARG] [flags]
# ARG is the first token that is neither a flag nor a flag's value. Later
# tokens that name a PR by number or URL are kept as EXTRA refs and checked
# too, so a stray word can never stand in for the real ARG.
parse_merge() {
  local k=$1 repo="$2" t arg="" admin=0 extra=""
  words_ok "$k" "gh pr merge" || return 0
  while [ $k -lt $NTOK ]; do
    t="${TOK[k]}"
    case "$t" in
      --admin) admin=1 ;;
      --admin=*) [ "${t#--admin=}" = false ] || admin=1 ;;
      -R|--repo) repo="${TOK[k+1]:-}"; k=$((k + 1)) ;;
      --repo=*) repo="${t#--repo=}" ;;
      -R?*) repo="${t#-R}" ;;
      -b|--body|-F|--body-file|-t|--subject|-A|--author-email|--match-head-commit) k=$((k + 1)) ;;
      -*) ;;
      *)
        if [ -z "$arg" ]; then
          arg="$t"
        else
          pr_ref "$t"; [ -n "$REF" ] && extra="$extra $REF"
        fi
        ;;
    esac
    k=$((k + 1))
  done
  # under xargs the PR (or a flag such as --admin) may come from stdin
  add_shape "merge$US$arg$US$admin$US$repo$US$extra$US$OPEN"
}

# parse_label K: gh label edit|delete NAME [--name NEW] ...
# After xargs the name may come from stdin, so it is unknown.
parse_label() {
  local k=$1 dyn=0
  words_ok "$k" "gh label" || return 0
  [ "$OPEN" = 1 ] && dyn=1
  while [ $k -lt $NTOK ]; do
    is_dyn "${TOK[k]}" && dyn=1
    k=$((k + 1))
  done
  add_shape "label$US$dyn$US$JOINED"
}

# skip_repo: advances J past gh's repo/host flags, recording the repo in RREPO
skip_repo() {
  while [ $J -lt $NTOK ]; do
    case "${TOK[J]}" in
      -R|--repo) RREPO="${TOK[J+1]:-}"; J=$((J + 2)) ;;
      --repo=*) RREPO="${TOK[J]#--repo=}"; J=$((J + 1)) ;;
      -R?*) RREPO="${TOK[J]#-R}"; J=$((J + 1)) ;;
      --hostname) J=$((J + 2)) ;;
      --hostname=*) J=$((J + 1)) ;;
      *) return 0 ;;
    esac
  done
}

# parse_gh I STRICT: gh [repo flags] <group> [repo flags] <verb> ...
# STRICT is 1 when word I is gh itself, 0 when it is a word the hook cannot
# read ($G, $(which gh)) that may expand to gh: then only a recognized
# group and verb make a shape.
parse_gh() {
  local grp verb
  J=$(($1 + 1)); RREPO=""
  skip_repo
  grp="${TOK[J]:-}"; J=$((J + 1))
  skip_repo
  verb="${TOK[J]:-}"
  case "$grp" in
    api) API=1; API_DIRS="$API_DIRS$NL$CUR_DIRS"; [ -n "$CUR_DYN" ] && API_DYN="$CUR_DYN"; return 0 ;;
  esac
  case "$grp $verb" in
    "issue edit") parse_issue_edit $((J + 1)) ;;
    "project item-edit"|"project item-archive"|"project item-delete") parse_item $((J + 1)) ;;
    "pr merge") parse_merge $((J + 1)) "$RREPO" ;;
    "label edit"|"label delete") parse_label $((J + 1)) ;;
    *)
      [ "$2" = 1 ] || return 0
      # a subcommand the hook cannot read: a variable or substitution
      # (gh "$@", gh $CMD), or words that xargs appends
      if is_dyn "$grp" || { [ "$OPEN" = 1 ] && [ -z "$grp" ]; }; then
        add_shape "opaque${US}could not verify the gh subcommand (gh ${grp:-with words from xargs}); blocking to be safe"
      else
        case "$grp" in
          pr|issue|project|label)
            if is_dyn "$verb" || { [ "$OPEN" = 1 ] && [ -z "$verb" ]; }; then
              add_shape "opaque${US}could not verify the gh subcommand (gh $grp ${verb:-with words from xargs}); blocking to be safe"
            fi ;;
        esac
      fi ;;
  esac
  return 0
}

# card_like WORD: WORD may be a card number: 14, #14, an issue URL, a word
# the hook cannot read with $ or ` in it, or digits with glob/brace
# characters (1?, {14,}); not a path or a name such as tests/*.sh
card_like() {
  issue_ref "$1"
  [ -n "$REF" ] && return 0
  case "$1" in
    *'$'*|*'`'*) return 0 ;;
    ''|*[!0-9#?*{},.\[\]-]*) return 1 ;;
  esac
  return 0
}

# pattern_word WORD I: WORD has a glob or brace expansion, so it may expand to
# a command word (g? g[h] {gh,} board-mov?.sh). Each command word it can match
# (see pattern_match) is parsed as with parse_gh I 0 or parse_move I; a
# board-move only when the next word may be a card number, since *.sh or *
# as an argument matches board-move.sh too (ls *.sh tests/*.sh).
pattern_word() {
  pattern_match "$1"
  [ "$PAT_GH" = 0 ] || parse_gh "$2" 0
  [ "$PAT_MOVE" = 0 ] && return 0
  card_like "${TOK[$2+1]:-}" || return 0
  case "$PAT_MOVE" in
    1) parse_move "$2" ;;
    2) case "$LOW" in *adapters*) parse_move "$2" ;; esac ;;
  esac
  return 0
}

# note_write T: records whether word T makes a gh api or curl call a write
note_write() {
  if [ "$PM" = 1 ]; then
    PM=0
    case "$1" in [Gg][Ee][Tt]|[Hh][Ee][Aa][Dd]) ;; *) WRITE=1 ;; esac
  fi
  case "$1" in
    -X|--method|--request) PM=1 ;;
    --method=*|--request=*|-X?*)
      case "${1#*=}" in [Gg][Ee][Tt]|[Hh][Ee][Aa][Dd]|-X[Gg][Ee][Tt]|-X[Hh][Ee][Aa][Dd]) ;; *) WRITE=1 ;; esac ;;
    -f|-F|--field|--raw-field|--input|--field=*|--raw-field=*|--input=*|-f?*|-F?*) WRITE=1 ;;
    -d|-d?*|--data|--data=*|--data-*|--json|--json=*|-T|--upload-file|--upload-file=*|--form|--form=*) WRITE=1 ;;
  esac
}

# starts_compound WORD: WORD is a reserved word (or time) that track_cd acts
# on at the start of a segment: it opens or closes a compound command, or
# comes before the command word
starts_compound() {
  case "$1" in
    if|while|until|then|do|else|elif|'!'|'{'|time|case|for|select|function|coproc|'[['|in|fi|done|esac|'}') return 0 ;;
  esac
  return 1
}

# track_cd SID BEFORE AFTER: updates scope SID's directories after a segment.
#
# Compound commands: SCMP[SID] holds the scope's open compound commands, one
# character each: i (if), l (while/until/for/select), c (case), g ({ }). The
# reserved words at the start of a segment open and close them (the lexer
# marks a quoted one with a backslash, and it is then an ordinary word), and
# every { word opens one (function f {, coproc x {). A closer counts only
# where the shell reads one: at the start of a command after ^ ; NL or &, not
# in a case pattern, and only when the command has no here-document, [[ ]]
# or comment, whose text the lexer reads as commands (NOPOP). An extra
# opener only makes the hook more careful; a false closer would not.
#
# The command word comes after those reserved words, assignments, and
# builtin/command/time with -p or --. When it is cd or pushd, the segment
# moves the scope definitely when no compound command is open, it starts an
# and-or list (after ^ ; or a newline) and it does not end in | || or &;
# otherwise the old directories stay possible too. A relative cd that may run
# more than once (in a loop) makes the directory unknowable, as do popd,
# eval, source, a cd to a word the hook cannot read, more than MAX_DIRS
# possible directories, and a command word the hook cannot read that is not
# a path (c=cd; $c DIR).
track_cd() {
  local sid="$1" k=0 w t d nd dirs="" n=0 cmp="" all load=0
  # SCMP[SID] is read and written only when the segment may change it or a cd
  # needs it: a bash 3.2 array is a list, and each access walks it
  [ $BR -gt 0 ] && load=1
  starts_compound "${TOK[0]}" && load=1
  [ $load = 1 ] && cmp="${SCMP[sid]:-}"
  while [ $BR -gt 0 ]; do cmp="${cmp}g"; BR=$((BR - 1)); done
  while [ $load = 1 ] && [ $k -lt $NTOK ]; do
    case "${TOK[k]}" in
      if) cmp="${cmp}i" ;;
      while|until) cmp="${cmp}l" ;;
      then|do|else|elif|'!'|'{') ;;
      time) while [ $((k + 1)) -lt $NTOK ]; do
              case "${TOK[k+1]}" in -p|--) k=$((k + 1)) ;; *) break ;; esac
            done ;;
      case) SCMP[sid]="${cmp}c"; return 0 ;;
      for|select) SCMP[sid]="${cmp}l"; return 0 ;;
      function) DEFER=1; SCMP[sid]="$cmp"; return 0 ;;
      coproc|'[['|in) SCMP[sid]="$cmp"; return 0 ;;
      fi|done|esac|'}')
        if [ "$NOPOP" = 0 ] && [ "$3" != ')' ]; then
          case "$2" in '^'|';'|NL|'&') cmp="${cmp%?}" ;; esac
        fi
        SCMP[sid]="$cmp"; return 0 ;;
      *) break ;;
    esac
    k=$((k + 1))
  done
  [ $load = 0 ] || SCMP[sid]="$cmp"
  while [ $k -lt $NTOK ]; do
    case "${TOK[k]}" in
      [A-Za-z_]*=*) ;;
      builtin|command)
        while [ $((k + 1)) -lt $NTOK ]; do
          case "${TOK[k+1]}" in -p|--) k=$((k + 1)) ;; *) break ;; esac
        done ;;
      *) break ;;
    esac
    k=$((k + 1))
  done
  w="${TOK[k]:-}"
  case "$w" in
    cd|pushd) ;;
    popd|eval|source|.) CDSEEN=1; SDYN[sid]="$w"; return 0 ;;
    trap) DEFER=1; return 0 ;;
    */*) return 0 ;;
    *) is_dyn "$w" && { CDSEEN=1; SDYN[sid]="$w"; }; return 0 ;;
  esac
  CDSEEN=1
  [ $load = 1 ] || cmp="${SCMP[sid]:-}"
  k=$((k + 1))
  while [ $k -lt $NTOK ]; do
    case "${TOK[k]}" in -L|-P|-e|-@|--) k=$((k + 1)) ;; *) break ;; esac
  done
  t="${TOK[k]:-}"
  # cd "" stays where it is (the lexer prints an empty word as "", and a
  # word that really is "" as \"\")
  [ "$t" = '""' ] && return 0
  [ "$t" = '\"\"' ] && t='""'
  if [ "$w" = pushd ]; then
    case "$t" in
      ''|[+-][0-9]*)
        # pushd without a directory rotates the directory stack: it fails
        # while the stack is empty (a new shell), unless a pushd before it
        # in the command filled it
        [ "$PUSHED" = 0 ] && { ENVCD=1; return 0; }
        SDYN[sid]="$w ${TOK[k]:-}"; return 0 ;;
    esac
    PUSHED=1
  fi
  # HOME decides a bare cd and ~; CDPATH decides a relative cd that does not
  # start with . or .. (the command may set either: see ENVCD)
  case "$t" in
    ''|'~'|'~/'*)
      ENVCD=1
      [ -n "${HOME:-}" ] || { SDYN[sid]="$w ${TOK[k]:-} (HOME is not set)"; return 0; }
      case "$t" in
        ''|'~') t="$HOME" ;;
        *) t="$HOME/${t#\~/}" ;;
      esac ;;
    /*|.|..|./*|../*) ;;
    *)
      ENVCD=1
      [ -z "$SESSION_CDPATH" ] || { SDYN[sid]="$w $t (CDPATH is set)"; return 0; } ;;
  esac
  if [ "$t" = - ] || is_dyn "$t"; then
    SDYN[sid]="$w ${TOK[k]:-}"; return 0
  fi
  if [ -n "$cmp" ]; then
    case "$cmp" in
      *l*) case "$t" in /*) ;; *) SDYN[sid]="$w $t (a relative cd in a loop)"; return 0 ;; esac ;;
    esac
  fi
  # definite: the new directories replace the old ones; otherwise they are added
  all=""
  if [ -z "$cmp" ]; then
    case "$2" in
      '^'|';'|NL) case "$3" in '&&'|';'|NL|'$') all=1 ;; esac ;;
    esac
  fi
  if [ -z "$all" ]; then
    dirs="${SDIRS[sid]}"
    while IFS= read -r d; do [ -z "$d" ] || n=$((n + 1)); done <<<"$dirs"
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$t" in /*) nd="$t" ;; *) nd="$d/$t" ;; esac
    case "$NL$dirs$NL" in *"$NL$nd$NL"*) continue ;; esac
    dirs="$dirs$NL$nd"; n=$((n + 1))
  done <<<"${SDIRS[sid]}"
  if [ $n -gt $MAX_DIRS ]; then
    SDYN[sid]="$w $t: more than $MAX_DIRS possible directories"; return 0
  fi
  SDIRS[sid]="$dirs"
}

LEXED="$(printf '%s' "$CMD" | LC_ALL=C awk -f "$HOOKS/gate-lex.awk" 2>/dev/null)" \
  || block "could not parse the command; blocking to be safe"

SDIRS[0]="$CWD"; SDYN[0]=""
while IFS= read -r line; do
  IFS="$US" read -r -a TOK <<<"$line"
  case "${TOK[0]:-}" in
    '!FLAT') LOW="${line#!FLAT$US}"; continue ;;
    # a nested scope starts in its parent's directories at that point
    '!SCOPE') SDIRS[TOK[1]]="${SDIRS[TOK[2]]}"; SDYN[TOK[1]]="${SDYN[TOK[2]]}"; continue ;;
    '!FUNC') DEFER=1; continue ;;
    '!NOPOP') NOPOP=1; continue ;;
    '!DEPTH') block "the command nests too deeply to check (quotes or substitutions); blocking to be safe" ;;
    '') continue ;;
  esac
  sid="${TOK[0]}"; before="${TOK[2]}"; after="${TOK[3]}"
  CUR_DIRS="${SDIRS[sid]}"; CUR_DYN="${SDYN[sid]}"
  TOK=("${TOK[@]:4}")
  NTOK=${#TOK[@]}
  [ "$NTOK" -gt 0 ] || continue
  JOINED="${TOK[*]}"
  OPEN=0; PM=0; BR=0; ASG=0
  # Every word whose basename is a command word is a candidate; each one is
  # parsed, so a decoy (sudo -u gh gh ...) cannot hide the real call behind
  # it. Command words match in any case: macOS file systems are
  # case-insensitive, so GH runs gh there.
  i=0
  while [ $i -lt $NTOK ]; do
    t="${TOK[i]}"
    case "${t##*/}" in
      [Gg][Hh]) parse_gh $i 1 ;;
      [Bb][Oo][Aa][Rr][Dd]-[Mm][Oo][Vv][Ee]|[Bb][Oo][Aa][Rr][Dd]-[Mm][Oo][Vv][Ee].[Ss][Hh]) parse_move $i ;;
      [Mm][Oo][Vv][Ee].[Ss][Hh]) case "$LOW" in *adapters*) parse_move $i ;; esac ;;
      [Cc][Uu][Rr][Ll]) API=1; API_DIRS="$API_DIRS$NL$CUR_DIRS"; [ -n "$CUR_DYN" ] && API_DYN="$CUR_DYN" ;;
      [Xx][Aa][Rr][Gg][Ss]) OPEN=1 ;;
      '{') BR=$((BR + 1)) ;;
      export|declare|typeset|local|readonly|read|mapfile|readarray|let) ASG=1 ;;
      printf) ASG=2 ;;
      '[[') NOPOP=1 ;;
      *'$'*|*'`'*)
        # a word the hook cannot read may be gh, or board-move when a card
        # number and a state follow it ($(which board-move.sh) 14 done)
        parse_gh $i 0
        issue_ref "${TOK[i+1]:-}"
        [ -n "$REF" ] && [ -n "${TOK[i+2]:-}" ] && parse_move $i
        case "$t" in *[\*\?\[]*|*'{'*[,.]*'}'*) pattern_word "$t" $i ;; esac ;;
      *) case "$t" in *[\*\?\[]*|*'{'*[,.]*'}'*) pattern_word "$t" $i ;; esac ;;
    esac
    case "$t" in -*) note_write "$t" ;; *) [ "$PM" = 1 ] && note_write "$t" ;; esac
    # HOME, CDPATH and DIRSTACK decide where a cd goes: set by name, or by a
    # name the hook cannot read (export "${v}ME=...", printf -v "$v"); only
    # the part before = is a name
    case "$t" in *HOME*|*CDPATH*|*DIRSTACK*) ENVRISK=1 ;; esac
    case "$ASG" in
      1) is_dyn "${t%%=*}" && ENVRISK=1 ;;
      2) [ "$t" = -v ] && ASG=3 ;;
      3) is_dyn "$t" && ENVRISK=1; ASG=2 ;;
    esac
    i=$((i + 1))
  done
  # track_cd only for a segment it may act on: most start with an ordinary
  # command word, and bash 3.2 copies a function's whole body on every call
  if [ $BR = 0 ] && ! starts_compound "${TOK[0]}"; then
    case "${TOK[0]}" in
      cd|pushd|popd|eval|source|.|trap|builtin|command|[A-Za-z_]*=*) ;;
      */*) continue ;;
      *[\$\`\*\?\[\{\~]*) ;;
      *) continue ;;
    esac
  fi
  track_cd "$sid" "$before" "$after"
done <<<"$LEXED"

# A gh api or curl call is classified by the whole command, so neither a
# quoted newline nor a variable holding the query can split the call from
# the mutation name or endpoint.
if [ "$API" = 1 ]; then
  case "$LOW" in
    *updateprojectv2itemfieldvalue*|*clearprojectv2itemfieldvalue*|*addlabelstolabelable*|*removelabelsfromlabelable*|*deleteprojectv2item*|*archiveprojectv2item*)
      add_shape "rawstate" "$API_DIRS" "$API_DYN" ;;
    *updateissue*labelids*|*labelids*updateissue*)
      add_shape "rawstate" "$API_DIRS" "$API_DYN" ;;
    */issues/*labels*|*/labels*) [ "$WRITE" = 1 ] && add_shape "rawstate" "$API_DIRS" "$API_DYN" ;;
  esac
  case "$LOW" in
    */pulls/*/merge*|*mergepullrequest*|*enablepullrequestautomerge*|*/merges*)
      add_shape "rawmerge" "$API_DIRS" "$API_DYN" ;;
  esac
fi

[ ${#SHAPES[@]} -gt 0 ] || exit 0

# Every directory a shape runs in starts from the payload's cwd. Without an
# absolute one the hook cannot tell where the command runs (a relative one
# would resolve against the hook's own directory).
case "$CWD" in
  /*) ;;
  '') block "cwd (none) in the hook payload; could not tell which directory the command runs in; blocking to be safe" ;;
  *) block "cwd $CWD is not absolute; could not tell which directory the command runs in; blocking to be safe" ;;
esac

# --- where the shapes run ------------------------------------------------------
# These change which repo or config applies, so the directory cannot decide.
case "$LOW" in
  *fleet_board_config*) block "FLEET_BOARD_CONFIG in the command; blocking to be safe" ;;
  *git_dir*) block "GIT_DIR in the command; blocking to be safe" ;;
  *git_work_tree*) block "GIT_WORK_TREE in the command; blocking to be safe" ;;
  # bash runs the file BASH_ENV names first, and it may cd
  *bash_env*) block "BASH_ENV in the command; blocking to be safe" ;;
esac
[ "$ENVCD" = 1 ] && [ "$ENVRISK" = 1 ] \
  && block "could not tell which directory the command runs in (HOME, CDPATH or the directory stack is set in the command); blocking to be safe"
GH_ENV=0
case "$LOW" in *gh_repo*|*gh_host*) GH_ENV=1 ;; esac

k=0
while [ $k -lt ${#SHAPES[@]} ]; do
  [ -z "${SHAPE_DYN[k]}" ] \
    || block "could not tell which directory the command runs in (after ${SHAPE_DYN[k]}); blocking to be safe"
  k=$((k + 1))
done

# --- config, per directory -----------------------------------------------------
# DIR_NAME[n] is a directory already read; DIR_OK[n] is 1 when it has a valid
# config, 0 when it has none (inert). The config fields are kept per directory.
DIR_NAME=()
DIR_OK=()
DIR_POLICY=()
DIR_BACKEND=()
DIR_QA=()
DIR_NAMES=()

# use_dir D: loads D's config (once) and sets CURDIR, POLICY, BACKEND,
# QA_NAME and STATE_NAMES (lower case, one per line); returns 1 when D has no
# config. Blocks when D is missing or its config is invalid or unreadable.
use_dir() {
  local d="$1" n=0 rc info
  while [ $n -lt ${#DIR_NAME[@]} ]; do
    [ "${DIR_NAME[n]}" = "$d" ] && break
    n=$((n + 1))
  done
  if [ $n -eq ${#DIR_NAME[@]} ]; then
    if [ ! -d "$d" ]; then
      [ "$d" = "$CWD" ] && block "cwd ${d:-(none)} does not exist; blocking to be safe"
      block "directory $d does not exist; blocking to be safe"
    fi
    (cd "$d" && bash "$S/config.sh" --check) >/dev/null 2>&1 </dev/null
    rc=$?
    case $rc in
      0) ;;
      3) DIR_NAME[n]="$d"; DIR_OK[n]=0; return 1 ;;
      *) block "config .fleet-board.yml is invalid; fix it before running board or merge commands" ;;
    esac
    # "policy", "backend", then one "state <canonical> <board name>" line per
    # state, tab-separated; any failure or unexpected value fails closed
    info="$(cd "$d" && . "$S/board-lib.sh" && fb_load_config >/dev/null 2>&1 \
      && p="$(fb_cfg merge.policy)" && b="$(fb_cfg board.backend)" \
      && printf 'policy\t%s\nbackend\t%s\n' "$p" "$b" \
      && for s in $FB_STATES; do printf 'state\t%s\t%s\n' "$s" "$(fb_state_name "$s")"; done)" || info=""
    DIR_POLICY[n]="$(printf '%s\n' "$info" | awk -F'\t' '$1 == "policy" { print $2; exit }')"
    DIR_BACKEND[n]="$(printf '%s\n' "$info" | awk -F'\t' '$1 == "backend" { print $2; exit }')"
    DIR_QA[n]="$(printf '%s\n' "$info" | awk -F'\t' '$1 == "state" && $2 == "human_qa" { print $3; exit }')"
    DIR_NAMES[n]="$(printf '%s\n' "$info" | awk -F'\t' '$1 == "state" { print $3 }' | tr '[:upper:]' '[:lower:]')"
    case "${DIR_POLICY[n]} ${DIR_BACKEND[n]}" in
      "human github-labels"|"human github-projects"|"auto github-labels"|"auto github-projects") ;;
      *) block "could not verify the board config; blocking to be safe" ;;
    esac
    [ -n "${DIR_QA[n]}" ] || block "could not verify the board config; blocking to be safe"
    DIR_NAME[n]="$d"; DIR_OK[n]=1
  fi
  [ "${DIR_OK[n]}" = 1 ] || return 1
  CURDIR="$d"; POLICY="${DIR_POLICY[n]}"; BACKEND="${DIR_BACKEND[n]}"
  QA_NAME="${DIR_QA[n]}"; STATE_NAMES="${DIR_NAMES[n]}"
  return 0
}

# --- lookups -------------------------------------------------------------------
# Every lookup runs in CURDIR under a watchdog (no timeout binary on macOS):
# the hook must decide well inside Claude Code's 60 s hook timeout, past which
# the call would proceed. FLEET_BOARD_GATE_TIMEOUT (seconds, default 45, at
# most 50) is the budget for all lookups together, counted by $SECONDS in
# whole seconds (so the real budget is up to one second shorter). A value that
# is not a positive decimal number gets the default; leading zeros are
# dropped, so 08 is not read as octal.
BUDGET="${FLEET_BOARD_GATE_TIMEOUT:-45}"
case "$BUDGET" in *[!0-9]*) BUDGET="" ;; esac
BUDGET="${BUDGET#"${BUDGET%%[!0]*}"}"
case "$BUDGET" in
  '') BUDGET=45 ;;
  ???*) BUDGET=50 ;;
  *) [ "$BUDGET" -le 50 ] || BUDGET=50 ;;
esac
LOOKUP_FILE=""
trap '[ -z "$LOOKUP_FILE" ] || rm -f "$LOOKUP_FILE"' EXIT

# lookup WHAT CMD...: runs CMD in CURDIR and sets LOOKUP_OUT to its stdout;
# blocks with "could not verify WHAT" when it fails or runs out of time. The
# output goes to a file, so a killed lookup's children cannot hold us up.
lookup() {
  local what="$1" left pid w rc
  shift
  left=$((BUDGET - SECONDS))
  [ $left -gt 0 ] || block "could not verify $what (out of time); blocking to be safe"
  if [ -z "$LOOKUP_FILE" ]; then
    LOOKUP_FILE="$(mktemp "${TMPDIR:-/tmp}/fleet-gate.XXXXXX" 2>/dev/null)" \
      || block "could not verify $what (no temp file); blocking to be safe"
  fi
  (cd "$CURDIR" && exec "$@") >"$LOOKUP_FILE" 2>/dev/null </dev/null &
  pid=$!
  (sleep "$left" & s=$!; trap 'kill $s 2>/dev/null; exit 0' TERM; wait $s; kill -TERM $pid 2>/dev/null) \
    >/dev/null 2>&1 </dev/null &
  w=$!
  wait $pid 2>/dev/null
  rc=$?
  kill -TERM $w 2>/dev/null
  wait $w 2>/dev/null
  [ $rc -ne 143 ] || block "could not verify $what (timed out); blocking to be safe"
  [ $rc -eq 0 ] || block "could not verify $what; blocking to be safe"
  LOOKUP_OUT="$(cat "$LOOKUP_FILE")"
}

# read_card N: sets CARD_STATE and CARD_BODY from board-read.sh, or blocks
read_card() {
  lookup "card #$1" bash "$S/board-read.sh" "$1"
  CARD_STATE="$(jq -r '.state // ""' <<<"$LOOKUP_OUT" 2>/dev/null)" \
    || block "could not verify card #$1; blocking to be safe"
  CARD_BODY="$(jq -r '.body // ""' <<<"$LOOKUP_OUT" 2>/dev/null)" \
    || block "could not verify card #$1; blocking to be safe"
}

has_acceptance() { (. "$S/board-lib.sh" && fb_has_acceptance "$1"); }

# touches_state TEXT: a state's board name appears in TEXT (case-insensitive:
# GitHub label names are)
touches_state() {
  local low name
  low="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$low" in *"$name"*) return 0 ;; esac
  done <<<"$STATE_NAMES"
  return 1
}

gate_move() {
  local n="$1" st="$2"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac # board-move.sh refuses a non-numeric number
  [ "$st" = human_qa ] && return 0
  read_card "$n"
  if [ "$CARD_STATE" = human_qa ] && [ "$st" != human_qa ]; then
    block "card #$n is in Human QA; only a human may move it out (GitHub UI)"
  fi
  if [ "$st" = ready ] && ! has_acceptance "$CARD_BODY"; then
    block "card #$n has no '## Acceptance' section"
  fi
}

# gate_edit NUMS NUM-UNKNOWN LABEL-UNKNOWN SEGMENT-TEXT
# A state label is touched when a label value cannot be read, or a state's
# board name appears in the segment. The segment match covers every
# --add-label/--remove-label value (split on commas) and any value written in
# pieces.
gate_edit() {
  local nums="$1" numdyn="$2" labdyn="$3" text="$4" n
  [ "$labdyn" = 1 ] || touches_state "$text" || return 0
  [ "$numdyn" = 0 ] || block "could not verify the card gh issue edit changes; blocking to be safe"
  for n in $nums; do
    read_card "$n"
    [ "$CARD_STATE" = human_qa ] \
      && block "card #$n is in Human QA; only a human may move it out (GitHub UI)"
  done
  return 0
}

gate_item() {
  local item="$1"
  [ "$BACKEND" = github-labels ] && return 0
  [ -n "$item" ] && ! is_dyn "$item" \
    || block "could not verify project item ${item:-(no --id)}; blocking to be safe"
  lookup "project item $item" bash "$S/adapters/github-projects/item-status.sh" "$item"
  [ "$LOOKUP_OUT" = "$QA_NAME" ] && block "project item $item is in Human QA; only a human may move it"
  return 0
}

# check_pr REF REPO: blocks unless the PR is not a draft and its checks are green
check_pr() {
  local ref="$1" repo="$2" info num draft green what="PR $1"
  local args=(pr view "$ref")
  [ -n "$repo" ] && args+=(-R "$repo")
  args+=(--json number,isDraft,statusCheckRollup)
  lookup "$what" gh "${args[@]}"
  info="$(jq -r '
    (.number // ""),
    (.isDraft | if type == "boolean" then . else error("no isDraft") end),
    (.statusCheckRollup | if type == "array" then . else error("no statusCheckRollup") end
      | map(.conclusion // .state)
      | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED"))' <<<"$LOOKUP_OUT" 2>/dev/null)" \
    || block "could not verify $what; blocking to be safe"
  num="$(printf '%s\n' "$info" | sed -n 1p)"
  draft="$(printf '%s\n' "$info" | sed -n 2p)"
  green="$(printf '%s\n' "$info" | sed -n 3p)"
  [ -n "$num" ] || num="$ref"
  [ "$draft" = true ] && block "PR #$num is a draft; drafts are never merged"
  [ "$green" = true ] || block "PR #$num checks are not green"
  return 0
}

# --- gates -----------------------------------------------------------------------
# Pass 1: gates that need no lookup, so a policy block never waits on the network.
k=0
while [ $k -lt ${#SHAPES[@]} ]; do
  IFS="$US" read -r kind f1 f2 f3 f4 f5 <<<"${SHAPES[k]}"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    use_dir "$d" || continue
    [ "$GH_ENV" = 1 ] && block "GH_REPO/GH_HOST in the command; blocking to be safe"
    case "$kind" in
      opaque) block "$f1" ;;
      rawstate)
        block "raw label/Status writes bypass the board adapter; use board-move.sh" ;;
      rawmerge)
        [ "$POLICY" = auto ] || block "merge.policy is human; merges happen in the GitHub UI"
        block "use gh pr merge so the draft/checks gate can run" ;;
      merge)
        [ "$POLICY" = auto ] || block "merge.policy is human; merges happen in the GitHub UI"
        [ "$f2" = 1 ] && block "--admin bypasses branch protection"
        # gh pr merge "" is gh pr merge without ARG: the current branch's PR
        case "$f1" in ''|'""') block "name the PR explicitly (gh pr merge <number>) so the gate can check it" ;; esac
        [ "$f5" = 1 ] && block "could not verify which PR gh pr merge merges under xargs; blocking to be safe"
        is_dyn "$f1" && block "could not verify PR $f1; blocking to be safe"
        is_dyn "$f3" && block "could not verify the repo of PR $f1 ($f3); blocking to be safe" ;;
      move)
        is_dyn "$f1" && block "could not verify card #$f1; blocking to be safe"
        is_dyn "$f2" && block "could not verify the state card #$f1 moves to ($f2); blocking to be safe" ;;
      label)
        if [ "$BACKEND" = github-labels ] && { [ "$f1" = 1 ] || touches_state "$f2"; }; then
          block "editing or deleting a state label bypasses the board adapter; change state labels in the GitHub UI"
        fi ;;
    esac
  done <<<"${SHAPE_DIRS[k]}"
  k=$((k + 1))
done

# A function or trap body runs when it is called or fires, perhaps after a cd
# that comes later in the text, and it may run many times; with a directory
# change anywhere in the command, the hook cannot tell where it runs. This
# comes after pass 1, so a directory known to block still gives its reason.
[ "$DEFER" = 1 ] && [ "$CDSEEN" = 1 ] \
  && block "could not tell which directory the command runs in (a function or trap, and a cd); blocking to be safe"

# Pass 2: gates that read the board or the PR.
k=0
while [ $k -lt ${#SHAPES[@]} ]; do
  IFS="$US" read -r kind f1 f2 f3 f4 f5 <<<"${SHAPES[k]}"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    use_dir "$d" || continue
    case "$kind" in
      move) gate_move "$f1" "$f2" ;;
      edit) gate_edit "$f1" "$f2" "$f3" "$f4" ;;
      item) gate_item "$f1" ;;
      merge)
        check_pr "$f1" "$f3"
        for ref in $f4; do check_pr "$ref" "$f3"; done ;;
    esac
  done <<<"${SHAPE_DIRS[k]}"
  k=$((k + 1))
done

exit 0
