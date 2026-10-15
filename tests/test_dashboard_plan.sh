#!/usr/bin/env bash
# The dashboard's pre-run plan and run plumbing:
#   * ut_cask_plan names what will happen to each outdated cask (restart,
#     check, wait, install, manual) without asking any app anything;
#   * ut_plan_homebrew / ut_plan_json turn brew's outdated list into the plan;
#   * ut_web_state marks missing tools, carries time estimates, the plan, and
#     the live output of running steps;
#   * step durations are remembered between runs;
#   * ut_web_retry re-runs only the failed steps and keeps every other result;
#   * --yes sets AUTO_START;
#   * page helpers hide the report step and missing tools, and read errors.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-plan.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools" --yes
trap 'rm -rf "$tmp"' EXIT

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

assert_eq "--yes starts without the chooser" "1" "$AUTO_START"

export HOME="$tmp/home"
APPS="$HOME/Applications"
mkdir -p "$APPS"
UT_TERM_BID="com.apple.Terminal"
unset UPDATETOOLS_CLOSE UPDATETOOLS_PROTECT UPDATETOOLS_SAFE_RESTART
CLOSE_APPS=1
BREW_CASK_SKIP="stats"

make_app() { # <bundle name> <bundle id> <version>
  local p="$APPS/$1/Contents"
  mkdir -p "$p"
  /usr/bin/plutil -create xml1 "$p/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$2" "$p/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "${3:-1.0}" "$p/Info.plist"
}
make_app "Rect.app" dev.test.rect
make_app "Chat.app" dev.test.chat
make_app "Chrome.app" com.google.Chrome
make_app "Term.app" com.apple.Terminal
make_app "Idle.app" dev.test.idle
make_app "Self.app" dev.test.self 2.0

running="dev.test.rect dev.test.chat com.google.Chrome com.apple.Terminal"
is_running() { in_list "$1" "$running"; }
# The policy itself is covered by test_safe_restart; here only its verdict.
ut_restart_safe() { [ "$1" = dev.test.rect ]; }
# The plan must never ask an app anything (no Automation prompt before Start).
osascript() { echo "osascript $*" >> "$tmp/osa"; return 1; }
has_unsaved() { echo "has_unsaved $*" >> "$tmp/osa"; return 1; }

assert_eq "not running installs" "update|" "$(ut_cask_plan idle Idle.app)"
assert_eq "no app bundle installs" "update|" "$(ut_cask_plan some-font '')"
assert_eq "safe running app restarts" "restart" "$(ut_cask_plan rect Rect.app | cut -d'|' -f1)"
assert_eq "other running app is checked first" "check" "$(ut_cask_plan chat Chat.app | cut -d'|' -f1)"
assert_eq "running browser waits for quit" "wait|Browser: open tabs and forms" "$(ut_cask_plan google-chrome Chrome.app)"
assert_eq "hosting terminal waits" "wait|This terminal is running the update" "$(ut_cask_plan terminal Term.app)"
assert_eq "interactive-sudo cask is manual" "manual" "$(ut_cask_plan stats Rect.app | cut -d'|' -f1)"
assert_eq "UPDATETOOLS_CLOSE restarts" "restart|Listed in UPDATETOOLS_CLOSE" "$(UPDATETOOLS_CLOSE=chat ut_cask_plan chat Chat.app)"
assert_eq "UPDATETOOLS_PROTECT waits" "wait|Listed in UPDATETOOLS_PROTECT" "$(UPDATETOOLS_PROTECT=rect ut_cask_plan rect Rect.app)"
assert_eq "--no-close waits" "wait|Closing apps is turned off (--no-close)" "$(CLOSE_APPS=0 ut_cask_plan rect Rect.app)"
[ -s "$tmp/osa" ] && fail "plan asked an app over AppleScript" || pass "plan never uses AppleScript"

