#!/usr/bin/env bash
# Running apps that are safe to restart (document-less menu-bar / background
# agents such as Rectangle, or a curated allowlist of utilities) are quit
# gracefully, updated, and relaunched in the background. Everything that can
# lose work stays protected: the hosting terminal, risky categories, apps with a
# document model, ordinary windowed apps, and agents that host other processes.
# An app that ignores the quit request is left running — never force-killed.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-safe-restart.XXXXXX)"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it and remove $tmp too.
trap 'cleanup; rm -rf "$tmp"' EXIT

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
APPS="$HOME/Applications"
mkdir -p "$APPS"
UT_REPORT_DIR="$tmp/report"
UT_LASTREPORT="$tmp/last"
MAKE_REPORT=1
UT_TERM_BID=""
unset UPDATETOOLS_CLOSE UPDATETOOLS_PROTECT UPDATETOOLS_SAFE_RESTART CLOSE_APPS

running="$tmp/running"     # one bundle id per line
calls="$tmp/calls.log"     # every side-effecting external call
: > "$running"; : > "$calls"

# make_app <bundle name> <bundle id> [LSUIElement|docs|plain]
make_app() {
  local p="$APPS/$1/Contents"
  mkdir -p "$p/MacOS"
  /usr/bin/plutil -create xml1 "$p/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$2" "$p/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "1.0" "$p/Info.plist"
  case "${3:-plain}" in
    LSUIElement) /usr/bin/plutil -insert LSUIElement -bool true "$p/Info.plist" ;;
    docs) /usr/bin/plutil -insert CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Text"}]' "$p/Info.plist" ;;
    mic) /usr/bin/plutil -insert LSUIElement -bool true "$p/Info.plist"
         /usr/bin/plutil -insert NSMicrophoneUsageDescription -string "Transcribe speech" "$p/Info.plist" ;;
    camera) /usr/bin/plutil -insert LSUIElement -bool true "$p/Info.plist"
            /usr/bin/plutil -insert NSCameraUsageDescription -string "Record video" "$p/Info.plist" ;;
  esac
}

make_app "UT Rect.app"   dev.test.rect   LSUIElement
make_app "UT Editor.app" dev.test.editor docs
make_app "UT Agent.app"  dev.test.agent  LSUIElement
make_app "UT Helper.app" dev.test.helper LSUIElement
make_app "UT Term.app"   com.googlecode.iterm2 LSUIElement
make_app "UT Vault.app"  dev.test.vault  LSUIElement
make_app "UT Chat.app"   dev.test.chat   plain
make_app "UT Maccy.app"  org.p0deje.Maccy plain
make_app "UT Stuck.app"  dev.test.stuck  LSUIElement
make_app "UT Gone.app"   dev.test.gone   LSUIElement
make_app "UT Dictate.app" dev.test.dictate mic
make_app "UT Cam.app"    dev.test.cam    camera

# token -> app bundle name
cask_to_apps() {
  case "$1" in
    ut-rect) echo "UT Rect.app" ;;      ut-editor) echo "UT Editor.app" ;;
    ut-agent) echo "UT Agent.app" ;;    ut-helper) echo "UT Helper.app" ;;
    iterm2) echo "UT Term.app" ;;       1password) echo "UT Vault.app" ;;
    ut-chat) echo "UT Chat.app" ;;      maccy) echo "UT Maccy.app" ;;
    ut-stuck) echo "UT Stuck.app" ;;    ut-gone) echo "UT Gone.app" ;;
    ut-dictate) echo "UT Dictate.app" ;; ut-cam) echo "UT Cam.app" ;;
  esac
}
pid_of() {
  case "$1" in
    dev.test.rect) echo 101 ;; dev.test.editor) echo 102 ;; dev.test.agent) echo 103 ;;
    dev.test.helper) echo 104 ;; com.googlecode.iterm2) echo 105 ;; dev.test.vault) echo 106 ;;
    dev.test.chat) echo 107 ;; org.p0deje.Maccy) echo 108 ;; dev.test.stuck) echo 109 ;;
    dev.test.gone) echo 110 ;; dev.test.dictate) echo 111 ;; dev.test.cam) echo 112 ;;
    *) echo 199 ;;
  esac
}
type_of() {
  case "$1" in
    dev.test.editor|dev.test.chat|org.p0deje.Maccy) echo Foreground ;;
    *) echo UIElement ;;
  esac
}
is_up() { grep -qxF "$1" "$running"; }
set_running() { printf '%s\n' "$@" > "$running"; }

