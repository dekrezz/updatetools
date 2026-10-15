#!/usr/bin/env bash
# The dashboard and the HTML report speak Antigravity's design language (the
# 2026.10.10 restyle): Google Sans Flex first with a system fallback, #121317
# ink on white (the reverse in dark), 24px cards, pill controls, the logo
# gradient for a run where every step completed, and one centred column with
# the theme switch pinned to the corner. Features added later keep this look.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-design.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

ut_web_page > "$tmp/page.html"

export HOME="$tmp/home"
mkdir -p "$HOME"
UT_REPORT_DIR="$tmp/report"
UT_LASTREPORT="$tmp/last"
UT_WEB_DATA="$tmp/updates.txt"
MAKE_REPORT=1
mkdir -p "$UT_REPORT_DIR"
brew() { return 0; }
have() { command -v "$1" >/dev/null 2>&1 || [ "$1" = brew ]; }
ut_capture_cli_versions() { :; }
ut_changelog_lookup() { :; }
ut_icon_homepage() { :; }
ut_icon_site() { :; }
ut_icon_datauri() { :; }
printf '%s\n' "chatgpt|26.928.31416|26.930.21537|cask" > "$UT_REPORT_DIR/brew"
ut_generate_report "$tmp/report.html" >/dev/null

python3 - "$tmp/page.html" "$tmp/report.html" <<'PY'
import re, sys
page = open(sys.argv[1]).read()
report = open(sys.argv[2]).read()
fails = 0
def ok(name, cond):
    global fails
    print(('ok - ' if cond else 'not ok - ') + name)
    if not cond:
        fails += 1
def var(doc, name):
    m = re.search(r'--' + re.escape(name) + r'\s*:\s*([^;}]+)', doc)
    return m.group(1).strip() if m else ''
def rule(doc, sel):
    m = re.search(r'(^|[}\s])' + re.escape(sel) + r'\s*\{([^}]*)\}', doc, re.M)
    return m.group(2) if m else ''

# dashboard
ok('dashboard text is Google Sans Flex first', var(page, 'sans').startswith('"Google Sans Flex"'))
ok('dashboard ink is #121317 on white', '--ink:#121317' in page and '--bg:#ffffff' in page)
ok('dashboard dark theme reverses it', re.search(r'html\[data-theme="dark"\]\{[^}]*--bg:#121317', page) is not None)
ok('dashboard cards are 24px', var(page, 'r-lg') == '24px' and 'var(--r-lg)' in rule(page, '.steps'))
ok('dashboard controls are pills', var(page, 'r-pill') == '9999px')
ok('a clean run fills the ribbon with the logo gradient',
   var(page, 'logo').startswith('linear-gradient(90deg,#FC413D') and ':not(:has(.seg:not(.done))) .seg' in page)
ok('dashboard is one centred column', 'calc(720px + 3rem)' in rule(page, '.wrap') and '<aside' not in page)
ok('theme switch is pinned to the corner', 'position:fixed' in rule(page, '.theme-switch'))

# report
ok('report text is Google Sans Flex first', var(report, 'sans').startswith('"Google Sans Flex"'))
ok('report cards are 24px on #f8f9fc', var(report, 'r') == '24px' and var(report, 'card') == '#f8f9fc'
   and 'var(--r)' in rule(report, '.card'))
ok('report controls are pills', var(report, 'pill') == '9999px')
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && pass "Antigravity design language" || fail "Antigravity design language"

if [ "$failures" -eq 0 ]; then
  echo "all design tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
