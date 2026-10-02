#!/usr/bin/env bash
# An auto-updating app often installs its own update before Homebrew does, so
# brew still lists the cask as outdated while the app on disk (and the running
# process) is already on the new version. Such a cask must not be reported as
# staged: nothing is waiting for a relaunch. A running app whose bundle really
# is older must still be staged.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-selfupdated.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export UPDATETOOLS_LIB_ONLY=1
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
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) pass "$name" ;; *) fail "$name (missing '$needle')" ;; esac
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) fail "$name (found '$needle')" ;; *) pass "$name" ;; esac
}

export HOME="$tmp/home"
mkdir -p "$HOME/Applications"
UT_REPORT_DIR="$tmp/report"
MAKE_REPORT=1
brew_log="$tmp/brew.log"
OUTDATED_CASKS=""
CASK_LATEST=""   # version string brew info reports for the cask

make_app() { # $1 bundle name, $2 CFBundleShortVersionString
  local p="$HOME/Applications/$1/Contents"
  rm -rf "$HOME/Applications/$1"
  mkdir -p "$p"
  /usr/bin/plutil -create xml1 "$p/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "dev.test.self" "$p/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$2" "$p/Info.plist"
}

brew() {
  case "$1" in
    outdated) for n in $OUTDATED_CASKS; do printf '%s\n' "$n"; done ;;
    info)     printf '{"casks":[{"version":"%s"}]}\n' "$CASK_LATEST" ;;
    upgrade)
      printf '%s\n' "$*" >> "$brew_log"
      OUTDATED_CASKS=""
      return 0
      ;;
    *) printf '%s\n' "$*" >> "$brew_log"; return 0 ;;
  esac
}
have() { command -v "$1" >/dev/null 2>&1 || [ "$1" = brew ]; }
classify_cask() { echo protect; }
cask_to_apps() { echo "UT Self.app"; }

run_casks() {
  : > "$brew_log"
  rm -rf "$UT_REPORT_DIR"
  out="$(ut_upgrade_casks_smart 2>&1)"; rc=$?
}

# ---------------------------------------------------------------------------
# Running app that already updated itself: not staged
# ---------------------------------------------------------------------------
make_app "UT Self.app" "1.6.1034"
CASK_LATEST="1.6.1034"
OUTDATED_CASKS="ut-self"
run_casks
assert_eq "self-updated running app does not leave the step staged" "0" "$rc"
assert_contains "self-updated app is counted as upgraded" "$out" "casks: 1 upgraded"
assert_contains "self-updated app is not counted as staged" "$out" "· 0 staged"
assert_contains "self-updated app is explained" "$out" "already on 1.6.1034"
assert_not_contains "self-updated app is not announced as staging" "$out" "staging (new version applies on next launch)"
assert_eq "self-updated app is not recorded as staged for the report" "no" \
  "$([ -f "$UT_REPORT_DIR/staged" ] && echo yes || echo no)"
assert_contains "Homebrew's record is still synced" "$(cat "$brew_log")" "upgrade --cask --no-quit ut-self"

# Cask versions can carry a build suffix after a comma (claude, cursor).
make_app "UT Self.app" "2.19675.0"
CASK_LATEST="2.19675.0,5706e5524dba58b23e105c31c358df8ab0a95852"
OUTDATED_CASKS="ut-self"
run_casks
assert_eq "self-updated app matches a cask version with a build suffix" "0" "$rc"
assert_contains "suffixed self-updated app is not staged" "$out" "· 0 staged"

# ---------------------------------------------------------------------------
# Running app whose bundle is really older: still staged
# ---------------------------------------------------------------------------
make_app "UT Self.app" "1.6.1021"
CASK_LATEST="1.6.1034"
OUTDATED_CASKS="ut-self"
run_casks
assert_eq "outdated running app leaves the step staged" "3" "$rc"
assert_contains "outdated running app is counted as staged" "$out" "· 1 staged"
assert_contains "outdated running app is recorded as staged" \
  "$(cat "$UT_REPORT_DIR/staged" 2>/dev/null)" "ut-self"

if [ "$failures" -eq 0 ]; then
  echo "all self-updated cask tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
