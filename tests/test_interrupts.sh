#!/usr/bin/env bash
# A run that is interrupted must not leave updates running behind it:
#   * Ctrl+C, kill (TERM) and a closed terminal (HUP) stop the running steps
#     safely, start nothing new, say what happened in the terminal (or, with
#     the terminal gone, in a notification), and keep the evidence;
#   * a second Ctrl+C does not wait for the rollback;
#   * kill -9 cannot be caught: the dashboard server, which outlives the run,
#     stops what it left running and says so in the terminal and on the page;
#   * the next run finds the run that did not finish, saves its log and warns.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-intr.XXXXXX)"
export HOME="$tmp/home" HOMEBREW_CACHE="$tmp/brew-cache"
mkdir -p "$HOME"
dead_log=""

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
finish() {
  local f
  for f in "$tmp"/*/*.child; do [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
  pkill -KILL -f "$tmp/" 2>/dev/null
  [ -n "$dead_log" ] && rm -f "$dead_log"
  rm -rf "$tmp"
}
trap finish EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
wait_for_file() { local n=0; while [ ! -f "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done; [ -f "$1" ]; }
alive() { ps -p "$1" >/dev/null 2>&1; }

# $1 marker prefix, $2 seconds its rollback takes once told to stop.
cat > "$tmp/tool" <<'EOF'
#!/bin/bash
echo started > "$1.started"
trap 'sleep ${2:-1}; echo done > "$1.rolled"; exit 143' TERM
sleep 30 &
echo $! > "$1.child"
n=0; while [ "$n" -lt 150 ]; do sleep 0.1; n=$((n + 1)); echo working; done
EOF
cat > "$tmp/run.sh" <<'EOF'
RUN="$1"
set --
export UPDATETOOLS_LIB_ONLY=1
source "$ROOT/updatetools"
STEPS=(
  "Homebrew · upgrade¦true¦\"$TOOL\" \"$RUN/brew\" $ROLLBACK"
  "npm · update globals¦true¦\"$TOOL\" \"$RUN/npm\" 1"
  "Report¦true¦:"
)
STEP_KEY=(homebrew npm report); STEP_ON=(1 1 1); TOTAL=3
STATUS=(pending pending pending); STEP_WHY=("" "" "")
sudo() { return 0; }
osascript() { printf '%s\n' "$*" >> "$RUN/notified"; }
ut_net_probe() { echo up; }
STALL_TIMEOUT=0; STOP_GRACE=10; DIAG_DIR="$RUN/diag"
mkdir -p "$RUN/web"; WEB_DIR="$RUN/web"
ut_run_steps
echo finished > "$RUN/finished"
EOF
chmod +x "$tmp/tool"
export ROOT TOOL="$tmp/tool"

# A shell started in the background ignores SIGINT; a terminal's foreground
# run does not, so the run under test gets SIGINT back.
start_run() { # <name> <rollback seconds>
  RUN="$tmp/$1"; mkdir -p "$RUN"
  ROLLBACK="$2" python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp("bash", ["bash"] + sys.argv[1:])' "$tmp/run.sh" "$RUN" > "$RUN/out" 2> "$RUN/err" &
  RUN_PID=$!
  wait_for_file "$RUN/brew.started" || fail "$1: the step started"
}
check_stopped() { # <name> <expected rc> <rc>
  [ "$3" = "$2" ] && pass "$1: the run exits $2" || fail "$1: the run exits $2 (rc $3)"
  [ -f "$RUN/brew.rolled" ] && pass "$1: the running step rolled back" || fail "$1: the running step rolled back"
  local child; child="$(cat "$RUN/brew.child" 2>/dev/null)"
  [ -n "$child" ] && ! alive "$child" && pass "$1: nothing of the step keeps running" || fail "$1: nothing of the step keeps running"
  [ ! -f "$RUN/npm.started" ] && [ ! -f "$RUN/finished" ] && pass "$1: nothing else starts" || fail "$1: nothing else starts"
  ls "$RUN"/diag/*/run.log >/dev/null 2>&1 && pass "$1: the run log is kept in the diagnostics" \
    || fail "$1: the run log is kept in the diagnostics"
}

