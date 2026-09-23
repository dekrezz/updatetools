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
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) pass "$name" ;; *) fail "$name (missing '$needle')" ;; esac
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) fail "$name (unexpected '$needle')" ;; *) pass "$name" ;; esac
}

tmp="$(mktemp -d /tmp/updatetools-schedule-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

assert_eq "default interval is 24h" "interval 86400" "$(ut_parse_interval "")"
assert_eq "bare seconds" "interval 3600" "$(ut_parse_interval "3600")"
assert_eq "minutes suffix" "interval 1800" "$(ut_parse_interval "30m")"
assert_eq "hours suffix" "interval 43200" "$(ut_parse_interval "12h")"
assert_eq "days suffix" "interval 86400" "$(ut_parse_interval "1d")"
assert_eq "weeks suffix" "interval 604800" "$(ut_parse_interval "1w")"
assert_eq "calendar midnight" "calendar 0 0" "$(ut_parse_interval "00:00")"
assert_eq "calendar morning" "calendar 9 30" "$(ut_parse_interval "9:30")"
assert_eq "calendar evening" "calendar 23 59" "$(ut_parse_interval "23:59")"
assert_false "rejects empty unit amount 0" ut_parse_interval "0"
assert_false "rejects 0h" ut_parse_interval "0h"
assert_false "rejects bad hour" ut_parse_interval "24:00"
assert_false "rejects junk" ut_parse_interval "tomorrow"
assert_false "rejects 12x" ut_parse_interval "12x"

# Plist contents: relative interval
plist="$tmp/interval.plist"
NOTIFY_MODE=always
ut_write_schedule_plist "$plist" "/usr/bin/true" interval 43200
assert_true "interval plist lints" plutil -lint "$plist"
plist_body="$(cat "$plist")"
assert_contains "label in plist" "$plist_body" "<string>com.dekrezz.updatetools</string>"
assert_contains "program is resolved path" "$plist_body" "<string>/usr/bin/true</string>"
assert_contains "always runs --plain" "$plist_body" "<string>--plain</string>"
assert_contains "StartInterval 12h" "$plist_body" "<integer>43200</integer>"
assert_not_contains "default notify has no extra flag" "$plist_body" "--no-notify"
assert_not_contains "default notify has no on-error flag" "$plist_body" "--notify-on-error"
assert_contains "RunAtLoad false" "$plist_body" "<false/>"

# Plist contents: calendar + notify-on-error baked in
plist2="$tmp/calendar.plist"
NOTIFY_MODE=on_error
ut_write_schedule_plist "$plist2" "/usr/bin/true" calendar 7 15
assert_true "calendar plist lints" plutil -lint "$plist2"
plist2_body="$(cat "$plist2")"
assert_contains "calendar hour" "$plist2_body" "<integer>7</integer>"
assert_contains "calendar minute" "$plist2_body" "<integer>15</integer>"
assert_contains "StartCalendarInterval key" "$plist2_body" "StartCalendarInterval"
assert_contains "bakes --notify-on-error" "$plist2_body" "<string>--notify-on-error</string>"
assert_not_contains "calendar plist has no StartInterval" "$plist2_body" "StartInterval"

plist3="$tmp/nonotify.plist"
NOTIFY_MODE=never
ut_write_schedule_plist "$plist3" "/usr/bin/true" interval 86400
assert_contains "bakes --no-notify" "$(cat "$plist3")" "<string>--no-notify</string>"

# Notify mode gating without posting a real notification (stub osascript).
osascript() { printf 'OSASCRIPT:%s\n' "$*" >> "$tmp/osa.log"; return 0; }

: > "$tmp/osa.log"
NOTIFY_MODE=always
assert_true "always notifies on clean" ut_notify_end 0
assert_contains "clean message" "$(cat "$tmp/osa.log")" "Run finished cleanly."

: > "$tmp/osa.log"
assert_true "always notifies on failure" ut_notify_end 2
assert_contains "failure message" "$(cat "$tmp/osa.log")" "Run finished with 2 failures."

: > "$tmp/osa.log"
NOTIFY_MODE=on_error
assert_true "on_error skips clean" ut_notify_end 0
assert_eq "on_error wrote nothing for clean" "" "$(cat "$tmp/osa.log")"
assert_true "on_error notifies on failure" ut_notify_end 1
assert_contains "on_error failure text" "$(cat "$tmp/osa.log")" "Run finished with 1 failure."

: > "$tmp/osa.log"
NOTIFY_MODE=never
assert_true "never skips" ut_notify_end 3
assert_eq "never wrote nothing" "" "$(cat "$tmp/osa.log")"

# Help must show usage flags, not the Apache license header.
help_out="$("$ROOT/updatetools" --help 2>&1)" || true
assert_contains "help shows --schedule" "$help_out" "--schedule"
assert_contains "help shows --unschedule" "$help_out" "--unschedule"
assert_contains "help shows --no-notify" "$help_out" "--no-notify"
assert_not_contains "help is not the license" "$help_out" "Licensed under the Apache"

# Conflicting flags
assert_false "schedule+unschedule rejected" "$ROOT/updatetools" --schedule --unschedule
assert_false "notify flag conflict rejected" "$ROOT/updatetools" --no-notify --notify-on-error

# Optional: bootstrap a harmless agent pointed at /usr/bin/true, then bootout.
# Skip if launchctl bootstrap is unavailable or denied.
test_label="com.dekrezz.updatetools.test.$$"
test_plist="$tmp/${test_label}.plist"
uid="$(id -u)"
domain="gui/${uid}"
cat > "$test_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${test_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
  <key>StartInterval</key>
  <integer>86400</integer>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF
assert_true "test agent plist lints" plutil -lint "$test_plist"
if launchctl bootstrap "$domain" "$test_plist" 2>"$tmp/boot.err"; then
  pass "launchctl bootstrap test agent"
  if launchctl bootout "${domain}/${test_label}" 2>"$tmp/bootout.err"; then
    pass "launchctl bootout test agent"
  else
    fail "launchctl bootout failed: $(cat "$tmp/bootout.err")"
    launchctl bootout "${domain}/${test_label}" 2>/dev/null || true
  fi
else
  # Environment may deny bootstrap; plist lint + parser tests still prove the feature.
  pass "launchctl bootstrap skipped ($(tr '\n' ' ' < "$tmp/boot.err"))"
fi

# Ensure our real label was never left loaded by this test.
if launchctl print "${domain}/com.dekrezz.updatetools" >/dev/null 2>&1; then
  fail "real com.dekrezz.updatetools agent is loaded (must not be)"
else
  pass "real schedule agent not loaded"
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall schedule tests passed\n'
exit 0
