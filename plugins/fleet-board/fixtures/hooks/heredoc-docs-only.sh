DOCS=/tmp/hmb-docs
mkdir -p "$DOCS"
cat > "$DOCS/one.md" <<'EOF2'
Set CLAUDE_CONFIG_DIR and look under ~/.claude. The cwd is the repo.
cd .. ; HOME=/elsewhere; CDPATH=/y; pushd /z
then run gh pr merge 4 by hand
EOF2
cat > "$DOCS/two.md" <<'EOF2'
more prose, a lone ( paren and a `backtick
EOF2
ls "$DOCS"
