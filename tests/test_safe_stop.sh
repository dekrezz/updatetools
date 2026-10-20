#!/usr/bin/env bash
# Stopping an update must not leave a tool half-done or still running. A tool
# told to stop gets SIGTERM and time to finish stopping (Homebrew cleans up an
# unfinished install on TERM); only one that has not exited when the grace is
# over is killed. Nothing it started may outlive the stop: the next step, or the next
# run, would collide with it on Homebrew's lock and leave mixed versions.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-stop.XXXXXX)"
export HOME="$tmp/home" HOMEBREW_CACHE="$tmp/brew-cache"
mkdir -p "$HOME"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
finish() {
  local f
  for f in "$tmp"/*.child "$tmp"/*.pid; do [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
  pkill -KILL -f "$tmp/" 2>/dev/null
  rm -rf "$tmp"
}
trap finish EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

LOG="$tmp/run.log"; : > "$LOG"

# A tool with a child of its own that needs 2 s to roll back once told to stop.
cat > "$tmp/rollback-tool" <<'EOF'
#!/bin/bash
trap 'sleep 2; echo done > "$1.rolled"; exit 143' TERM
sleep 30 &
echo $! > "$1.child"
while :; do sleep 0.1; done
EOF
# A tool that ignores SIGTERM.
cat > "$tmp/stubborn-tool" <<'EOF'
#!/bin/bash
trap '' TERM
echo $$ > "$1.pid"
while :; do sleep 0.1; done
EOF
chmod +x "$tmp/rollback-tool" "$tmp/stubborn-tool"

wait_for_file() { local n=0; while [ ! -s "$1" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; [ -s "$1" ]; }
alive() { ps -p "$1" >/dev/null 2>&1; }

# A step runs the way ut_spawn_step starts it: a background subshell.
{ "$tmp/rollback-tool" "$tmp/a"; } >/dev/null 2>&1 &
step=$!
wait_for_file "$tmp/a.child" || fail "rollback tool started"
STOP_GRACE=10 ut_stop_tree "$step"; rc=$?
[ "$rc" = "0" ] && pass "a tool that exits within the grace is a clean stop" || fail "a tool that exits within the grace is a clean stop (rc $rc)"
[ -f "$tmp/a.rolled" ] && pass "the tool finished rolling back before the stop returned" \
  || fail "the tool finished rolling back before the stop returned"
alive "$step" && fail "the step is gone after the stop" || pass "the step is gone after the stop"
child="$(cat "$tmp/a.child" 2>/dev/null)"
[ -n "$child" ] && ! alive "$child" && pass "the tool's own child does not outlive the stop" \
  || fail "the tool's own child does not outlive the stop (pid '$child')"
grep -q "SIGTERM" "$LOG" && pass "the stop is written to the run log" || fail "the stop is written to the run log"

{ "$tmp/stubborn-tool" "$tmp/b"; } >/dev/null 2>&1 &
step=$!
wait_for_file "$tmp/b.pid" || fail "stubborn tool started"
t0=$SECONDS
STOP_GRACE=1 ut_stop_tree "$step"; rc=$?
[ "$rc" = "1" ] && pass "a tool still running after the grace is reported as forced" || fail "a tool still running after the grace is reported as forced (rc $rc)"
alive "$(cat "$tmp/b.pid")" && fail "a tool that ignores SIGTERM is killed after the grace" \
  || pass "a tool that ignores SIGTERM is killed after the grace"
[ $((SECONDS - t0)) -le 4 ] && pass "the grace bounds the wait" || fail "the grace bounds the wait ($((SECONDS - t0)) s)"
grep -q "SIGKILL" "$LOG" && pass "a forced stop is written to the run log" || fail "a forced stop is written to the run log"

# The stall watchdog stops a silent step the same safe way.
: > "$tmp/stall.log"
{ "$tmp/rollback-tool" "$tmp/c"; } >/dev/null 2>&1 &
step=$!
wait_for_file "$tmp/c.child" || fail "stalled tool started"
STALL_TIMEOUT=1 STOP_GRACE=10 ut_watch_pid "$step" "$tmp/stall.log"
[ "$UT_WAIT_STALLED" = "1" ] && pass "a silent step is stopped as stalled" || fail "a silent step is stopped as stalled"
[ -f "$tmp/c.rolled" ] && pass "a stalled tool rolls back before the next step can start" \
  || fail "a stalled tool rolls back before the next step can start"
child="$(cat "$tmp/c.child" 2>/dev/null)"
[ -n "$child" ] && ! alive "$child" && pass "nothing of a stalled step keeps running" \
  || fail "nothing of a stalled step keeps running (pid '$child')"

if [ "$failures" -eq 0 ]; then
  echo "all safe stop tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
