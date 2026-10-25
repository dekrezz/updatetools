#!/usr/bin/env bash
# "Remember password" on the dashboard's administrator password sheet.
#
# Ticked, the password sudo accepted is sealed with a key that lives in this
# Mac's Secure Enclave, and the next run answers sudo with it without asking.
# The file holds no plaintext and cannot be opened anywhere but this Mac.
#   * a saved password sudo rejects (it was changed), or one that cannot be
#     opened on this Mac, is deleted, and the sheet says so with the box ticked;
#   * one that cannot be read right now is kept, and the sheet says why;
#   * unticked, a saved password is deleted;
#   * the password reaches the helper on stdin, never in its arguments;
#   * only the administrator password sheet offers the box, never a tool's own
#     prompt, and without a Secure Enclave the box is off and says why;
#   * `updatetools --forget-password` deletes it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-saved.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch" XDG_CACHE_HOME="$tmp/cache"
export UPDATETOOLS_SAVED_PASSWORD="$tmp/home/.config/updatetools/saved-password"
mkdir -p "$HOME/.config/updatetools" "$TMPDIR"
saved="$UPDATETOOLS_SAVED_PASSWORD"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it, stop the server,
# remove $tmp. WEB_PID stands for this shell below: cleanup must not kill it.
trap 'WEB_PID=""; cleanup; pkill -KILL -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else
    fail "$name (expected '$expected', got '$actual')"
  fi
}
assert_has() {
  local name="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) pass "$name" ;; *) fail "$name ('$needle' not in '$hay')" ;; esac
}

# ---------------------------------------------------------------------------
# The Secure Enclave helper itself (built from the source in the script)
# ---------------------------------------------------------------------------
secret='correct horse — батарея $1 "x"'
ut_password_helper check 2> "$tmp/check.err"; rc=$?
if [ "$rc" = 10 ]; then
  pass "# SKIP the Secure Enclave helper: this machine has no Secure Enclave"
elif [ "$rc" != 0 ]; then
  fail "the helper builds and finds the Secure Enclave (rc $rc: $(cat "$tmp/check.err"))"
else
  pass "the helper builds and finds the Secure Enclave"
  printf '%s\n' "$secret" | ut_password_helper seal "$saved"; rc=$?
  assert_eq "a password is sealed" 0 "$rc"
  assert_eq "the sealed file is readable by its owner only" "-rw-------" "$(stat -f %Sp "$saved" 2>/dev/null)"
  if grep -qF 'correct horse' "$saved" || grep -qF 'батарея' "$saved"; then
    fail "the sealed file does not hold the password"
  else
    pass "the sealed file does not hold the password"
  fi
  assert_eq "this Mac's Secure Enclave opens it, with no prompt" "$secret" "$(ut_password_helper open "$saved" < /dev/null)"

  # One byte of the ciphertext changed.
  python3 -I -c '
import base64, sys
l = open(sys.argv[1]).read().split("\n")
b = bytearray(base64.b64decode(l[3])); b[-1] ^= 1; l[3] = base64.b64encode(b).decode()
open(sys.argv[2], "w").write("\n".join(l))' "$saved" "$tmp/damaged"
  out="$(ut_password_helper open "$tmp/damaged" 2>/dev/null)"; rc=$?
  assert_eq "a damaged file cannot be opened" 3 "$rc"
  assert_eq "a damaged file gives nothing out" "" "$out"

  # The same file with another Mac's key handle in it.
  python3 -I -c '
import base64, os, sys
l = open(sys.argv[1]).read().split("\n")
l[1] = base64.b64encode(os.urandom(len(base64.b64decode(l[1])))).decode()
open(sys.argv[2], "w").write("\n".join(l))' "$saved" "$tmp/foreign"
  out="$(ut_password_helper open "$tmp/foreign" 2>/dev/null)"; rc=$?
  assert_eq "a password saved on another Mac cannot be opened here" 3 "$rc"
  assert_eq "a password saved on another Mac gives nothing out" "" "$out"

  bins="$(find "$XDG_CACHE_HOME/updatetools" -type f -name updatetools-password 2>/dev/null)"
  assert_eq "the helper is built once and kept" 1 "$(printf '%s\n' "$bins" | grep -c .)"
  assert_eq "the kept helper is its owner's only" "-rwx------" "$(stat -f %Sp "$bins" 2>/dev/null)"
  rm -f "$saved"
