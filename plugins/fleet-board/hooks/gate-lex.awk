# gate-lex.awk: splits a shell command into segments of words, for gate.sh.
#
# Input: the command text on stdin. Output: a first line "!FLAT" US TEXT (the
# command lower-cased, without quote or backslash characters, see END), then
# one line per segment,
#
#   SCOPE US PARENT US BEFORE US AFTER (US WORD)...
#
# with US = \037. SCOPE numbers the context the segment runs in: 0 is the
# command itself, and each ( ... ), $( ... ), ` ... `, <( ... ) and each quoted
# string opens a new one; PARENT is the enclosing scope. BEFORE and AFTER are
# the separators around the segment inside its scope: ^ (start), $ (end),
# ; NL && || | & ( ). A scope's segments are printed in order, and the
# segments of a nested scope are printed before the segment that contains it.
# A line "!SCOPE" US SCOPE US PARENT is printed when a nested scope opens,
# before any of its segments. A line "!NOPOP" is printed where a comment or a
# here-document starts: from there on the lexer reads text as commands that
# the shell does not, so the caller must not trust a closer (fi, done, }).
# Near the end, a line "!FUNC" means the command defines a function with
# name ( ) (its body runs later, when it is called), and a last line "!DEPTH"
# means nesting went deeper than MAXDEPTH; the part below that depth was
# skipped, so the caller must not trust the result.
#
# Words are shell words after quote removal:
#   - a backslash-newline disappears (line continuation), inside quotes too;
#   - quotes are removed, and every remaining backslash is dropped;
#   - $( ... ), ` ... ` and <( ... ) become the placeholder $SUB, and their
#     text is lexed as a scope of its own;
#   - ${ ... } is kept as written, so the word still shows a $, and its
#     text is also lexed as a scope of its own (see param);
#   - an empty word ("", '', $'') is printed as "" (see flush);
#   - a reserved word (if, fi, {, ...) with any quoting or backslash in it is
#     printed with a leading backslash (\fi): the shell does not treat it as
#     reserved, so the caller must not either;
#   - $'...' is decoded (\n, \t, \xHH, \NNN, \\, \');
#   - a redirection operator and its target are not words (2>&1, >file, <<EOF).
# The content of every quoted string is ALSO lexed as a script of its own
# scope, so bash -c "...", sh -c '...' and eval "..." are seen; so is a whole
# word written in pieces (gh\ pr\ merge, "cd x"'; gh ...'), since the shell
# joins the pieces into one script. Quoted text that only mentions a command
# is lexed too: a false positive, never a miss. Comment text and the body of a
# here-document with an unquoted delimiter (it expands $( )) are lexed as
# commands, for the same reason (see !NOPOP); the body of a quoted-delimiter
# here-document (<<'EOF') is plain text and is skipped through its delimiter
# line, but only in the simplest shape (see queue_heredoc): plain words before
# the operator, no sub-scope or comment, no unquoted here-document before it,
# and a delimiter line that exists. Every other shape is lexed.

BEGIN {
  US = "\037"; HEX = "0123456789abcdef"; MAXDEPTH = 24
  NSCOPE = 0; HDN = 0; NOHD = 0; CMT = 0; UNQ = 0; FNDEF = 0; SUBSEG = 0; RLX = 0; OVER = 0; FUNC = 0; QW = 0; MX = 0
  split("! case coproc do done elif else esac fi for function if in select then time until while { } [[ ]]", r, " ")
  for (k in r) RES[r[k]] = 1
}

{ S = (NR > 1) ? S "\n" $0 : $0 }

