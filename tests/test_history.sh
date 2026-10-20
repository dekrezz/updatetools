#!/usr/bin/env bash
# Every run in which a step ran is remembered, for the dashboard's History panel:
#   * it is one JSON line in the history file (UPDATETOOLS_HISTORY_FILE, else
#     ~/.config/updatetools/history), oldest first; after every write only the
#     newest HISTORY_KEEP runs (200 by default) remain, and no temp file is left;
#   * the record says which run it is (id "<start epoch>-<pid>"), when its steps
#     started, how long the run took (what the dashboard clock shows at the
#     end), how it was started (dashboard or plain) and how it ended (ok, fail,
#     or halted with why); it lists the steps that ran (not the skipped ones,
#     never the report) with their outcome and time, and every update from the
#     report's records: versions cut at the first comma, an http(s) link only,
#     a staged/restarted state only when there is one, a logo slug only when
#     ut_icon_slug knows one, never an icon;
#   * a run stopped by the network or by SIGTERM is recorded as halted, with
#     the interrupted step "stopped"; a run in which no step ran is not;
#   * the dashboard serves the history as history.json, newest first, before
#     the browser opens, and every state.json that names this run's record
#     ("hist":{"id","rev"}) is written after history.json serves that record;
#   * a retry rewrites the same record: the retried steps replace their
#     entries, the updates merge by key, its time is added, the outcome is
#     worked out again and the revision goes up;
#   * a corrupt history file is reported (history.json carries the error, the
#     terminal is told once) and never repaired; the new run is still appended;
#   * a history file that cannot be written costs the run one stderr line;
#   * the plain path never needs python.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(command -v python3)" || { echo "not ok - python3 is required to run this test"; exit 1; }
tmp="$(mktemp -d /tmp/updatetools-history.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch" HOMEBREW_CACHE="$tmp/brew-cache" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$TMPDIR" "$tmp/bin"
unset UPDATETOOLS_HISTORY_FILE HISTORY_KEEP UPDATETOOLS_ENABLED_FILE UPDATETOOLS_DURATIONS_FILE UPDATETOOLS_PASSWORD_LAYOUT

# No Homebrew, no mas, no network, no browser: a PATH of system tools plus
# fakes. `open` and `curl` fail loudly into a file if anything reaches them.
cat > "$tmp/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/open-binary-used"
exit 0
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
cat > "$tmp/bin/osascript" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp/bin/sudo" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/bin/open" "$tmp/bin/curl" "$tmp/bin/osascript" "$tmp/bin/sudo"
ln -s "$PY" "$tmp/bin/python3"
export SAFE_PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing puts Homebrew's bin dir first (brew shellenv); take it away again.
export PATH="$SAFE_PATH"
if command -v brew >/dev/null 2>&1; then
  echo "not ok - the test keeps the real Homebrew out of reach (brew is $(command -v brew))"
  rm -rf "$tmp"
  exit 1
