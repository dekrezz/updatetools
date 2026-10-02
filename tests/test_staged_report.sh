#!/usr/bin/env bash
# A staged update (installed on disk, the running app still on the old build)
# is still a change from this run: it belongs in "What changed", marked so the
# reader knows it applies on the next launch.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-staged-report.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) pass "$name" ;; *) fail "$name (missing '$needle')" ;; esac
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) fail "$name (found '$needle')" ;; *) pass "$name" ;; esac
}

export HOME="$tmp/home"
mkdir -p "$HOME"
UT_REPORT_DIR="$tmp/report"
UT_LASTREPORT="$tmp/last"
UT_WEB_DATA="$tmp/updates.txt"
MAKE_REPORT=1
mkdir -p "$UT_REPORT_DIR"

brew() { return 0; }   # nothing is outdated after the run
have() { command -v "$1" >/dev/null 2>&1 || [ "$1" = brew ]; }
ut_capture_cli_versions() { :; }
ut_changelog_lookup() { :; }
ut_icon_homepage() { :; }
ut_icon_site() { :; }
ut_icon_datauri() { :; }

printf '%s\n' "chatgpt|26.928.31416|26.930.21537|cask" \
              "wispr-flow|1.6.1021|1.6.1034|cask" > "$UT_REPORT_DIR/brew"
printf '%s\n' "wispr-flow" > "$UT_REPORT_DIR/staged"

report="$(ut_generate_report "$tmp/report.html")"
data="$(cat "$UT_WEB_DATA" 2>/dev/null)"
assert_contains "upgraded cask is in the diff" "$data" "26.930.21537"
assert_contains "staged cask is in the diff" "$data" "1.6.1034"

json="$(ut_web_updates "$UT_WEB_DATA")"
wispr="$(printf '%s' "$json" | tr '{' '\n' | grep '1.6.1034')"
chat="$(printf '%s' "$json" | tr '{' '\n' | grep '26.930.21537')"
assert_contains "staged cask is flagged for the dashboard" "$wispr" '"st":"staged"'
assert_not_contains "upgraded cask is not flagged" "$chat" '"st":"staged"'

html="$(cat "$tmp/report.html" 2>/dev/null)"
assert_contains "HTML report lists the staged cask" "$html" "1.6.1034"
assert_contains "HTML report marks the staged cask" "$html" 'class="staged-note"'

# The dashboard ledger renders the mark next to the version.
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const pick = (from, to) => {
  const a = html.indexOf(from), b = html.indexOf(to, a + 1);
  if (a < 0 || b < 0) { console.log('not ok - helper ' + from + ' not found'); process.exit(1); }
  return html.slice(a, b);
};
eval(pick('function stagedNote(', 'function versionMarkup('));
eval(pick('function escapeHtml(', '\n  }\n') + '\n  }');
let fails = 0;
const ok = (name, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + name); if (!cond) fails++; };
const staged = stagedNote({ n: 'Wispr Flow', st: 'staged' });
ok('staged entry gets an info mark', /class="staged-note"/.test(staged));
ok('info mark explains the next launch', /next launch/i.test(staged));
ok('info mark is keyboard reachable', /tabindex="0"/.test(staged));
ok('regular entry gets no mark', stagedNote({ n: 'ChatGPT' }) === '');
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "dashboard ledger marks staged entries" || fail "dashboard ledger marks staged entries"

if [ "$failures" -eq 0 ]; then
  echo "all staged report tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