fi

# ---------------------------------------------------------------------------
# The run's side, with a stand-in helper (the real one is tested above)
# ---------------------------------------------------------------------------
WEB_DIR="$tmp/web"; mkdir -p "$WEB_DIR"
LOG="$tmp/run.log"; : > "$LOG"
T0=$SECONDS
PROMPT_REP="$tmp/rep"
WEB_PID=$$
SUDO_PW=""
PROMPT_TIMEOUT=5
ut_read_input_source() { UT_LAYOUT_NOW=English; UT_LAYOUT_ID=com.apple.keylayout.US; }
ut_remember_password_layout() { :; }

GOOD="new pass"
# Fake sudo: nothing cached; -S takes the password on stdin.
sudo() {
  case "$1" in
    -n) return 1 ;;
    -S) local pw; IFS= read -r pw; printf '%s\n' "$pw" >> "$tmp/sudo-got"; [ "$pw" = "$GOOD" ] ;;
    *) return 0 ;;
  esac
}
# Stand-in helper: keeps what it was given to seal in plain text, so the test
# can see it; HELPER_* make it fail the way the real one does.
HELPER_CHECK_RC=0; HELPER_OPEN_RC=0; HELPER_SEAL_RC=0; HELPER_ERR=""
ut_password_helper() {
  printf '%s\n' "$*" >> "$tmp/helper-argv"
  case "$1" in
    check)
      [ "$HELPER_CHECK_RC" = 0 ] && return 0
      echo "updatetools-password: this Mac has no Secure Enclave" >&2; return "$HELPER_CHECK_RC" ;;
    seal)
      if [ "$HELPER_SEAL_RC" != 0 ]; then echo "updatetools-password: $HELPER_ERR" >&2; return "$HELPER_SEAL_RC"; fi
      cat > "$tmp/sealed-plain"; echo sealed > "$2" ;;
    open)
      if [ "$HELPER_OPEN_RC" != 0 ]; then echo "updatetools-password: $HELPER_ERR" >&2; return "$HELPER_OPEN_RC"; fi
      printf '%s' "$(cat "$tmp/sealed-plain")" ;;
  esac
}
save_plain() { printf '%s\n' "$1" > "$tmp/sealed-plain"; echo sealed > "$saved"; }
reset() {
  rm -f "$tmp/helper-argv" "$tmp/sudo-got" "$tmp"/state.* "$PROMPT_REP" "$PROMPT_REP.remember"
  HELPER_CHECK_RC=0; HELPER_OPEN_RC=0; HELPER_SEAL_RC=0; HELPER_ERR=""
  SUDO_PW=""; UT_WEB_NOTICE=""
}
seals() { grep -c '^seal ' "$tmp/helper-argv" 2>/dev/null || true; }

# jq-free JSON reads: field KEY of state FILE, as compact sorted JSON ("null" when absent).
field() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get(sys.argv[2]) if d.get("prompt") else "no prompt"
print(json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False))' "$1" "$2" 2>/dev/null
}
ask_of() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("ask", "") if d.get("prompt") else "-")' "$WEB_DIR/state.json" 2>/dev/null
}
# page REPLY:BOX... — what the page does, in the background: answer each prompt
# in turn (BOX 1 ticked, 0 not, - not offered), keeping the state.json it
# answered as state.1, state.2, …
page() {
  local n=0 last=none a pair
  for pair in "$@"; do
    n=$((n + 1)); a=""
    local w=0
    while [ "$w" -lt 100 ]; do
      a="$(ask_of)"
      [ -n "$a" ] && [ "$a" != "-" ] && [ "$a" != "$last" ] && break
      a=""; sleep 0.1; w=$((w + 1))
    done
    [ -n "$a" ] || return 1
    cp "$WEB_DIR/state.json" "$tmp/state.$n"
    last="$a"
    [ "${pair##*:}" != "-" ] && printf '%s' "${pair##*:}" > "$PROMPT_REP.remember"
    printf '%s\n' "${pair%:*}" > "$PROMPT_REP"
  done
}

