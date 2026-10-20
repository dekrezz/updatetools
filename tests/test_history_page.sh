#!/usr/bin/env bash
# The dashboard has a History panel that shows what earlier runs did. It reads
# history.json ({"v":1,"runs":[...]}, newest first) and shows:
#   * the last 30 local calendar days (today and the 29 days before it):
#     - updates installed: every "up" entry of every run in the window, staged
#       and restarted ones too, from failed and halted runs too;
#     - runs: the number of runs in the window;
#     - clean: floor(100 * ok runs / runs);
#     - per run: the median length of the runs that were not stopped;
#     - a run older than that is not counted;
#   * a run length from an hour up reads "{h}h {mm}m" with whole minutes, so
#     1h 59m 30s reads "2h 00m", never "1h 60m";
#   * a chart of those 30 days, today last. Each day has its updates, runs and
#     failed runs. A day without a run is empty;
#   * "Updated most often", over the whole file: tools updated at least twice,
#     by count, then the most recent first, at most 5;
#   * "Latest runs", each run summed up in words: which steps failed ("A failed",
#     "A and B failed", "A and N more failed"); a step stopped by a halt is not
#     called failed, and a halted run says why it stopped; "N updated: names";
#     "Everything was up to date";
#   * "This run" is the run whose id state.json names in "hist":{"id","rev"}.
#     The page reads history.json again, once, for each {id, rev} it has not
#     loaded. If that run is not in the file, it says so and does not retry;
#   * "Usual time per source": the median of a source's last 10 done or staged
#     entries. Failed and stopped entries are left out;
#   * logos come from the slugs in the data: the page has no client-side copy of
#     ut_icon_slug, and an entry without a slug gets a monogram;
#   * a history.json with an error ({"v":1,"error":"..."}) or an unknown version
#     shows "History is unavailable." with the reason. An empty one shows
#     "No runs recorded yet.";
#   * during a run, the panel has no alarm colour. The live run is the only
#     colour on the page. Red returns in choose and done.
#
# The page's history code (from `const HIST_DAYS` to the final `poll();`) runs
# in node with the page's own helpers. Stand-ins replace only what needs a
# browser: the DOM ($, document), fetch (serves history.json), and render and
# openLedger. render here records the state the way the page's render does.
# Nothing touches the network or opens a browser.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-histpage.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch"
mkdir -p "$HOME" "$TMPDIR"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# After the source: updatetools sets its own EXIT trap (cleanup) when sourced.
finish() {
  cleanup 2>/dev/null
  pkill -KILL -f "$tmp/" 2>/dev/null
  rm -rf "$tmp"
}
trap finish EXIT
NET_TIMEOUT=0
DIAG_DIR="$tmp/diag"

if ! ut_web_page > "$tmp/page.html"; then
  echo "not ok - ut_web_page writes the dashboard page"
  exit 1
fi

node - "$tmp/page.html" <<'NODE'
'use strict';
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');

