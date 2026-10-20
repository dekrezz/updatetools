#!/usr/bin/env bash
# How long Homebrew will take depends on what it has to upgrade, not on how long
# it took last time (2026-10-21: the last run upgraded 29 packages in 14:41, so
# a run with nothing to upgrade was told "about 19 min" and took 9 s). Like
# yay's "previous duration" and genlop's estimate:
#   * the Homebrew step times each package it upgrades (from "==> Upgrading X",
#     or ">> X:" for the casks updatetools upgrades one by one, to the next one;
#     the downloads before the first are shared among the packages of that
#     command) and what is left is Homebrew's own time (brew update, cleanup);
#     the last of each is kept in UPDATETOOLS_PACKAGE_TIMES_FILE, else
#     ~/.config/updatetools/package-times;
#   * the estimate is Homebrew's own time plus each package's last time, for
#     the packages the plan lists, and once `brew update` has run, the list it
#     left; a package never timed counts as the median of those that were;
#   * with nothing to go on there is no estimate, never the step's last time;
#   * the step's output and exit code are Homebrew's, untouched.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-hbest.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"
unset UPDATETOOLS_PACKAGE_TIMES_FILE UPDATETOOLS_DURATIONS_FILE

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
trap 'cleanup; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
near() { [ -n "$1" ] && [ "$1" -ge $(($2 - 1)) ] && [ "$1" -le $(($2 + 1)) ]; }
times_file() { printf '%s\n' "${UPDATETOOLS_PACKAGE_TIMES_FILE:-$HOME/.config/updatetools/package-times}"; }
# time_of NAME: a package's kept time; "base": Homebrew's own.
time_of() {
  awk -v n="$1" '($1 == "package" && $2 == n) { v = $3 } ($1 == "base" && n == "base") { v = $2 } END { print v }' "$(times_file)" 2>/dev/null
}

# ── Timing a Homebrew step ──────────────────────────────────────────────────
UT_REPORT_DIR="$tmp/report"
brew() {
  case "$1" in
    update) sleep 1; echo "==> Updating Homebrew..." ;;
    upgrade)
      echo "==> Fetching downloads for: alpha, beta"
      sleep 2
      echo "==> Upgrading alpha"; echo "==> Pouring alpha--2.0.bottle.tar.gz"
      sleep 3
      echo "==> Upgrading beta"
      sleep 1
      echo "🍺  /opt/homebrew/Cellar/beta/2.0"
      return "${UPGRADE_RC:-0}" ;;
    autoremove|cleanup) return 0 ;;
  esac
}
ut_report_begin() { :; }
ut_upgrade_casks_smart() {
  echo ">> big-app: not running — upgrading in place"
  echo "==> Upgrading big-app"
  sleep 2
  echo "🍺  big-app was successfully upgraded!"
  return 0
}
t0=$SECONDS
ut_update_homebrew_all > "$tmp/step.out" 2>&1; rc=$?
STATUS=(done); STEP_KEY=(homebrew); STEP_SEC=($((SECONDS - t0))); STEP_ON=(1); TOTAL=1
ut_save_package_times
[ "$rc" = 0 ] && pass "the step exits as Homebrew did" || fail "the step exits as Homebrew did (rc $rc)"
grep -qx '==> Upgrading alpha' "$tmp/step.out" && grep -qx '==> Pouring alpha--2.0.bottle.tar.gz' "$tmp/step.out" \
  && grep -qx '>> big-app: not running — upgrading in place' "$tmp/step.out" \
  && pass "the step's output is Homebrew's, line for line" || fail "the step's output is Homebrew's, line for line ($(cat "$tmp/step.out"))"
near "$(time_of alpha)" 4 && pass "a package's time is its own span plus its share of the downloads (alpha: 3 s + 2 s / 2)" \
  || fail "a package's time is its own span plus its share of the downloads (alpha: $(time_of alpha), want 4 ±1)"
near "$(time_of beta)" 2 && pass "the last package of a command runs until the command ends (beta: 1 s + 2 s / 2)" \
  || fail "the last package of a command runs until the command ends (beta: $(time_of beta), want 2 ±1)"
near "$(time_of big-app)" 2 && pass "a cask updatetools upgrades itself is timed from its >> line" \
  || fail "a cask updatetools upgrades itself is timed from its >> line (big-app: $(time_of big-app), want 2 ±1)"
near "$(time_of base)" 1 && pass "what is left is Homebrew's own time (brew update)" \
  || fail "what is left is Homebrew's own time (base: $(time_of base), want 1 ±1, step ${STEP_SEC[0]} s)"
