#!/usr/bin/env bash
# A cask whose app was lost mid-upgrade is repaired with reinstall, and pnpm
# updates find their global bin dir and never shadow a Homebrew-managed pnpm.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-broken.XXXXXX)"
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
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) pass "$name" ;; *) fail "$name (missing '$needle')" ;; esac
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) fail "$name (found '$needle')" ;; *) pass "$name" ;; esac
}

# ---------------------------------------------------------------------------
# Cask with its app missing from /Applications and a stale backup in Caskroom
# ---------------------------------------------------------------------------
export HOME="$tmp/home"
mkdir -p "$HOME/Applications"
caskroom="$tmp/Caskroom"
brew_log="$tmp/brew.log"
brew_reinstall_rc=0
: > "$brew_log"

brew() {
  case "$1" in
    --caskroom) printf '%s\n' "$caskroom" ;;
    --prefix)   if [ -n "${2:-}" ]; then printf '%s\n' "$tmp/prefix/opt/$2"
                else printf '%s\n' "$tmp/prefix"; fi ;;
    outdated)   printf '%s\n' "${OUTDATED_CASKS:-}" ;;
    reinstall)  printf '%s\n' "$*" >> "$brew_log"; return "$brew_reinstall_rc" ;;
    *)          printf '%s\n' "$*" >> "$brew_log"; return 0 ;;
  esac
}
cask_to_apps() {
  case "$1" in
    ut-broken|ut-gone) printf '%s\n' "UtTestBroken.app" ;;
  esac
}

mkdir -p "$caskroom/ut-broken/1.0/UtTestBroken.app/Contents" "$caskroom/ut-gone/1.0"

assert_eq "stale Caskroom backup with no installed app is broken" \
  "broken" "$(classify_cask ut-broken)"
assert_eq "missing app without a stale backup still upgrades in place" \
  "skip" "$(classify_cask ut-gone)"

OUTDATED_CASKS="ut-broken"
out="$(ut_upgrade_casks_smart 2>&1)"; rc=$?
assert_eq "broken cask repair succeeds" "0" "$rc"
assert_contains "broken cask is reinstalled" "$(cat "$brew_log")" "reinstall --cask ut-broken"
assert_not_contains "broken cask is not upgraded" "$(cat "$brew_log")" "upgrade --cask"
assert_contains "broken cask is named in the log" "$out" "ut-broken"

: > "$brew_log"
brew_reinstall_rc=1
ut_upgrade_casks_smart >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass "failed reinstall fails the step"; else
  fail "failed reinstall fails the step"; fi
brew_reinstall_rc=0
unset OUTDATED_CASKS

# ---------------------------------------------------------------------------
# pnpm global bin dir
# ---------------------------------------------------------------------------
unset PNPM_HOME
assert_eq "default global bin dir on macOS" \
  "$HOME/Library/pnpm/bin" "$(ut_pnpm_global_bin_dir)"
assert_eq "PNPM_HOME decides the global bin dir" \
  "/opt/pnh/bin" "$(PNPM_HOME=/opt/pnh ut_pnpm_global_bin_dir)"

# Fake pnpm that behaves like pnpm 12: global commands fail unless the global
# bin dir is on PATH. It records every invocation.
pnpm_log="$tmp/pnpm.log"
make_fake_pnpm() { # $1 = dir to install the fake into
  mkdir -p "$1"
  cat > "$1/pnpm" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$pnpm_log"
bindir="\${PNPM_HOME:-\$HOME/Library/pnpm}/bin"
case "\$*" in
  *-g*|*--global*)
    case ":\$PATH:" in *":\$bindir:"*) ;; *)
      echo "Error: ERR_PNPM_GLOBAL_BIN_DIR_NOT_IN_PATH" >&2; exit 1 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$1/pnpm"
}
ut_brew_cli_lock() { return 0; }
ut_brew_cli_unlock() { return 0; }
saved_path="$PATH"

# pnpm from Homebrew: brew owns updates, self-update would install a shadow copy.
make_fake_pnpm "$tmp/prefix/opt/pnpm/bin"
mkdir -p "$tmp/prefix/bin"
ln -s "$tmp/prefix/opt/pnpm/bin/pnpm" "$tmp/prefix/bin/pnpm"
: > "$pnpm_log"; : > "$brew_log"
PATH="$tmp/prefix/bin:$saved_path"
( pnpm_update_global ) >/dev/null 2>&1; rc=$?
PATH="$saved_path"
assert_eq "brew-managed pnpm global update succeeds" "0" "$rc"
assert_not_contains "brew-managed pnpm is not self-updated" "$(cat "$pnpm_log")" "self-update"
assert_contains "brew-managed pnpm is upgraded by brew" "$(cat "$brew_log")" "upgrade pnpm"
assert_contains "global packages are updated" "$(cat "$pnpm_log")" "update -g --latest"

# Standalone pnpm: its own updater is used.
make_fake_pnpm "$tmp/standalone/bin"
: > "$pnpm_log"; : > "$brew_log"
PATH="$tmp/standalone/bin:$saved_path"
( pnpm_update_global ) >/dev/null 2>&1; rc=$?
PATH="$saved_path"
assert_eq "standalone pnpm global update succeeds" "0" "$rc"
assert_contains "standalone pnpm self-updates" "$(cat "$pnpm_log")" "self-update"
assert_not_contains "standalone pnpm is not touched by brew" "$(cat "$brew_log")" "upgrade pnpm"

# pnpm installed by npm into the brew prefix (Intel /usr/local) is not brew's.
rm "$tmp/prefix/bin/pnpm"
make_fake_pnpm "$tmp/prefix/bin"
: > "$pnpm_log"; : > "$brew_log"
PATH="$tmp/prefix/bin:$saved_path"
( pnpm_update_global ) >/dev/null 2>&1; rc=$?
PATH="$saved_path"
assert_eq "npm-installed pnpm in the brew prefix updates" "0" "$rc"
assert_contains "npm-installed pnpm in the brew prefix self-updates" "$(cat "$pnpm_log")" "self-update"

if [ "$failures" -ne 0 ]; then
  printf '%s failure(s)\n' "$failures"
  exit 1
fi
echo "all broken-install tests passed"
