#!/bin/sh
# Runs every test: CoastlineCore self-tests, then the engine's pytest suite.
# Optional argument: a name filter for the Swift tests (e.g. "Engine").
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/CoastlineCore" || exit 1
swift build --product CoastlineSelfTest 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*error:" && exit 1
.build/debug/CoastlineSelfTest "$@" | tr '\r' '\n' | grep -v "…"
SWIFT=$?
[ -n "$1" ] && exit $SWIFT
echo "\nengine:"
cd "$ROOT/engine" && PATH="$HOME/.local/bin:$PATH" uv run python -m pytest -q 2>&1 | tail -3
exit $(( SWIFT || $? ))
