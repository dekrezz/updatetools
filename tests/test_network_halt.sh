#!/usr/bin/env bash
# When the network goes away mid-run, every step after it would fail one by
# one, each in its own words. The run stops instead: once the connection has
# been gone for NET_TIMEOUT seconds, the running step is stopped safely, no
# other step starts, the dashboard and the terminal say why, and the evidence
# is kept. A blip shorter than that (Wi-Fi switching) changes nothing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-net.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch" HOMEBREW_CACHE="$tmp/brew-cache"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
finish() {
  pkill -KILL -f "$tmp/" 2>/dev/null
  rm -rf "$tmp"
}
trap finish EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

# A tool that prints progress for $2 seconds (15 without $2) and needs
# 1 s to roll back when told to stop.
cat > "$tmp/tool" <<'EOF'
#!/bin/bash
echo started > "$1.started"
trap 'sleep 1; echo done > "$1.rolled"; exit 143' TERM
n=0
while [ "$n" -lt $(( ${2:-15} * 10 )) ]; do sleep 0.1; n=$((n + 1)); echo "working $n"; done
EOF
chmod +x "$tmp/tool"

sudo() { return 0; }
ut_needs_sudo() { return 1; }
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_notify_end() { :; }
ut_net_probe() { cat "$tmp/net"; }
STALL_TIMEOUT=0
STOP_GRACE=10
NET_PROBE_EVERY=1

state_get() {
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$WEB_DIR/state.json" "$1" 2>/dev/null
}
wait_for_file() { local n=0; while [ ! -f "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done; [ -f "$1" ]; }

setup_run() { # <name> <homebrew seconds> <npm seconds>
  local d="$tmp/$1"
  mkdir -p "$d/web"
  WEB_DIR="$d/web"; LOG="$d/run.log"; : > "$LOG"; DIAG_DIR="$d/diag"; T0=$SECONDS
  STEPS=(
    "Homebrew · upgrade¦true¦\"$tmp/tool\" \"$d/brew\" $2"
    "npm · update globals¦true¦\"$tmp/tool\" \"$d/npm\" $3"
    "Report¦true¦:"
  )
  STEP_KEY=(homebrew npm report); STEP_ON=(1 1 1); TOTAL=3
  STATUS=(pending pending pending); STEP_WHY=("" "" ""); STEP_SEC=(); STEP_T0=()
  RUN="$d"
}

# The connection drops while Homebrew runs.
(
  failures=0
  setup_run lost "" 1
  NET_TIMEOUT=2
  echo up > "$tmp/net"
  ( wait_for_file "$RUN/brew.started" && echo "down no default route (test)" > "$tmp/net" ) &
  ut_net_gate || fail "an online run passes the network gate"
  ut_run_steps 2> "$RUN/stderr"
  [ -f "$RUN/brew.rolled" ] && pass "the running step rolled back before the run stopped" \
    || fail "the running step rolled back before the run stopped"
  [ "${STATUS[0]}:${STEP_WHY[0]}" = "fail:stopped" ] && pass "the interrupted step is marked stopped" \
    || fail "the interrupted step is marked stopped (${STATUS[0]}:${STEP_WHY[0]})"
  [ ! -f "$RUN/npm.started" ] && pass "no step starts once the network is gone" || fail "no step starts once the network is gone"
  [ "${STATUS[1]}:${STEP_WHY[1]}" = "skip:halted" ] && [ "${STATUS[2]}:${STEP_WHY[2]}" = "skip:halted" ] \
    && pass "the steps that never ran are marked as not run" \
    || fail "the steps that never ran are marked as not run (${STATUS[1]}:${STEP_WHY[1]} ${STATUS[2]}:${STEP_WHY[2]})"
  [ "$(state_get halt.why)" = "network" ] && pass "the dashboard is told the run stopped for the network" \
    || fail "the dashboard is told the run stopped for the network ($(cat "$WEB_DIR/state.json"))"
  case "$(state_get halt.msg)" in *Homebrew*) pass "the dashboard says which step was stopped" ;;
    *) fail "the dashboard says which step was stopped ('$(state_get halt.msg)')" ;; esac
  grep -q "updatetools: stopp" "$RUN/stderr" && pass "the terminal is told the run stopped" \
    || fail "the terminal is told the run stopped ($(cat "$RUN/stderr"))"
  grep -Eq '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] updatetools: network down' "$LOG" && pass "the loss is in the run log with its time" \
    || fail "the loss is in the run log with its time"
  diag="$(state_get halt.diag)"
  [ -n "$diag" ] && [ -f "$diag/diagnostics.txt" ] && pass "diagnostics are saved and their place is published" \
    || fail "diagnostics are saved and their place is published ('$diag')"
  grep -q "no default route (test)" "$diag/diagnostics.txt" 2>/dev/null && pass "diagnostics say why the network was down" \
    || fail "diagnostics say why the network was down"
  grep -q "Homebrew" "$diag/diagnostics.txt" 2>/dev/null && pass "diagnostics list the steps and their outcome" \
    || fail "diagnostics list the steps and their outcome"
  grep -q "working" "$diag/run.log" 2>/dev/null && pass "diagnostics keep the run log with the steps' output" \
    || fail "diagnostics keep the run log with the steps' output"
  exit "$failures"
)
failures=$((failures + $?))