# A saved password answers sudo, and nothing is asked.
reset; save_plain "$GOOD"
seq0="${UT_PROMPT_SEQ:-0}"
sudo_prime; rc=$?
assert_eq "a saved password sudo accepts lets the run go on" 0 "$rc"
assert_eq "a saved password is not asked for" "$seq0" "${UT_PROMPT_SEQ:-0}"
assert_eq "sudo got the saved password" "$GOOD" "$(tail -1 "$tmp/sudo-got" 2>/dev/null)"
assert_eq "the saved password answers the privileged steps' own sudo prompts" "$GOOD" "$SUDO_PW"
[ -f "$saved" ] && pass "an accepted saved password is kept" || fail "an accepted saved password is kept"

# Nothing saved: the box is offered unticked; ticked, only the accepted password is sealed.
reset; rm -f "$saved" "$tmp/sealed-plain"
page "nope:1" "$GOOD:1" & pg=$!
sudo_prime; rc=$?
wait "$pg" || fail "the page saw both prompts"
assert_eq "a typed password sudo accepts lets the run go on" 0 "$rc"
assert_eq "with nothing saved, the box is offered unticked" '{"ok":true,"on":false}' "$(field "$tmp/state.1" remember)"
assert_eq "after a rejected password, the box keeps the tick it was given" '{"ok":true,"on":true}' "$(field "$tmp/state.2" remember)"
assert_eq "ticked, the accepted password is sealed" "$GOOD" "$(cat "$tmp/sealed-plain" 2>/dev/null)"
assert_eq "a rejected password is not sealed" 1 "$(seals)"
[ -f "$saved" ] && pass "the sealed password is saved" || fail "the sealed password is saved"
if grep -qF "$GOOD" "$tmp/helper-argv" 2>/dev/null || grep -qF nope "$tmp/helper-argv" 2>/dev/null; then
  fail "the password never reaches the helper's arguments"
else
  pass "the password never reaches the helper's arguments"
fi

# A saved password sudo rejects (it was changed) is deleted, and the sheet says so.
reset; save_plain "old pass"
page "$GOOD:1" & pg=$!
sudo_prime; rc=$?
wait "$pg" || fail "the page saw the prompt"
assert_eq "after a rejected saved password, the typed one lets the run go on" 0 "$rc"
assert_has "the sheet says the saved password was not accepted" "was not accepted" "$(field "$tmp/state.1" prompt)"
assert_has "the sheet says the rejected saved password was deleted" "deleted" "$(field "$tmp/state.1" prompt)"
assert_eq "after a rejected saved password, the box is ticked" '{"ok":true,"on":true}' "$(field "$tmp/state.1" remember)"
assert_eq "the new password is sealed in its place" "$GOOD" "$(cat "$tmp/sealed-plain" 2>/dev/null)"

reset; save_plain "old pass"
page "$GOOD:0" & pg=$!
sudo_prime >/dev/null 2>&1
wait "$pg"
[ -f "$saved" ] && fail "a rejected saved password is deleted" || pass "a rejected saved password is deleted"

# One that cannot be opened on this Mac (another Mac's, damaged) is deleted.
reset; save_plain "$GOOD"; HELPER_OPEN_RC=3; HELPER_ERR="it was saved on another Mac"
page "$GOOD:0" & pg=$!
sudo_prime >/dev/null 2>&1; rc=$?
wait "$pg" || fail "the page saw the prompt"
assert_eq "after a saved password that cannot be opened, the typed one lets the run go on" 0 "$rc"
assert_has "the sheet says the saved password could not be opened" "could not be opened" "$(field "$tmp/state.1" prompt)"
assert_has "the sheet says it was deleted" "deleted" "$(field "$tmp/state.1" prompt)"
[ -f "$saved" ] && fail "a saved password that cannot be opened is deleted" || pass "a saved password that cannot be opened is deleted"

