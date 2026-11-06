#!/usr/bin/env bash
# `claude update` can stall on "Updating to ..." (2026-11-06). The Claude Code
# step gives each try its own deadline and tries twice.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-claude.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
trap 'cleanup; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

CLAUDE_UPDATE_TIMEOUT=1
calls="$tmp/calls"

# A first try that hangs is killed at the deadline; the second succeeds.
claude() { echo x >> "$calls"; if [ "$(wc -l < "$calls")" -eq 1 ]; then sleep 30; else echo done; fi; }
: > "$calls"
start=$SECONDS
claude_update_retry >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "a hung first try is retried and the step succeeds" || fail "a hung first try is retried (rc $rc)"
[ "$(wc -l < "$calls")" -eq 2 ] && pass "claude ran twice" || fail "claude ran twice"
[ $((SECONDS - start)) -lt 10 ] && pass "the hung try ended at its deadline" || fail "the hung try ended at its deadline"

# Two failures fail the step with the last exit code.
claude() { echo x >> "$calls"; return 3; }
: > "$calls"
claude_update_retry >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && [ "$(wc -l < "$calls")" -eq 2 ] && pass "two failures fail the step" || fail "two failures fail the step (rc $rc)"

# A success on the first try runs once.
claude() { echo x >> "$calls"; return 0; }
: > "$calls"
claude_update_retry >/dev/null 2>&1
[ "$(wc -l < "$calls")" -eq 1 ] && pass "success runs claude once" || fail "success runs claude once"

[ "$failures" -eq 0 ] && echo "all claude update retry tests passed"
exit "$failures"