LSAPPINFO_FORMAT=classic   # classic: "pid"=N ; tahoe: pid = N / type="X"
lsappinfo() {
  local bid key="" a
  case "$1" in
    find)
      bid="${2#bundleID=}"
      is_up "$bid" && printf 'ASN:0x0-0x%s-"%s":\n' "$(pid_of "$bid")" "$bid"
      return 0 ;;
    info)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in -only) key="$2"; shift 2 ;; -app) a="$2"; shift 2 ;; *) a="$1"; shift ;; esac
      done
      case "$a" in ASN:*) bid="${a#*\"}"; bid="${bid%%\"*}" ;; *) bid="$a" ;; esac
      is_up "$bid" || return 0
      if [ "$LSAPPINFO_FORMAT" = tahoe ]; then
        case "$key" in
          pid) printf '    pid = %s !cgsConnection type=[ NULL ]\n' "$(pid_of "$bid")" ;;
          ApplicationType) printf ' !cgsConnection !signalled type="%s" flavor=[ NULL ]\n' "$(type_of "$bid")" ;;
        esac
      else
        case "$key" in
          pid) printf '"pid"=%s\n' "$(pid_of "$bid")" ;;
          ApplicationType) printf '"ApplicationType"="%s"\n' "$(type_of "$bid")" ;;
        esac
      fi
      return 0 ;;
  esac
  return 0
}
pgrep() { # only -P <pid> is meaningful here
  [ "${1:-}" = "-P" ] || return 1
  case "$2" in 103) echo 203 ;; 104) echo 204 ;; *) return 1 ;; esac
}
ps() { # ps -o comm= -p <pid>
  local p="${*: -1}"
  case "$p" in
    203) echo "/usr/bin/python3" ;;
    204) echo "$APPS/UT Helper.app/Contents/MacOS/helper-xpc" ;;
    *) command ps "$@" ;;
  esac
}
osascript() {
  local script="$*"
  printf 'osascript %s\n' "$script" >> "$calls"
  case "$script" in
    *"to quit"*)
      local bid="${script#*application id \"}"; bid="${bid%%\"*}"
      [ "$bid" = dev.test.stuck ] && return 0     # ignores the quit request
      grep -vxF "$bid" "$running" > "$running.n"; mv "$running.n" "$running"
      return 0 ;;
    *documents*) echo "execution error: Can't get every document. (-1728)" >&2; return 1 ;;
  esac
  return 0
}
open() {
  printf 'open %s\n' "$*" >> "$calls"
  local target="${*: -1}" bid
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null)"
  [ -n "$bid" ] || bid="$target"
  [ "$bid" = dev.test.gone ] && return 0         # launch silently fails
  printf '%s\n' "$bid" >> "$running"
  return 0
}
kill() { # liveness probes (kill -0) are not signals; log everything else
  [ "${1:-}" = "-0" ] || printf 'kill %s\n' "$*" >> "$calls"
  builtin kill "$@"
}
pkill()   { printf 'pkill %s\n' "$*" >> "$calls"; }
killall() { printf 'killall %s\n' "$*" >> "$calls"; }
sleep()   { :; }

OUTDATED=""
brew() {
  case "$1" in
    outdated) local t; for t in $OUTDATED; do printf '%s\n' "$t"; done ;;
    info) printf '{"casks":[{"version":"9.9"}]}\n' ;;
    upgrade|reinstall)
      printf 'brew %s\n' "$*" >> "$calls"
      OUTDATED="" ;;
    --caskroom) echo "$tmp/caskroom" ;;
  esac
  return 0
}
have() { command -v "$1" >/dev/null 2>&1 || [ "$1" = brew ]; }

