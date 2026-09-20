#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATETOOLS_LIB_ONLY=1
export UPDATETOOLS_LIB_ONLY
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
assert_true() {
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
assert_false() {
  local name="$1"; shift
  if "$@"; then fail "$name"; else pass "$name"; fi
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) fail "$name" ;; *) pass "$name" ;; esac
}

tmp="$(mktemp -d /tmp/updatetools-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

assert_true "numeric version increases" ut_version_lt "1.9.3" "1.10.0"
assert_false "equal version is not newer" ut_version_lt "2.4" "2.4"
assert_false "downgrade is rejected" ut_version_lt "3.0" "2.9.9"
assert_false "uncomparable version fails closed" ut_version_lt "latest" "2.0"

cat > "$tmp/catalog.json" <<'JSON'
[
  {"token":"alpha","artifacts":[{"app":["Alpha.app"],"target":"/Applications/Alpha.app"}]},
  {"token":"beta","artifacts":[{"app":["Beta.app"],"target":"/Applications/Beta.app"}]},
  {"token":"beta-preview","artifacts":[{"app":["Beta.app"],"target":"/Applications/Beta.app"}]}
]
JSON
assert_eq "unique app artifact match" "alpha" "$(ut_cask_match_token "$tmp/catalog.json" "Alpha.app")"
assert_eq "ambiguous app artifact is rejected" "" "$(ut_cask_match_token "$tmp/catalog.json" "Beta.app")"
assert_eq "missing app artifact is rejected" "" "$(ut_cask_match_token "$tmp/catalog.json" "Missing.app")"
assert_true "cask app index builds" ut_cask_build_index "$tmp/catalog.json" "$tmp/catalog.tsv"
assert_eq "indexed unique app match" "alpha" "$(ut_cask_match_index "$tmp/catalog.tsv" "Alpha.app")"
assert_eq "indexed ambiguity is rejected" "" "$(ut_cask_match_index "$tmp/catalog.tsv" "Beta.app")"

mkdir "$tmp/old" "$tmp/new"
printf old > "$tmp/old/value"
printf new > "$tmp/new/value"
assert_true "atomic directory swap succeeds" ut_atomic_swap "$tmp/old" "$tmp/new"
assert_eq "new directory occupies target" "new" "$(cat "$tmp/old/value")"
assert_eq "old directory moves to staging path" "old" "$(cat "$tmp/new/value")"

mkdir "$tmp/installed.app" "$tmp/staged.app"
printf installed > "$tmp/installed.app/value"
printf staged > "$tmp/staged.app/value"
is_running() { return 1; }
assert_true "stopped app installs immediately" ut_install_or_defer "$tmp/installed.app" "$tmp/staged.app" "dev.test.App"
assert_eq "immediate install replaces app" "staged" "$(cat "$tmp/installed.app/value")"

mkdir "$tmp/running.app" "$tmp/waiting.app"
printf running > "$tmp/running.app/value"
printf waiting > "$tmp/waiting.app/value"
is_running() { return 0; }
UPDATETOOLS_DEFER_SPAWN=0
export UPDATETOOLS_DEFER_SPAWN
assert_false "running app is never replaced immediately" ut_install_or_defer "$tmp/running.app" "$tmp/waiting.app" "dev.test.Running"
assert_eq "running target remains untouched" "running" "$(cat "$tmp/running.app/value")"
assert_eq "staged update remains available" "waiting" "$(cat "$tmp/waiting.app/value")"
manual_impl="$(declare -f ut_update_manual_apps; declare -f ut_install_or_defer; declare -f ut_spawn_deferred_swap)"
assert_not_contains "manual updater never sends quit events" "$manual_impl" "graceful_quit"
assert_not_contains "manual updater never relaunches apps" "$manual_impl" "relaunch_app"
assert_not_contains "manual updater never uses AppleScript" "$manual_impl" "osascript"

assert_true "https DMG URL is accepted" ut_urls_look_like_dmg "https://example.test/App-1.2.dmg"
assert_false "empty source is not a DMG" ut_urls_look_like_dmg ""
assert_false "null Spotlight value is not a DMG" ut_urls_look_like_dmg "(null)"
assert_false "non-DMG URL is rejected" ut_urls_look_like_dmg "https://example.test/App.pkg"

mkdir -p "$tmp/sparkle.app/Contents/Frameworks/Sparkle.framework" \
         "$tmp/mozilla.app/Contents/MacOS/updater.app"
assert_true "Sparkle framework is a self-updater" ut_app_self_updates "$tmp/sparkle.app"
assert_true "Mozilla updater.app is a self-updater" ut_app_self_updates "$tmp/mozilla.app"
assert_false "plain app is not a self-updater" ut_app_self_updates "$tmp/installed.app"
assert_false "missing app is not from a DMG" ut_app_from_dmg "$tmp/missing.app"

mkdir -p "$tmp/apps/Alpha.app/Contents"
cat > "$tmp/apps/Alpha.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.test.Alpha</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
cat > "$tmp/info.json" <<'JSON'
{"casks":[{"token":"alpha","version":"1.1","url":"https://example.invalid/Alpha.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
brew() {
  if [ "${1:-}" = "list" ]; then return 1; fi
  if [ "${1:-}" = "info" ]; then cat "$tmp/info.json"; return 0; fi
  return 1
}
UPDATETOOLS_APP_ROOTS="$tmp/apps"
UPDATETOOLS_CASK_CATALOG="$tmp/catalog.json"
UPDATETOOLS_MANUAL_APPS_DRY_RUN=1
export UPDATETOOLS_APP_ROOTS UPDATETOOLS_CASK_CATALOG UPDATETOOLS_MANUAL_APPS_DRY_RUN
scan_output="$(ut_update_manual_apps)"
case "$scan_output" in
  *"not installed from a DMG"*) pass "dry-run leaves non-DMG apps alone" ;;
  *) fail "dry-run leaves non-DMG apps alone: $scan_output" ;;
esac
assert_not_contains "dry-run does not stage non-DMG apps" "$scan_output" "would stage verified DMG"
case "$scan_output" in
  *"already up to date"*) pass "dry-run reports already up to date" ;;
  *) fail "dry-run reports already up to date: $scan_output" ;;
esac

ut_app_from_dmg() { return 0; }
scan_output="$(ut_update_manual_apps)"
case "$scan_output" in
  *"Alpha.app: 1.0 → 1.1 (would stage verified DMG)"*) pass "dry-run scans a DMG app update" ;;
  *) fail "dry-run scans a DMG app update: $scan_output" ;;
esac
case "$scan_output" in
  *"1 updates matched"*) pass "dry-run reports one strict match" ;;
  *) fail "dry-run reports one strict match: $scan_output" ;;
esac

mkdir -p "$tmp/apps/Alpha.app/Contents/MacOS/updater.app"
scan_output="$(ut_update_manual_apps)"
case "$scan_output" in
  *"updates itself"*) pass "dry-run leaves self-updating apps alone" ;;
  *) fail "dry-run leaves self-updating apps alone: $scan_output" ;;
esac
assert_not_contains "self-updating apps are not staged" "$scan_output" "would stage verified DMG"

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'all manual app tests passed\n'
