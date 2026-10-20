#!/usr/bin/env bash
# The tab's progress percentage during a run says how much of the run is
# behind, the same way "about N min left" does: the share of the expected time
# that has passed. Counting steps would read 0% for most of a run, because
# Homebrew alone is one step of many but most of the time. Without a time
# estimate (no earlier run to learn from) the steps done are all there is. It
# never reads 100% while the run is still going.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-progress.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it and remove $tmp too.
trap 'cleanup; rm -rf "$tmp"' EXIT

ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
let fails = 0;
const ok = (n, cond, why) => { console.log((cond ? 'ok - ' : 'not ok - ') + n + (cond || why === undefined ? '' : ` (${why})`)); if (!cond) fails++; };
const pick = (from) => {
  const a = html.indexOf(from), b = html.indexOf('\n  }\n', a);
  if (a < 0 || b < 0) return null;
  return html.slice(a, b) + '\n  }';
};
const SERIAL_LINE = (html.match(/^  const SERIAL = \[.*\];$/m) || [])[0];
const parts = [SERIAL_LINE, pick('function stepSelected('), pick('function stepsForRibbon('), pick('function estimateLeft('), pick('function runPercent(')];
if (parts.some((p) => !p)) {
  console.log('not ok - the page has runPercent() beside estimateLeft() (missing: '
    + ['SERIAL', 'stepSelected', 'stepsForRibbon', 'estimateLeft', 'runPercent'].filter((_, i) => !parts[i]).join(', ') + ')');
  process.exit(1);
}
eval(parts.join('\n'));

const step = (key, s, est, b) => Object.assign({ n: key, key, slug: key, s, on: true, est }, b == null ? {} : { b });
const counts = (steps) => {
  const sel = steps.filter((s) => s.key !== 'report');
  const n = (x) => sel.filter((s) => s.s === x).length;
  return { total: sel.length, done: n('done'), skip: n('skip'), fail: n('fail'), staged: n('staged') };
};

// Homebrew has run 5:55 of the 6:40 it took last time; the rest is about 2 min.
const busy = [
  step('homebrew', 'run', 400, 0), step('applications', 'pending', 20), step('macos', 'pending', 30),
  step('npm', 'pending', 25), step('pnpm', 'pending', 10), step('report', 'pending', 2),
];
const st = { phase: 'run', elapsed: 355, steps: busy };
ok('the run in the example has about 2 min left (test setup)', estimateLeft(st) === 120, estimateLeft(st));
ok('with 5:55 behind and about 2 min left the tab reads 74%, not the 0% of 0 steps done',
  runPercent(st, counts(busy)) === 74, runPercent(st, counts(busy)));

const later = { phase: 'run', elapsed: 400, steps: busy };
ok('the percentage grows as the run goes on', runPercent(later, counts(busy)) > runPercent(st, counts(busy)),
  `${runPercent(st, counts(busy))} then ${runPercent(later, counts(busy))}`);

const fresh = [step('homebrew', 'done', null), step('npm', 'done', null), step('pnpm', 'done', null), step('cargo', 'run', null, 30)];
ok('without a time estimate the tab reads the share of steps done',
  runPercent({ phase: 'run', elapsed: 90, steps: fresh }, counts(fresh)) === 75, runPercent({ phase: 'run', elapsed: 90, steps: fresh }, counts(fresh)));

const last = [step('homebrew', 'done', 400), step('npm', 'done', 25), step('report', 'run', 2, 420)];
ok('it never reads 100% while the run is still going', runPercent({ phase: 'run', elapsed: 425, steps: last }, counts(last)) === 99,
  runPercent({ phase: 'run', elapsed: 425, steps: last }, counts(last)));
const over = [step('homebrew', 'run', 60, 0), step('npm', 'pending', 5)];
ok('a step running past its estimate stays below 100%', runPercent({ phase: 'run', elapsed: 3000, steps: over }, counts(over)) < 100,
  runPercent({ phase: 'run', elapsed: 3000, steps: over }, counts(over)));
process.exit(fails ? 1 : 0);
NODE
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "all run progress tests passed"
  exit 0
fi
echo "run progress tests failed"
exit 1