classify() { # $1 token, rest: running bids
  local token="$1"; shift
  set_running "$@"
  classify_cask "$token"
}

# ---------------------------------------------------------------------------
# classify_cask: running apps
# ---------------------------------------------------------------------------
assert_eq "document-less menu-bar agent is closed for a restart" "close" "$(classify ut-rect dev.test.rect)"
LSAPPINFO_FORMAT=tahoe
assert_eq "agent is detected from the macOS 26 lsappinfo format" "close" "$(classify ut-rect dev.test.rect)"
LSAPPINFO_FORMAT=classic
assert_eq "not running agent is upgraded in place" "upgrade" "$(classify ut-rect)"
assert_eq "app with a document model stays protected" "protect" "$(classify ut-editor dev.test.editor)"
assert_eq "agent hosting a foreign child process stays protected" "protect" "$(classify ut-agent dev.test.agent)"
assert_eq "agent whose children live in its own bundle is closed" "close" "$(classify ut-helper dev.test.helper)"
assert_eq "risky category stays protected even as an agent" "protect" "$(classify 1password dev.test.vault)"
assert_eq "ordinary windowed app without documents stays protected" "protect" "$(classify ut-chat dev.test.chat)"
assert_eq "menu-bar agent that uses the microphone stays protected" "protect" "$(classify ut-dictate dev.test.dictate)"
assert_eq "menu-bar agent that uses the camera stays protected" "protect" "$(classify ut-cam dev.test.cam)"
UPDATETOOLS_SAFE_RESTART="dev.test.dictate"
assert_eq "explicit user allowlist can opt a microphone agent in" "close" "$(classify ut-dictate dev.test.dictate)"
unset UPDATETOOLS_SAFE_RESTART
assert_eq "allowlisted foreground utility is closed" "close" "$(classify maccy org.p0deje.Maccy)"
UPDATETOOLS_SAFE_RESTART="com.googlecode.iterm2 iterm2"
assert_eq "a terminal is never restarted, even when allowlisted" "protect" "$(classify iterm2 com.googlecode.iterm2)"
unset UPDATETOOLS_SAFE_RESTART
UT_TERM_BID=dev.test.rect
assert_eq "the hosting terminal stays protected" "protect" "$(classify ut-rect dev.test.rect)"
UT_TERM_BID=""
UPDATETOOLS_PROTECT="ut-rect"
assert_eq "UPDATETOOLS_PROTECT beats the safe-restart policy" "protect" "$(classify ut-rect dev.test.rect)"
unset UPDATETOOLS_PROTECT

# ---------------------------------------------------------------------------
# ut_upgrade_casks_smart: quit -> upgrade -> relaunch
# ---------------------------------------------------------------------------
run_casks() { # $1 outdated tokens, rest: running bids
  OUTDATED="$1"; shift
  set_running "$@"
  : > "$calls"
  rm -rf "$UT_REPORT_DIR"; mkdir -p "$UT_REPORT_DIR"
  out="$(ut_upgrade_casks_smart 2>&1)"; rc=$?
  log="$(cat "$calls")"
}

run_casks "ut-rect" dev.test.rect
assert_eq "restarted agent leaves the step done" "0" "$rc"
assert_contains "agent gets a Quit event" "$log" 'application id "dev.test.rect" to quit'
assert_contains "agent is upgraded without --no-quit" "$log" "brew upgrade --cask ut-rect"
assert_not_contains "agent upgrade does not stage" "$log" "--no-quit ut-rect"
assert_contains "agent is relaunched from its bundle path" "$log" "$APPS/UT Rect.app"
assert_contains "agent relaunch stays in the background" "$log" "open -g"
assert_contains "agent relaunch starts hidden" "$log" "-j"
assert_not_contains "agent relaunch does not resolve by bundle id" "$log" "-b dev.test.rect"
assert_true_running() { is_up "$1" && pass "$2" || fail "$2"; }
assert_true_running dev.test.rect "agent is running again after the update"
assert_contains "summary counts the restart" "$out" "1 restarted"
assert_eq "restarted cask is recorded for the report" "ut-rect" "$(cat "$UT_REPORT_DIR/restarted" 2>/dev/null)"
assert_eq "restarted cask is not recorded as staged" "" "$(cat "$UT_REPORT_DIR/staged" 2>/dev/null)"