start_run int 1
( while alive "$RUN_PID"; do grep -q '"why":"signal"' "$RUN/web/state.json" 2>/dev/null && : > "$RUN/page-told"; sleep 0.05; done ) &
kill -INT "$RUN_PID"; wait "$RUN_PID"; rc=$?
check_stopped "Ctrl+C" 130 "$rc"
grep -q "Ctrl+C" "$RUN/err" && grep -q "Homebrew" "$RUN/err" && pass "Ctrl+C: the terminal says what was stopped" \
  || fail "Ctrl+C: the terminal says what was stopped ($(cat "$RUN/err"))"
grep -q "$RUN/diag/" "$RUN/err" && pass "Ctrl+C: the terminal says where the diagnostics are" \
  || fail "Ctrl+C: the terminal says where the diagnostics are"
[ -f "$RUN/page-told" ] && pass "Ctrl+C: the page is told before the dashboard goes" || fail "Ctrl+C: the page is told before the dashboard goes"

start_run force 6
t0=$SECONDS
kill -INT "$RUN_PID"; sleep 0.5; kill -INT "$RUN_PID"; wait "$RUN_PID"; rc=$?
[ "$rc" = "130" ] && [ $((SECONDS - t0)) -le 3 ] && pass "a second Ctrl+C stops at once" \
  || fail "a second Ctrl+C stops at once (rc $rc after $((SECONDS - t0)) s)"
child="$(cat "$RUN/brew.child" 2>/dev/null)"
[ -n "$child" ] && ! alive "$child" && pass "a forced stop leaves nothing running" || fail "a forced stop leaves nothing running"
grep -qi "forc" "$RUN/err" && pass "the terminal says the stop was forced" || fail "the terminal says the stop was forced"

start_run term 1
kill -TERM "$RUN_PID"; wait "$RUN_PID"; rc=$?
check_stopped "kill" 143 "$rc"

start_run hup 1
kill -HUP "$RUN_PID"; wait "$RUN_PID"; rc=$?
check_stopped "closed terminal" 129 "$rc"
grep -qi "terminal" "$RUN/notified" 2>/dev/null && pass "closed terminal: a notification says why the run stopped" \
  || fail "closed terminal: a notification says why the run stopped"

