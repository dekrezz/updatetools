#!/usr/bin/env bash
# Focused checks for step keys, enabled-file load, and --only/--skip selection.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-chooser-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp"
export UPDATETOOLS_ENABLED_FILE="$tmp/enabled"
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

assert_eq "homebrew key" "homebrew" "$(ut_step_key "Homebrew · update everything")"
assert_eq "uv key uses ribbon slug" "astral" "$(ut_step_key "uv · self + tools")"
assert_eq "cargo key uses ribbon slug" "rust" "$(ut_step_key "cargo · update binaries")"
assert_eq "codex key when icon empty" "codex" "$(ut_step_key "Codex CLI · update")"
assert_eq "vscode key when icon empty" "vscode" "$(ut_step_key "VS Code · extensions")"
assert_eq "report key" "report" "$(ut_step_key "Report · what changed")"

# Missing enabled file => all on
rm -f "$UPDATETOOLS_ENABLED_FILE"
ONLY_STEPS=""; SKIP_STEPS=""
ut_resolve_step_selection
assert_eq "missing file enables homebrew" "1" "${STEP_ON[0]}"
assert_eq "missing file enables report" "1" "${STEP_ON[$((TOTAL-1))]}"

# Saved subset
printf '%s\n' "npm" "report" > "$UPDATETOOLS_ENABLED_FILE"
ONLY_STEPS=""; SKIP_STEPS=""
ut_resolve_step_selection
assert_eq "saved file disables homebrew" "0" "${STEP_ON[0]}"
i=0
while [ "$i" -lt "$TOTAL" ]; do
  [ "${STEP_KEY[i]}" = "npm" ] && assert_eq "saved file enables npm" "1" "${STEP_ON[i]}"
  [ "${STEP_KEY[i]}" = "report" ] && assert_eq "saved file enables report" "1" "${STEP_ON[i]}"
  i=$((i+1))
done

# --only overrides saved file for this run
ONLY_STEPS="homebrew,github"
SKIP_STEPS=""
ut_resolve_step_selection
assert_eq "--only enables homebrew" "1" "${STEP_ON[0]}"
i=0
while [ "$i" -lt "$TOTAL" ]; do
  [ "${STEP_KEY[i]}" = "npm" ] && assert_eq "--only disables npm" "0" "${STEP_ON[i]}"
  [ "${STEP_KEY[i]}" = "github" ] && assert_eq "--only enables github" "1" "${STEP_ON[i]}"
  i=$((i+1))
done

# --skip on top of all-on
rm -f "$UPDATETOOLS_ENABLED_FILE"
ONLY_STEPS=""; SKIP_STEPS="astral,rust"
ut_resolve_step_selection
i=0
while [ "$i" -lt "$TOTAL" ]; do
  [ "${STEP_KEY[i]}" = "astral" ] && assert_eq "--skip disables astral" "0" "${STEP_ON[i]}"
  [ "${STEP_KEY[i]}" = "rust" ] && assert_eq "--skip disables rust" "0" "${STEP_ON[i]}"
  [ "${STEP_KEY[i]}" = "homebrew" ] && assert_eq "--skip leaves homebrew on" "1" "${STEP_ON[i]}"
  i=$((i+1))
done

# Persist after a simulated Start
ONLY_STEPS=""; SKIP_STEPS=""
ut_resolve_step_selection
for ((i=0;i<TOTAL;i++)); do STEP_ON[i]=0; done
STEP_ON[0]=1
ut_save_enabled
assert_eq "saved enabled file content" "homebrew" "$(cat "$UPDATETOOLS_ENABLED_FILE")"

# Unreadable enabled file must fail loudly
printf 'npm\n' > "$UPDATETOOLS_ENABLED_FILE"
chmod 000 "$UPDATETOOLS_ENABLED_FILE"
if ( ut_resolve_step_selection ) >/dev/null 2>"$tmp/err"; then
  fail "unreadable enabled file should exit"
else
  if grep -q "cannot read enabled-steps file" "$tmp/err"; then
    pass "unreadable enabled file errors specifically"
  else
    fail "unreadable enabled file wrong error: $(cat "$tmp/err")"
  fi
fi
chmod 600 "$UPDATETOOLS_ENABLED_FILE" 2>/dev/null || true

if [ "$failures" -ne 0 ]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall ok\n'
