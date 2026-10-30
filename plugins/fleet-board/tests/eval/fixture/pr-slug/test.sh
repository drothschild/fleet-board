#!/usr/bin/env bash
# Runs this fixture PR's test files one at a time.
cd "$(dirname "$0")" || exit 1
for f in test/*.test.js; do node "$f" || exit 1; done
