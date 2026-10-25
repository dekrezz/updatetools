#!/usr/bin/env bash
# A run's scratch files are where only this user can reach them, and the
# dashboard's server takes nothing it should not.
#   * TMPDIR unset, or a directory others can write to (a shared /tmp), is
#     replaced by this user's own temporary directory: the run names its files
#     after its PID, and another user must not be able to plant one first;
#   * the password prompt's directory (askpass, request, reply) is made new for
#     each run with mktemp: 0700, never one that was already there. When it
#     cannot be made, the run says so and does not start. An unfinished run's
#     is swept, and only that run's;
#   * the server writes the password reply only into a file, never through a
#     link planted at its path; refuses a body over its limit; and takes the
#     token only as the exact value of k, or as the cookie.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-scratch.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it, stop the server, remove $tmp.
trap 'cleanup; pkill -KILL -f "$tmp/" 2>/dev/null; chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$name"; else
    fail "$name (expected '$expected', got '$actual')"
  fi
}

# ---------------------------------------------------------------------------
# TMPDIR: only a directory that is ours alone
# ---------------------------------------------------------------------------
user_tmp="$(getconf DARWIN_USER_TEMP_DIR)"; user_tmp="${user_tmp%/}"
# settled START — the TMPDIR a run exports, starting from START ("-": unset).
settled() {
  local script='f="$1"; set --; source "$f" >/dev/null 2>&1; t="$(printenv TMPDIR)"; printf "%s" "${t%/}"'
  if [ "$1" = - ]; then
    env -u TMPDIR HOME="$HOME" UPDATETOOLS_LIB_ONLY=1 bash -c "$script" _ "$ROOT/updatetools"
  else
    env TMPDIR="$1" HOME="$HOME" UPDATETOOLS_LIB_ONLY=1 bash -c "$script" _ "$ROOT/updatetools"
  fi
}
mkdir -p "$tmp/mine" "$tmp/shared" "$tmp/group"
chmod 700 "$tmp/mine"; chmod 1777 "$tmp/shared"; chmod 770 "$tmp/group"
assert_eq "TMPDIR unset: this user's own temporary directory" "$user_tmp" "$(settled -)"
assert_eq "TMPDIR=/tmp, shared with every user: this user's own instead" "$user_tmp" "$(settled /tmp)"
assert_eq "a TMPDIR anyone can write to: this user's own instead" "$user_tmp" "$(settled "$tmp/shared")"
assert_eq "a TMPDIR its group can write to: this user's own instead" "$user_tmp" "$(settled "$tmp/group")"
assert_eq "a TMPDIR that does not exist: this user's own instead" "$user_tmp" "$(settled "$tmp/missing")"
assert_eq "a TMPDIR that is ours alone is kept" "$tmp/mine" "$(settled "$tmp/mine")"

# ---------------------------------------------------------------------------
# The password prompt's directory
# ---------------------------------------------------------------------------
scratch="${TMPDIR%/}"
planted="$scratch/updatetools-wrap-$$"
mkdir -p "$planted"; printf 'planted\n' > "$planted/rep"; chmod 777 "$planted"
ut_make_wrap_dir; rc=$?
assert_eq "the password prompt's directory is made" 0 "$rc"
[ -n "${WRAP_DIR:-}" ] && [ "$WRAP_DIR" != "$planted" ] \
  && pass "a directory already at the run's name is never used" \
  || fail "a directory already at the run's name is never used (got '${WRAP_DIR:-}')"
case "${WRAP_DIR:-}" in
  "$scratch"/updatetools-wrap-$$.*) pass "it is in TMPDIR, named after the run" ;;
  *) fail "it is in TMPDIR, named after the run (got '${WRAP_DIR:-}')" ;;
esac
assert_eq "it is its owner's only" "drwx------" "$(stat -f %Sp "${WRAP_DIR:-/nonexistent}" 2>/dev/null)"
assert_eq "it is owned by this user" "$(id -un)" "$(stat -f %Su "${WRAP_DIR:-/nonexistent}" 2>/dev/null)"
assert_eq "it is new: nothing is in it" "" "$(ls -A "${WRAP_DIR:-/nonexistent}" 2>&1)"
assert_eq "the password's reply goes in it" "${WRAP_DIR:-}/rep" "${PROMPT_REP:-}"
assert_eq "the prompt's request goes in it" "${WRAP_DIR:-}/req" "${PROMPT_REQ:-}"
first="${WRAP_DIR:-}"
ut_make_wrap_dir
[ -n "$first" ] && [ "${WRAP_DIR:-}" != "$first" ] && pass "each run gets a directory of its own" \
  || fail "each run gets a directory of its own"