END {
  # First line: the whole command flattened for substring checks: no
  # backslash-newline, no quote or backslash characters, blanks for control
  # characters, lower case
  F = S
  gsub(/\\\n/, "", F); gsub(/['"\\]/, "", F); gsub(/[\n\r\t]/, " ", F); gsub(US, " ", F)
  print "!FLAT" US tolower(F)
  N = length(S); P = 1
  W = ""; IW = 0; T = ""; R = 0; B = "^"
  lex_scope("", 0, 0, 0)
  if (FUNC) print "!FUNC"
  if (OVER) print "!DEPTH"
}

# flush: ends the current word; a redirection target is dropped. An empty
# word ("", '', $'') is still a word: dropping it would let a flag take the
# next word as its value. It is printed as "" (bash's read -a drops a
# trailing empty field), and a word that really is "" is printed as \"\" so
# the two cannot be confused (no other word keeps a backslash, apart from the
# marked reserved words).
function flush() {
  if (IW) {
    if (R) R = 0
    else {
      # a word with quoting in more than one piece, or with a backslash, is
      # lexed whole (a quoted piece alone was lexed when it was read)
      if (QW && MX) relex(W, CSID, CDEP)
      gsub(/\\/, "", W)
      gsub(/[\n\t\r]/, " ", W)
      gsub(US, " ", W)
      # Heredoc-body skipping needs every earlier command word in the call to be
      # inert (FNDEF otherwise): a first word of a segment, after any assignment
      # words, that is not on the short list below could rebind cat or tee (an
      # alias, a function, hash, a brace expansion, a wrapper, a $-held word) or
      # change what runs later (a loop, a group, a redirect on a closer); an
      # assignment to a variable that steers command lookup counts the same. Words
      # that are not first (arguments) never run, so they are not checked.
      if (!RLX && T ~ /^(\037[A-Za-z_][A-Za-z0-9_]*\+?=[^\037]*)*$/) {
        if (W ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) {
          if (W ~ /^(PATH|ENV|BASH[A-Za-z0-9_]*|POSIX[A-Za-z0-9_]*|SHELLOPTS|IFS|CDPATH|GLOBIGNORE|HOME|FUNCNEST|PS4|PROMPT_COMMAND|LD_[A-Za-z0-9_]*|DYLD_[A-Za-z0-9_]*)\+?=/) FNDEF = 1
        } else if (W !~ /^(cat|tee|mkdir|ls|echo|true|pwd|cd|rm|touch)$/) FNDEF = 1
      }
      if (W == "") W = "\"\""
      else if (W == "\"\"") W = "\\\"\\\""
      else if (QW && (W in RES)) W = "\\" W
      T = T US W
    }
  }
  W = ""; IW = 0; QW = 0; MX = 0
}

# endseg: ends the current segment at separator SEP
function endseg(sid, par, sep) {
  flush(); R = 0
  if (T != "") print sid US par US B US sep T
  T = ""; B = sep; SUBSEG = 0
}

# lex_scope: lexes from P until TERM (")" or "`", or "" for end of input)
function lex_scope(term, sid, par, depth,    c, d, content) {
  CSID = sid; CDEP = depth
  while (P <= N) {
    c = substr(S, P, 1)
    if (term == "`" && c == "`") { P++; endseg(sid, par, "$"); return }
    if (term == ")" && c == ")") { P++; endseg(sid, par, "$"); return }
    if (c == "\\") {
      d = substr(S, P + 1, 1); P += 2
      if (d == "\n") continue
      W = W d; IW = 1; QW = 1; MX = 1; continue
    }
    if (c == "'") {
      P++; content = scan("'")
      if (IW) MX = 1
      W = W content; IW = 1; QW = 1; relex(content, sid, depth); continue
    }
    if (c == "\"") {
      P++; content = dq_unescape(scan("\""))
      if (IW) MX = 1
      W = W content; IW = 1; QW = 1; relex(content, sid, depth); continue
    }
    if (c == "$") {
      d = substr(S, P + 1, 1)
      if (d == "(") { P += 2; sub_scope(")", sid, depth); if (IW) MX = 1; W = W "$SUB"; IW = 1; continue }
      if (d == "{") {
        P += 2; content = scan("{"); if (IW) MX = 1; W = W "${" content "}"; IW = 1
        if (content ~ /=/ || content ~ /BASH_/) FNDEF = 1   # ${x:=v} assigns in this shell
        param(content, sid, depth); continue
      }
      if (d == "'") {
        P += 2; content = ansi(); if (IW) MX = 1
        W = W content; IW = 1; QW = 1; relex(content, sid, depth); continue
      }
      if (IW) MX = 1
      W = W c; IW = 1; P++; continue
    }
    if (c == "`") { P++; sub_scope("`", sid, depth); if (IW) MX = 1; W = W "$SUB"; IW = 1; continue }
    if ((c == "<" || c == ">") && substr(S, P + 1, 1) == "(") {
      P += 2; sub_scope(")", sid, depth); if (IW) MX = 1; W = W "$SUB"; IW = 1; continue
    }
    if (c == "<" || c == ">") { redirect(); continue }
    if (c == "&") {
      d = substr(S, P + 1, 1)
      if (d == ">") { flush(); P += 2; if (substr(S, P, 1) == ">") P++; R = 1; continue }
      if (d == "&") { P += 2; endseg(sid, par, "&&"); continue }
      P++; endseg(sid, par, "&"); continue
    }
    if (c == "|") {
      d = substr(S, P + 1, 1)
      if (d == "|") { P += 2; endseg(sid, par, "||"); continue }
      P += (d == "&") ? 2 : 1; endseg(sid, par, "|"); continue
    }
    if (c == ";") {
      P++; d = substr(S, P, 1); if (d == ";" || d == "&") P++
      endseg(sid, par, ";"); continue
    }
    if (c == "\n") { P++; endseg(sid, par, "NL"); CMT = 0; if (HDN) skip_heredocs(); continue }
    if (c == "(") {
      P++
      # name ( ) defines a function
      for (d = P; d <= N && (substr(S, d, 1) == " " || substr(S, d, 1) == "\t"); d++) ;
      if (substr(S, d, 1) == ")") FUNC = 1
      endseg(sid, par, "("); sub_scope(")", sid, depth); B = ")"; continue
    }
    if (c == ")") { P++; endseg(sid, par, ")"); continue }
    if (c == " " || c == "\t" || c == "\r") { flush(); P++; continue }
    if (c == "#" && !IW) { print "!NOPOP"; CMT = 1 }
    if (IW) MX = 1
    W = W c; IW = 1; P++
  }
  endseg(sid, par, "$")
}

# sub_scope: lexes a nested ( ... ) or ` ... ` as a new scope, keeping the
# state of the segment it interrupts
function sub_scope(term, par, depth,    shn, sw, siw, sq, sm, st, sr, sb, sc, sd) {
  if (depth >= MAXDEPTH) { OVER = 1; scan(term == "`" ? "`" : "("); return }
  sw = W; siw = IW; sq = QW; sm = MX; st = T; sr = R; sb = B; sc = CSID; sd = CDEP
  W = ""; IW = 0; QW = 0; MX = 0; T = ""; R = 0; B = "^"
  print "!SCOPE" US (++NSCOPE) US par
  # inside ( ), $( ), ` ` and (( )) no heredoc body is skipped: bash finds the
  # closer before it reads a body (a ) on a body line ends the substitution),
  # and << in (( )) may be a shift with a quoted operand. The body is lexed.
  shn = HDN; HDN = 0; NOHD++
  lex_scope(term, NSCOPE, par, depth + 1)
  NOHD--
  HDN = shn
  W = sw; IW = siw; QW = sq; MX = sm; T = st; R = sr; B = sb; CSID = sc; CDEP = sd
  SUBSEG = 1   # a (...), $(...), `...` or >(...) ran in this segment
}

# relex: lexes the content of a quoted string as a script of a new scope
function relex(content, par, depth,    shn, ss, sp, sn, sw, siw, sq, sm, st, sr, sb, sc, sd) {
  if (content !~ /[^ \t\n]/) return
  if (depth >= MAXDEPTH) { OVER = 1; return }
  ss = S; sp = P; sn = N
  sw = W; siw = IW; sq = QW; sm = MX; st = T; sr = R; sb = B; sc = CSID; sd = CDEP
  S = content; P = 1; N = length(S)
  W = ""; IW = 0; QW = 0; MX = 0; T = ""; R = 0; B = "^"
  shn = HDN; HDN = 0
  print "!SCOPE" US (++NSCOPE) US par
  RLX++; NOHD++   # the outer shell expands $( ) in a quoted string first: skip no body here
  lex_scope("", NSCOPE, par, depth + 1)
  NOHD--; RLX--
  HDN = shn
  S = ss; P = sp; N = sn
  W = sw; IW = siw; QW = sq; MX = sm; T = st; R = sr; B = sb; CSID = sc; CDEP = sd
}

# param: lexes the text inside ${ ... } as a scope of its own. It runs code:
# $( ... ) and backquotes anywhere in it (a subscript too), and the word after
# an operator (${x:-WORD}, ${x#WORD}, ...) becomes text that may be a command
# word or a bash -c script. The name and the operator are left out, so
# ${x:-gh pr merge 4} is lexed as "gh pr merge 4". When the text does not
# start with a name and an operator, all of it is lexed.
function param(content, par, depth,    rest, sb) {
  if (match(content, /^[#!]?([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])/)) {
    rest = substr(content, RLENGTH + 1); sb = ""
    if (match(rest, /^\[[^]]*\]/)) { sb = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1) }
    if (match(rest, /^(:?[-=+?]|##?|%%?|\/[\/#%]?|\^\^?|,,?|@)/)) {
      relex(sb " " substr(rest, RLENGTH + 1), par, depth); return
    }
  }
  relex(content, par, depth)
}

# scan: P is just past an opening ( ` " ' or {. Consumes through the matching
# closer and returns the raw text between them. Quotes, $( ... ), ( ... ),
# { ... } and backquotes nest inside; a backslash keeps the next character.
function scan(open,    stk, out, c, d, top, n) {
  stk = open; out = ""
  while (P <= N) {
    c = substr(S, P, 1); n = length(stk); top = substr(stk, n, 1)
    if (top == "'") {
      P++
      if (c == "'") { stk = substr(stk, 1, n - 1); if (stk == "") return out }
      out = out c; continue
    }
    if (c == "\\") {
      d = substr(S, P + 1, 1); P += 2
      if (d == "\n") continue
      out = out c d; continue
    }
    P++
    if (top == "\"") {
      if (c == "\"") { stk = substr(stk, 1, n - 1); if (stk == "") return out }
      else if (c == "$" && substr(S, P, 1) == "(") { stk = stk "("; out = out "$("; P++; continue }
      else if (c == "`") { stk = stk "`" }
      out = out c; continue
    }
    if ((top == "(" && c == ")") || (top == "{" && c == "}") || (top == "`" && c == "`")) {
      stk = substr(stk, 1, n - 1); if (stk == "") return out
    } else if (c == "(") { stk = stk "(" }
    else if (c == "{" && top == "{") { stk = stk "{" }
    else if (c == "'" || c == "\"" || c == "`") { stk = stk c }
    out = out c
  }
  return out
}

# dq_unescape: inside double quotes a backslash escapes only " \ $ and `
function dq_unescape(s,    out, i, n, c, d) {
  if (index(s, "\\") == 0) return s
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      d = substr(s, i + 1, 1)
      if (d == "\"" || d == "\\" || d == "$" || d == "`") { out = out d; i++; continue }
    }
    out = out c
  }
  return out
}

# ansi: P is just past $' ; decodes through the closing quote
function ansi(    out, c, d, v, k, h) {
  out = ""
  while (P <= N) {
    c = substr(S, P, 1); P++
    if (c == "'") return out
    if (c != "\\") { out = out c; continue }
    d = substr(S, P, 1); P++
    if (d == "n") out = out "\n"
    else if (d == "t") out = out "\t"
    else if (d == "x") {
      v = 0
      for (k = 0; k < 2; k++) {
        h = index(HEX, tolower(substr(S, P, 1)))
        if (h == 0) break
        v = v * 16 + h - 1; P++
      }
      if (k > 0 && v > 0) out = out sprintf("%c", v)
    } else if (d ~ /^[0-7]$/) {
      v = d + 0
      for (k = 1; k < 3 && substr(S, P, 1) ~ /^[0-7]$/; k++) { v = v * 8 + substr(S, P, 1); P++ }
      if (v > 0) out = out sprintf("%c", v)
    } else out = out d
  }
  return out
}

# redirect: P is at < or >. An fd number or {name} written right before the
# operator belongs to it; the word after the operator is its target.
function redirect(    op, c, dash) {
  if (IW && (W ~ /^[0-9]+$/ || W ~ /^\{[A-Za-z_][A-Za-z0-9_]*\}$/)) { W = ""; IW = 0 }
  else flush()
  op = ""
  while (P <= N) {
    c = substr(S, P, 1)
    if (c != "<" && c != ">" && c != "&" && c != "|") break
    op = op c; P++
  }
  dash = 0
  if (substr(S, P, 1) == "-") {
    if (op ~ /&$/) { P++; return }   # >&- and <&- close a descriptor: no target
    if (op == "<<") { P++; dash = 1 }   # <<- is a here-document operator
  }
  if (op == "<<") {
    print "!NOPOP"
    if (queue_heredoc(dash)) return   # quoted delimiter: the body is skipped at the next newline
    UNQ = 1   # not skipped (unquoted, or in a comment or sub-scope): no later quoted body is skipped
  }
  R = 1
}

# queue_heredoc: P is just past << (or <<-). When the delimiter is quoted or
# backslashed, the shell does no expansion in the body, so it is plain text:
# the delimiter is consumed here and the body skipped at the next newline
# (skip_heredocs). Returns 1 then. An unquoted delimiter returns 0 and
# consumes nothing: its body expands $( ) and backquotes, so it stays lexed.
function queue_heredoc(dash,    q, d, c, e, quoted, word, ch, n, i) {
  if (SUBSEG) return 0   # a process substitution may run a shell that reads the body
  if (FUNC || FNDEF) return 0   # a function or alias may stand in for cat, tee, ...
  if (NOHD || CMT) return 0   # comment text and a sub-scope hold no heredoc to skip
  # allowlist: skip a body only when every word before the operator is plain
  # (a command name and simple arguments). Anything else (an assignment, a
  # subscript, [ or [[, a quote, $, #) may make bash read << as something other
  # than a heredoc, and a wrong guess would hide the rest of the command.
  if (T !~ /^(\037[A-Za-z0-9_.\/+,:-]+)*$/ || W != "") return 0
  # and the command must only read its input as data (cat, tee, ...): a shell,
  # source, python or xargs would run the body. Nothing may follow the
  # delimiter on the line either (a pipe to bash would run it).
  # Only cat and tee, and no - option: an option may name a program that runs
  # the body (sort --compress-program sh).
  n = split(substr(T, 2), cw, US)
  if (cw[1] !~ /^(cat|tee)$/) return 0
  for (i = 2; i <= n; i++) if (cw[i] ~ /^-/) return 0
  if (UNQ) return 0                   # an unquoted heredoc was seen: its body expands $( ), so lex all
  q = P
  while (substr(S, q, 1) == " " || substr(S, q, 1) == "\t") q++
  word = ""; quoted = 0
  while (q <= N) {
    c = substr(S, q, 1)
    if (c == "'" || c == "\"") {
      e = index(substr(S, q + 1), c)
      if (e == 0) return 0
      word = word substr(S, q + 1, e - 1); q += e + 1; quoted = 1; continue
    }
    if (c == "\\") {
      ch = substr(S, q + 1, 1)
      if (ch == "\n" || ch == "") return 0
      word = word ch; q += 2; quoted = 1; continue
    }
    if (c ~ /[ \t\n;&|()<>]/ || c == "$" || c == "`") break
    word = word c; q++
  }
  if (!quoted || word == "" || (substr(S, q, 1) == "$" || substr(S, q, 1) == "`")) { UNQ = 1; return 0 }
  e = index(substr(S, q), "\n")
  if ((e ? substr(S, q, e - 1) : substr(S, q)) !~ /^[ \t\r]*$/) return 0
  # the delimiter must be written 'WORD' or "WORD" (letters, digits, _): bash
  # unescapes a backslash in other forms, so its terminator line would differ
  if (substr(S, P, q - P) !~ /^[ \t]*('[A-Za-z0-9_]+'|"[A-Za-z0-9_]+")$/) return 0
  HDN++; HDD[HDN] = word; HDS[HDN] = dash
  P = q
  return 1
}

# skip_heredocs: P is at the start of the line after a newline. Skips the
# queued here-document bodies, each through the line holding its delimiter
# (leading tabs ignored for <<-). A body with no delimiter line is not skipped.
function skip_heredocs(    i, e, line, p0, found) {
  p0 = P
  for (i = 1; i <= HDN; i++) {
    found = 0
    while (P <= N) {
      e = index(substr(S, P), "\n")
      if (e == 0) { line = substr(S, P); P = N + 1 }
      else { line = substr(S, P, e - 1); P += e }
      if (HDS[i]) sub(/^\t+/, "", line)
      if (line == HDD[i]) { found = 1; break }
    }
    if (!found) { P = p0; UNQ = 1; break }   # no delimiter line: lex the body
  }
  HDN = 0
}
