#!/usr/bin/env bash
# A password the page already sent must not bring the sheet back. The page
# polls state.json, and a snapshot taken before the run read the answer still
# carries the prompt just answered: the sheet flashed open again and shut.
# Each prompt is numbered, so the page can tell that stale snapshot from a new
# prompt (a wrong password asked for again), which must still open the sheet.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-prompt.XXXXXX)"
# updatetools keeps its scratch files (the run log) in TMPDIR: inside $tmp, they go with it.
export TMPDIR="$tmp/scratch"
mkdir -p "$TMPDIR"
asker=""

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
trap '[ -n "$asker" ] && kill "$asker" 2>/dev/null; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

# ---------------------------------------------------------------------------
# state.json: every prompt the run asks carries its own number
# ---------------------------------------------------------------------------
WEB_DIR="$tmp/web"; mkdir -p "$WEB_DIR"
LOG="$tmp/run.log"; : > "$LOG"
T0=$SECONDS
PROMPT_REP="$tmp/rep"
WEB_PID=$$
SUDO_PW=""
PROMPT_TIMEOUT=20
ut_read_input_source() { UT_LAYOUT_NOW=English; UT_LAYOUT_ID=com.apple.keylayout.US; }

# The prompt's number in the current state.json, "-" when nothing is asked.
ask_of() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("ask", "") if d.get("prompt") else "-")' "$WEB_DIR/state.json" 2>/dev/null
}
# Wait (at most 10 s) for a prompt whose number is not $1; print that number.
wait_prompt_other_than() {
  local n=0 a
  while [ "$n" -lt 100 ]; do
    a="$(ask_of)"
    if [ -n "$a" ] && [ "$a" != "-" ] && [ "$a" != "$1" ]; then printf '%s' "$a"; return 0; fi
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

( ut_web_ask "Password" force && ut_web_ask "Wrong password — try again" force ) > "$tmp/ask.out" 2>&1 &
asker=$!

first="$(wait_prompt_other_than none)"
[ -n "$first" ] && pass "a prompt carries its number" || fail "a prompt carries its number"
printf 'first\n' > "$PROMPT_REP"
second="$(wait_prompt_other_than "${first:-none}")"
[ -n "$second" ] && [ "$second" != "$first" ] && pass "the next prompt has a new number" \
  || fail "the next prompt has a new number (first '$first', second '$second')"
printf 'second\n' > "$PROMPT_REP"
if wait "$asker"; then pass "both answers reached the run"; else fail "both answers reached the run"; fi
asker=""
[ "$(ask_of)" = "-" ] && pass "no prompt once both are answered" || fail "no prompt once both are answered"

# ---------------------------------------------------------------------------
# the page: which snapshot opens the sheet
# ---------------------------------------------------------------------------
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const a = html.indexOf('function freshPrompt('), b = html.indexOf('\n  }\n', a);
if (a < 0 || b < 0) { console.log('not ok - helper freshPrompt not found'); process.exit(1); }
eval(html.slice(a, b) + '\n  }');
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
ok('a prompt not yet answered opens the sheet', freshPrompt({ prompt: 'Password', ask: 1 }, null) === true);
ok('a snapshot of the prompt just answered does not reopen it', freshPrompt({ prompt: 'Password', ask: 1 }, 1) === false);
ok('a new prompt after an answer opens the sheet', freshPrompt({ prompt: 'Wrong password — try again', ask: 2 }, 1) === true);
ok('no prompt, no sheet', freshPrompt({ phase: 'run' }, null) === false);
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "page opens the sheet only for an unanswered prompt" || fail "page opens the sheet only for an unanswered prompt"

if [ "$failures" -eq 0 ]; then
  echo "all password prompt tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
