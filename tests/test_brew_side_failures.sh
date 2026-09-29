#!/usr/bin/env bash
# `brew upgrade` can exit non-zero for reasons unrelated to the package it was
# asked about: on a new macOS every run also tries to rebuild pkgconf from
# source, which fails while Xcode is outdated. A package that is already
# current must not be "upgraded" (that only re-triggers the side failure), and
# a cask that did reach the new version must be counted as upgraded.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-brewside.XXXXXX)"
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

export HOME="$tmp/home"
mkdir -p "$HOME/Applications"
brew_log="$tmp/brew.log"
: > "$brew_log"
# Space-separated names brew currently reports as outdated.
OUTDATED_FORMULAE=""
OUTDATED_CASKS=""
# Outdated casks that `brew upgrade --cask` really moves to the new version.
CASK_UPGRADE_LANDS=""
BREW_UPGRADE_RC=1   # the pkgconf/Xcode side failure

is_listed() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

brew() {
  case "$1" in
    --caskroom) printf '%s\n' "$tmp/Caskroom" ;;
    list)       return 0 ;;
    outdated)
      local kind=formula names="" n
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --cask) kind=cask ;;
          --formula|--quiet|--greedy) ;;
          -*) ;;
          *) names="$names $1" ;;
        esac
        shift
      done
      local pool="$OUTDATED_FORMULAE"
      [ "$kind" = cask ] && pool="$OUTDATED_CASKS"
      for n in $pool; do
        if [ -z "$names" ] || is_listed "$n" "$names"; then printf '%s\n' "$n"; fi
      done
      ;;
    upgrade)
      printf '%s\n' "$*" >> "$brew_log"
      local last="${*: -1}"
      if is_listed "$last" "$CASK_UPGRADE_LANDS"; then
        OUTDATED_CASKS="$(for n in $OUTDATED_CASKS; do [ "$n" = "$last" ] || printf '%s ' "$n"; done)"
      fi
      return "$BREW_UPGRADE_RC"
      ;;
    *) printf '%s\n' "$*" >> "$brew_log"; return 0 ;;
  esac
}
have() { command -v "$1" >/dev/null 2>&1 || [ "$1" = brew ]; }
classify_cask() { echo upgrade; }
ut_brew_cli_lock() { return 0; }
ut_brew_cli_unlock() { return 0; }

# ---------------------------------------------------------------------------
# Formula steps: never call `brew upgrade` for a formula that is already current
# ---------------------------------------------------------------------------
step_command() { # $1 = label prefix -> command field of the STEPS entry
  local s
  for s in "${STEPS[@]}"; do
    case "$s" in "$1"*) printf '%s\n' "${s##*¦}"; return 0 ;; esac
  done
  return 1
}

for label in "Supabase CLI" "Vercel CLI"; do
  : > "$brew_log"
  OUTDATED_FORMULAE=""
  out="$(eval "$(step_command "$label")" 2>&1)"; rc=$?
  assert_eq "$label: current formula succeeds" "0" "$rc"
  assert_not_contains "$label: current formula is not upgraded" "$(cat "$brew_log")" "upgrade"
done

: > "$brew_log"
OUTDATED_FORMULAE="supabase"
eval "$(step_command "Supabase CLI")" >/dev/null 2>&1; rc=$?
assert_contains "outdated formula is upgraded" "$(cat "$brew_log")" "upgrade supabase"
assert_eq "failed upgrade of an outdated formula fails the step" "1" "$rc"

# uv's self-update always refuses a Homebrew install; the brew fallback must
# then only act when uv is actually outdated.
uv() { case "$1" in self) return 2 ;; *) return 0 ;; esac; }
: > "$brew_log"
OUTDATED_FORMULAE=""
uv_update_self_and_tools >/dev/null 2>&1; rc=$?
assert_eq "uv: current Homebrew uv succeeds" "0" "$rc"
assert_not_contains "uv: current Homebrew uv is not upgraded" "$(cat "$brew_log")" "upgrade"

: > "$brew_log"
OUTDATED_FORMULAE="uv"
uv_update_self_and_tools >/dev/null 2>&1; rc=$?
assert_contains "uv: outdated Homebrew uv is upgraded" "$(cat "$brew_log")" "upgrade uv"
assert_eq "uv: failed upgrade fails the step" "1" "$rc"
unset -f uv

# ---------------------------------------------------------------------------
# Casks: judge the upgrade by the resulting version, not brew's exit code alone
# ---------------------------------------------------------------------------
: > "$brew_log"
OUTDATED_CASKS="ut-landed"
CASK_UPGRADE_LANDS="ut-landed"
out="$(ut_upgrade_casks_smart 2>&1)"; rc=$?
assert_eq "cask that reached the new version succeeds" "0" "$rc"
assert_contains "cask that reached the new version is counted" "$out" "casks: 1 upgraded"
assert_contains "non-zero brew exit after a landed upgrade is reported" "$out" "ut-landed: upgraded, but brew exited non-zero"

: > "$brew_log"
OUTDATED_CASKS="ut-stuck"
CASK_UPGRADE_LANDS=""
out="$(ut_upgrade_casks_smart 2>&1)"; rc=$?
assert_eq "cask still outdated after a failed upgrade fails the step" "1" "$rc"
assert_contains "cask still outdated is not counted" "$out" "casks: 0 upgraded"

if [ "$failures" -eq 0 ]; then
  echo "all brew side-failure tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
