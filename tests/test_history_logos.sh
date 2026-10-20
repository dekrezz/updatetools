#!/usr/bin/env bash
# A past run's record shows each update with the logo the dashboard has for it,
# as this run's record does:
#   * the app's own icon, when the run's plan showed one: it is kept when the
#     run is recorded, and wins over a Simple Icons mark, as on the live record;
#   * else, for an update with no Simple Icons mark, the project's site icon
#     already in the icon cache (its homepage from Homebrew's cached metadata:
#     a GitHub org's avatar or the site's favicon);
#   * else a Simple Icons mark (slug) or a monogram.
# history.json points at icon files the dashboard serves; the history file
# itself holds no icons, and serving the history fetches nothing and asks
# Homebrew nothing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(command -v python3)" || { echo "not ok - python3 is required to run this test"; exit 1; }
NODE="$(command -v node)" || { echo "not ok - node is required to run this test"; exit 1; }
tmp="$(mktemp -d /tmp/updatetools-histlogo.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$TMPDIR" "$tmp/bin"
unset UPDATETOOLS_HISTORY_FILE HISTORY_KEEP

# No Homebrew and no network: anything that reaches them is written down.
for b in curl brew; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$0 $*" >> "%s/reached"\nexit 7\n' "$tmp" > "$tmp/bin/$b"
  chmod +x "$tmp/bin/$b"
done
ln -s "$PY" "$tmp/bin/python3"
ln -s "$NODE" "$tmp/bin/node"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing puts Homebrew's bin dir first (brew shellenv); take it away again.
export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
trap 'cleanup; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

png() { printf '\211PNG\r\n\032\n%s' "$2" > "$1"; }
ico() { printf '\000\000\001\000%s' "$2" > "$1"; }
C="$XDG_CACHE_HOME/updatetools/icons"
mkdir -p "$C"
# What Homebrew's metadata and the site icons left in the cache on earlier runs.
meta() { printf '%s' "$1" > "$C/$1.name"; printf '%s' "$2" > "$C/$1.url"; : > "$C/$1.meta"; }
meta fastfetch https://github.com/fastfetch-cli/fastfetch
png "$C/gh-fastfetch-cli" fastfetch-avatar
meta c-ares https://c-ares.org/
ico "$C/c-ares.org" c-ares-favicon
meta herdr https://herdr.dev
meta node https://nodejs.org/
png "$C/nodejs.org" node-favicon
meta google-chrome https://www.google.com/chrome/
meta mystery ""

export UPDATETOOLS_HISTORY_FILE="$tmp/history"
cat > "$UPDATETOOLS_HISTORY_FILE" <<'EOF'
{"v":1,"id":"100-1","at":100,"sec":60,"mode":"dashboard","out":"ok","steps":[{"k":"homebrew","n":"Homebrew","s":"done","t":50,"slug":"homebrew"}],"up":[{"k":"fastfetch","n":"fastfetch","o":"2.69.0","w":"2.70.0"},{"k":"c-ares","n":"c-ares","o":"1.34.8","w":"1.34.9"},{"k":"herdr","n":"herdr","o":"0.9.3","w":"0.9.5"},{"k":"node","n":"Node.js","o":"24.21.0","w":"24.22.0","slug":"nodedotjs"},{"k":"mystery","n":"mystery","o":"1","w":"2"}]}
EOF
cp "$UPDATETOOLS_HISTORY_FILE" "$tmp/history.before"

# This run: the plan showed Chrome's own icon; it is recorded with the run.
T0=$SECONDS; UT_T_END=$SECONDS; UT_RUN_AT=200; UT_RUN_MODE=dashboard; UT_HIST_SEC0=0; UT_HIST_REV=0; UT_HALT=""
STEPS=("Homebrew · update everything¦true¦true" "Report¦true¦:")
STEP_KEY=(homebrew report); STEP_ON=(1 1); STATUS=(done done); STEP_WHY=("" ""); STEP_SEC=(9 1); STEP_SLUG=(homebrew ""); TOTAL=2
UT_PLAN_DIR="$tmp/web1/plan"; mkdir -p "$UT_PLAN_DIR/icons"
png "$UT_PLAN_DIR/icons/google-chrome.png" chrome-app-icon
: > "$UT_PLAN_DIR/icons/google-chrome.app"
UT_WEB_DATA="$tmp/updates"
printf '%s\n' 'google-chrome|Google Chrome|155.0.8059.40|155.0.8059.85||' > "$UT_WEB_DATA"
WEB_DIR="$tmp/web1"
ut_history_record 2> "$tmp/record.err" || fail "the run is recorded ($(cat "$tmp/record.err"))"

