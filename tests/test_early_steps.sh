#!/usr/bin/env bash
# Claude Code's self-update starts together with Homebrew instead of after it
# (it stalled for minutes on 2026-11-06 once Homebrew was long finished); the
# wave then only waits for it. A halt while Homebrew runs stops it too.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-early.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
trap 'cleanup; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

WEB_DIR=""
ev="$tmp/events"
STEPS=(
  "Homebrew · update everything¦true¦echo hb-start >> $ev; sleep 2; echo hb-end >> $ev"
  "uv · self + tools¦true¦echo uv >> $ev"
  "Claude Code · self-update¦true¦echo cc-start >> $ev; sleep 1; echo cc-end >> $ev"
  "Report · what changed¦true¦echo report >> $ev"
)
TOTAL=${#STEPS[@]}
for ((i=0;i<TOTAL;i++)); do
  STATUS[i]=pending; STEP_KEY[i]="$(ut_step_key "${STEPS[i]%%¦*}")"; STEP_ON[i]=1; STEP_WHY[i]=""
done
ut_after_steps() { :; }
ut_drop_sudo() { :; }

: > "$ev"
ut_run_steps >/dev/null 2>&1
order="$(tr '\n' ' ' < "$ev")"
case "$order" in
  "hb-start cc-start"*|"cc-start hb-start"*) pass "Claude Code starts together with Homebrew" ;;
  *) fail "Claude Code starts together with Homebrew ($order)" ;;
esac
case "$order" in
  *"cc-end"*"hb-end"*"uv"*"report"*) pass "it ends while Homebrew still runs; uv and Report follow Homebrew" ;;
  *) fail "ordering ($order)" ;;
esac
[ "${STATUS[2]}" = done ] && [ "${STATUS[0]}" = done ] && pass "both steps are recorded as done" || fail "statuses: ${STATUS[*]}"

# A halt while Homebrew runs stops the early step too.
: > "$ev"
for ((i=0;i<TOTAL;i++)); do STATUS[i]=pending; done
STEPS[0]="Homebrew · update everything¦true¦echo hb-start >> $ev; sleep 5; echo hb-end >> $ev"
STEPS[2]="Claude Code · self-update¦true¦echo cc-start >> $ev; sleep 30; echo cc-end >> $ev"
( sleep 1; touch "$tmp/halt" ) &
ut_net_tick() { [ -f "$tmp/halt" ] && { UT_HALT=1; UT_HALT_CAUSE="test halt"; }; return 0; }
STOP_GRACE=3
t0=$SECONDS
ut_run_steps >/dev/null 2>&1
[ $((SECONDS - t0)) -lt 15 ] && pass "a halt ends the run promptly" || fail "a halt ends the run promptly"
case "$(cat "$ev")" in *cc-end*) fail "the early step was stopped by the halt" ;; *) pass "the early step was stopped by the halt" ;; esac
[ "${STATUS[2]}" = fail ] && pass "the stopped early step is recorded as stopped" || fail "status after halt: ${STATUS[2]}"

[ "$failures" -eq 0 ] && echo "all early step tests passed"
exit "$failures"
