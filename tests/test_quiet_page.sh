#!/usr/bin/env bash
# The dashboard's server lives as long as the run needs it, not as long as the
# page keeps asking. A browser stops the timers of a tab that is hidden (the
# window is behind the terminal, another tab is in front), so a quiet page is
# usually an open page, not a closed one:
#   * while the run is going, the server never ends because the page is quiet;
#     the page finds it again whenever it asks;
#   * after the run, a page that is only quiet is waited for WEB_AWAY seconds
#     (counted from the end of the run if it was quiet through it), then the
#     server ends and the terminal is free;
#   * a page that says it is gone (pagehide: the tab closed or reloaded) is
#     waited for WEB_IDLE seconds, so a reload comes back to it; once the run is
#     over, a closed tab ends the server at once.
# The server's arguments: ROOT TOKEN-FILE REPLY-FILE WEB_IDLE TTY STOP_GRACE WEB_AWAY.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-quiet.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it, stop the servers, remove $tmp.
trap 'cleanup; pkill -KILL -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
alive() { ps -p "$1" >/dev/null 2>&1; }
# gone PID SECONDS: true once PID has exited, waiting at most SECONDS.
gone() { local n=0; while alive "$1" && [ "$n" -lt $(( $2 * 10 )) ]; do sleep 0.1; n=$((n + 1)); done; ! alive "$1"; }

# phase DIR PHASE: what the run publishes, written the way ut_web_state writes it.
phase() { printf '{"phase":"%s","elapsed":5,"steps":[{"n":"Homebrew","s":"run","key":"homebrew"}]}\n' "$2" > "$1/.state.tmp" && mv -f "$1/.state.tmp" "$1/state.json"; }

# serve DIR PHASE WEB_IDLE WEB_AWAY: start the real server; sets PID and PORT.
serve() {
  mkdir -p "$1"
  ut_web_server_py > "$1/serve.py"
  printf '%s' token > "$1/.token"
  phase "$1" "$2"
  python3 "$1/serve.py" "$1" "$1/.token" "$1/rep" "$3" "" 5 "$4" > "$1/port" 2>/dev/null &
  PID=$!
  local n=0; while [ ! -s "$1/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  PORT="$(head -1 "$1/port")"
}
# ask: the page's poll; prints the HTTP status and the phase it read.
ask() { curl -s -m 2 -H 'Cookie: ut=token' "http://127.0.0.1:$PORT/state.json" -w ' %{http_code}' 2>/dev/null | tr -d '\n' | sed -E 's/.*"phase":"([a-z]+)".* ([0-9]+)$/\2 \1/'; }
# beacon PATH: what the page sends from pagehide.
beacon() { curl -s -m 2 -o /dev/null -X POST -H 'Cookie: ut=token' --data '' "http://127.0.0.1:$PORT/$1" 2>/dev/null; }

# A page quiet through the run and past its end.
serve "$tmp/a" run 1 3
[ "$(ask)" = "200 run" ] && pass "the page reaches the server (test setup)" || fail "the page reaches the server (test setup): $(ask)"
sleep 4.5
alive "$PID" && [ "$(ask)" = "200 run" ] \
  && pass "while the run is going, a page quiet for longer than WEB_IDLE and WEB_AWAY still finds the server" \
  || fail "while the run is going, a page quiet for longer than WEB_IDLE and WEB_AWAY still finds the server"
sleep 4.5
phase "$tmp/a" done
sleep 2
alive "$PID" && [ "$(ask)" = "200 done" ] \
  && pass "after the run, a page that was quiet through its end finds the server and the result" \
  || fail "after the run, a page that was quiet through its end finds the server and the result"
sleep 1.5
alive "$PID" && pass "after the run, a quiet page is waited for longer than WEB_IDLE" \
  || fail "after the run, a quiet page is waited for longer than WEB_IDLE"
gone "$PID" 4 && pass "after the run, a page quiet for WEB_AWAY ends the server, which frees the terminal" \
  || fail "after the run, a page quiet for WEB_AWAY ends the server, which frees the terminal"

# A tab closed while the run is going.
serve "$tmp/b" run 1 30
ask >/dev/null
beacon gone
sleep 2.5
alive "$PID" && pass "a tab closed during the run does not end the server while the run goes on" \
  || fail "a tab closed during the run does not end the server while the run goes on"
phase "$tmp/b" done
gone "$PID" 4 && pass "once the run is over, a tab closed during it frees the terminal after WEB_IDLE, not WEB_AWAY" \
  || fail "once the run is over, a tab closed during it frees the terminal after WEB_IDLE, not WEB_AWAY"

# The chooser: a reload comes back, a closed tab cancels the run.
serve "$tmp/c" choose 1 30
ask >/dev/null
beacon gone
ask >/dev/null
sleep 2.5
alive "$PID" && pass "a reload (the page leaves and asks again) keeps the server" \
  || fail "a reload (the page leaves and asks again) keeps the server"
beacon gone
gone "$PID" 4 && pass "a tab closed on the chooser ends the server after WEB_IDLE, which cancels the run" \
  || fail "a tab closed on the chooser ends the server after WEB_IDLE, which cancels the run"

# After the run, closing the tab ends the server at once.
serve "$tmp/d" done 30 30
ask >/dev/null
beacon quit
gone "$PID" 2 && pass "after the run, a closed tab ends the server at once" \
  || fail "after the run, a closed tab ends the server at once"

# The page: pagehide says "gone" before and during the run, "quit" after it.
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE' || failures=$((failures + 1))
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const a = html.indexOf("addEventListener('pagehide'"), b = html.indexOf('\n  });', a);
if (a < 0 || b < 0) { console.log('not ok - the page has a pagehide handler'); process.exit(1); }
const block = html.slice(a, b) + '\n  });';
let fails = 0;
for (const [ph, want] of [['choose', 'gone'], ['run', 'gone'], ['done', 'quit'], ['error', 'quit']]) {
  const sent = [], handlers = {};
  const navigator = { sendBeacon: (url) => { sent.push(url); return true; } };
  const addEventListener = (ev, fn) => { handlers[ev] = fn; };
  const latestPhase = ph;
  eval(block);
  handlers.pagehide();
  const ok = sent.length === 1 && sent[0] === want;
  console.log(`${ok ? 'ok' : 'not ok'} - a tab that goes away in ${ph} tells the server "${want}" (sent: ${JSON.stringify(sent)})`);
  if (!ok) fails++;
}
process.exit(fails ? 1 : 0);
NODE

if [ "$failures" -eq 0 ]; then
  echo "all quiet page tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