# One that cannot be read right now is kept, and the sheet says why; unticked, it is deleted.
reset; save_plain "$GOOD"; HELPER_OPEN_RC=1; HELPER_ERR="the Secure Enclave did not open it (is this Mac locked?)"
page "$GOOD:-" & pg=$!
sudo_prime >/dev/null 2>&1; rc=$?
wait "$pg" || fail "the page saw the prompt"
assert_eq "after a saved password that cannot be read, the typed one lets the run go on" 0 "$rc"
assert_has "the sheet gives the helper's reason" "is this Mac locked?" "$(field "$tmp/state.1" prompt)"
assert_eq "with a saved password, the box is ticked" '{"ok":true,"on":true}' "$(field "$tmp/state.1" remember)"
[ -f "$saved" ] && pass "a saved password that cannot be read right now is kept" || fail "a saved password that cannot be read right now is kept"
assert_eq "a box the page did not answer changes nothing" 0 "$(seals)"

reset; save_plain "$GOOD"; HELPER_OPEN_RC=1; HELPER_ERR="busy"
page "$GOOD:0" & pg=$!
sudo_prime >/dev/null 2>&1
wait "$pg"
[ -f "$saved" ] && fail "unticked, the saved password is deleted" || pass "unticked, the saved password is deleted"
assert_eq "unticked, nothing is sealed" 0 "$(seals)"

# A seal that fails does not stop the run, and says so.
reset; rm -f "$saved"; HELPER_SEAL_RC=1; HELPER_ERR="cannot create a Secure Enclave key"
page "$GOOD:1" & pg=$!
sudo_prime 2> "$tmp/prime.err"; rc=$?
wait "$pg"
assert_eq "a password that could not be saved still lets the run go on" 0 "$rc"
assert_has "the dashboard says the password was not saved, and why" "cannot create a Secure Enclave key" "${UT_WEB_NOTICE:-}"
assert_has "the terminal says the password was not saved" "not saved" "$(cat "$tmp/prime.err")"

# Without a Secure Enclave the box is off, with the reason.
reset; rm -f "$saved"; HELPER_CHECK_RC=10
page "$GOOD:-" & pg=$!
sudo_prime >/dev/null 2>&1
wait "$pg"
assert_eq "without a Secure Enclave the box is off and says why" '{"ok":false,"why":"this Mac has no Secure Enclave"}' "$(field "$tmp/state.1" remember)"
assert_eq "without a Secure Enclave nothing is sealed" 0 "$(seals)"

# A tool's own prompt (an SSH key, a pkg's sudo) never offers the box.
reset
page "passphrase:-" & pg=$!
ut_web_ask "Enter passphrase for key '/Users/me/.ssh/id_ed25519':"
wait "$pg"
assert_eq "a tool's own prompt does not offer the box" null "$(field "$tmp/state.1" remember)"