# Ctrl+C once the run has finished is how the dashboard run is left: no stop,
# no diagnostics, no warning.
cat > "$tmp/after.sh" <<'EOF'
RUN="$1"
set --
export UPDATETOOLS_LIB_ONLY=1
source "$ROOT/updatetools"
STEPS=("npm · update globals¦true¦:" "Report¦true¦:")
STEP_KEY=(npm report); STEP_ON=(1 1); TOTAL=2
AUTO_START=1; NET_TIMEOUT=0; STALL_TIMEOUT=0; DIAG_DIR="$RUN/diag"
ut_web_start() { WEB_DIR="$RUN/web"; mkdir -p "$WEB_DIR"; ( exec sleep 60 ) & WEB_PID=$!; WEB_OPENED=1; }
ut_web_stop() { kill "$WEB_PID" 2>/dev/null; }
ut_icon_site() { :; }
ut_needs_sudo() { return 1; }
ut_save_enabled() { :; }
ut_preflight() { :; }
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_generate_report() { :; }
ut_notify_end() { :; }
ut_save_durations() { :; }
ut_web_summary_line() { : > "$RUN/finished"; }
run_web
EOF
RUN="$tmp/after"; mkdir -p "$RUN"
python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp("bash", ["bash"] + sys.argv[1:])' "$tmp/after.sh" "$RUN" > "$RUN/out" 2> "$RUN/err" &
RUN_PID=$!
wait_for_file "$RUN/finished" || fail "after the run: the run finished"
kill -INT "$RUN_PID"; wait "$RUN_PID"; rc=$?
[ "$rc" = "130" ] && pass "after the run: Ctrl+C exits" || fail "after the run: Ctrl+C exits (rc $rc)"
grep -qi "stopp" "$RUN/err" && fail "after the run: no stop is reported ($(cat "$RUN/err"))" || pass "after the run: no stop is reported"
ls "$RUN"/diag/* >/dev/null 2>&1 && fail "after the run: no diagnostics are saved" || pass "after the run: no diagnostics are saved"

# kill -9: the dashboard server stops what the run left behind.
G="$tmp/guard"; mkdir -p "$G"
ut_web_server_py > "$G/serve.py"
printf '%s' token > "$G/.token"
printf '{"phase":"run","elapsed":5,"steps":[{"n":"Homebrew","s":"run","key":"homebrew"},{"n":"npm","s":"pending","key":"npm"}]}\n' > "$G/state.json"
{ "$tmp/tool" "$G/brew" 1; } >/dev/null 2>&1 &
echo "$!" > "$G/pids"
wait_for_file "$G/brew.started" || fail "kill -9: the step started"
bash -c 'python3 "$1/serve.py" "$1" "$1/.token" "$1/rep" 75 "$2" 5 > "$1/port" 2>/dev/null & echo $! > "$1/server.pid"; exec sleep 300' \
  _ "$G" "$tmp/tty" &
main=$!
disown "$main"
wait_for_file "$G/port" && sleep 0.3
kill -KILL "$main"
n=0; while [ ! -f "$G/brew.rolled" ] && [ "$n" -lt 80 ]; do sleep 0.1; n=$((n + 1)); done
sleep 0.5
[ -f "$G/brew.rolled" ] && pass "kill -9: the step left behind rolls back" || fail "kill -9: the step left behind rolls back"
child="$(cat "$G/brew.child" 2>/dev/null)"
[ -n "$child" ] && ! alive "$child" && pass "kill -9: nothing of the step keeps running" || fail "kill -9: nothing of the step keeps running"
grep -qi "killed" "$tmp/tty" 2>/dev/null && grep -q "Homebrew" "$tmp/tty" && pass "kill -9: the terminal is told" \
  || fail "kill -9: the terminal is told ($(cat "$tmp/tty" 2>/dev/null))"
grep -q '"why": *"killed"' "$G/state.json" && pass "kill -9: the page is told" || fail "kill -9: the page is told ($(cat "$G/state.json"))"
kill "$(cat "$G/server.pid")" 2>/dev/null

# The next run finds the one that did not finish.
LOCK_BASE="$tmp/lock"; mkdir -p "$LOCK_BASE"
( exit 0 ) & dead=$!; wait "$dead"
echo "$dead" > "$LOCK_BASE/pid"
echo "Homebrew · upgrade" > "$LOCK_BASE/steps"
dead_log="${TMPDIR:-/tmp}/updatetools-$dead.log"
printf '######## Homebrew ########\nleftover output\n' > "$dead_log"
DIAG_DIR="$tmp/diag-killed"
ut_acquire_lock 2> "$tmp/lock.err"; rc=$?
[ "$rc" = "0" ] && [ "$(cat "$LOCK_BASE/pid" 2>/dev/null)" = "$$" ] && pass "the stale lock is taken over" || fail "the stale lock is taken over (rc $rc)"
grep -q "did not finish" "$tmp/lock.err" && grep -q "Homebrew" "$tmp/lock.err" \
  && pass "the terminal is warned that the last run did not finish, and in what step" \
  || fail "the terminal is warned that the last run did not finish ($(cat "$tmp/lock.err"))"
grep -q "leftover output" "$DIAG_DIR"/*/run.log 2>/dev/null && pass "the unfinished run's log is saved" || fail "the unfinished run's log is saved"
[ ! -f "$dead_log" ] && pass "its scratch log is cleared" || fail "its scratch log is cleared"
[ -n "${UT_PREV_WARN:-}" ] && pass "the warning is kept for the dashboard" || fail "the warning is kept for the dashboard"

if [ "$failures" -eq 0 ]; then
  echo "all interrupt tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