UPGRADE_RC=1 ut_update_homebrew_all > /dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && pass "a failed brew upgrade still fails the step" || fail "a failed brew upgrade still fails the step"

# ── The estimate ─────────────────────────────────────────────────────────────
export UPDATETOOLS_PACKAGE_TIMES_FILE="$tmp/package-times"
printf '%s\n' 'base 9' 'package node 30' 'package go 5' 'package google-chrome 60' > "$UPDATETOOLS_PACKAGE_TIMES_FILE"
export UPDATETOOLS_DURATIONS_FILE="$tmp/durations"
printf '%s\n' 'homebrew 881' 'report 3' > "$UPDATETOOLS_DURATIONS_FILE"

WEB_DIR="$tmp/web"; mkdir -p "$WEB_DIR"
UT_PLAN_DIR="$WEB_DIR/plan"; mkdir -p "$UT_PLAN_DIR"
UT_REPORT_DIR="$tmp/report2"; mkdir -p "$UT_REPORT_DIR"
STEPS=("Homebrew · update everything¦true¦true" "Report · what changed¦true¦:")
STEP_KEY=(homebrew report); STEP_ON=(1 1); STATUS=(pending pending); STEP_WHY=("" ""); STEP_SEC=("" "")
STEP_SLUG=(homebrew ""); STEP_IMG=("" ""); STEP_AVAIL=(1 1); TOTAL=2
STEP_EST=("$(ut_duration_of homebrew)" "$(ut_duration_of report)")
T0=$SECONDS
est() { # the Homebrew step's est in the state.json the page reads
  ut_web_state "$1" >/dev/null 2>&1
  python3 -I -c 'import json,sys; s=[x for x in json.load(open(sys.argv[1]))["steps"] if x["key"]=="homebrew"][0]; print(s.get("est",""))' "$WEB_DIR/state.json"
}
plan() { # the plan's lines: name|old|new|act|why|token|app
  : > "$UT_PLAN_DIR/homebrew.plan"
  local t; for t in "$@"; do printf '%s|1|2|update||%s|\n' "$t" "$t" >> "$UT_PLAN_DIR/homebrew.plan"; done
  : > "$UT_PLAN_DIR/homebrew.done"
}

got="$(est choose)"
[ "$got" != 881 ] && pass "before the plan is in, Homebrew's last time (881 s) is not its estimate" \
  || fail "before the plan is in, Homebrew's last time (881 s) is not its estimate"
plan
got="$(est choose)"
[ "$got" = 9 ] && pass "nothing to upgrade: the estimate is Homebrew's own time (9 s), not the last run's 881 s" \
  || fail "nothing to upgrade: the estimate is Homebrew's own time (9 s), not the last run's 881 s (est '$got')"
plan node google-chrome
got="$(est choose)"
[ "$got" = 99 ] && pass "the estimate adds each planned package's last time (9 + 30 + 60)" \
  || fail "the estimate adds each planned package's last time (9 + 30 + 60; est '$got')"
plan node newcomer
got="$(est choose)"
[ "$got" = 69 ] && pass "a package never timed counts as the median of those that were (9 + 30 + 30)" \
  || fail "a package never timed counts as the median of those that were (9 + 30 + 30; est '$got')"
# brew update ran and left the list it will upgrade: name|old|new|kind.
printf '%s\n' 'go|1|2|formula' 'google-chrome|1|2|cask' > "$UT_REPORT_DIR/brew"
STATUS=(run pending)
got="$(est run)"
[ "$got" = 74 ] && pass "once brew update has run, the estimate follows the list it left (9 + 5 + 60)" \
  || fail "once brew update has run, the estimate follows the list it left (9 + 5 + 60; est '$got')"

rm -f "$UT_REPORT_DIR/brew"; STATUS=(pending pending)
rm -f "$UPDATETOOLS_PACKAGE_TIMES_FILE"
STEP_EST=("$(ut_duration_of homebrew)" "$(ut_duration_of report)")
plan node
got="$(est choose)"
[ -z "$got" ] && pass "with no package times kept yet there is no estimate, not the step's last time" \
  || fail "with no package times kept yet there is no estimate, not the step's last time (est '$got')"
plan
got="$(est choose)"
[ -z "$got" ] && pass "with Homebrew's own time unknown, nothing to upgrade has no estimate either" \
  || fail "with Homebrew's own time unknown, nothing to upgrade has no estimate either (est '$got')"

if [ "$failures" -eq 0 ]; then
  echo "all Homebrew estimate tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
