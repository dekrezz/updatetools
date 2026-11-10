#!/usr/bin/env bash
# Licensed under the Apache License, Version 2.0 (see LICENSE).
DRY=0
YES=0
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help)
      printf 'Usage: uninstall.sh [--dry-run] [--yes]\n'
      printf 'Removes updatetools and everything it left on this Mac.\n'
      exit 0 ;;
    *) printf 'uninstall.sh: unknown option %s\n' "$a" >&2; exit 2 ;;
  esac
done

LABEL="com.dekrezz.updatetools"
AGENTS="${UT_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

tmp_dirs=()
for d in "${TMPDIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" /tmp /var/tmp; do
  [ -n "$d" ] && [ -d "$d" ] && tmp_dirs+=("${d%/}")
done

targets=()
add() {
  local t
  [ -e "$1" ] || [ -L "$1" ] || return 0
  for t in "${targets[@]}"; do [ "$t" = "$1" ] && return 0; done
  targets+=("$1")
}

add "$AGENTS/$LABEL.plist"
add "$HOME/.config/updatetools"
add "$CACHE_HOME/updatetools"
add "$HOME/.cache/updatetools"
add "$HOME/Library/Caches/updatetools"
add "$HOME/Library/Logs/updatetools"
add "${UPDATETOOLS_SAVED_PASSWORD:-}"
add "${UPDATETOOLS_ENABLED_FILE:-}"
add "${UPDATETOOLS_HISTORY_FILE:-}"
add "${UPDATETOOLS_DURATIONS_FILE:-}"
add "${UPDATETOOLS_PACKAGE_TIMES_FILE:-}"
add "${UPDATETOOLS_PASSWORD_LAYOUT:-}"
add "${DIAG_DIR:-}"

for d in "${tmp_dirs[@]}"; do
  for f in "$d"/updatetools "$d"/updatetools-* "$d"/updatetools.*; do add "$f"; done
done
for f in "$HOME"/Desktop/updatetools-report-*.html; do add "$f"; done
for d in /Applications "$HOME/Applications"; do
  for f in "$d"/.updatetools-stage-*.app; do add "$f"; done
done

brew_formula=0
brew_tap=0
if command -v brew >/dev/null 2>&1; then
  brew list --formula 2>/dev/null | grep -qx updatetools && brew_formula=1
  brew tap 2>/dev/null | grep -qx 'dekrezz/updatetools' && brew_tap=1
fi

bins=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  bins+=("$p")
  for f in "$(dirname "$p")"/updatetools.??????; do [ -e "$f" ] && bins+=("$f"); done
done < <(type -aP updatetools 2>/dev/null | sort -u)

live=""
for d in "${tmp_dirs[@]}"; do
  pid="$(cat "$d/updatetools.lock/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && live="$pid"
done
if [ -n "$live" ]; then
  printf 'uninstall.sh: an updatetools run is in progress (pid %s). Stop it, then run this again.\n' "$live" >&2
  exit 1
fi

printf 'Will remove:\n'
for t in "${targets[@]}" "${bins[@]}"; do printf '  %s\n' "$t"; done
[ "$brew_formula" = 1 ] && printf '  Homebrew formula: updatetools\n'
[ "$brew_tap" = 1 ] && printf '  Homebrew tap: dekrezz/updatetools\n'
printf '  LaunchAgent %s (stopped, if loaded)\n' "$LABEL"
printf '  background app-swap helpers (stopped, if any)\n'

[ "$DRY" = 1 ] && exit 0

if [ "$YES" != 1 ]; then
  printf 'Continue? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) printf 'Cancelled.\n'; exit 1 ;; esac
fi

rc=0
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
pkill -f "$HOME/Library/Caches/updatetools/jobs/" >/dev/null 2>&1
pkill -f "$CACHE_HOME/updatetools/" >/dev/null 2>&1

if [ "$brew_formula" = 1 ]; then
  brew uninstall --formula updatetools || rc=1
fi
if [ "$brew_tap" = 1 ]; then
  brew untap dekrezz/updatetools || rc=1
fi

for t in "${targets[@]}" "${bins[@]}"; do
  rm -rf "$t" || rc=1
done

for t in "${targets[@]}" "${bins[@]}"; do
  [ -e "$t" ] || [ -L "$t" ] && { printf 'uninstall.sh: could not remove %s\n' "$t" >&2; rc=1; }
done

[ "$rc" = 0 ] && printf 'updatetools is removed.\n'
exit "$rc"
