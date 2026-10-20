#!/usr/bin/env bash
# Homebrew prints nothing while a bottle or a cask downloads, so a long download
# on a slow line looked like a stall: the watchdog killed `brew upgrade` in the
# middle of a 322 MB bottle that was still arriving. A download that grows is
# progress; a step that is silent and downloads nothing is still a stall.
# The same downloads tell the page how far each one has got.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-stall.XXXXXX)"
# updatetools keeps its scratch files (the run log) in TMPDIR: inside $tmp, they go with it.
export TMPDIR="$tmp/scratch"
mkdir -p "$TMPDIR"
grower=""

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
trap '[ -n "$grower" ] && kill "$grower" 2>/dev/null; rm -rf "$tmp"' EXIT

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

export HOMEBREW_CACHE="$tmp/brewcache"
dl="$HOMEBREW_CACHE/downloads"
mkdir -p "$dl"
unset WEB_DIR
STALL_TIMEOUT=2
part="$dl/5699fe62--llvm@21--21.1.8_1.arm64_tahoe.bottle.tar.gz.incomplete"

# a silent step while a download keeps arriving: not a stall
: > "$tmp/quiet.log"
( sleep 5 ) & step=$!
( for _ in $(seq 1 14); do head -c 4096 /dev/zero >> "$part"; sleep 0.4; done ) & grower=$!
ut_watch_pid "$step" "$tmp/quiet.log"
assert_eq "a growing download keeps a silent step alive" "0" "$UT_WAIT_STALLED"
assert_eq "the step ends on its own" "0" "$UT_WAIT_RC"
kill "$grower" 2>/dev/null; wait "$grower" 2>/dev/null; grower=""

# a silent step and a download that no longer moves: a stall
: > "$tmp/stuck.log"
( sleep 30 ) & step=$!
t0=$SECONDS
ut_watch_pid "$step" "$tmp/stuck.log"
assert_eq "a silent step with no download moving is a stall" "1" "$UT_WAIT_STALLED"
[ $((SECONDS - t0)) -lt 15 ] && pass "the stall is caught in time" || fail "the stall is caught in time"
assert_contains "the stall is said in the step's log" "$(cat "$tmp/stuck.log")" "stalled 2s with no output"

# the page learns how far each download has got
WEB_DIR="$tmp/web"; mkdir -p "$WEB_DIR"
LOG="$tmp/run.log"; : > "$LOG"
T0=$SECONDS
ut_web_state run
state="$(cat "$WEB_DIR/state.json")"
size=$(stat -f %z "$part")
assert_contains "a download in progress is published by package" "$state" "\"dl\":{\"llvm@21\":$size}"
rm -f "$part"
ut_web_state run
case "$(cat "$WEB_DIR/state.json")" in
  *'"dl"'*) fail "no downloads, no download field" ;;
  *) pass "no downloads, no download field" ;;
esac

# the plan row says how far its download has got
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const pick = (from, to) => {
  const a = html.indexOf(from), b = html.indexOf(to, a + 1);
  if (a < 0 || b < 0) { console.log('not ok - helper ' + from + ' not found'); process.exit(1); }
  return html.slice(a, b);
};
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
eval(pick('function planProgress(', '\n  }\n') + '\n  }');
const items = [{ k: 'llvm@21', n: 'llvm@21' }, { k: 'node', n: 'node' }, { k: 'herdr', n: 'herdr' }];
const section = [
  '==> Would upgrade 3 outdated packages',
  'llvm@21    21.1.8    -> 21.1.8_1   (322.8MB)',
  'node       24.9.0    -> 24.10.0    (21.3MB)',
  'herdr      0.9.3     -> 0.9.5      (8.4MB)',
  '✔︎ Bottle node (24.10.0)',
].join('\n');
const live = planProgress(section, items, { 'llvm@21': 74919936 });
ok('a download in progress is its own state', live['llvm@21'] === 'dl');
const got = (live.$dl || {})['llvm@21'] || {};
ok('it knows how much has arrived', got.got === 74919936);
ok('it knows the size Homebrew announced', got.size === 322.8e6);
ok('a finished download is downloaded', live.node === 'got');
ok('a package not reached yet has no state', live.herdr === undefined);
const document = { getElementById: () => ({}) };
const window = {};
const lift = (src) => src.replace(/(^|\n)(\s*)const /g, '$1$2var ');
eval(lift(pick('const ICON = {', '\n  };\n') + '\n  };'));
eval(pick('function escapeHtml(', '\n  }\n') + '\n  }');
eval(pick('function versionMarkup(', 'function escapeHtml('));
eval(pick('function logo(', 'function prettyTail('));
const plural = (n, a, b) => `${n} ${n === 1 ? a : b}`;
eval(lift(pick('const ACT = {', 'function planFor(')));
eval(pick('function planRows(', 'function planBlock('));
const rows = planRows([{ k: 'llvm@21', n: 'llvm@21', o: '21.1.8', w: '21.1.8_1', act: 'update' }], live);
ok('the row says the download and how far it is', /class="row dl"/.test(rows) && />Downloading 23%</.test(rows));
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "plan rows show download progress" || fail "plan rows show download progress"

if [ "$failures" -eq 0 ]; then
  echo "all stall watch tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