run_casks "maccy" org.p0deje.Maccy
assert_contains "foreground utility relaunches in the background" "$log" "open -g"
assert_not_contains "foreground utility is not launched hidden" "$log" "-j"
assert_true_running org.p0deje.Maccy "foreground utility is running again"

run_casks "ut-editor" dev.test.editor
assert_eq "protected editor leaves the step staged" "3" "$rc"
assert_not_contains "protected editor gets no Quit event" "$log" "to quit"
assert_contains "protected editor is staged with --no-quit" "$log" "--no-quit ut-editor"
assert_not_contains "protected editor is not relaunched" "$log" "open "

CLOSE_APPS=0
run_casks "ut-rect" dev.test.rect
assert_not_contains "CLOSE_APPS=0 sends no Quit event" "$log" "to quit"
assert_contains "CLOSE_APPS=0 stages the agent" "$log" "--no-quit ut-rect"
assert_eq "CLOSE_APPS=0 leaves the step staged" "3" "$rc"
unset CLOSE_APPS

run_casks "ut-stuck" dev.test.stuck
assert_contains "stuck agent is asked to quit" "$log" 'application id "dev.test.stuck" to quit'
assert_not_contains "stuck agent is never killed" "$log" "kill"
assert_contains "stuck agent is staged instead" "$log" "--no-quit ut-stuck"
assert_not_contains "stuck agent is not relaunched" "$log" "open "
assert_true_running dev.test.stuck "stuck agent is still running, untouched"
assert_eq "stuck agent leaves the step staged" "3" "$rc"

run_casks "ut-gone" dev.test.gone
assert_contains "failed relaunch is reported loudly" "$out" "relaunch failed"
assert_eq "failed relaunch fails the step" "1" "$rc"
assert_not_contains "failed relaunch is not counted as restarted" "$out" "1 restarted"

# ---------------------------------------------------------------------------
# Report: restarted is distinct from staged
# ---------------------------------------------------------------------------
rm -rf "$UT_REPORT_DIR"; mkdir -p "$UT_REPORT_DIR"
UT_WEB_DATA="$tmp/updates.txt"
ut_changelog_lookup() { :; }
ut_icon_homepage() { :; }
ut_icon_site() { :; }
ut_icon_datauri() { :; }
ut_capture_cli_versions() { :; }
OUTDATED=""
printf '%s\n' "ut-rect|1.0|9.9|cask" "ut-editor|1.0|9.9|cask" > "$UT_REPORT_DIR/brew"
printf '%s\n' "ut-rect" > "$UT_REPORT_DIR/restarted"
printf '%s\n' "ut-editor" > "$UT_REPORT_DIR/staged"
ut_generate_report "$tmp/report.html" >/dev/null
json="$(ut_web_updates "$UT_WEB_DATA")"
rect_json="$(printf '%s' "$json" | tr '{' '\n' | grep -i 'rect')"
editor_json="$(printf '%s' "$json" | tr '{' '\n' | grep -i 'editor')"
assert_contains "restarted cask is flagged for the dashboard" "$rect_json" '"st":"restarted"'
assert_contains "staged cask keeps its own flag" "$editor_json" '"st":"staged"'
html="$(cat "$tmp/report.html" 2>/dev/null)"
assert_contains "HTML report marks the restarted cask" "$html" 'class="restarted-note"'

ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const a = html.indexOf('function stagedNote('), b = html.indexOf('function versionMarkup(', a);
if (a < 0 || b < 0) { console.log('not ok - stagedNote helper not found'); process.exit(1); }
eval(html.slice(a, b));
const c = html.indexOf('function escapeHtml('), d = html.indexOf('\n  }\n', c);
eval(html.slice(c, d) + '\n  }');
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
const r = stagedNote({ n: 'Rectangle', st: 'restarted' });
ok('restarted entry gets its own mark', /class="restarted-note"/.test(r));
ok('restarted mark says it is already running the new version', /restarted/i.test(r) && !/next launch/i.test(r));
ok('staged entry still mentions the next launch', /next launch/i.test(stagedNote({ n: 'X', st: 'staged' })));
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "dashboard ledger distinguishes restarted from staged" || fail "dashboard ledger distinguishes restarted from staged"

