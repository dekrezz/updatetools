#!/usr/bin/env bash
# The npm step updates the global packages that no other step owns. Codex CLI
# (@openai/codex), Claude Code (@anthropic-ai/claude-code), Supabase CLI
# (supabase) and Vercel CLI (vercel) each have their own step, which is the only
# one that installs them: the npm and Codex CLI steps run at the same time, and
# two `npm install -g` of one package collide in its directory (ENOTEMPTY,
# 2026-10-20). A step switched off also means its tool is left alone. npm itself
# stays Homebrew's.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-npm.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it and remove $tmp too.
trap 'cleanup; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

# What `npm outdated -g --depth=0 --parseable` prints: path:wanted:current:latest:dependent.
OUTDATED=""
outdated() { OUTDATED="$OUTDATED/opt/homebrew/lib/node_modules/$1:$1@$3:$1@$2:$1@$3:global
"; }
npm() {
  case "$1" in
    outdated) printf '%s' "$OUTDATED" ;;
    install) printf '%s\n' "$*" >> "$tmp/installs" ;;
    cache) return 0 ;;
  esac
}

outdated @openai/codex 0.163.0 0.164.0
outdated @anthropic-ai/claude-code 2.1.300 2.1.304
outdated supabase 2.40.0 2.41.0
outdated vercel 48.1.0 48.2.0
outdated npm 10.9.9 12.2.0
outdated corepack 0.36.0 0.36.1
outdated typescript 5.9.2 5.9.3
: > "$tmp/installs"
npm_update_global >/dev/null 2>&1; rc=$?
installs="$(cat "$tmp/installs")"
[ "$rc" = 0 ] && pass "the npm step succeeds" || fail "the npm step succeeds (rc $rc)"
for p in corepack typescript; do
  [[ " $installs " == *" $p "* ]] && pass "an outdated package no step owns is installed: $p" \
    || fail "an outdated package no step owns is installed: $p (npm calls: $installs)"
done
for p in @openai/codex @anthropic-ai/claude-code supabase vercel npm; do
  [[ " $installs " == *" $p "* ]] && fail "the npm step leaves $p to its own step (npm calls: $installs)" \
    || pass "the npm step leaves $p to its own step"
done

OUTDATED=""
outdated @openai/codex 0.163.0 0.164.0
outdated npm 10.9.9 12.2.0
: > "$tmp/installs"
npm_update_global >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$tmp/installs" ] \
  && pass "with only owned packages outdated, the npm step installs nothing" \
  || fail "with only owned packages outdated, the npm step installs nothing (rc $rc, npm calls: $(cat "$tmp/installs"))"

if [ "$failures" -eq 0 ]; then
  echo "all npm globals tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