# A later dashboard: its own served dir; this run's plan dir is gone.
rm -rf "$tmp/web1"
UT_PLAN_DIR=""
WEB_DIR="$tmp/web2"; mkdir -p "$WEB_DIR"
: > "$tmp/reached"
ut_history_serve 2> "$tmp/serve.err"

"$PY" -I - "$WEB_DIR" "$C" "$UPDATETOOLS_HISTORY_FILE" "$tmp/history.before" <<'PY' || failures=$((failures + 1))
import json, os, sys
web, cache, hist, before = sys.argv[1:]
fails = 0
def ok(name, cond, why=''):
    global fails
    print(('ok - ' if cond else 'not ok - ') + name + ('' if cond else ' (%s)' % (why,)))
    if not cond: fails += 1
try:
    runs = json.load(open(os.path.join(web, 'history.json')))['runs']
except Exception as e:
    print('not ok - history.json is served (%s)' % e); sys.exit(1)
up = {u['k']: u for r in runs for u in r.get('up', [])}
def served(k, src):
    u = up.get(k, {})
    img = u.get('img')
    if not isinstance(img, str) or img.startswith(('data:', '/', 'http')):
        return False, u
    path = os.path.join(web, img)
    return os.path.isfile(path) and open(path, 'rb').read() == open(src, 'rb').read(), u
good, u = served('google-chrome', os.path.join(web, '..', 'none'))
img = up.get('google-chrome', {}).get('img')
chrome_bytes = open(os.path.join(web, img), 'rb').read() if isinstance(img, str) and os.path.isfile(os.path.join(web, img)) else b''
ok("the app icon this run's plan showed is the logo of its update in the history",
   chrome_bytes == b'\x89PNG\r\n\x1a\nchrome-app-icon' and up.get('google-chrome', {}).get('app') is True, up.get('google-chrome'))
good, u = served('fastfetch', os.path.join(cache, 'gh-fastfetch-cli'))
ok("an update with no Simple Icons mark shows its GitHub org's avatar from the cache", good, u)
good, u = served('c-ares', os.path.join(cache, 'c-ares.org'))
ok("an update with no Simple Icons mark shows its site's favicon from the cache", good, u)
ok('an update with a Simple Icons mark and no app icon keeps the mark, as on the live record',
   'img' not in up.get('node', {}) and up.get('node', {}).get('slug') == 'nodedotjs', up.get('node'))
ok('an update whose icon is not in the cache gets no logo file (a monogram)', 'img' not in up.get('herdr', {}), up.get('herdr'))
ok('an update with no homepage gets no logo file (a monogram)', 'img' not in up.get('mystery', {}), up.get('mystery'))
lines = open(hist).read().splitlines()
ok('the history file holds no icons', all('"img"' not in l and 'data:' not in l for l in lines), lines)
ok('serving the history leaves the earlier records as they were', lines[0] == open(before).read().splitlines()[0])
sys.exit(1 if fails else 0)
PY
[ -s "$tmp/reached" ] && fail "serving the history fetches nothing and asks Homebrew nothing ($(cat "$tmp/reached"))" \
  || pass "serving the history fetches nothing and asks Homebrew nothing"
[ -s "$tmp/serve.err" ] && fail "serving the history says nothing on stderr ($(cat "$tmp/serve.err"))" \
  || pass "serving the history says nothing on stderr"

# The panel's list of the tools that move most shows the same logos.
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE' || failures=$((failures + 1))
const html = require('fs').readFileSync(process.argv[2], 'utf8');
const line = (html.match(/^ *const toolLogo = .*;$/m) || [])[0];
if (!line) { console.log('not ok - the page has toolLogo()'); process.exit(1); }
const calls = [];
const logo = (...a) => { calls.push(a); return ''; };
eval(line.replace('const toolLogo', 'globalThis.toolLogo'));
toolLogo({ n: 'Google Chrome', slug: 'googlechrome', img: 'hist/google-chrome.png', app: true });
toolLogo({ n: 'c-ares', img: 'hist/c-ares.org.ico' });
toolLogo({ n: 'Node.js', slug: 'nodedotjs' });
const want = [['googlechrome', 'hist/google-chrome.png', 'Google Chrome', true], ['', 'hist/c-ares.org.ico', 'c-ares', undefined], ['nodedotjs', '', 'Node.js', undefined]];
const ok = JSON.stringify(calls) === JSON.stringify(want);
console.log(`${ok ? 'ok' : 'not ok'} - the tools that move most show the logo files history.json names (logo() got ${JSON.stringify(calls)})`);
process.exit(ok ? 0 : 1);
NODE

if [ "$failures" -eq 0 ]; then
  echo "all history logo tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