# ---------------------------------------------------------------------------
# DMG / manual apps: a safe running app is restarted onto the verified bundle
# ---------------------------------------------------------------------------
UPDATETOOLS_DEFER_SPAWN=0
export UPDATETOOLS_DEFER_SPAWN
mkdir -p "$tmp/stage-rect.app/Contents"
cp "$APPS/UT Rect.app/Contents/Info.plist" "$tmp/stage-rect.app/Contents/"
printf new > "$tmp/stage-rect.app/marker"
mv "$tmp/stage-rect.app" "$APPS/.stage-rect.app"
set_running dev.test.rect; : > "$calls"
ut_install_or_defer "$APPS/UT Rect.app" "$APPS/.stage-rect.app" dev.test.rect >/dev/null 2>&1; rc=$?
log="$(cat "$calls")"
assert_eq "safe running DMG app reports a restart" "4" "$rc"
assert_eq "safe running DMG app gets the new bundle" "new" "$(cat "$APPS/UT Rect.app/marker" 2>/dev/null)"
assert_contains "safe running DMG app is asked to quit" "$log" 'application id "dev.test.rect" to quit'
assert_contains "safe running DMG app is relaunched" "$log" "open -g"
assert_true_running dev.test.rect "safe running DMG app is running again"

mkdir -p "$APPS/.stage-editor.app/Contents"
cp "$APPS/UT Editor.app/Contents/Info.plist" "$APPS/.stage-editor.app/Contents/"
printf new > "$APPS/.stage-editor.app/marker"
set_running dev.test.editor; : > "$calls"
ut_install_or_defer "$APPS/UT Editor.app" "$APPS/.stage-editor.app" dev.test.editor >/dev/null 2>&1; rc=$?
log="$(cat "$calls")"
assert_eq "unsafe running DMG app is deferred" "3" "$rc"
assert_eq "unsafe running DMG app is untouched" "" "$(cat "$APPS/UT Editor.app/marker" 2>/dev/null)"
assert_not_contains "unsafe running DMG app gets no Quit event" "$log" "to quit"

# ---------------------------------------------------------------------------
# App Store (mas): a safe running app is restarted, others are left for later
# ---------------------------------------------------------------------------
mas_log="$tmp/mas.log"; : > "$mas_log"
mas() {
  case "$1" in
    outdated) printf '%s' "$MAS_OUTDATED" ;;
    update|upgrade) printf '%s\n' "$*" >> "$mas_log"; return 0 ;;
  esac
  return 0
}
mdfind() {
  case "$*" in
    *"== 701"*) echo "$APPS/UT Rect.app" ;;
    *"== 702"*) echo "$APPS/UT Editor.app" ;;
  esac
}
MAS_OUTDATED='701  UT Rect    (1.0 -> 1.1)
702  UT Editor  (1.0 -> 1.1)
'
set_running dev.test.rect dev.test.editor; : > "$calls"
out="$(ut_update_appstore 2>&1)"; rc=$?
log="$(cat "$calls")"
assert_contains "safe running App Store app is updated" "$(cat "$mas_log")" "701"
assert_not_contains "unsafe running App Store app is not updated" "$(cat "$mas_log")" "702"
assert_contains "safe running App Store app is quit first" "$log" 'application id "dev.test.rect" to quit'
assert_not_contains "unsafe running App Store app gets no Quit event" "$log" 'dev.test.editor" to quit'
assert_contains "safe running App Store app is relaunched" "$log" "$APPS/UT Rect.app"
assert_true_running dev.test.rect "safe running App Store app is running again"
assert_eq "an unsafe open App Store app still leaves the step staged" "3" "$rc"

if [ "$failures" -eq 0 ]; then
  echo "all safe restart tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
