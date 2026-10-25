#!/usr/bin/env bash
# The dashboard clock counts the tools' time only. The password sheet and the
# wait for the read-only checks are not part of it: once the password is
# answered, the clock must not show the time spent so far and then drop back
# to zero when the tools start. It reads 00:00 until then and never goes back.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-clock.XXXXXX)"
export HOME="$tmp/home"
mkdir -p "$HOME"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools" --yes

answerer=""
finish() {
  [ -n "$answerer" ] && kill "$answerer" 2>/dev/null
  [ -n "${SUDO_KEEPER:-}" ] && kill_tree "$SUDO_KEEPER"
  [ -n "${WEB_PID:-}" ] && kill "$WEB_PID" 2>/dev/null
  rm -rf "$tmp" "${WRAP_DIR:-}" "${LOG:-}" "${UT_WEB_DATA:-}"
}
trap finish EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

PROMPT_TIMEOUT=20
# The network watch has its own test; this one must not reach the network.
NET_TIMEOUT=0
clock_log=""

# Every state.json the run writes, as the page's clock shows it: 00:00 on the
# chooser, on an error and while the password sheet is open, else elapsed.
eval "real_$(declare -f ut_web_state)"
ut_web_state() {
  real_ut_web_state "$@"
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(0 if d["phase"] in ("choose", "error") or d.get("prompt") else d["elapsed"])' \
    "$WEB_DIR/state.json" >> "$clock_log"
}

ut_web_start() {
  WEB_DIR="$tmp/web"
  mkdir -p "$WEB_DIR"
  ( exec sleep 60 ) &
  WEB_PID=$!
  WEB_OPENED=1
}
ut_web_stop() { :; }
ut_icon_site() { :; }
ut_needs_sudo() { return 0; }
ut_save_enabled() { :; }
ut_remember_password_layout() { :; }
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_generate_report() { :; }
ut_notify_end() { :; }
ut_save_durations() { :; }
ut_web_summary_line() { kill "$WEB_PID" 2>/dev/null; }
ut_preflight() { mkdir -p "$1"; sleep 1.5; }
# Each look at the keyboard layout stands for 20 s with the password sheet open.
ut_read_input_source() {
  UT_LAYOUT_NOW=English; UT_LAYOUT_ID=com.apple.keylayout.US
  SECONDS=$((SECONDS + 20))
}
sudo() {
  case "$*" in
    "-n true") return 1 ;;
    *) return 0 ;;
  esac
}
ut_run_steps() {
  printf 'steps\n' >> "$clock_log"
  ut_web_state run
  SECONDS=$((SECONDS + 30))
  ut_web_state run
  kill_tree "$SUDO_KEEPER"
  SUDO_KEEPER=""
}

# The user, answering each new password prompt the page shows (into the
# run's prompt directory, named after its PID).
(
  seen=""
  while :; do
    ask="$(sed -n 's/.*"ask":\([0-9]*\).*/\1/p' "$tmp/web/state.json" 2>/dev/null)"
    if [ -n "$ask" ] && [ "$ask" != "$seen" ]; then
      for rep in "${TMPDIR:-/tmp}"/updatetools-wrap-$$*/; do :; done
      printf 'secret\n' > "${rep}rep"
      seen="$ask"
    fi
    sleep 0.05
  done
) &
answerer=$!

before_steps() { awk '$1 == "steps" { exit } $1 > m { m = $1 } END { print m + 0 }' "$1"; }
went_back() {
  awk '$1 == "steps" { next }
       seen && $1 < last { printf "%s -> %s", last, $1; exit }
       { last = $1; seen = 1 }' "$1"
}
last_shown() { tail -n 1 "$1"; }

check_round() { # <name> <clock log>
  local name="$1" log="$2" back
  [ "$(before_steps "$log")" = "0" ] \
    && pass "$name: the clock reads 00:00 until the tools start" \
    || fail "$name: the clock reads 00:00 until the tools start (showed $(before_steps "$log") s; clock: $(tr '\n' ' ' < "$log"))"
  back="$(went_back "$log")"
  [ -z "$back" ] && pass "$name: the clock never goes back" \
    || fail "$name: the clock never goes back ($back s; clock: $(tr '\n' ' ' < "$log"))"
  [ "$(last_shown "$log")" -ge 30 ] && pass "$name: the tools' time is counted" \
    || fail "$name: the tools' time is counted (ended at $(last_shown "$log") s)"
}

clock_log="$tmp/clock-run"
run_web
check_round "first run" "$clock_log"

clock_log="$tmp/clock-retry"
( exec sleep 60 ) &
WEB_PID=$!
ut_web_retry "${STEP_KEY[0]}"
check_round "retry" "$clock_log"

if [ "$failures" -eq 0 ]; then
  echo "all run clock tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