let fails = 0;
const ok = (name, cond, why) => {
  console.log((cond ? 'ok - ' : 'not ok - ') + name + (!cond && why !== undefined ? ` (${why})` : ''));
  if (!cond) fails++;
};
const eq = (name, got, want) => ok(name, JSON.stringify(got) === JSON.stringify(want),
  `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
async function check(group, fn) {
  try { await fn(); } catch (e) { console.log(`not ok - ${group}: ${(e && e.message) || e}`); fails++; }
}

/* ── the page's script, split into its helpers and the history panel ───────── */
const HEAD = "(() => {\n  'use strict';";
const a = html.indexOf(HEAD), b = html.lastIndexOf('\n  poll();\n})();');
if (a < 0 || b < 0) { console.log('not ok - the page script ends with poll(); as the harness expects'); process.exit(1); }
const script = html.slice(a + HEAD.length, b + 1);
const histAt = script.search(/^[ \t]*(?:const|let)\s+HIST_DAYS\s*=/m);
const NO_PANEL = 'the page has no history panel script (no `const HIST_DAYS` before the final poll())';

// Everything before the panel's code that only declares: top-level functions,
// one-line arrow helpers, ICON and setHtml's memo. Declaring runs nothing.
// The names below get stand-ins instead because they need a browser.
const STAND_INS = new Set(['$', 'render', 'openLedger', 'closeLedger', 'poll']);
function pageHelpers(src) {
  const out = [];
  for (const m of src.matchAll(/^  (?:async )?function ([\w$]+)\(/gm)) {
    if (STAND_INS.has(m[1])) continue;
    const first = src.slice(m.index, src.indexOf('\n', m.index));
    if (first.trimEnd().endsWith('}')) { out.push(first); continue; }
    out.push(src.slice(m.index, src.indexOf('\n  }\n', m.index) + 4));
  }
  for (const m of src.matchAll(/^  const ([\w$]+) = (?:async )?\([^)]*\) => .*;$/gm)) if (!STAND_INS.has(m[1])) out.push(m[0]);
  const icon = src.search(/^  const ICON = \{$/m);
  if (icon >= 0) out.push(src.slice(icon, src.indexOf('\n  };\n', icon) + 5));
  const memo = src.match(/^  const written = new WeakMap\(\);$/m);
  if (memo) out.push(memo[0]);
  return out.join('\n');
}
const HELPERS = histAt < 0 ? '' : pageHelpers(script.slice(0, histAt));
const CHUNK = histAt < 0 ? '' : script.slice(histAt);
// The page's sprite: logo() draws a slug only when #i-<slug> is in it.
const SPRITE = new Set(Array.from(html.matchAll(/<symbol\b[^>]*\bid="(i-[^"]+)"/g), (m) => m[1]));

/* ── DOM stand-ins: elements keep what is written to them ──────────────────── */
function makeEl(id) {
  const attrs = {}, cls = new Set();
  return {
    id, innerHTML: '', textContent: '', hidden: false, inert: false, dataset: {}, value: '', parentElement: null,
    style: { setProperty() {}, getPropertyValue: () => '', removeProperty() {} },
    classList: {
      add: (...c) => c.forEach((x) => cls.add(x)), remove: (...c) => c.forEach((x) => cls.delete(x)),
      contains: (c) => cls.has(c),
      toggle: (c, on) => { const v = on === undefined ? !cls.has(c) : !!on; if (v) cls.add(c); else cls.delete(c); return v; },
    },
    setAttribute: (k, v) => { attrs[k] = String(v); }, getAttribute: (k) => (k in attrs ? attrs[k] : null),
    removeAttribute: (k) => { delete attrs[k]; }, hasAttribute: (k) => k in attrs,
    addEventListener() {}, removeEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
    closest: () => null, contains: () => false, focus() {}, blur() {}, scrollIntoView() {},
    appendChild: (c) => c, insertBefore: (c) => c, remove() {},
    getBoundingClientRect: () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }),
    animate: () => ({ finished: Promise.resolve(), cancel() {} }),
  };
}
const asyncErrors = [];
process.on('unhandledRejection', (e) => asyncErrors.push(e));
async function settle() {
  for (let i = 0; i < 30; i++) await new Promise((r) => setImmediate(r));
  if (asyncErrors.length) {
    const e = asyncErrors.shift();
    throw new Error(`the panel threw: ${(e && e.message) || e}`);
  }
}
const respond = (r) => ({
  ok: r.status >= 200 && r.status < 300, status: r.status, statusText: r.statusText,
  json: async () => JSON.parse(r.body), text: async () => r.body,
});
const serve = (doc) => ({ status: 200, statusText: 'OK', body: typeof doc === 'string' ? doc : JSON.stringify(doc) });

// One page load: the panel's code evaluated fresh, history.json served from
// `doc` (change p.doc to change the file on disk). p.tick(st) is one poll:
// render records the state, then poll calls histTick(st).
async function page(doc) {
  if (histAt < 0) throw new Error(NO_PANEL);
  const els = new Map();
  const $ = (id) => { if (!els.has(id)) els.set(id, makeEl(id)); return els.get(id); };
  const root = makeEl('html');
  const document = {
    documentElement: root, body: makeEl('body'), title: 'updatetools', activeElement: null,
    getElementById: (id) => (id.startsWith('i-') ? (SPRITE.has(id) ? makeEl(id) : null) : $(id)),
    querySelector: () => null, querySelectorAll: () => [], createElement: (t) => makeEl(t),
    addEventListener() {}, removeEventListener() {},
  };
  const window = {
    addEventListener() {}, removeEventListener() {}, location: { reload() {} },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
  };
  const p = { doc, fetches: 0 };
  const fetch = async (url) => {
    if (!/^history\.json(\?|$)/.test(String(url))) return respond({ status: 404, statusText: 'Not Found', body: '' });
    p.fetches++;
    return respond(p.doc);
  };
  const src = `'use strict';
    let latestState = null, latestPhase = '', latestUpdates = [];
    const reduce = true;
    function render(st) { latestState = st; latestPhase = st.phase; latestUpdates = st.updates || []; root.dataset.phase = st.phase; }
    function openLedger() {}
    function closeLedger() {}
${HELPERS}
${CHUNK}
    return {
      get(name) { try { return eval(name); } catch (e) { return undefined; } },
      tick(st) { render(st); histTick(st); },
    };`;
  let api;
  try {
    api = new Function('$', 'document', 'window', 'root', 'fetch', 'requestAnimationFrame', 'cancelAnimationFrame',
      'getComputedStyle', 'CSS', 'navigator', 'matchMedia', 'localStorage', src)(
      $, document, window, root, fetch, (f) => setImmediate(() => f(0)), () => {},
      () => ({ height: '0px', getPropertyValue: () => '' }), { escape: (s) => String(s) },
      { sendBeacon: () => true }, window.matchMedia, { getItem: () => null, setItem() {} });
  } catch (e) {
    throw new Error(`the page's history code does not run: ${e.message}`);
  }
  await settle();
  p.need = (name) => {
    const v = api.get(name);
    if (typeof v !== 'function') throw new Error(`the page has no ${name}() helper`);
    return v;
  };
  p.tick = async (st) => { api.tick(st); await settle(); };
  p.panel = () => $('hist-body').innerHTML;
  return p;
}