# A blip shorter than NET_TIMEOUT: the run goes on, the page warns meanwhile.
(
  failures=0
  setup_run blip 4 1
  NET_TIMEOUT=4
  echo up > "$tmp/net"
  ( wait_for_file "$RUN/brew.started" && echo "down DNS lookup failed (test)" > "$tmp/net" \
      && sleep 1.5 && echo up > "$tmp/net" ) &
  ( while [ ! -f "$RUN/npm.started" ]; do
      grep -q '"net":{' "$WEB_DIR/state.json" 2>/dev/null && : > "$RUN/warned"
      sleep 0.1
    done ) &
  ut_net_gate || fail "an online run passes the network gate"
  ut_run_steps 2>/dev/null
  [ "${STATUS[0]}" = "done" ] && [ "${STATUS[1]}" = "done" ] && pass "a short blip does not stop the run" \
    || fail "a short blip does not stop the run (${STATUS[*]})"
  [ -z "$(state_get halt.why)" ] && pass "no stop is published after a blip" || fail "no stop is published after a blip"
  [ -f "$RUN/warned" ] && pass "the page is warned while the network is down" || fail "the page is warned while the network is down"
  grep -q "updatetools: network back" "$LOG" && pass "the return of the network is logged" || fail "the return of the network is logged"
  exit "$failures"
)
failures=$((failures + $?))

# No network when the steps are about to start: nothing starts.
(
  failures=0
  setup_run offline 1 1
  NET_TIMEOUT=2
  echo "down no default route (test)" > "$tmp/net"
  if ut_net_gate 2>/dev/null; then fail "an offline run does not pass the network gate"; else pass "an offline run does not pass the network gate"; fi
  ut_run_steps 2>/dev/null
  [ ! -f "$RUN/brew.started" ] && [ ! -f "$RUN/npm.started" ] && pass "no step starts offline" || fail "no step starts offline"
  [ "$(state_get halt.why)" = "network" ] && pass "the offline start is published" || fail "the offline start is published"
  exit "$failures"
)
failures=$((failures + $?))

# Plain output (cron, launchd, --plain): the same stop, and a distinct exit code.
(
  failures=0
  setup_run plain "" 1
  WEB_DIR=""
  NET_TIMEOUT=2
  echo up > "$tmp/net"
  ( wait_for_file "$RUN/brew.started" && echo "down no default route (test)" > "$tmp/net" ) &
  run_plain > "$RUN/out" 2>&1; rc=$?
  [ "$rc" = "75" ] && pass "a plain run stopped by the network exits 75" || fail "a plain run stopped by the network exits 75 (rc $rc)"
  [ -f "$RUN/brew.rolled" ] && [ ! -f "$RUN/npm.started" ] && pass "a plain run stops the same safe way" \
    || fail "a plain run stops the same safe way"
  grep -q "$DIAG_DIR" "$RUN/out" && pass "a plain run prints where the diagnostics are" \
    || fail "a plain run prints where the diagnostics are"
  exit "$failures"
)
failures=$((failures + $?))

if [ "$failures" -eq 0 ]; then
  echo "all network halt tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
