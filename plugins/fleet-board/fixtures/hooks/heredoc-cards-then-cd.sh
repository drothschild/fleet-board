DOCS=/tmp/hmb-cards
mkdir -p "$DOCS"
cat > "$DOCS/a.md" <<'EOF2'
## Acceptance
- the loader reads CLAUDE_CONFIG_DIR, then ~/notes
- cd ../elsewhere && HOME=/x gh pr merge 4
EOF2
cat > "$DOCS/b.md" <<'EOF2'
## Acceptance
- the cwd is kept
EOF2
cd __REPO__ && gh issue edit 12 --body-file "$DOCS/a.md"; bash /x/scripts/board-move.sh 12 ready