/* ── reading the panel's markup ─────────────────────────────────────────────── */
const ENT = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" };
const text = (s) => String(s || '').replace(/<[^>]*>/g, ' ').replace(/&(?:amp|lt|gt|quot|#39);/g, (m) => ENT[m])
  .replace(/\s+/g, ' ').trim();
const noSr = (s) => String(s || '').replace(/<span class="sr">[\s\S]*?<\/span>/g, '');
const sectionOf = (h, title) => (h.match(/<section\b[\s\S]*?<\/section>/g) || [])
  .find((s) => new RegExp(`<h3\\b[^>]*>\\s*${title}\\s*</h3>`).test(s)) || '';
const items = (h) => Array.from(h.matchAll(/<li\b[^>]*>([\s\S]*?)<\/li>/g), (m) => m[1]);
const runRows = (h) => Array.from(sectionOf(h, 'Latest runs').matchAll(/<button\b([^>]*)>([\s\S]*?)<\/button>/g),
  (m) => ({ id: (m[1].match(/\bdata-id="([^"]*)"/) || [])[1], text: text(m[2]) }));
const label = (rows, id) => { const r = rows.find((x) => x.id === id); return r ? r.text : `(no row for ${id})`; };
const logoOf = (h) => {
  const use = h.match(/<use\b[^>]*href="#i-([\w-]+)"/), img = h.match(/<img\b[^>]*src="([^"]*)"/);
  const mono = h.match(/class="logo mono"[^>]*>([^<]*)</);
  return use ? `#i-${use[1]}` : img ? `img ${img[1]}` : mono ? `monogram ${mono[1]}` : 'none';
};
function fig(h, name) {
  const m = h.match(new RegExp(`<dt>\\s*${name}\\s*</dt>\\s*<dd\\b[^>]*>([\\s\\S]*?)</dd>`))
    || h.match(new RegExp(`<dd\\b[^>]*>([\\s\\S]*?)</dd>\\s*<dt>\\s*${name}\\s*</dt>`));
  return m ? text(noSr(m[1])) : `(no "${name}" figure)`;
}
function chartDays(h) {
  const chart = (h.match(/<div\b[^>]*class="hist-chart"[^>]*>([\s\S]*?)<\/div>/) || [])[1] || '';
  return Array.from(chart.matchAll(/<span\b[^>]*>/g), (m) => m[0]).filter((t) => /class="hist-day\b/.test(t)).map((t) => ({
    cls: ((t.match(/class="([^"]*)"/) || [])[1] || '').split(/\s+/),
    h: parseFloat((t.match(/--h:\s*([\d.]+)%/) || [])[1]),
  }));
}

/* ── history files built around the real current time ─────────────────────── */
const now = new Date();
const dayStart = (back) => new Date(now.getFullYear(), now.getMonth(), now.getDate() - back);
const at = (back, h = 12, m = 0, s = 0) =>
  Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - back, h, m, s).getTime() / 1000);
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WEEK = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const md = (back) => `${MON[dayStart(back).getMonth()]} ${dayStart(back).getDate()}`;
const run = (o) => Object.assign({ v: 1, mode: 'dashboard', out: 'ok', steps: [], up: [] }, o);
const HB = (s, t) => ({ k: 'homebrew', n: 'Homebrew', s, t, slug: 'homebrew' });
const LIVE = [
  { n: 'Homebrew', a: 'update everything', slug: 'homebrew', key: 'homebrew', on: true, img: 'data:image/png;base64,TEST' },
  { n: 'Report', a: '', slug: 'report', key: 'report', on: true },
];
const st = (phase, extra) => Object.assign({ phase, elapsed: 0, total: LIVE.length,
  steps: LIVE.map((s) => Object.assign({}, s, { s: phase === 'choose' ? 'pending' : phase === 'run' ? 'run' : 'done' })) }, extra);

// Six runs in the window, one just outside it.
const MAIN = [
  run({ id: 'r-today', at: at(0, 12), sec: 100, steps: [HB('done', 60)], up: [
    { k: 'node', n: 'node', o: '24.9.0', w: '24.10.0', slug: 'nodedotjs' },
    { k: 'slack', n: 'Slack', o: '4.46.99', w: '4.47.59', st: 'staged' }] }),
  run({ id: 'r-today-fail', at: at(0, 9), sec: 300, out: 'fail',
    steps: [HB('done', 70), { k: 'npm', n: 'npm', s: 'fail', t: 5, slug: 'npm' }],
    up: [{ k: 'google-chrome', n: 'Google Chrome', o: '141.0.7390.55', w: '141.0.7390.66', st: 'restarted', slug: 'googlechrome' }] }),
  run({ id: 'r-yesterday', at: at(1, 12), sec: 150, mode: 'plain', steps: [HB('done', 80)],
    up: [{ k: 'ffmpeg', n: 'ffmpeg', o: '8.0', w: '8.0_1' }] }),
  run({ id: 'r-halted', at: at(3, 12), sec: 5000, out: 'halted', halt: 'network', steps: [HB('stopped', 4000)],
    up: [{ k: 'node', n: 'node', o: '24.8.0', w: '24.9.0', slug: 'nodedotjs' }] }),
  run({ id: 'r-10', at: at(10, 12), sec: 400, steps: [HB('done', 90)], up: [{ k: 'git', n: 'git', o: '2.51.0', w: '2.51.1' }] }),
  run({ id: 'r-29', at: at(29, 0, 0, 30), sec: 200, steps: [HB('done', 100)], up: [] }),
  run({ id: 'r-30', at: at(30, 23, 59, 0), sec: 50, steps: [HB('done', 110)],
    up: Array.from({ length: 7 }, (_, i) => ({ k: `old${i}`, n: `old${i}`, o: '1', w: '2' })) }),
];

(async () => {
  /* 1. the 30-day window and its figures */
  await check('the 30-day figures', async () => {
    const p = await page(serve({ v: 1, runs: MAIN }));
    await p.tick(st('choose'));
    const h = p.panel();
    const big = (h.match(/class="hist-big"[^>]*>\s*<b>([^<]*)<\/b>/) || [])[1];
    eq('updates installed counts every up entry in the window: staged, restarted, from failed and halted runs', big, '6');
    ok('the big figure says "updates installed in the last 30 days"', /updates installed/.test(text(h)) && /in the last 30 days/.test(text(h)), text(h).slice(0, 120));
    eq('runs counts the runs of the last 30 local days, not one more', fig(h, 'runs'), '6');
    eq('clean is floor(100 * ok / runs): 4 of 6 is 66%', fig(h, 'clean'), '66%');
    eq('per run is the median length of the runs that were not stopped', fig(h, 'per run'), '3m 20s');
    eq('a run of an hour or more reads hours and whole minutes, never 60 minutes',
      [3600, 3725, 7170, 7199].map(p.need('histDur')), ['1h 00m', '1h 02m', '2h 00m', '2h 00m']);
    const inWin = p.need('histWindow')(MAIN).map((r) => r.id);
    eq('the window starts at local midnight 29 days ago and drops older runs', inWin,
      ['r-today', 'r-today-fail', 'r-yesterday', 'r-halted', 'r-10', 'r-29']);

    const q = await page(serve({ v: 1, runs: [run({ id: 'r-old', at: at(31), sec: 60, up: [{ k: 'jq', n: 'jq', o: '1', w: '2' }] })] }));
    await q.tick(st('choose'));
    const t = text(q.panel());
    ok('with no run in the window the panel says so', t.includes('No runs in the last 30 days.'), t.slice(0, 160));
    ok('and names the day of the last run', t.includes(`The last one was on ${md(31)}.`), t.slice(0, 160));
  });

  /* 2. the per-day chart */
  await check('the per-day chart', async () => {
    const p = await page(serve({ v: 1, runs: MAIN }));
    await p.tick(st('choose'));
    const days = p.need('histDays')(p.need('histWindow')(MAIN));
    const dayLine = p.need('dayLine');
    const same = (d, back) => d instanceof Date && d.getTime() === dayStart(back).getTime();
    eq('the chart has 30 days', days.length, 30);
    ok('the first day is 29 days ago', days.length && same(new Date(days[0].d.getFullYear(), days[0].d.getMonth(), days[0].d.getDate()), 29));
    ok('today is the last day', days.length && same(new Date(days[29].d.getFullYear(), days[29].d.getMonth(), days[29].d.getDate()), 0));
    const pick = (x) => x && { runs: x.runs, ups: x.ups, fail: x.fail };
    eq("today has its updates, its runs and its failed run", pick(days[29]), { runs: 2, ups: 3, fail: 1 });
    eq('a day with only a halted run counts no failure', pick(days[26]), { runs: 1, ups: 1, fail: 0 });
    eq('a day with no run is empty', pick(days[1]), { runs: 0, ups: 0, fail: 0 });
    eq("today's read-out", dayLine(days[29]), 'Today: 3 updates, 2 runs, 1 failed');
    eq("a run day without updates reads 'nothing to update'", dayLine(days[0]), `${md(29)}: nothing to update`);
    eq('an empty day reads "no run"', dayLine(days[1]), `${md(28)}: no run`);

    const bars = chartDays(p.panel());
    eq('the chart draws 30 days', bars.length, 30);
    ok('the last bar is today', bars.length === 30 && bars[29].cls.includes('today') && bars.filter((x) => x.cls.includes('today')).length === 1);
    ok("today's bar is marked failed", bars.length === 30 && bars[29].cls.includes('fail'));
    ok('a halted-only day is not marked failed', bars.length === 30 && !bars[26].cls.includes('fail'));
    ok('a day with no run has no bar', bars.length === 30 && bars[1].h === 0, bars[1] && bars[1].h);
    ok('a day with a run has a bar', bars.length === 30 && bars[0].h > 0 && bars[29].h > 0);
  });

  /* 3. updated most often */
  await check('updated most often', async () => {
    const ups = {
      0: [{ k: 'node', n: 'node', o: '24.9.0', w: '24.10.0', slug: 'nodedotjs' }, { k: 'jq', n: 'jq', o: '1.7.1', w: '1.8.1' }],
      1: [{ k: 'git', n: 'git', o: '2.51.0', w: '2.51.1' }], 2: [{ k: 'slack', n: 'Slack', o: '4.46', w: '4.47' }],
      3: [{ k: 'ffmpeg', n: 'ffmpeg', o: '8.0', w: '8.0_1' }], 4: [{ k: 'python@3.13', n: 'python@3.13', o: '3.13.7', w: '3.13.8', slug: 'python' }],
      5: [{ k: 'gh', n: 'gh', o: '2.81', w: '2.82', slug: 'github' }], 6: [{ k: 'git', n: 'git', o: '2.50.1', w: '2.51.0' }],
      7: [{ k: 'slack', n: 'Slack', o: '4.45', w: '4.46' }], 8: [{ k: 'ffmpeg', n: 'ffmpeg', o: '7.1', w: '8.0' }],
      9: [{ k: 'python@3.13', n: 'python@3.13', o: '3.13.6', w: '3.13.7', slug: 'python' }],
      11: [{ k: 'gh', n: 'gh', o: '2.80', w: '2.81', slug: 'github' }],
      12: [{ k: 'node', n: 'node', o: '24.8.0', w: '24.9.0', slug: 'nodedotjs' }], 20: [{ k: 'git', n: 'git', o: '2.50.0', w: '2.50.1' }],
      21: [{ k: 'slack', n: 'Slack', o: '4.44', w: '4.45' }], 35: [{ k: 'node', n: 'node', o: '24.7.0', w: '24.8.0', slug: 'nodedotjs' }],
      40: [{ k: 'node', n: 'node', o: '24.6.0', w: '24.7.0', slug: 'nodedotjs' }],
    };
    const runs = Object.keys(ups).map(Number).sort((x, y) => x - y)
      .map((back) => run({ id: `t-${back}`, at: at(back), sec: 60, steps: [HB('done', 30)], up: ups[back] }));
    const p = await page(serve({ v: 1, runs }));
    await p.tick(st('choose'));
    const sec = sectionOf(p.panel(), 'Updated most often');
    ok('the panel has an "Updated most often" section', !!sec);
    const rows = items(sec).map((r) => ({ name: text((r.match(/<b\b[^>]*>([\s\S]*?)<\/b>/) || [])[1]), n: (text(r).match(/(\d+)×/) || [])[1], r }));
    eq('tools updated at least twice over the whole file, by count then the most recent, at most 5',
      rows.map((x) => x.name), ['node', 'git', 'Slack', 'ffmpeg', 'python@3.13']);
    eq('each tool shows how many times it was updated, older than 30 days included', rows.map((x) => x.n), ['4', '3', '3', '2', '2']);
    ok("a tool shows its newest version", rows.length > 0 && text(rows[0].r).includes('24.10.0') && !text(rows[0].r).includes('24.7.0'), rows[0] && text(rows[0].r));
    ok('the section counts since the oldest run in the file', text(sec).includes(`since ${md(40)}`), text(sec).slice(0, 80));
    ok('a tool updated once is not listed', !rows.some((x) => x.name === 'jq'));

    /* 7. logos come from the data */
    const row = (n) => (rows.find((x) => x.name === n) || { r: '' }).r;
    eq("an update with a slug shows that slug's logo", logoOf(row('node')), '#i-nodedotjs');
    eq('an update without a slug shows a monogram, even when a logo by that name exists', logoOf(row('git')), 'monogram G');
  });

  /* 4. latest runs, summed up in words */
  await check('latest runs summary', async () => {
    const p = await page(serve({ v: 1, runs: MAIN }));
    await p.tick(st('choose'));
    const sum = (r) => text(p.need('runSummary')(run(r)));
    const f = (n) => ({ k: n.toLowerCase(), n, s: 'fail', t: 3 });
    eq('one failed step is named', sum({ out: 'fail', steps: [HB('done', 9), f('npm')] }), 'npm failed');
    eq('two failed steps are both named', sum({ out: 'fail', steps: [f('npm'), f('pnpm')] }), 'npm and pnpm failed');
    eq('more failed steps: the first and how many more', sum({ out: 'fail', steps: [f('npm'), f('pnpm'), f('cargo'), f('gem')] }),
      'npm and 3 more failed');
    const net = sum({ out: 'halted', halt: 'network', steps: [HB('stopped', 40)] });
    ok('a halted run shows its halt text', /^Stopped\b/.test(net) && /network/i.test(net), net);
    ok('a step stopped by a halt is not called failed', !/fail/i.test(net) && !net.includes('Homebrew'), net);
    const sig = sum({ out: 'halted', halt: 'signal', steps: [f('npm'), HB('stopped', 40)] });
    ok('a run stopped from the terminal says so, and names only what really failed',
      sig.includes('Stopped from the terminal') && sig.includes('npm failed') && !sig.includes('Homebrew'), sig);
    eq('updates are counted and named', sum({ up: [{ k: 'node', n: 'node' }, { k: 'slack', n: 'Slack' }, { k: 'google-chrome', n: 'Google Chrome' }] }),
      '3 updated: node, Slack, Google Chrome');
    eq('one update', sum({ up: [{ k: 'node', n: 'node' }] }), '1 updated: node');
    eq('a run that changed nothing', sum({ steps: [HB('done', 9)] }), 'Everything was up to date');
    eq('failures and updates together', sum({ out: 'fail', steps: [f('npm')], up: [{ k: 'node', n: 'node' }] }), 'npm failed · 1 updated: node');
    const raw = p.need('runSummary')(run({ up: [{ k: 'x', n: '<img src=x onerror=alert(1)>' }] }));
    ok('names from the file are escaped', !raw.includes('<img') && raw.includes('&lt;img'), raw);
    const rows = runRows(p.panel());
    eq('Latest runs lists the first 5 runs of the file', rows.map((r) => r.id), ['r-today', 'r-today-fail', 'r-yesterday', 'r-halted', 'r-10']);
    ok("the halted run's row says why it stopped and not that it failed",
      /Stopped\b.*network/i.test(label(rows, 'r-halted')) && !/fail/i.test(label(rows, 'r-halted')), label(rows, 'r-halted'));
  });

  /* 5. "This run" comes from state.json */
  await check('this run', async () => {
    const NEW1 = run({ id: `${at(0, 13)}-4242`, at: at(0, 13), sec: 95, steps: [HB('done', 60)], up: [{ k: 'jq', n: 'jq', o: '1.7.1', w: '1.8.1' }] });
    const NEW2 = Object.assign({}, NEW1, { sec: 140, up: NEW1.up.concat([
      { k: 'ripgrep', n: 'ripgrep', o: '14.1.0', w: '14.1.1' }, { k: 'fd', n: 'fd', o: '10.2.0', w: '10.3.0' }]) });
    const p = await page(serve({ v: 1, runs: MAIN }));
    await p.tick(st('choose'));
    let rows = runRows(p.panel());
    ok('a run of today is labelled Today', label(rows, 'r-today').startsWith('Today'), label(rows, 'r-today'));
    ok("yesterday's run is labelled Yesterday", label(rows, 'r-yesterday').startsWith('Yesterday'), label(rows, 'r-yesterday'));
    ok('a run of this week is labelled by its weekday', label(rows, 'r-halted').startsWith(WEEK[dayStart(3).getDay()]), label(rows, 'r-halted'));
    ok('an older run is labelled by its date', label(rows, 'r-10').startsWith(md(10)), label(rows, 'r-10'));
    ok('before state.json names a run, no row is "This run"', !rows.some((r) => r.text.startsWith('This run')));
    ok('and no missing-run note shows', !text(p.panel()).includes('This run is not in history.json yet.'));

    await p.tick(st('run'));
    let before = p.fetches;
    p.doc = serve({ v: 1, runs: [NEW1].concat(MAIN) });
    const done1 = st('done', { hist: { id: NEW1.id, rev: 1 } });
    await p.tick(done1); await p.tick(done1); await p.tick(done1);
    eq('a new {id, rev} in state.json makes the page read history.json again, once', p.fetches - before, 1);
    rows = runRows(p.panel());
    ok('the run state.json names is labelled This run', label(rows, NEW1.id).startsWith('This run'), label(rows, NEW1.id));
    ok('the other runs keep their dates', label(rows, 'r-today').startsWith('Today') && label(rows, 'r-yesterday').startsWith('Yesterday'),
      `${label(rows, 'r-today')} | ${label(rows, 'r-yesterday')}`);

    // A retry round rewrites the same record: same id, the next rev.
    p.doc = serve({ v: 1, runs: [NEW2].concat(MAIN) });
    await p.tick(st('run', { round: 2, hist: { id: NEW1.id, rev: 1 } }));
    before = p.fetches;
    const done2 = st('done', { round: 2, hist: { id: NEW1.id, rev: 2 } });
    await p.tick(done2); await p.tick(done2);
    eq("a retry's new rev is read again, once", p.fetches - before, 1);
    rows = runRows(p.panel());
    ok('the rewritten record replaces the row and keeps This run',
      label(rows, NEW1.id).startsWith('This run') && label(rows, NEW1.id).includes('3 updated') && rows.filter((r) => r.id === NEW1.id).length === 1,
      label(rows, NEW1.id));

    const reload = await page(serve({ v: 1, runs: [NEW2].concat(MAIN) }));
    await reload.tick(done2); await reload.tick(done2);
    ok('after a reload the run is still This run', label(runRows(reload.panel()), NEW1.id).startsWith('This run'),
      label(runRows(reload.panel()), NEW1.id));

    const gone = await page(serve({ v: 1, runs: MAIN }));
    const missing = st('done', { hist: { id: '1790000000-77', rev: 1 } });
    await gone.tick(missing);
    const asked = gone.fetches;
    await gone.tick(missing); await gone.tick(missing); await gone.tick(missing);
    const t = text(gone.panel());
    ok('a run state.json names but history.json lacks is reported', t.includes('This run is not in history.json yet.'), t.slice(0, 200));
    eq('and the page does not keep asking for it', gone.fetches - asked, 0);
    ok('and no other run is called This run', !runRows(gone.panel()).some((r) => r.text.startsWith('This run')));
  });

  /* 6. usual time per source */
  await check('usual time per source', async () => {
    const runs = [];
    for (let back = 0; back < 14; back++) {
      const steps = [];
      if (back === 0) steps.push(HB('fail', 1), { k: 'cargo', n: 'cargo', s: 'fail', t: 50, slug: 'rust' });
      else if (back === 1) steps.push(HB('stopped', 1), { k: 'cargo', n: 'cargo', s: 'stopped', t: 60, slug: 'rust' });
      else if (back < 12) steps.push(HB(back === 5 ? 'staged' : 'done', 100 + 10 * (back - 2)));
      else steps.push(HB('done', 900));
      if (back === 2) steps.push({ k: 'npm', n: 'npm', s: 'done', t: 5, slug: 'npm' });
      if (back === 3) steps.push({ k: 'git', n: 'git', s: 'done', t: 3 });
      runs.push(run({ id: `s-${back}`, at: at(back), sec: 200, out: back === 0 ? 'fail' : back === 1 ? 'halted' : 'ok',
        halt: back === 1 ? 'signal' : undefined, steps }));
    }
    const p = await page(serve({ v: 1, runs }));
    await p.tick(st('choose'));
    const sec = sectionOf(p.panel(), 'Usual time per source');
    ok('the panel has a "Usual time per source" section', !!sec);
    const rows = items(sec).map((r) => ({
      name: text((r.match(/class="nm"[^>]*>([\s\S]*?)<\/span>/) || [])[1]),
      t: text((r.match(/class="t"[^>]*>([\s\S]*?)<\/span>/) || [])[1]), r,
    }));
    eq('sources by their usual time, longest first; a source that only failed or stopped is left out',
      rows.map((x) => x.name), ['Homebrew', 'npm', 'git']);
    eq("a source's time is the median of its last 10 done or staged entries, failed and stopped ones left out",
      (rows[0] || {}).t, '2m 25s');
    eq('a source with one entry shows that time', (rows[1] || {}).t, '5s');

    /* 7. source logos */
    const row = (n) => (rows.find((x) => x.name === n) || { r: '' }).r;
    eq('a source on this dashboard shows the logo of its row', logoOf(row('Homebrew')), 'img data:image/png;base64,TEST');
    eq("a source not on this dashboard shows its history step's slug", logoOf(row('npm')), '#i-npm');
    eq('a source without a slug shows a monogram', logoOf(row('git')), 'monogram G');
  });

  /* 7. no client-side copy of ut_icon_slug */
  ok('the page has no SLUG_ALIAS table and no histSlug guesser', !/SLUG_ALIAS|function histSlug\b/.test(html));

  /* 8. empty, broken and unknown history files */
  await check('empty and unavailable history', async () => {
    const card = async (doc, phase = 'choose') => { const p = await page(doc); await p.tick(st(phase)); return p.panel(); };
    const code = (h) => text((h.match(/<code\b[^>]*>([\s\S]*?)<\/code>/) || [])[1]);
    const why = '/Users/me/.config/updatetools/history: line 3 is not a valid run record';
    let h = await card(serve({ v: 1, error: why }));
    ok('a history file the server could not read shows "History is unavailable."', text(h).includes('History is unavailable.'), text(h).slice(0, 160));
    ok('with the reason from history.json, in mono', code(h).includes(why), code(h));
    h = await card(serve({ v: 2, runs: [] }));
    ok('an unknown version shows "History is unavailable."', text(h).includes('History is unavailable.'), text(h).slice(0, 160));
    ok('with the version it does not know', code(h).includes('history.json has an unknown format (v2)'), code(h));
    h = await card({ status: 404, statusText: 'Not Found', body: '' });
    ok('a missing history.json shows the status', text(h).includes('History is unavailable.') && code(h).includes('history.json: 404 Not Found'), code(h));
    h = await card(serve('{"v":1,"runs":['));
    ok('a history.json that is not JSON says so', code(h).includes('history.json is not valid JSON'), code(h));
    h = await card(serve({ v: 1, runs: [] }));
    ok('an empty history says "No runs recorded yet."', text(h).includes('No runs recorded yet.'), text(h).slice(0, 160));
    ok('on the chooser it says what will be recorded',
      text(h).includes('Each run is recorded here when it finishes: what it updated and how long it took.'), text(h).slice(0, 200));
    ok('an empty history has no Latest runs', !sectionOf(h, 'Latest runs'));
    h = await card(serve({ v: 1, runs: [] }), 'run');
    ok('during the first run it says this run will appear', text(h).includes('This run is the first. It appears here when it finishes.'),
      text(h).slice(0, 200));
  });

  /* 9. no alarm colour during a run */
  const css = (html.match(/<style>[\s\S]*?<\/style>/g) || []).join('\n').replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = Array.from(css.matchAll(/([^{}]+)\{([^{}]*)\}/g), (m) => ({ sels: m[1].split(',').map((s) => s.trim()), decl: m[2] }));
  const prop = (decl, names) => {
    for (const n of names) {
      const m = decl.match(new RegExp(`(?:^|;)\\s*${n}\\s*:\\s*([^;]+)`));
      if (m) return m[1].trim();
    }
    return '';
  };
  const RUN = 'html[data-phase="run"]';
  const NEUTRAL = /var\(--(?:ink(?:-[1-4])?|seg-done)\)|currentcolor|inherit/i;
  const inRun = (target, props) => rules.some((r) => r.sels.some((s) => s.includes(RUN) && s.includes(target))
    && NEUTRAL.test(prop(r.decl, props)) && !/--bad/.test(prop(r.decl, props)));
  const outside = (target, props) => rules.some((r) => r.sels.some((s) => s.includes(target) && !s.includes(RUN))
    && /--bad/.test(prop(r.decl, props)));
  const BG = ['background', 'background-color'], FG = ['color'];
  ok('during a run, failed days in the chart are neutral', inRun('.hist-day.fail', BG));
  ok('during a run, the mark of a failed run is neutral', inRun('.hist-mark.fail', FG));
  ok('during a run, the "A failed" text is neutral', inRun('.hist-sum em', FG));
  ok('in choose and done, failed days are red', outside('.hist-day.fail', BG));
  ok('in choose and done, the mark of a failed run is red', outside('.hist-mark.fail', FG));
  ok('in choose and done, the "A failed" text is red', outside('.hist-sum em', FG));

  process.exit(Math.min(fails, 255));
})();
NODE
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "all history page tests passed"
  exit 0
fi
echo "$rc test(s) failed"
exit "$rc"