fi
finish() {
  chmod -R u+w "$tmp" 2>/dev/null
  pkill -KILL -f "$tmp/" 2>/dev/null
  rm -rf "$tmp"
}
trap finish EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
wait_for_file() { local n=0; while [ ! -f "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done; [ -f "$1" ]; }

# pycheck LABEL ARGS... <<'PY' — run python checks; they print ok/not ok lines
# (ok(msg, cond, detail); need() also stops the block when it fails).
cat > "$tmp/harness.py" <<'PY'
import json, sys
label, args = sys.argv[1], sys.argv[2:]
code = sys.stdin.read()
class Stop(Exception):
    pass
def ok(msg, cond, detail=None):
    if cond:
        print('ok - ' + msg)
    else:
        print('not ok - ' + msg + ('' if detail is None else ' (' + str(detail)[:600] + ')'))
    return bool(cond)
def need(msg, cond, detail=None):
    if not ok(msg, cond, detail):
        raise Stop()
def raw_lines(path):
    try:
        with open(path, encoding='utf-8') as f:
            return [l for l in f.read().split('\n') if l != '']
    except FileNotFoundError:
        return []
def parse(s):
    try:
        return json.loads(s)
    except ValueError:
        return None
def load(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
try:
    exec(compile(code, label, 'exec'), {'ok': ok, 'need': need, 'raw_lines': raw_lines, 'parse': parse,
                                        'load': load, 'args': args, 'json': json})
except Stop:
    pass
except Exception as e:
    print('not ok - %s: %s: %s' % (label, type(e).__name__, e))
PY
pycheck() {
  local out n
  out="$("$PY" -I "$tmp/harness.py" "$@" 2>&1)"
  [ -n "$out" ] && printf '%s\n' "$out"
  n="$(printf '%s\n' "$out" | grep -c '^not ok')"
  failures=$((failures + n))
  printf '%s\n' "$out" | grep -q '^ok - \|^not ok - ' || fail "$1: the checks ran ($out)"
}

# An earlier run, as the history file holds it.
old_record() { # ID AT
  printf '{"v":1,"id":"%s","at":%s,"sec":61,"mode":"plain","out":"ok","steps":[{"k":"homebrew","n":"Homebrew","s":"done","t":50,"slug":"homebrew"}],"up":[{"k":"jq","n":"jq","o":"1.7","w":"1.8"}]}\n' "$1" "$2"
}
NOW="$(date +%s)"

# A tool that runs for up to 15 s and stops at once when told to.
cat > "$tmp/tool" <<'EOF'
#!/bin/bash
echo started > "$1.started"
trap 'echo stopped > "$1.rolled"; exit 143' TERM
n=0
while [ "$n" -lt 150 ]; do sleep 0.1; n=$((n + 1)); echo "working $n"; done
EOF
chmod +x "$tmp/tool"

# Homebrew's own name for gh (what ut_pretty_name reads from its cache).
mkdir -p "$XDG_CACHE_HOME/updatetools/icons"
printf 'GitHub CLI' > "$XDG_CACHE_HOME/updatetools/icons/gh.name"
: > "$XDG_CACHE_HOME/updatetools/icons/gh.meta"

sudo() { return 0; }
ut_needs_sudo() { return 1; }
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_notify_end() { return 0; }
ut_net_probe() { echo up; }
STALL_TIMEOUT=0
STOP_GRACE=10
NET_TIMEOUT=0
NET_PROBE_EVERY=1

setup_case() { # NAME — its own run dir and history file
  RUN="$tmp/$1"; mkdir -p "$RUN"
  HIST="$RUN/history"
  export UPDATETOOLS_HISTORY_FILE="$HIST"
  DIAG_DIR="$RUN/diag"
  rm -f "$UT_WEB_DATA"
  STATUS=(); STEP_WHY=(); STEP_SEC=(); STEP_T0=(); STEP_SLUG=(); STEP_IMG=(); STEP_PID=()
}
quick_steps() {
  STEPS=("Homebrew · upgrade¦true¦true" "Report¦true¦:")
  STEP_KEY=(homebrew report); STEP_ON=(1 1); TOTAL=2
}

# ── Where the history lives, and how the dashboard gets it ──────────────────
(
  failures=0
  RUN="$tmp/json"; mkdir -p "$RUN"
  if declare -F ut_history_file >/dev/null; then
    got="$(unset UPDATETOOLS_HISTORY_FILE; ut_history_file)"
    [ "$got" = "$HOME/.config/updatetools/history" ] && pass "the history file sits next to durations and enabled by default" \
      || fail "the history file sits next to durations and enabled by default ('$got')"
    got="$(UPDATETOOLS_HISTORY_FILE="$RUN/elsewhere" ut_history_file)"
    [ "$got" = "$RUN/elsewhere" ] && pass "UPDATETOOLS_HISTORY_FILE moves the history file" \
      || fail "UPDATETOOLS_HISTORY_FILE moves the history file ('$got')"
  else
    fail "ut_history_file prints where the history is kept (ut_history_file: command not found)"
  fi

  if declare -F ut_history_json >/dev/null; then
    UPDATETOOLS_HISTORY_FILE="$RUN/none/history" ut_history_json > "$RUN/empty.json" 2> "$RUN/empty.err"
    { old_record first $((NOW - 200)); old_record second $((NOW - 100)); } > "$RUN/two"
    UPDATETOOLS_HISTORY_FILE="$RUN/two" ut_history_json > "$RUN/two.json" 2> "$RUN/two.err"
    { old_record first $((NOW - 200)); echo 'this is not a run record'; old_record third $((NOW - 50)); } > "$RUN/text"
    UPDATETOOLS_HISTORY_FILE="$RUN/text" ut_history_json > "$RUN/text.json" 2>/dev/null
    { echo '[1,2]'; old_record second $((NOW - 100)); } > "$RUN/array"
    UPDATETOOLS_HISTORY_FILE="$RUN/array" ut_history_json > "$RUN/array.json" 2>/dev/null
    { old_record first $((NOW - 200)); echo '{"v":2,"id":"future"}'; } > "$RUN/v2"
    UPDATETOOLS_HISTORY_FILE="$RUN/v2" ut_history_json > "$RUN/v2.json" 2>/dev/null
    pycheck "history.json" "$RUN" <<'PY'
d = args[0]
ok('with no history file yet, history.json is an empty list of runs',
   load(d + '/empty.json') == {'v': 1, 'runs': []}, open(d + '/empty.json').read()[:300])
two = [parse(l) for l in raw_lines(d + '/two')]
got = load(d + '/two.json')
ok('history.json lists the runs newest first', got == {'v': 1, 'runs': [two[1], two[0]]}, got)
for name, line in (('text', 2), ('array', 1), ('v2', 2)):
    got = load(d + '/' + name + '.json') or {}
    err = got.get('error') if isinstance(got, dict) else None
    ok('a history file whose line %d is %s is served as an error naming the file and the line'
       % (line, {'text': 'not JSON', 'array': 'not an object', 'v2': 'not format version 1'}[name]),
       got.get('v') == 1 and isinstance(err, str) and (d + '/' + name) in err and ('line %d' % line) in err, got)
PY
  else
    fail "ut_history_json prints the history for the dashboard (ut_history_json: command not found)"
  fi
  exit "$failures"
)
failures=$((failures + $?))

# ── A plain run: what one record holds ───────────────────────────────────────
(
  failures=0
  setup_case plain
  STEPS=(
    "Homebrew · upgrade¦true¦sleep 1.1"
    "Widgetctl · refresh¦true¦echo broken; false"
    "pnpm · update globals¦true¦exit 3"
    "npm · update globals¦true¦: > \"$RUN/npm.ran\""
    "Report¦true¦cp \"$RUN/updates\" \"\$UT_WEB_DATA\""
  )
  STEP_KEY=(homebrew widgetctl pnpm npm report); STEP_ON=(1 1 1 0 1); TOTAL=5
  # The report's records: key|display|old|new|url|state
  cat > "$RUN/updates" <<'EOF'
node|node|20.1.0|22.3.0,rev2|https://nodejs.org/en/blog/release|
firefox|Firefox|130.0,1|131.0,2|ftp://ftp.mozilla.org/notes|staged
gh|gh|2.40.0|2.41.0|http://example.test/gh/releases|restarted
zzfrob|Zz "frob" Tool|1.0|1.1||
EOF
  # Every python the run starts is noted (the plain path must not need one).
  mkdir -p "$RUN/spy"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/python-calls"\nexec "%s" "$@"\n' "$RUN" "$PY" > "$RUN/spy/python3"
  chmod +x "$RUN/spy/python3"
  python3() { printf '%s\n' "$*" >> "$RUN/python-calls"; command python3 "$@"; }
  before="$(date +%s)"
  PATH="$RUN/spy:$PATH" run_plain > "$RUN/out" 2> "$RUN/err"
  after="$(date +%s)"
  unset -f python3
  [ "${STATUS[0]}:${STATUS[1]}:${STATUS[2]}:${STATUS[3]}" = "done:fail:staged:skip" ] \
    && pass "plain run: the fake steps ran as planned (test setup)" \
    || fail "plain run: the fake steps ran as planned (test setup: ${STATUS[*]})"
  pycheck "plain run" "$HIST" "$before" "$after" "$$" "${STEP_SEC[0]:-}" "${STEP_SEC[1]:-}" "${STEP_SEC[2]:-}" <<'PY'
hist, before, after, pid, t_brew, t_widget, t_pnpm = args
before, after = int(before), int(after)
lines = raw_lines(hist)
need('plain run: the run appends exactly one record to the history file', len(lines) == 1, '%d lines' % len(lines))
r = parse(lines[0])
need('plain run: the record is one line of valid JSON', isinstance(r, dict), lines[0][:300])
ok('plain run: the record has format version 1', r.get('v') == 1, r.get('v'))
at = r.get('at')
ok('plain run: the record starts when the steps started', isinstance(at, int) and before <= at <= after, (at, before, after))
ok('plain run: the record id is the start time and the process id', r.get('id') == '%s-%s' % (at, pid), (r.get('id'), pid))
sec = r.get('sec')
ok('plain run: the record holds how long the run took, in seconds',
   isinstance(sec, int) and int(t_brew) <= sec <= after - before + 1, (sec, t_brew, after - before))
ok('plain run: a run without the dashboard is recorded as plain', r.get('mode') == 'plain', r.get('mode'))
ok('plain run: a run with a failed step is recorded as failed', r.get('out') == 'fail', r.get('out'))
ok('plain run: a run that was not stopped has no halt reason', 'halt' not in r, r.get('halt'))
steps = r.get('steps')
need('plain run: the steps are a list', isinstance(steps, list), steps)
keys = [s.get('k') for s in steps]
ok('plain run: only the steps that ran are recorded (not the one turned off, never the report)',
   sorted(keys) == ['homebrew', 'pnpm', 'widgetctl'], keys)
by = dict((s.get('k'), s) for s in steps)
want = {'k': 'homebrew', 'n': 'Homebrew', 's': 'done', 't': int(t_brew), 'slug': 'homebrew'}
ok('plain run: a step is recorded with its key, its name before " · ", its outcome, its time and its logo slug',
   by.get('homebrew') == want, (by.get('homebrew'), want))
want = {'k': 'widgetctl', 'n': 'Widgetctl', 's': 'fail', 't': int(t_widget)}
ok('plain run: a failed step is recorded as fail, with no slug when ut_icon_slug knows none',
   by.get('widgetctl') == want, (by.get('widgetctl'), want))
want = {'k': 'pnpm', 'n': 'pnpm', 's': 'staged', 't': int(t_pnpm), 'slug': 'pnpm'}
ok('plain run: a staged step is recorded as staged', by.get('pnpm') == want, (by.get('pnpm'), want))
up = r.get('up')
need('plain run: the updates are a list', isinstance(up, list), up)
ok("plain run: every record of the report is recorded once as an update",
   sorted(u.get('k') for u in up) == ['firefox', 'gh', 'node', 'zzfrob'], [u.get('k') for u in up])
ub = dict((u.get('k'), u) for u in up)
want = {'k': 'node', 'n': 'node', 'o': '20.1.0', 'w': '22.3.0', 'u': 'https://nodejs.org/en/blog/release', 'slug': 'nodedotjs'}
ok('plain run: an update keeps its versions up to the first comma, its https link and its logo slug',
   ub.get('node') == want, (ub.get('node'), want))
want = {'k': 'firefox', 'n': 'Firefox', 'o': '130.0', 'w': '131.0', 'st': 'staged', 'slug': 'firefox'}
ok('plain run: a staged update says so, and a link that is not http(s) is left out',
   ub.get('firefox') == want, (ub.get('firefox'), want))
want = {'k': 'gh', 'n': 'GitHub CLI', 'o': '2.40.0', 'w': '2.41.0', 'st': 'restarted',
        'u': 'http://example.test/gh/releases', 'slug': 'github'}
ok("plain run: an update is named as ut_pretty_name names it, keeps a restarted state and an http link",
   ub.get('gh') == want, (ub.get('gh'), want))
want = {'k': 'zzfrob', 'n': 'Zz "frob" Tool', 'o': '1.0', 'w': '1.1'}
ok('plain run: an update with no link, state or known logo carries none of them, and quotes in a name survive',
   ub.get('zzfrob') == want, (ub.get('zzfrob'), want))
ok('plain run: no icon or data URI is stored', 'data:' not in lines[0] and '"img"' not in lines[0], lines[0][:300])
PY
  if ls "$HIST".tmp.* >/dev/null 2>&1; then fail "plain run: the history file is replaced whole (no temp file left behind)"
  else pass "plain run: the history file is replaced whole (no temp file left behind)"; fi
  [ ! -s "$RUN/python-calls" ] && pass "plain run: the plain path never needs python" \
    || fail "plain run: the plain path never needs python (called: $(tr '\n' ';' < "$RUN/python-calls"))"
  exit "$failures"
)
failures=$((failures + $?))

# ── HISTORY_KEEP: only the newest runs remain ────────────────────────────────
keep_case() { # NAME KEEP(empty = default) LINES-BEFORE LINES-AFTER MESSAGE
  (
    failures=0
    setup_case "$1"
    quick_steps
    [ -n "$2" ] && HISTORY_KEEP="$2"
    local n=1
    : > "$HIST"
    while [ "$n" -le "$3" ]; do old_record "old-$n" $((NOW - 100000 + n)) >> "$HIST"; n=$((n + 1)); done
    cp "$HIST" "$RUN/before"
    run_plain > "$RUN/out" 2> "$RUN/err"
    pycheck "$1" "$HIST" "$RUN/before" "$4" "$5" <<'PY'
hist, before, after_n, msg = args
old, now = raw_lines(before), raw_lines(hist)
want = old[len(old) - (int(after_n) - 1):] if int(after_n) > 1 else []
last = parse(now[-1]) if now else None
ok(msg, len(now) == int(after_n) and now[:-1] == want, '%d lines; kept %s' % (len(now), [(parse(l) or {}).get('id') for l in now[:3]]))
ok(msg + ': the new run is the last line',
   isinstance(last, dict) and last.get('v') == 1 and not str(last.get('id', 'old-')).startswith('old-'),
   now[-1][:200] if now else 'empty')
PY
    exit "$failures"
  )
  failures=$((failures + $?))
}
keep_case keep-default "" 200 200 "by default the newest 200 runs are kept"
keep_case keep-full 3 3 3 "with HISTORY_KEEP runs already kept, the oldest is dropped for the new one"
keep_case keep-room 3 1 2 "with fewer than HISTORY_KEEP runs, nothing is dropped"

# ── A plain run stopped by the network ───────────────────────────────────────
(
  failures=0
  setup_case netstop
  STEPS=(
    "Homebrew · upgrade¦true¦\"$tmp/tool\" \"$RUN/brew\""
    "npm · update globals¦true¦\"$tmp/tool\" \"$RUN/npm\""
    "Report¦true¦:"
  )
  STEP_KEY=(homebrew npm report); STEP_ON=(1 1 1); TOTAL=3
  NET_TIMEOUT=2
  echo up > "$RUN/net"
  ut_net_probe() { cat "$RUN/net"; }
  ( wait_for_file "$RUN/brew.started" && echo "down no default route (test)" > "$RUN/net" ) &
  run_plain > "$RUN/out" 2> "$RUN/err"; rc=$?
  [ "$rc" = "75" ] && [ ! -f "$RUN/npm.started" ] && pass "network stop: the run stopped for the network (test setup)" \
    || fail "network stop: the run stopped for the network (test setup: rc $rc)"
  pycheck "network stop" "$HIST" <<'PY'
lines = raw_lines(args[0])
need('network stop: the stopped run is recorded once, before the exit code is returned', len(lines) == 1, '%d lines' % len(lines))
r = parse(lines[0])
need('network stop: the record is valid JSON', isinstance(r, dict), lines[0][:300])
ok('network stop: the run is recorded as halted', r.get('out') == 'halted', r.get('out'))
ok('network stop: the record says the network stopped it', r.get('halt') == 'network', r.get('halt'))
ok('network stop: the run is recorded as plain', r.get('mode') == 'plain', r.get('mode'))
steps = r.get('steps') or []
ok('network stop: only the step that ran is recorded, as stopped (not as failed)',
   [(s.get('k'), s.get('s')) for s in steps] == [('homebrew', 'stopped')], steps)
PY
  exit "$failures"
)
failures=$((failures + $?))

# ── Offline before the first step: nothing ran, nothing is recorded ──────────
(
  failures=0
  setup_case offline
  STEPS=(
    "Homebrew · upgrade¦true¦\"$tmp/tool\" \"$RUN/brew\""
    "Report¦true¦:"
  )
  STEP_KEY=(homebrew report); STEP_ON=(1 1); TOTAL=2
  NET_TIMEOUT=1
  echo "down no default route (test)" > "$RUN/net"
  ut_net_probe() { cat "$RUN/net"; }
  old_record earlier $((NOW - 3600)) > "$HIST"
  cp "$HIST" "$RUN/before"
  run_plain > "$RUN/out" 2> "$RUN/err"; rc=$?
  [ "$rc" = "75" ] && [ ! -f "$RUN/brew.started" ] && pass "offline: no step started (test setup)" \
    || fail "offline: no step started (test setup: rc $rc)"
  cmp -s "$HIST" "$RUN/before" && pass "offline: a run in which no step ran is not recorded" \
    || fail "offline: a run in which no step ran is not recorded ($(wc -l < "$HIST" | tr -d ' ') lines now)"
  exit "$failures"
)
failures=$((failures + $?))

# ── The dashboard ────────────────────────────────────────────────────────────
# The real ut_web_start (it serves on 127.0.0.1); the browser is `open`, stubbed
# here: what history.json holds at that moment is what the page first loads.
cat > "$tmp/probe.py" <<'PY'
# After each state.json: if it names a record, is that record already served?
import json, sys
state_path, served_path, hist_path, phase, out_path = sys.argv[1:6]
def load(p):
    try:
        with open(p, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
st = load(state_path) or {}
h = st.get('hist')
row = {'phase': phase, 'elapsed': st.get('elapsed')}
if h is None:
    row['verdict'] = 'nohist'
elif not (isinstance(h, dict) and isinstance(h.get('id'), str) and h.get('id') and isinstance(h.get('rev'), int)):
    row.update(verdict='hist is not {"id":"...","rev":N}', hist=h)
else:
    row.update(id=h['id'], rev=h['rev'])
    served = load(served_path)
    runs = served.get('runs') if isinstance(served, dict) else None
    if not isinstance(runs, list):
        row['verdict'] = 'history.json missing or without runs'
    else:
        mine = [r for r in runs if isinstance(r, dict) and r.get('id') == h['id']]
        filed = None
        try:
            with open(hist_path, encoding='utf-8') as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and r.get('id') == h['id']:
                        filed = r
        except OSError:
            pass
        if not mine:
            row['verdict'] = 'history.json lacks the record'
        elif mine[0] != filed:
            row['verdict'] = 'history.json serves another version of the record'
        else:
            row['verdict'] = 'served'
with open(out_path, 'a') as f:
    f.write(json.dumps(row) + '\n')
PY
dashboard_stubs() {
  AUTO_START=1
  ut_web_stop() { [ -n "${WEB_PID:-}" ] && kill "$WEB_PID" 2>/dev/null; return 0; }
  ut_icon_site() { :; }
  ut_save_enabled() { :; }
  ut_preflight() { mkdir -p "$1"; }
  ut_save_durations() { :; }
  ut_generate_report() { [ -f "$RUN/updates-retry" ] && cp "$RUN/updates-retry" "$UT_WEB_DATA"; return 0; }
  ut_web_summary_line() { kill "$WEB_PID" 2>/dev/null; }
  open() {
    : > "$RUN/opened"
    [ -f "$WEB_DIR/history.json" ] && cp "$WEB_DIR/history.json" "$RUN/at-open.json"
    return 0
  }
}

(
  failures=0
  setup_case dashboard
  dashboard_stubs
  eval "real_$(declare -f ut_web_state)"
  ut_web_state() {
    real_ut_web_state "$@"
    local rc=$?
    [ -n "${WEB_DIR:-}" ] && [ -f "$WEB_DIR/state.json" ] \
      && "$PY" -I "$tmp/probe.py" "$WEB_DIR/state.json" "$WEB_DIR/history.json" "$HIST" "${1:-run}" "$RUN/probe"
    return "$rc"
  }
  STEPS=(
    "Homebrew · upgrade¦true¦sleep 1.1"
    "Widgetctl · refresh¦true¦[ -f \"$RUN/fixed\" ] && sleep 1.1"
    "Report¦true¦cp \"$RUN/updates\" \"\$UT_WEB_DATA\""
  )
  STEP_KEY=(homebrew widgetctl report); STEP_ON=(1 1 1); TOTAL=3
  printf '%s\n' 'node|node|20.1.0|22.3.0|https://nodejs.org/en/blog|' 'firefox|Firefox|130.0|131.0||staged' > "$RUN/updates"
  { old_record older $((NOW - 172800)); old_record newer $((NOW - 86400)); } > "$HIST"
  cp "$HIST" "$RUN/before"
  : > "$RUN/probe"

  before="$(date +%s)"
  run_web < /dev/null > "$RUN/out" 2> "$RUN/err"
  after="$(date +%s)"
  [ -f "$RUN/opened" ] && [ "${STATUS[0]}:${STATUS[1]}" = "done:fail" ] \
    && pass "dashboard: the dashboard opened and the fake steps ran as planned (test setup)" \
    || fail "dashboard: the dashboard opened and the fake steps ran as planned (test setup: ${STATUS[*]}; $(cat "$RUN/err"))"
  pycheck "dashboard" "$RUN/at-open.json" "$RUN/before" <<'PY'
at_open, before = args
hj = load(at_open)
need('dashboard: history.json is in place before the browser opens', hj is not None, 'no readable history.json when open ran')
earlier = [parse(l) for l in raw_lines(before)]
ok('dashboard: the first history.json lists the earlier runs, newest first',
   isinstance(hj, dict) and hj.get('v') == 1 and hj.get('runs') == list(reversed(earlier)), hj)
PY
  pycheck "dashboard" "$HIST" "$RUN/before" "$WEB_DIR/state.json" "$WEB_DIR/history.json" "$RUN/probe" \
      "$before" "$after" "$$" "${STEP_SEC[0]:-}" "${STEP_SEC[1]:-}" <<'PY'
hist, before, state, served, probe, t0, t1, pid, t_brew, t_widget = args
old, now = raw_lines(before), raw_lines(hist)
need('dashboard: the run appends exactly one record after the earlier ones',
     len(now) == len(old) + 1 and now[:-1] == old, '%d lines' % len(now))
r = parse(now[-1])
need('dashboard: the record is valid JSON', isinstance(r, dict), now[-1][:300])
ok('dashboard: a run from the dashboard is recorded as dashboard', r.get('mode') == 'dashboard', r.get('mode'))
at = r.get('at')
ok('dashboard: the record starts when the steps started', isinstance(at, int) and int(t0) <= at <= int(t1), (at, t0, t1))
ok('dashboard: the record id is the start time and the process id', r.get('id') == '%s-%s' % (at, pid), (r.get('id'), pid))
st = load(state) or {}
ok("dashboard: the record's length is what the dashboard clock shows at the end",
   r.get('sec') == st.get('elapsed') and isinstance(r.get('sec'), int), (r.get('sec'), st.get('elapsed')))
ok('dashboard: a run with a failed step is recorded as failed', r.get('out') == 'fail', r.get('out'))
by = dict((s.get('k'), s) for s in (r.get('steps') or []))
ok('dashboard: the steps that ran are recorded, never the report',
   by == {'homebrew': {'k': 'homebrew', 'n': 'Homebrew', 's': 'done', 't': int(t_brew), 'slug': 'homebrew'},
          'widgetctl': {'k': 'widgetctl', 'n': 'Widgetctl', 's': 'fail', 't': int(t_widget)}}, r.get('steps'))
ok("dashboard: the report's records are recorded as updates",
   sorted(u.get('k') for u in (r.get('up') or [])) == ['firefox', 'node'], r.get('up'))
hj = load(served) or {}
ok('dashboard: history.json then lists this run first, then the earlier runs',
   [x.get('id') for x in hj.get('runs', [])] == [r.get('id')] + [parse(l)['id'] for l in reversed(old)],
   [x.get('id') for x in hj.get('runs', [])] if isinstance(hj.get('runs'), list) else hj)
rows = [json.loads(l) for l in raw_lines(probe)]
bad = [x for x in rows if x['verdict'] not in ('nohist', 'served')]
ok('dashboard: every state.json naming the record is written after history.json serves that record', not bad, bad[:3])
done = [x for x in rows if x['phase'] == 'done']
ok("dashboard: the finished run's state.json names its record",
   done != [] and all(x.get('id') == r.get('id') for x in done), done[:3])
h = st.get('hist')
ok('dashboard: state.json names the record by id and revision',
   isinstance(h, dict) and h.get('id') == r.get('id') and isinstance(h.get('rev'), int), h)
PY

  # Retry the failed step: it succeeds now, and the report has a newer node.
  cp "$HIST" "$RUN/history-1"; cp "$WEB_DIR/state.json" "$RUN/state-1.json"
  probe_lines="$(wc -l < "$RUN/probe" | tr -d ' ')"
  : > "$RUN/fixed"
  printf '%s\n' 'widgetctl|Widgetctl|1.0|2.0||' 'node|node|22.3.0|22.4.0|https://nodejs.org/x|' > "$RUN/updates-retry"
  ( exec sleep 60 ) &
  WEB_PID=$!
  disown "$WEB_PID" 2>/dev/null
  ut_web_retry widgetctl > "$RUN/retry.out" 2> "$RUN/retry.err"
  kill "$WEB_PID" 2>/dev/null
  [ "${STATUS[1]}" = "done" ] && pass "retry: the retried step succeeded (test setup)" \
    || fail "retry: the retried step succeeded (test setup: ${STATUS[*]})"
  pycheck "retry" "$HIST" "$RUN/history-1" "$RUN/before" "$RUN/state-1.json" "$WEB_DIR/state.json" \
      "$WEB_DIR/history.json" "$RUN/probe" "$probe_lines" <<'PY'
hist, hist1, before, state1, state, served, probe, skip = args
old, first = raw_lines(before), raw_lines(hist1)
need("retry: the first round left this run's record to rewrite",
     len(first) == len(old) + 1 and isinstance(parse(first[-1]), dict), '%d lines, %d before the run' % (len(first), len(old)))
r1 = parse(first[-1])
h1 = (load(state1) or {}).get('hist') or {}
now = raw_lines(hist)
recs = [parse(l) for l in now]
ok('retry: a retry adds no record', len(now) == len(first), '%d lines, was %d' % (len(now), len(first)))
mine = [x for x in recs if isinstance(x, dict) and x.get('id') == r1.get('id')]
need('retry: the run keeps one record under the same id', len(mine) == 1, [(x or {}).get('id') for x in recs])
r = mine[0]
ok('retry: the record keeps when and how the run started', r.get('at') == r1.get('at') and r.get('mode') == 'dashboard',
   (r.get('at'), r.get('mode')))
steps = r.get('steps') or []
w = [s for s in steps if s.get('k') == 'widgetctl']
ok("retry: the retried step's entry replaces its earlier one", len(w) == 1 and w[0].get('s') == 'done', w)
b1 = [s for s in (r1.get('steps') or []) if s.get('k') == 'homebrew']
ok('retry: a step that was not retried keeps its entry', [s for s in steps if s.get('k') == 'homebrew'] == b1, steps)
st = load(state) or {}
ok("retry: the retry's time is added to the run's length",
   isinstance(r.get('sec'), int) and r.get('sec') > r1.get('sec', 0) and r.get('sec') == r1.get('sec', 0) + st.get('elapsed', -1),
   (r1.get('sec'), st.get('elapsed'), r.get('sec')))
ok('retry: the outcome is worked out again (nothing has failed now)', r.get('out') == 'ok', r.get('out'))
up = r.get('up') or []
ks = [u.get('k') for u in up]
node = [u for u in up if u.get('k') == 'node']
ok('retry: the updates are merged by key, the latest winning',
   sorted(ks) == ['firefox', 'node', 'widgetctl'] and len(node) == 1 and node[0].get('w') == '22.4.0', up)
h = st.get('hist') or {}
ok('retry: state.json names the same record with a higher revision',
   h.get('id') == r1.get('id') and isinstance(h.get('rev'), int) and isinstance(h1.get('rev'), int) and h['rev'] > h1['rev'],
   (h1, h))
hj = load(served) or {}
runs = hj.get('runs') if isinstance(hj.get('runs'), list) else []
ok('retry: history.json serves the rewritten record first', runs[:1] == [r], runs[:1])
rows = [json.loads(l) for l in raw_lines(probe)][int(skip):]
bad = [x for x in rows if x['verdict'] not in ('nohist', 'served')]
ok('retry: every state.json naming the record is written after history.json serves that version', not bad, bad[:3])
PY
  exit "$failures"
)
failures=$((failures + $?))

# ── A corrupt history file ───────────────────────────────────────────────────
(
  failures=0
  setup_case corrupt
  dashboard_stubs
  quick_steps
  { old_record older $((NOW - 172800)); echo 'this line is not a run record'; old_record newer $((NOW - 86400)); } > "$HIST"
  cp "$HIST" "$RUN/before"
  run_web < /dev/null > "$RUN/out" 2> "$RUN/err"
  [ -f "$RUN/opened" ] && [ "${STATUS[0]}" = "done" ] && pass "corrupt file: the dashboard opened and the step ran (test setup)" \
    || fail "corrupt file: the dashboard opened and the step ran (test setup: ${STATUS[*]})"
  pycheck "corrupt file" "$RUN/at-open.json" "$HIST" "$RUN/before" "$RUN/err" "$WEB_DIR/history.json" <<'PY'
at_open, hist, before, err, served = args
hj = load(at_open)
e = hj.get('error') if isinstance(hj, dict) else None
ok('corrupt file: before the browser opens, history.json is an error naming the file and the line',
   isinstance(hj, dict) and hj.get('v') == 1 and isinstance(e, str) and hist in e and 'line 2' in e,
   hj if hj is not None else 'no readable history.json when open ran')
told = [l for l in open(err, encoding='utf-8', errors='replace').read().splitlines() if hist in l]
ok('corrupt file: the terminal is told once, naming the file and the line', len(told) == 1 and 'line 2' in told[0], told)
old, now = raw_lines(before), raw_lines(hist)
ok('corrupt file: the file is not repaired: its lines stay as they were', now[:len(old)] == old, now[:3])
last = parse(now[-1]) if now else None
ok('corrupt file: the new run is still appended',
   len(now) == len(old) + 1 and isinstance(last, dict) and last.get('v') == 1 and last.get('mode') == 'dashboard',
   now[-1][:200] if now else 'empty')
hj = load(served) or {}
ok('corrupt file: history.json still reports the corrupt line once the run is recorded',
   'line 2' in str(hj.get('error', '')), hj)
PY
  exit "$failures"
)
failures=$((failures + $?))

# ── A history file that cannot be written ────────────────────────────────────
(
  failures=0
  setup_case readonly
  quick_steps
  mkdir -p "$RUN/ro"; chmod 555 "$RUN/ro"
  HIST="$RUN/ro/history"; export UPDATETOOLS_HISTORY_FILE="$HIST"
  if [ -w "$RUN/ro" ]; then
    fail "unwritable history: the test can make a read-only directory (running as root?)"
    exit "$failures"
  fi
  run_plain > "$RUN/out" 2> "$RUN/err"; rc=$?
  [ "$rc" = "0" ] && [ "${STATUS[0]}" = "done" ] && grep -q "Done" "$RUN/out" \
    && pass "unwritable history: the run still completes" \
    || fail "unwritable history: the run still completes (rc $rc, ${STATUS[*]})"
  told="$(grep -F "$HIST" "$RUN/err")"
  n="$(printf '%s' "$told" | grep -c .)"
  if [ "$n" = "1" ] && printf '%s\n' "$told" | grep -Fq "updatetools: could not record this run in $HIST: " \
     && [ -n "${told#updatetools: could not record this run in $HIST: }" ]; then
    pass "unwritable history: one stderr line says the run could not be recorded, where, and why"
  else
    fail "unwritable history: one stderr line says the run could not be recorded, where, and why (stderr: $(tr '\n' '|' < "$RUN/err"))"
  fi
  exit "$failures"
)
failures=$((failures + $?))

# ── A run ended by SIGTERM after a step started ──────────────────────────────
cat > "$tmp/sig.sh" <<'EOF'
RUN="$1"
set --
export UPDATETOOLS_LIB_ONLY=1
source "$ROOT/updatetools"
export PATH="$SAFE_PATH"
STEPS=(
  "Homebrew · upgrade¦true¦\"$TOOL\" \"$RUN/brew\""
  "npm · update globals¦true¦\"$TOOL\" \"$RUN/npm\""
  "Report¦true¦:"
)
STEP_KEY=(homebrew npm report); STEP_ON=(1 1 1); TOTAL=3
STATUS=(pending pending pending); STEP_WHY=("" "" "")
sudo() { return 0; }
ut_needs_sudo() { return 1; }
ut_net_probe() { echo up; }
ut_report_capture_cli() { :; }
ut_report_capture_brew() { :; }
ut_notify_end() { return 0; }
NET_TIMEOUT=0; STALL_TIMEOUT=0; STOP_GRACE=10; DIAG_DIR="$RUN/diag"
run_plain
echo finished > "$RUN/finished"
EOF
(
  failures=0
  RUN="$tmp/sigterm"; mkdir -p "$RUN"
  before="$(date +%s)"
  ROOT="$ROOT" TOOL="$tmp/tool" UPDATETOOLS_HISTORY_FILE="$RUN/history" \
    bash "$tmp/sig.sh" "$RUN" > "$RUN/out" 2> "$RUN/err" &
  pid=$!
  if wait_for_file "$RUN/brew.started"; then
    kill -TERM "$pid"
  else
    fail "SIGTERM: the step started (test setup)"
    kill -KILL "$pid" 2>/dev/null
  fi
  wait "$pid"; rc=$?
  after="$(date +%s)"
  [ "$rc" = "143" ] && [ ! -f "$RUN/npm.started" ] && pass "SIGTERM: the run was stopped by the signal (test setup)" \
    || fail "SIGTERM: the run was stopped by the signal (test setup: rc $rc)"
  pycheck "SIGTERM" "$RUN/history" "$pid" "$before" "$after" <<'PY'
hist, pid, t0, t1 = args
lines = raw_lines(hist)
need('SIGTERM: a run ended by a signal once a step had started is recorded once', len(lines) == 1, '%d lines' % len(lines))
r = parse(lines[0])
need('SIGTERM: the record is valid JSON', isinstance(r, dict), lines[0][:300])
ok('SIGTERM: the run is recorded as halted', r.get('out') == 'halted', r.get('out'))
ok('SIGTERM: the record says a signal stopped it', r.get('halt') == 'signal', r.get('halt'))
ok('SIGTERM: the record names the run that was stopped',
   isinstance(r.get('at'), int) and int(t0) <= r['at'] <= int(t1) and r.get('id') == '%s-%s' % (r.get('at'), pid), r.get('id'))
ok('SIGTERM: the step that was running is recorded as stopped, the one never started is not recorded',
   [(s.get('k'), s.get('s')) for s in (r.get('steps') or [])] == [('homebrew', 'stopped')], r.get('steps'))
PY
  exit "$failures"
)
failures=$((failures + $?))

[ ! -f "$tmp/open-binary-used" ] && pass "no browser was opened (the test's own check)" \
  || fail "no browser was opened (the test's own check: $(cat "$tmp/open-binary-used"))"

if [ "$failures" -eq 0 ]; then
  echo "all history tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
