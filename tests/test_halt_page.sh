#!/usr/bin/env bash
# The page says why a run stopped and what to do next:
#   * a stopped run (network lost, stopped from the terminal, killed) gets a
#     banner with the reason, the detail and where the diagnostics are;
#   * while the network is down but the run has not stopped yet, it warns;
#   * on the chooser, it warns that the last run did not finish;
#   * after a stop, one action continues: it runs the stopped steps again and
#     the ones that never ran.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-haltpage.XXXXXX)"
export HOME="$tmp/home"
mkdir -p "$HOME"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing sets updatetools' own EXIT trap (cleanup); keep it and remove $tmp too.
trap 'cleanup; rm -rf "$tmp"' EXIT

ut_web_page > "$tmp/page.html"
node - "$tmp/page.html" <<'NODE'
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const pick = (from) => {
  const a = html.indexOf(from), b = html.indexOf('\n  }\n', a);
  if (a < 0 || b < 0) { console.log('not ok - helper ' + from + ' not found'); process.exit(1); }
  return html.slice(a, b) + '\n  }';
};
eval(pick('function haltNotice('));
eval(pick('function retryKeys('));
eval(pick('function retryAction('));
let fails = 0;
const ok = (n, cond) => { console.log((cond ? 'ok - ' : 'not ok - ') + n); if (!cond) fails++; };

const net = haltNotice({ phase: 'done', halt: { why: 'network', msg: 'No connection for 30 s. Homebrew was stopped.', diag: '/d/1' } });
ok('a network stop has a banner', !!net && net.kind === 'bad');
ok('the banner names the network', !!net && /network/i.test(net.title));
ok('the banner carries the detail', !!net && net.detail === 'No connection for 30 s. Homebrew was stopped.');
ok('the banner carries the diagnostics path', !!net && net.diag === '/d/1');
const sig = haltNotice({ phase: 'done', halt: { why: 'signal', msg: 'Stopped by Ctrl+C.' } });
ok('a stop from the terminal says so', !!sig && /terminal/i.test(sig.title));
const killed = haltNotice({ phase: 'done', halt: { why: 'killed', msg: 'The run was killed.' } });
ok('a killed run says so', !!killed && /killed/i.test(killed.title));
const down = haltNotice({ phase: 'run', net: { down: 12, limit: 30, why: 'no default route' } });
ok('a network outage warns while the run waits for it', !!down && down.kind === 'warn' && /12/.test(down.detail) && /30/.test(down.detail));
const prev = haltNotice({ phase: 'choose', prev: 'The last run was killed while Homebrew ran.' });
ok('the chooser warns about an unfinished last run', !!prev && prev.kind === 'warn' && prev.detail === 'The last run was killed while Homebrew ran.');
ok('a normal run has no banner', haltNotice({ phase: 'run', steps: [] }) === null);

const stopped = {
  phase: 'done', halt: { why: 'network', msg: 'x' },
  steps: [
    { key: 'homebrew', s: 'fail', why: 'stopped' }, { key: 'npm', s: 'skip', why: 'halted' },
    { key: 'cargo', s: 'skip', why: 'off' }, { key: 'pipx', s: 'done' }, { key: 'report', s: 'skip', why: 'halted' },
  ],
};
ok('continuing runs the stopped step and the ones that never ran', JSON.stringify(retryKeys(stopped)) === '["homebrew","npm"]');
ok('a stopped run offers to continue', retryAction(stopped, { fail: 1 }) === 'Continue');
const offline = { phase: 'done', halt: { why: 'network', msg: 'x' }, steps: [{ key: 'homebrew', s: 'skip', why: 'halted' }] };
ok('a run stopped before anything ran offers to continue', retryAction(offline, { fail: 0 }) === 'Continue');
const failed = { phase: 'done', steps: [{ key: 'homebrew', s: 'fail' }, { key: 'npm', s: 'done' }] };
ok('a plain failure still retries only what failed', JSON.stringify(retryKeys(failed)) === '["homebrew"]' && retryAction(failed, { fail: 1 }) === 'Retry failed');
const rejected = { phase: 'error', steps: [{ key: 'homebrew', s: 'pending', on: true }, { key: 'npm', on: false }, { key: 'report', s: 'pending' }] };
ok('a rejected password runs the same selection again', JSON.stringify(retryKeys(rejected)) === '["homebrew"]');

ok('the page has an alert region for the banner', /<[a-z]+[^>]*id="alert"[^>]*role="alert"|<[a-z]+[^>]*role="alert"[^>]*id="alert"/.test(html));
process.exit(fails ? 1 : 0);
NODE
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "all halt page tests passed"
  exit 0
fi
echo "halt page tests failed"
exit 1