# ---------------------------------------------------------------------------
# The server: the box's answer goes next to the reply, before it
# ---------------------------------------------------------------------------
srv="$tmp/srv"; mkdir -p "$srv"
ut_web_server_py > "$srv/serve.py"
printf '%s' token > "$srv/.token"
printf '{"phase":"run","elapsed":0,"steps":[]}\n' > "$srv/state.json"
python3 "$srv/serve.py" "$srv" "$srv/.token" "$srv/rep" 30 "" 5 30 > "$srv/port" 2>/dev/null &
srv_pid=$!
n=0; while [ ! -s "$srv/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
PORT="$(head -1 "$srv/port")"
post() { curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST -H 'Cookie: ut=token' -H 'Content-Type: application/json' --data "$1" "http://127.0.0.1:$PORT/prompt"; }
assert_eq "the server takes a reply with the box ticked" 204 "$(post '{"reply":"pw","remember":true}')"
assert_eq "ticked, the server writes 1 next to the reply" 1 "$(cat "$srv/rep.remember" 2>/dev/null)"
assert_eq "the reply itself is unchanged" pw "$(cat "$srv/rep" 2>/dev/null)"
assert_eq "the box's answer is its owner's only" "-rw-------" "$(stat -f %Sp "$srv/rep.remember" 2>/dev/null)"
post '{"reply":"pw","remember":false}' >/dev/null
assert_eq "unticked, the server writes 0" 0 "$(cat "$srv/rep.remember" 2>/dev/null)"
rm -f "$srv/rep.remember"
post '{"reply":"pw"}' >/dev/null
[ -e "$srv/rep.remember" ] && fail "a reply without the box writes no answer for it" || pass "a reply without the box writes no answer for it"
kill "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null

# ---------------------------------------------------------------------------
# The page: the box, and what it posts
# ---------------------------------------------------------------------------
ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };
const fn = (name) => {
  const a = html.indexOf(`function ${name}(`), b = html.indexOf('\n  }\n', a);
  if (a < 0 || b < 0) { ok(`helper ${name} found`, false); return null; }
  return eval('(' + html.slice(a, b) + '\n  })');
};
ok('the sheet has a Remember password box', /<input type="checkbox" id="pw-remember-box"/.test(html)
  && /Remember password/.test(html));
ok('the sheet says the password is encrypted on this Mac', /encrypted on this Mac/i.test(html));
ok('the sheet no longer says the password is never stored', !/never stored/.test(html));
const rememberView = fn('rememberView'), promptBody = fn('promptBody');
if (rememberView && promptBody) {
  const none = rememberView({ prompt: 'Password' });
  ok('no box for a prompt that does not offer it', none.show === false);
  const on = rememberView({ prompt: 'Password', remember: { ok: true, on: true } });
  ok('a ticked box', on.show && on.on && !on.disabled);
  const off = rememberView({ prompt: 'Password', remember: { ok: true, on: false } });
  ok('an unticked box', off.show && !off.on && !off.disabled);
  const na = rememberView({ prompt: 'Password', remember: { ok: false, why: 'this Mac has no Secure Enclave' } });
  ok('an unavailable box is off, disabled, and says why', na.show && !na.on && na.disabled && /no Secure Enclave/.test(na.note));
  ok('ticked, the reply carries remember: true', JSON.stringify(promptBody('pw', on, true)) === '{"reply":"pw","remember":true}');
  ok('unticked, the reply carries remember: false', JSON.stringify(promptBody('pw', on, false)) === '{"reply":"pw","remember":false}');
  ok('without the box, the reply is the password alone', JSON.stringify(promptBody('pw', none, true)) === '{"reply":"pw"}');
  ok('an unavailable box sends nothing', JSON.stringify(promptBody('pw', na, true)) === '{"reply":"pw"}');
}
process.exit(fails ? 1 : 0);
NODE
[ $? -eq 0 ] && pass "the page offers the box and posts its answer" || fail "the page offers the box and posts its answer"

# ---------------------------------------------------------------------------
# updatetools --forget-password
# ---------------------------------------------------------------------------
echo sealed > "$saved"
out="$(env -u UPDATETOOLS_LIB_ONLY bash "$ROOT/updatetools" --forget-password 2>&1)"; rc=$?
assert_eq "--forget-password succeeds" 0 "$rc"
[ -f "$saved" ] && fail "--forget-password deletes the saved password" || pass "--forget-password deletes the saved password"
assert_has "--forget-password says it deleted it" "Deleted the saved administrator password" "$out"
out="$(env -u UPDATETOOLS_LIB_ONLY bash "$ROOT/updatetools" --forget-password 2>&1)"; rc=$?
assert_eq "--forget-password with nothing saved succeeds" 0 "$rc"
assert_has "--forget-password says when nothing was saved" "No saved administrator password" "$out"

if [ "$failures" -eq 0 ]; then
  echo "all saved password tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