# brew stub: outdated casks/formulae and the catalogue read
brew() {
  case "$*" in
    "outdated --cask --greedy --verbose") printf '%s\n' "rect (1.0) != 1.1" "chrome-x (140.0) != 141.0" "self-upd (1.0) != 2.0" ;;
    "outdated --formula --verbose") printf '%s\n' "node (24.9.0) < 24.10.0" "herdr (0.9.3) < 0.9.5" "llvm@21 (21.1.8) < 21.1.8_1" ;;
    "info --formula --json=v2 node herdr llvm@21")
      cat <<'JSON'
{"formulae":[
 {"name":"node","homepage":"https://nodejs.org/"},
 {"name":"herdr","homepage":"https://herdr.example/"},
 {"name":"llvm@21","homepage":"https://llvm.example/"}
]}
JSON
      ;;
    "info --cask --json=v2 rect chrome-x self-upd")
      cat <<'JSON'
{"casks":[
 {"token":"rect","name":["Rectangle"],"version":"1.1","artifacts":[{"app":["Rect.app"]}]},
 {"token":"chrome-x","name":["Idle Thing"],"version":"141.0","artifacts":[{"app":["Idle.app"]}]},
 {"token":"self-upd","name":["Self Updater"],"version":"2.0,abc","artifacts":[{"app":["Self.app"]}]}
]}
JSON
      ;;
    *) return 1 ;;
  esac
}
have() { [ "$1" = brew ] || [ "$1" = jq ]; }
GREEDY=1
# Each planned program shows its own logo: an app's icon from its bundle, a
# formula's Simple Icons mark or its site's icon, else nothing (the page draws
# a monogram). Here the network is down: only the cached site icon is found.
mkdir -p "$APPS/Rect.app/Contents/Resources"
cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns "$APPS/Rect.app/Contents/Resources/RectIcon.icns"
/usr/bin/plutil -insert CFBundleIconFile -string RectIcon "$APPS/Rect.app/Contents/Info.plist"
export XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$XDG_CACHE_HOME/updatetools/icons"
sips -s format png -Z 32 "$APPS/Rect.app/Contents/Resources/RectIcon.icns" --out "$XDG_CACHE_HOME/updatetools/icons/herdr.example" >/dev/null 2>&1
curl() { echo "curl $*" >> "$tmp/curl"; return 1; }
mkdir -p "$tmp/plan"
ut_plan_homebrew "$tmp/plan"
plan="$(cat "$tmp/plan/homebrew.plan")"
assert_contains "cask uses its display name and restarts" "$plan" "Rectangle|1.0|1.1|restart|"
assert_contains "idle cask installs" "$plan" "Idle Thing|140.0|141.0|update|"
assert_contains "self-updated cask only syncs the record" "$plan" "Self Updater|1.0|2.0|sync|Already updated itself"
assert_contains "formulae are planned too" "$plan" "node|24.9.0|24.10.0|update|"
json="$(ut_plan_json "$tmp/plan")"
assert_contains "plan json is not done before the marker" "$json" '"homebrew":{"done":false'
: > "$tmp/plan/homebrew.done"
json="$(ut_plan_json "$tmp/plan")"
assert_contains "plan json done after the marker" "$json" '"homebrew":{"done":true'
assert_contains "plan json item" "$json" '{"n":"Rectangle","o":"1.0","w":"1.1","act":"restart"'
assert_contains "a cask's plan line keeps its token and app" "$plan" "|rect|$APPS/Rect.app"
[ "$(head -c 4 "$tmp/plan/icons/rect.png" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 89504e47 ] \
  && pass "an app's icon is written as a PNG" || fail "an app's icon is written as a PNG"
[ "$(sips -g pixelWidth "$tmp/plan/icons/rect.png" 2>/dev/null | awk '/pixelWidth/ { print $2 }')" -le 64 ] 2>/dev/null \
  && pass "an app's icon is small" || fail "an app's icon is small"
python3 - "{\"plan\":$json}" <<'PY' && pass "plan items carry their key and logo" || fail "plan items carry their key and logo"
import json, sys
items = {it.get('k'): it for it in json.loads(sys.argv[1])['plan']['homebrew']['items']}
checks = [
    ('rect', 'img', 'plan/icons/rect.png'), ('rect', 'app', True),
    ('chrome-x', 'img', None),
    ('node', 'slug', 'nodedotjs'),
    ('herdr', 'img', 'plan/icons/herdr.png'), ('herdr', 'app', None),
    ('llvm@21', 'img', None), ('llvm@21', 'slug', None),
]
bad = [f'{k}.{f}={items.get(k, {}).get(f)!r}, want {v!r}' for k, f, v in checks if items.get(k, {}).get(f) != v]
print('\n'.join('not ok - ' + b for b in bad))
sys.exit(1 if bad else 0)
PY
[ -s "$tmp/plan/icons/herdr.png" ] && pass "a cached site icon is copied for the page" || fail "a cached site icon is copied for the page"
UT_PLAN_DIR="$tmp/plan"
printf '%s\n' "rect|Rectangle|1.0|1.1||restarted" > "$tmp/updates.txt"
assert_contains "the record shows the app's own icon" "$(ut_web_updates "$tmp/updates.txt")" '"img":"plan/icons/rect.png","app":true'
python3 -c 'import json,sys; json.loads(sys.argv[1])' "{\"plan\":$json}" && pass "plan json parses" || fail "plan json parses"

# ---------------------------------------------------------------------------
# state.json: missing tools, estimates, plan, live output of running steps
# ---------------------------------------------------------------------------
UPDATETOOLS_DURATIONS_FILE="$tmp/durations"
WEB_DIR="$tmp/web"; mkdir -p "$WEB_DIR"
LOG="$tmp/run.log"; printf '\n######## Homebrew · update everything ########\nold output\n' > "$LOG"
T0=$SECONDS
STATUS=(); STEP_SEC=(); STEP_T0=(); STEP_WHY=(); STEP_AVAIL=(); STEP_EST=(); STEP_SLUG=(); STEP_IMG=()
for ((i=0;i<TOTAL;i++)); do STATUS[i]=pending; STEP_AVAIL[i]=1; STEP_ON[i]=1; done
npm_i=-1; for ((i=0;i<TOTAL;i++)); do [ "${STEP_KEY[i]}" = npm ] && npm_i=$i; done
STEP_AVAIL[1]=0
STEP_EST[0]=42
STATUS[npm_i]=run; STEP_T0[npm_i]=$SECONDS
UT_STEP_LOG_DIR="$tmp/steps"; mkdir -p "$UT_STEP_LOG_DIR"
printf '\n######## npm · global packages ########\nupgrading typescript\n' > "$UT_STEP_LOG_DIR/$npm_i.log"
UT_PLAN_DIR="$tmp/plan"; UT_PLAN_PID=""; UT_PLAN_FINAL=""; UT_PLAN_SIG=""
ut_web_state run
state="$(cat "$WEB_DIR/state.json")"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WEB_DIR/state.json" && pass "state.json parses" || fail "state.json parses"
assert_contains "missing tool is marked" "$state" '"av":false'
assert_contains "estimate from the last run" "$state" '"est":42'
assert_contains "plan travels with the state" "$state" '"plan":{"homebrew"'
assert_contains "running step has its own tail" "$state" '"tail":"upgrading typescript"'
assert_contains "running step output is served live" "$(cat "$WEB_DIR/log.txt")" "upgrading typescript"
assert_contains "finished output is still served" "$(cat "$WEB_DIR/log.txt")" "old output"
assert_contains "--yes is visible to the page" "$state" '"auto":true'

# durations: remembered per key, newest wins, other keys kept
printf 'cargo 9\nhomebrew 100\n' > "$UPDATETOOLS_DURATIONS_FILE"
for ((i=0;i<TOTAL;i++)); do STATUS[i]=skip; STEP_SEC[i]=""; done
STATUS[0]=done; STEP_SEC[0]=61; STATUS[npm_i]=fail; STEP_SEC[npm_i]=7
ut_save_durations
assert_eq "homebrew duration updated" "61" "$(ut_duration_of homebrew)"
assert_eq "failed step duration kept" "7" "$(ut_duration_of npm)"
assert_eq "other keys survive" "9" "$(ut_duration_of cargo)"
ut_duration_of nothing-here >/dev/null && fail "unknown key has no duration" || pass "unknown key has no duration"

# ---------------------------------------------------------------------------
# retry: only the failed steps run again; every other result stays
# ---------------------------------------------------------------------------
for ((i=0;i<TOTAL;i++)); do STATUS[i]=done; STEP_SEC[i]=3; STEP_ON[i]=1; STEP_WHY[i]=""; done
STATUS[npm_i]=fail
UT_WEB_UPDATES='{"n":"Rectangle","o":"1","w":"2","slug":""}'
UT_WEB_DATA="$tmp/updates.txt"
ut_needs_sudo() { return 1; }
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_generate_report() { printf 'typescript|TypeScript|5.0|5.1||\n' > "$UT_WEB_DATA"; }
ut_web_summary_line() { :; }
ran=""
ut_run_steps() {
  local i
  for ((i=0;i<TOTAL;i++)); do
    if [ "${STEP_ON[i]}" = "1" ]; then ran="$ran ${STEP_KEY[i]}"; STATUS[i]=done; STEP_SEC[i]=5
    else STATUS[i]=skip; STEP_WHY[i]=off; fi
  done
}
ut_web_retry "npm"
assert_eq "only the failed step ran again" " npm" "$ran"
assert_eq "retried step now done" "done" "${STATUS[npm_i]}"
assert_eq "other step keeps its result" "done" "${STATUS[0]}"
assert_eq "other step keeps its time" "3" "${STEP_SEC[0]}"
assert_eq "other step stays selected" "1" "${STEP_ON[0]}"
assert_contains "earlier updates are kept" "$UT_WEB_UPDATES" '"n":"Rectangle"'
assert_contains "retry updates are added" "$UT_WEB_UPDATES" '"n":"TypeScript"'
assert_contains "state says done again" "$(cat "$WEB_DIR/state.json")" '"phase":"done"'
assert_contains "state carries the round" "$(cat "$WEB_DIR/state.json")" '"round":2'


# ---------------------------------------------------------------------------
# the read-only preflight never overlaps the steps: it is waited for (bounded)
# and stopped before any step starts
# ---------------------------------------------------------------------------
UT_PLAN_DIR="$tmp/plan2"; mkdir -p "$UT_PLAN_DIR"; UT_PLAN_FINAL=""; UT_PLAN_SIG=""
( sleep 0.3; : > "$UT_PLAN_DIR/homebrew.done" ) &
UT_PLAN_PID=$!
UPDATETOOLS_PREFLIGHT_WAIT=10 ut_preflight_settle
assert_eq "a quick preflight is waited for" "1" "$([ -f "$UT_PLAN_DIR/homebrew.done" ] && echo 1)"
assert_eq "settled preflight leaves no pid behind" "" "$UT_PLAN_PID"
assert_eq "settled plan is frozen" "1" "$UT_PLAN_FINAL"
UT_PLAN_FINAL=""
( exec sleep 30 ) &
slow=$!
UT_PLAN_PID=$slow
t_start=$SECONDS
UPDATETOOLS_PREFLIGHT_WAIT=1 ut_preflight_settle
sleep 0.2
if kill -0 "$slow" 2>/dev/null; then fail "a slow preflight is stopped before the steps"; kill "$slow"; else pass "a slow preflight is stopped before the steps"; fi
[ $((SECONDS - t_start)) -le 3 ] && pass "the wait for a slow preflight is bounded" || fail "the wait for a slow preflight is bounded"
body="$(declare -f run_web)"
before="${body%%ut_run_steps*}"
assert_contains "run_web settles the preflight before the steps" "$before" "ut_preflight_settle"
body="$(declare -f ut_web_retry)"
before="${body%%ut_run_steps*}"
assert_contains "a retry also settles the preflight before the steps" "$before" "ut_preflight_settle"
# ---------------------------------------------------------------------------
# a rejected password is not a dead end: the page can ask again, and a retry
# whose password is rejected says so instead of repeating the old screen
# ---------------------------------------------------------------------------
( exec sleep 30 ) &
WEB_PID=$!
sudo_tries=0
ut_require_sudo() { sudo_tries=$((sudo_tries+1)); [ "$sudo_tries" -ge 2 ]; }
( sleep 0.5; printf 'homebrew\n' > "$WEB_DIR/retry" ) &
ut_web_sudo_gate; gate_rc=$?
assert_eq "the password is asked again after Try again" "0" "$gate_rc"
assert_eq "the second attempt is the one that passed" "2" "$sudo_tries"
assert_eq "the retry request is consumed" "" "$(ls "$WEB_DIR/retry" 2>/dev/null)"
sudo_tries=-10
( sleep 0.3; kill "$WEB_PID" ) &
ut_web_sudo_gate; gate_rc=$?
assert_eq "closing the tab ends the wait for a retry" "1" "$gate_rc"
assert_contains "the rejection is published as an error" "$(cat "$WEB_DIR/state.json")" '"phase":"error"'
wait 2>/dev/null

ut_needs_sudo() { return 0; }
ut_require_sudo() { return 1; }
for ((i=0;i<TOTAL;i++)); do STATUS[i]=done; STEP_SEC[i]=3; STEP_ON[i]=1; STEP_WHY[i]=""; done
STATUS[npm_i]=fail
ran=""
ut_web_retry "npm"
assert_eq "nothing runs when the retry password is rejected" "" "$ran"
assert_contains "a rejected retry password is reported on the page" "$(cat "$WEB_DIR/state.json")" '"notice":"'
ut_needs_sudo() { return 1; }
ut_web_retry "npm"
assert_not_contains "the notice is gone once a retry runs" "$(cat "$WEB_DIR/state.json")" '"notice"'

# ---------------------------------------------------------------------------
# page helpers
# ---------------------------------------------------------------------------
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const pick = (from, to) => {
  const a = html.indexOf(from), b = html.indexOf(to, a + 1);
  if (a < 0 || b < 0) { console.log('not ok - helper ' + from + ' not found'); process.exit(1); }
  return html.slice(a, b);
};
let chooseLocal = null;
eval(pick('function stepSelected(', 'function paintRibbon('));
eval(pick('function sourceRows(', '/* ── the plan'));
eval(pick('function errorFrom(', 'async function loadFailReasons('));
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
const steps = [
  { n: 'Homebrew', key: 'homebrew', s: 'done', on: true },
  { n: 'App Store', key: 'appstore', s: 'skip', why: 'guard', on: true, av: false },
  { n: 'npm', key: 'npm', s: 'fail', on: true },
  { n: 'gh', key: 'github', s: 'skip', why: 'off', on: false },
  { n: 'Report', key: 'report', slug: 'report', s: 'done', on: true },
];
const keys = (st) => sourceRows(st).map(([s]) => s.key).join(',');
ok('choose lists installed tools, not the report', keys({ phase: 'choose', steps }) === 'homebrew,npm,github');
ok('run lists selected tools only', keys({ phase: 'run', steps }) === 'homebrew,npm');
ok('npm error line is found', errorFrom('npm ERR! code EACCES\nnpm ERR! syscall rename') === 'npm ERR! syscall rename');
ok('a !! line from the script is a reason', errorFrom('>> rect: running\n!! rect: upgraded, but relaunch failed') === 'rect: upgraded, but relaunch failed');
ok('a stall banner is a reason', /stalled 600s/.test(errorFrom('working\n######## stalled 600s with no output — killed ########')));
ok('no error line, no invented reason', errorFrom('all fine\ndone') === '');
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "page helpers" || fail "page helpers"

# ---------------------------------------------------------------------------
# page layout and states (rendered behaviour checked through the page's code)
# ---------------------------------------------------------------------------
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
const pick = (from, to) => {
  const a = html.indexOf(from), b = html.indexOf(to, a + 1);
  if (a < 0 || b < 0) { console.log('not ok - helper ' + from + ' not found'); process.exit(1); }
  return html.slice(a, b);
};
// CSS: the last declaration of a property inside a rule wins.
const rule = (sel) => {
  const re = new RegExp('(^|[}\\s])' + sel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*\\{([^}]*)\\}', 'm');
  const m = html.match(re);
  return m ? m[2] : '';
};
const prop = (body, name) => {
  const all = [...body.matchAll(new RegExp('(?:^|[;\\s{])' + name + '\\s*:\\s*([^;]+)', 'g'))];
  return all.length ? all[all.length - 1][1].trim() : '';
};
const logRule = rule('.log');
ok('the live output box has a bounded height, so it can follow new lines',
  prop(logRule, 'max-height') !== '' && prop(logRule, 'max-height') !== 'none');
ok('the live output box scrolls', /auto|scroll/.test(prop(logRule, 'overflow')));
ok('a failure card heading row wraps', prop(rule('.fail-card .who'), 'flex-wrap') === 'wrap');
ok('a failure card button row wraps', prop(rule('.fail-card .tools'), 'flex-wrap') === 'wrap');
// A see-through sheet still takes Tab and Enter: its Continue would post an
// empty password with no prompt pending. Closed, it must be out of reach.
const scrimRule = rule('.scrim');
ok('the closed password sheet is out of the tab order',
  prop(scrimRule, 'visibility') === 'hidden' || prop(scrimRule, 'display') === 'none');

// the forecast under the output: only the viewed step's, and only before it ran
let planFor = (st, key) => (st.plan || {})[key];
let planBlock = (st, s) => `[plan ${s.key}]`;
eval(pick('function livePlan(', '\n  }\n') + '\n  }');
const plan = { homebrew: { done: true, items: [{ n: 'x' }] }, appstore: { done: true, items: [] } };
ok('a running step shows its own forecast', livePlan({ phase: 'run', plan }, { key: 'homebrew', s: 'run' }) === '[plan homebrew]');
ok('a waiting step shows its own forecast', livePlan({ phase: 'run', plan }, { key: 'homebrew', s: 'pending' }) === '[plan homebrew]');
ok('a finished step shows no stale forecast', livePlan({ phase: 'run', plan }, { key: 'homebrew', s: 'done' }) === '');
ok('another step never shows a foreign forecast', livePlan({ phase: 'run', plan }, { key: 'macos', s: 'run' }) === '');
ok('no forecast after the run', livePlan({ phase: 'done', plan }, { key: 'homebrew', s: 'pending' }) === '');

// the header action: retry after failures, try again after a rejected password
eval(pick('function retryAction(', '\n  }\n') + '\n  }');
ok('failed sources offer a retry', retryAction({ phase: 'done' }, { fail: 2 }) === 'Retry failed');
ok('a clean run offers no retry', retryAction({ phase: 'done' }, { fail: 0 }) === '');
ok('a rejected password offers to try again', retryAction({ phase: 'error' }, { fail: 0 }) === 'Try again');
ok('a running update offers no retry', retryAction({ phase: 'run' }, { fail: 1 }) === '');

// source list after a rejected password: no time estimates for steps that will not run
const fmt = (s) => `${s}`, dur = (s) => `${s}s`;
eval(pick('function sideNote(', 'const glyphFor'));
ok('pending steps carry no estimate on the error screen', sideNote({ s: 'pending', est: 80 }, { phase: 'error', elapsed: 0 }) === '');
ok('pending steps still carry an estimate during a run', sideNote({ s: 'pending', est: 80 }, { phase: 'run', elapsed: 0 }) === '~80s');

// header copy: the error screen points at the button, a rejected retry is said
const els = {};
const el = () => ({ textContent: '', innerHTML: '', disabled: false, classList: { _s: new Set(), add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, contains(c) { return this._s.has(c); } } });
const $ = (id) => (els[id] = els[id] || el());
const document = { title: '' };
const plural = (n, a, b) => `${n} ${n === 1 ? a : b}`;
eval(pick('function escapeHtml(', '\n  }\n') + '\n  }');
eval(pick('function paintHeader(', '/* ── the source list'));
paintHeader({ phase: 'error', message: 'x' }, { fail: 0, done: 0, staged: 0, skip: 0, total: 3 });
ok('the error screen does not send the user back to the terminal', !/Run updatetools again/.test($('phase').innerHTML));
ok('the error screen names the way forward', /Try again/.test($('phase').innerHTML));
paintHeader({ phase: 'done', elapsed: 5, updates: [], notice: 'The password was not accepted, so nothing ran again.' }, { fail: 1, done: 2, staged: 0, skip: 0, total: 3 });
ok('a rejected retry is said in the header', /nothing ran again/.test($('phase').innerHTML));
ok('a rejected retry is marked as a problem', $('phase').classList.contains('lost'));
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "page layout and states" || fail "page layout and states"

# ---------------------------------------------------------------------------
# the plan during the run: each program's own logo and where it is right now
# ---------------------------------------------------------------------------
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
const pick = (from, to) => {
  const a = html.indexOf(from), b = html.indexOf(to, a + 1);
  if (a < 0 || b < 0) { console.log('not ok - helper ' + from + ' not found'); process.exit(1); }
  return html.slice(a, b);
};
// Homebrew's own markers (formulae, then the casks loop's per-app lines).
const section = [
  '==> Fetching downloads for: node, herdr, llvm@21',
  '✔︎ Bottle node (24.10.0)',
  '✔︎ Bottle llvm@21 (21.1.8_1)',
  '==> Upgrading node',
  '  24.9.0 -> 24.10.0',
  '==> Pouring node--24.10.0.arm64_tahoe.bottle.tar.gz',
  '🍺  /opt/homebrew/Cellar/node/24.10.0: 2,000 files, 70MB',
  '==> Upgrading k1low/tap/tbls',
  '🍺  /opt/homebrew/Cellar/tbls/1.74.2: 9 files, 30MB',
  '>> rect: running & safe to restart — quitting, upgrading, relaunching',
  '==> Upgrading rect',
  '🍺  rect was successfully upgraded!',
  '   restarted on the new version',
  '>> idle: running & protected — staging (new version applies on next launch)',
  '🍺  idle was successfully upgraded!',
  '>> broken: not running — upgrading in place',
  'Error: broken: Download failed',
  '>> chatgpt: not running — upgrading in place',
  '==> Downloading https://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg',
].join('\n');
const items = ['node', 'llvm@21', 'k1low/tap/tbls', 'rect', 'idle', 'broken', 'chatgpt', 'herdr'].map((k) => ({ k, n: k }));
eval(pick('function planProgress(', '\n  }\n') + '\n  }');
const live = planProgress(section, items);
ok('a poured formula is updated', live.node === 'done');
ok('a downloaded bottle is not yet installed', live['llvm@21'] === 'got');
ok('a tap formula matches its Cellar name', live['k1low/tap/tbls'] === 'done');
ok('a restarted app says so', live.rect === 'restarted');
ok('a staged app waits for the next launch', live.idle === 'staged');
ok('an error while a cask is in hand fails it', live.broken === 'fail');
ok('the cask in hand is installing', live.chatgpt === 'run');
ok('a package not reached yet has no state', live.herdr === undefined);

// the row: the program's logo, and the live state in place of the plan chip
const document = { getElementById: () => ({}) };
const window = {};
eval(pick('const ICON = {', '\n  };\n') + '\n  };');
eval(pick('function escapeHtml(', '\n  }\n') + '\n  }');
eval(pick('function versionMarkup(', 'function escapeHtml('));
eval(pick('function logo(', 'function prettyTail('));
const plural = (n, a, b) => `${n} ${n === 1 ? a : b}`;
eval(pick('const ACT = {', 'function planFor('));
eval(pick('function planRows(', 'function planBlock('));
const rows = planRows([
  { k: 'rect', n: 'Rectangle', o: '1.0', w: '1.1', act: 'restart', img: 'plan/icons/rect.png', app: true },
  { k: 'node', n: 'node', o: '24.9.0', w: '24.10.0', act: 'update', slug: 'nodedotjs' },
  { k: 'chatgpt', n: 'ChatGPT', o: '1', w: '2', act: 'update' },
  { k: 'herdr', n: 'herdr', o: '0.9.3', w: '0.9.5', act: 'update' },
], { rect: 'restarted', node: 'done', chatgpt: 'run' });
const row = (k) => (rows.match(new RegExp(`<div class="row[^"]*" data-k="${k}"[\\s\\S]*?(?=<div class="row|$)`)) || [''])[0];
ok('an app shows its own icon', /class="logo app-logo"><img src="plan\/icons\/rect.png"/.test(row('rect')));
ok('a formula shows its mark', /<use href="#i-nodedotjs"\/>/.test(row('node')));
ok('a program with no logo gets a monogram', /class="logo mono">C</.test(row('chatgpt')));
ok('the package in hand is marked as installing', /class="row run"/.test(row('chatgpt')) && />Installing</.test(row('chatgpt')));
ok('an updated package says so', />Updated</.test(row('node')) && !/>Installs</.test(row('node')));
ok('a restarted app says so', />Restarted</.test(row('rect')));
ok('a package not reached yet keeps its plan', />Installs</.test(row('herdr')));
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "plan rows show logos and live progress" || fail "plan rows show logos and live progress"

if [ "$failures" -eq 0 ]; then
  echo "all dashboard plan tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
