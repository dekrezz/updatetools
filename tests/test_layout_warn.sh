#!/usr/bin/env bash
# Wrong keyboard layout closes the sudo reveal control and names both languages.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-layout.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export UPDATETOOLS_LIB_ONLY=1
export UPDATETOOLS_PASSWORD_LAYOUT="$tmp/password-layout"
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

assert_eq "Russian layout" "Russian" "$(ut_layout_language com.apple.keylayout.Russian)"
assert_eq "US layout is English" "English" "$(ut_layout_language com.apple.keylayout.US)"
assert_eq "ABC layout is English" "English" "$(ut_layout_language com.apple.keylayout.ABC)"
assert_eq "U.S. name is English" "English" "$(ut_layout_language 'U.S.')"
assert_eq "German layout" "German" "$(ut_layout_language com.apple.keylayout.German)"
if ut_layout_language "" >/dev/null 2>&1; then
  fail "empty layout should fail"
else
  pass "empty layout fails"
fi

ut_remember_password_layout com.apple.keylayout.German
assert_eq "remembered id" "com.apple.keylayout.German" "$(head -1 "$UPDATETOOLS_PASSWORD_LAYOUT")"
ut_read_input_source
assert_eq "saved password language" "German" "$UT_LAYOUT_PASS"
if [ -n "$UT_LAYOUT_NOW" ]; then
  pass "current layout read ($UT_LAYOUT_NOW)"
else
  fail "current layout was empty"
fi

ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
function die(msg) { console.error(msg); process.exit(1); }
if (!html.includes('id="layout-note"')) die('missing layout note');
if (!html.includes('wrong-layout')) die('missing wrong-layout style');
const start = html.indexOf('function layoutsDiffer(');
const end = html.indexOf('function scriptOf(');
const end2 = html.indexOf('function paintLayout(');
if (start < 0 || end < 0 || end2 < 0) die('helpers missing');
const fn = html.slice(start, end2);
const scriptOf = new Function(fn + '\nreturn { layoutsDiffer, scriptOf };')();
const { layoutsDiffer, scriptOf: script } = scriptOf;
const checks = [
  ['russian vs english', layoutsDiffer('Russian', 'English'), true],
  ['same language', layoutsDiffer('English', 'English'), false],
  ['empty now', layoutsDiffer('', 'English'), false],
  ['cyrillic', script('ф'), 'Russian'],
  ['latin', script('a'), 'Latin'],
  ['digit ignored', script('1'), ''],
];
let bad = 0;
for (const [name, got, exp] of checks) {
  if (got !== exp) { console.error(`not ok - ${name} (expected ${exp}, got ${got})`); bad++; }
  else console.log(`ok - ${name}`);
}
if (bad) process.exit(1);
NODE
node_rc=$?
if [ "$node_rc" -ne 0 ]; then
  fail "page layout helpers"
fi

if [ "$failures" -eq 0 ]; then
  echo "all ok"
else
  echo "$failures failed" >&2
  exit 1
fi
