#!/usr/bin/env bash
# sudo is held only while the steps that need it run. Package-manager steps
# (npm, cargo, uv, CLIs) run after the credential and the remembered dashboard
# password are dropped, so their install scripts can never reuse them.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-sudo.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export UPDATETOOLS_ENABLED_FILE="$tmp/enabled"
export UPDATETOOLS_LIB_ONLY=1
mkdir -p "$HOME"
# shellcheck source=../updatetools
source "$ROOT/updatetools"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else
    fail "$name (expected '$expected', got '$actual')"
  fi
}

# Fake sudo: one cached credential, dropped by `sudo -k`.
state="$tmp/sudo-state"
order="$tmp/order"
sudo_calls="$tmp/sudo-calls"
sudo() {
  printf '%s\n' "$*" >> "$sudo_calls"
  case "$1" in
    -k) echo dropped > "$state"; return 0 ;;
    -n) [ "$(cat "$state")" = "cached" ] ;;
    *) return 0 ;;
  esac
}
export -f sudo 2>/dev/null || true

rec() { printf '%s:%s\n' "$1" "$(cat "$state")" >> "$order"; }

STEPS=(
  "Homebrew · update everything¦true¦rec homebrew"
  "Applications · manual DMGs¦true¦rec applications"
  "App Store · apps¦true¦rec appstore"
  "macOS · system updates¦true¦rec macos"
  "npm · global packages¦true¦rec npm"
  "cargo · update binaries¦true¦rec rust"
  "Supabase CLI¦true¦rec supabase"
  "Report · what changed¦true¦rec report"
)
TOTAL=${#STEPS[@]}
STEP_KEY=(); STEP_ON=(); STATUS=(); STEP_WHY=()
for ((i=0;i<TOTAL;i++)); do
  STEP_KEY[i]="$(ut_step_key "${STEPS[i]%%¦*}")"; STEP_ON[i]=1; STATUS[i]=pending; STEP_WHY[i]=""
done
STALL_TIMEOUT=0
WEB_DIR=""

set_on() {  # set_on key... — enable exactly these keys
  local i k
  for ((i=0;i<TOTAL;i++)); do
    STEP_ON[i]=0
    for k in "$@"; do [ "${STEP_KEY[i]}" = "$k" ] && STEP_ON[i]=1; done
  done
}

# ---------------------------------------------------------------------------
# Which steps need sudo
# ---------------------------------------------------------------------------
for k in homebrew applications appstore macos; do
  if ut_step_privileged "$k"; then pass "$k needs sudo"; else fail "$k needs sudo"; fi
done
for k in npm pnpm astral rust claude codex antigravity github vscode supabase vercel report; do
  if ut_step_privileged "$k"; then fail "$k runs without sudo"; else pass "$k runs without sudo"; fi
done

set_on npm rust report
if ut_needs_sudo; then fail "no privileged step enabled: no sudo"; else pass "no privileged step enabled: no sudo"; fi
set_on npm macos
if ut_needs_sudo; then pass "an enabled privileged step needs sudo"; else fail "an enabled privileged step needs sudo"; fi
STEPS[3]="macOS · system updates¦false¦rec macos"
if ut_needs_sudo; then fail "a privileged step whose tool is missing needs no sudo"; else pass "a privileged step whose tool is missing needs no sudo"; fi
STEPS[3]="macOS · system updates¦true¦rec macos"

# ---------------------------------------------------------------------------
# Dashboard runner: privileged phase, then drop, then everything else
# ---------------------------------------------------------------------------
check_order() {  # $1 runner label
  local runner="$1" line key st
  while IFS= read -r line; do
    key="${line%%:*}"; st="${line#*:}"
    if ut_step_privileged "$key"; then
      assert_eq "$runner: $key runs with sudo" "cached" "$st"
    else
      assert_eq "$runner: $key runs after sudo is dropped" "dropped" "$st"
    fi
  done < "$order"
  assert_eq "$runner: every enabled step ran" "8" "$(wc -l < "$order" | tr -d ' ')"
  assert_eq "$runner: remembered password is forgotten" "" "${SUDO_PW:-}"
}

set_on homebrew applications appstore macos npm rust supabase report
echo cached > "$state"; : > "$order"; : > "$sudo_calls"
SUDO_PW="secret"
ut_run_steps >/dev/null 2>&1
check_order "dashboard"

# ---------------------------------------------------------------------------
# Plain runner: same contract, and no password prompt without a privileged step
# ---------------------------------------------------------------------------
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_notify_end() { :; }
require_calls="$tmp/require"
ut_require_sudo() { echo "$1" >> "$require_calls"; echo cached > "$state"; return 0; }

echo dropped > "$state"; : > "$order"; : > "$require_calls"
SUDO_PW="secret"
set_on homebrew applications appstore macos npm rust supabase report
run_plain >/dev/null 2>&1
check_order "plain"
assert_eq "plain: sudo is asked for once" "1" "$(wc -l < "$require_calls" | tr -d ' ')"

echo dropped > "$state"; : > "$order"; : > "$require_calls"
set_on npm rust report
run_plain >/dev/null 2>&1
assert_eq "plain: no privileged step, no sudo prompt" "0" "$(wc -l < "$require_calls" | tr -d ' ')"
assert_eq "plain: unprivileged steps still run" "3" "$(wc -l < "$order" | tr -d ' ')"

if [ "$failures" -ne 0 ]; then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all sudo scope checks passed"
