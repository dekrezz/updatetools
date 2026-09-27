#!/usr/bin/env bash
# App Store apps (mas) and macOS system updates (softwareupdate): open apps and
# restart-required updates are never forced; everything else is installed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-system.XXXXXX)"
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
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) pass "$name" ;; *) fail "$name (missing '$needle')" ;; esac
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) fail "$name (found '$needle')" ;; *) pass "$name" ;; esac
}

# ---------------------------------------------------------------------------
# Step table
# ---------------------------------------------------------------------------
keys=" $(ut_all_step_keys | tr ',' ' ') "
assert_contains "App Store step exists" "$keys" " appstore "
assert_contains "macOS step exists" "$keys" " macos "

# ---------------------------------------------------------------------------
# App Store (mas)
# ---------------------------------------------------------------------------
mas_log="$tmp/mas.log"
mas_update_rc=0
MAS_OUTDATED=""
RUNNING_BIDS=""
mas() {
  case "$1" in
    outdated) printf '%s' "$MAS_OUTDATED" ;;
    update|upgrade) printf '%s\n' "$*" >> "$mas_log"; return "$mas_update_rc" ;;
    *) return 0 ;;
  esac
}
ut_appstore_bundle_id() {
  case "$1" in
    111) echo com.example.closed ;;
    222) echo com.example.open ;;
    333) echo com.example.other ;;
  esac
}
is_running() { case " $RUNNING_BIDS " in *" $1 "*) return 0 ;; esac; return 1; }

: > "$mas_log"
MAS_OUTDATED=""
out="$(ut_update_appstore 2>&1)"; rc=$?
assert_eq "no outdated App Store apps succeeds" "0" "$rc"
assert_eq "nothing is updated when nothing is outdated" "" "$(cat "$mas_log")"
assert_contains "up-to-date App Store is reported" "$out" "up to date"

: > "$mas_log"
MAS_OUTDATED='111  Closed App  (1.0 -> 1.1)
222  Open App    (2.0 -> 2.1)
333  Other App   (3.0 -> 3.2)
'
RUNNING_BIDS="com.example.open"
out="$(ut_update_appstore 2>&1)"; rc=$?
assert_eq "an open App Store app leaves the step staged" "3" "$rc"
assert_contains "closed apps are updated" "$(cat "$mas_log")" "111"
assert_contains "every closed app is updated" "$(cat "$mas_log")" "333"
assert_not_contains "open apps are not updated" "$(cat "$mas_log")" "222"
assert_contains "the deferred open app is named" "$out" "Open App"

: > "$mas_log"
RUNNING_BIDS=""
out="$(ut_update_appstore 2>&1)"; rc=$?
assert_eq "all closed apps updated succeeds" "0" "$rc"
assert_contains "all apps are passed to mas" "$(cat "$mas_log")" "111 222 333"

: > "$mas_log"
RUNNING_BIDS="com.example.closed com.example.open com.example.other"
out="$(ut_update_appstore 2>&1)"; rc=$?
assert_eq "all apps open leaves the step staged" "3" "$rc"
assert_eq "mas is not called when every app is open" "" "$(cat "$mas_log")"

RUNNING_BIDS=""
mas_update_rc=1
ut_update_appstore >/dev/null 2>&1; rc=$?
assert_eq "a failed mas update fails the step" "1" "$rc"
mas_update_rc=0

# ---------------------------------------------------------------------------
# macOS (softwareupdate)
# ---------------------------------------------------------------------------
su_log="$tmp/su.log"
SU_LIST=""
su_list_rc=0
su_install_rc=0
softwareupdate() {
  case "$1" in
    -l|--list) printf '%s' "$SU_LIST"; return "$su_list_rc" ;;
    -i|--install) printf '%s\n' "$*" >> "$su_log"; return "$su_install_rc" ;;
  esac
}
sudo() {
  [ "$1" = "-n" ] && shift
  "$@"
}

: > "$su_log"
SU_LIST='Software Update Tool

Finding available software
No new software available.
'
out="$(ut_update_macos 2>&1)"; rc=$?
assert_eq "no macOS updates succeeds" "0" "$rc"
assert_eq "nothing is installed when nothing is available" "" "$(cat "$su_log")"
assert_contains "up-to-date macOS is reported" "$out" "up to date"

: > "$su_log"
SU_LIST='Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: Safari26.1-26.1
	Title: Safari, Version: 26.1, Size: 150000KiB, Recommended: YES,
* Label: Command Line Tools for Xcode 26.1-26.1
	Title: Command Line Tools for Xcode 26.1, Version: 26.1, Size: 900000KiB, Recommended: YES,
* Label: macOS Tahoe 26.1-25B78
	Title: macOS Tahoe 26.1, Version: 26.1, Size: 7000000KiB, Recommended: YES, Action: restart,
'
out="$(ut_update_macos 2>&1)"; rc=$?
assert_eq "a restart-required update leaves the step staged" "3" "$rc"
assert_contains "no-restart update is installed" "$(cat "$su_log")" "Safari26.1-26.1"
assert_contains "labels with spaces are installed intact" "$(cat "$su_log")" "Command Line Tools for Xcode 26.1-26.1"
assert_not_contains "restart-required update is not installed" "$(cat "$su_log")" "macOS Tahoe"
assert_contains "restart-required update is named" "$out" "macOS Tahoe 26.1"
assert_contains "restart command is given" "$out" "softwareupdate -i -a -R"

: > "$su_log"
SU_LIST='Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: XProtectPlistConfigData-5300
	Title: XProtectPlistConfigData, Version: 5300, Size: 800KiB, Recommended: YES,
'
out="$(ut_update_macos 2>&1)"; rc=$?
assert_eq "only no-restart updates succeeds" "0" "$rc"
assert_contains "background security data is installed" "$(cat "$su_log")" "XProtectPlistConfigData-5300"

su_install_rc=1
ut_update_macos >/dev/null 2>&1; rc=$?
assert_eq "a failed install fails the step" "1" "$rc"
su_install_rc=0

su_list_rc=1
SU_LIST=""
ut_update_macos >/dev/null 2>&1; rc=$?
assert_eq "a failed update check fails the step" "1" "$rc"
su_list_rc=0

if [ "$failures" -ne 0 ]; then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all system update checks passed"