if declare -f run_web | grep -q 'ut_make_wrap_dir'; then
  pass "the dashboard run makes its prompt directory this way"
else
  fail "the dashboard run makes its prompt directory this way"
fi

out="$( (TMPDIR="$tmp/nowhere"; ut_make_wrap_dir) 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && pass "a directory that cannot be made stops the run" || fail "a directory that cannot be made stops the run"
case "$out" in
  *"cannot create"*) pass "and says so" ;;
  *) fail "and says so (got '$out')" ;;
esac

mkdir -p "$scratch/updatetools-wrap-4242.abc123" "$scratch/updatetools-wrap-42420.def456"
ut_unfinished_run 4242 "" 2>/dev/null
[ -e "$scratch/updatetools-wrap-4242.abc123" ] && fail "an unfinished run's prompt directory is swept" \
  || pass "an unfinished run's prompt directory is swept"
[ -e "$scratch/updatetools-wrap-42420.def456" ] && pass "another run's is left alone" \
  || fail "another run's is left alone"

# ---------------------------------------------------------------------------
# The server
# ---------------------------------------------------------------------------
srv="$tmp/srv"; mkdir -p "$srv/wrap"
ut_web_server_py > "$srv/serve.py"
printf '%s' token > "$srv/.token"
printf '{"phase":"run","elapsed":0,"steps":[]}\n' > "$srv/state.json"
python3 "$srv/serve.py" "$srv" "$srv/.token" "$srv/wrap/rep" 30 "" 5 30 > "$srv/port" 2>/dev/null &
srv_pid=$!
n=0; while [ ! -s "$srv/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
PORT="$(head -1 "$srv/port")"
post() { curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H 'Cookie: ut=token' -H 'Content-Type: application/json' --data-binary "$1" "http://127.0.0.1:$PORT/prompt" 2>/dev/null; }
get() { curl -s -m 5 -o /dev/null -w '%{http_code}' ${2:+-H "Cookie: ut=$2"} "http://127.0.0.1:$PORT$1" 2>/dev/null; }

assert_eq "a reply reaches the run (test setup)" 204 "$(post '{"reply":"pw"}')"
rm -f "$srv/wrap/rep"

printf 'keep\n' > "$tmp/target"
ln -s "$tmp/target" "$srv/wrap/rep"
code="$(post '{"reply":"pw"}')"
assert_eq "the reply is never written through a link at its path" keep "$(cat "$tmp/target")"
[ "$code" != 204 ] && pass "and the page is not told it went through" || fail "and the page is not told it went through"
rm -f "$srv/wrap/rep"

printf 'keep\n' > "$tmp/target2"
ln -s "$tmp/target2" "$srv/wrap/rep.remember"
post '{"reply":"pw","remember":true}' >/dev/null
assert_eq "the box's answer is never written through a link at its path" keep "$(cat "$tmp/target2")"
rm -f "$srv/wrap/rep.remember" "$srv/wrap/rep"

python3 -I -c 'import json; print(json.dumps({"reply": "a" * (1 << 20)}))' > "$tmp/big.json"
assert_eq "a body over the limit is refused" 413 "$(post "@$tmp/big.json")"
[ -e "$srv/wrap/rep" ] && fail "and nothing is written for it" || pass "and nothing is written for it"

assert_eq "the token in the URL lets the page in (test setup)" 302 "$(get '/?k=token')"
assert_eq "a longer value that only starts with the token does not" 403 "$(get '/?k=tokenx')"
assert_eq "the token in the cookie lets the page in (test setup)" 200 "$(get /state.json token)"
assert_eq "a longer cookie that only starts with the token does not" 403 "$(get /state.json tokenx)"
kill "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null

if [ "$failures" -eq 0 ]; then
  echo "all private scratch tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
