#!/usr/bin/env bash
# Prove ribbon/legend/post-start list filters omit unselected tools.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-dashboard-sel.XXXXXX)"
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

# Header order: ribbon sits above the clock.
ut_web_page > "$tmp/page.html"
python3 - "$tmp/page.html" <<'PY' > "$tmp/order.txt"
import re, sys
html = open(sys.argv[1]).read()
ids = re.findall(r'id="(ribbon|clock|legend|steps)"', html)
print(' '.join(ids))
PY
assert_eq "header order clock then ribbon then legend" "clock ribbon legend steps" "$(cat "$tmp/order.txt")"
grep -q 'id="select-all"' "$tmp/page.html" && pass "select all control" || fail "select all control"

# Drive the named selection helpers extracted from the generated page.
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const start = html.indexOf('function stepSelected(');
const end = html.indexOf('function paintRibbon(');
if (start < 0 || end < 0 || end <= start) {
  console.error('helpers not found in page');
  process.exit(2);
}
const src = html.slice(start, end);
eval(src);

const steps = [
  { n: 'Homebrew', slug: 'homebrew', s: 'done', on: true, why: '', t: 12 },
  { n: 'npm', slug: 'npm', s: 'skip', on: false, why: 'off', t: 0 },
  { n: 'uv', slug: 'astral', s: 'skip', on: false, why: 'off', t: 0 },
  { n: 'cargo', slug: 'rust', s: 'skip', on: true, why: 'guard', t: 0 },
  { n: 'Report', slug: 'report', s: 'done', on: true, why: '', t: 1 },
];

let fails = 0;
function assertEq(name, exp, act) {
  const e = JSON.stringify(exp), a = JSON.stringify(act);
  if (e === a) console.log('ok - ' + name);
  else { console.log('not ok - ' + name + ' (expected ' + e + ', got ' + a + ')'); fails++; }
}

// choose phase: only toggled-on tools in ribbon; list keeps all rows
const chooseOn = [true, false, false, false, true];
assertEq(
  'choose ribbon only selected (no report)',
  ['homebrew'],
  stepsForRibbon(steps, 'choose', chooseOn).map((s) => s.slug)
);
assertEq(
  'choose list keeps all toggles',
  5,
  stepsForList(steps, 'choose', chooseOn).length
);
assertEq(
  'choose ribbon follows server on when local unset',
  ['homebrew', 'rust'],
  stepsForRibbon(steps, 'choose', null).map((s) => s.slug)
);

// after Start: ribbon + list omit off tools; guard-skipped selected stays
assertEq(
  'run ribbon omits off and report',
  ['homebrew', 'rust'],
  stepsForRibbon(steps, 'run', null).map((s) => s.slug)
);
assertEq(
  'run list omits off keeps guard',
  ['homebrew', 'rust', 'report'],
  stepsForList(steps, 'run', null).map((s) => s.slug)
);
assertEq(
  'run counts only selected',
  { total: 3, done: 2, skip: 1, fail: 0 },
  selectedCounts(steps, 'run', null)
);

// sole Homebrew selection (report off too)
const onlyBrew = [
  { n: 'Homebrew', slug: 'homebrew', s: 'run', on: true, why: '' },
  { n: 'npm', slug: 'npm', s: 'skip', on: false, why: 'off' },
  { n: 'Report', slug: 'report', s: 'skip', on: false, why: 'off' },
];
assertEq(
  'only-homebrew ribbon',
  ['homebrew'],
  stepsForRibbon(onlyBrew, 'run', null).map((s) => s.slug)
);
assertEq(
  'only-homebrew list',
  ['homebrew'],
  stepsForList(onlyBrew, 'run', null).map((s) => s.slug)
);
assertEq(
  'only-homebrew counts 1 of 1',
  { total: 1, done: 0, skip: 0, fail: 0 },
  selectedCounts(onlyBrew, 'run', null)
);

process.exit(fails ? 1 : 0);
NODE
node_rc=$?
if [ "$node_rc" -eq 0 ]; then
  pass "selection helpers filter unselected tools"
else
  fail "selection helpers (see node output above)"
fi

if [ "$failures" -ne 0 ] || [ "$node_rc" -ne 0 ]; then
  printf '\n%d failure(s)\n' "$((failures + (node_rc ? 1 : 0)))" >&2
  exit 1
fi
printf '\nall ok\n'
