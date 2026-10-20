#!/usr/bin/env bash
# A project's logo is its own, or none (a monogram), never a stand-in:
#   * DuckDuckGo's icon service answers a site it has no icon for with 404 and
#     a generic grey placeholder; that placeholder is never anyone's logo, and
#     one an earlier version cached is not used again;
#   * a site with no icon of its own falls back, in order, to: the GitHub
#     org's avatar for <org>.github.io; the parent domain's icon
#     (openmp.llvm.org -> llvm.org); the avatar of the GitHub org its source
#     comes from (Homebrew's stable or head URL);
#   * with none of these, there is no logo file.
# This holds for the plan's logos, the run's record, and the History panel.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(command -v python3)" || { echo "not ok - python3 is required to run this test"; exit 1; }
JQ="$(command -v jq)" || { echo "not ok - jq is required to run this test"; exit 1; }
tmp="$(mktemp -d /tmp/updatetools-siteicons.XXXXXX)"
export HOME="$tmp/home" TMPDIR="$tmp/scratch" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME" "$TMPDIR" "$tmp/bin" "$tmp/net" "$tmp/brew"
ln -s "$PY" "$tmp/bin/python3"
ln -s "$JQ" "$tmp/bin/jq"

# The network: $tmp/net/<url with / : ? = & as _> is a 200 body; a .404 file
# is a 404 whose body is the placeholder. curl -f/--fail fails on a 404 (exit
# 22, writes nothing); without it the placeholder is written as if it were fine.
PLACEHOLDER="$tmp/placeholder"
printf '\211PNG\r\n\032\nduckduckgo-grey-placeholder' > "$PLACEHOLDER"
cat > "$tmp/bin/curl" <<EOF
#!/bin/bash
out="" url="" fail=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    --max-time|-m) shift ;;
    --fail) fail=1 ;;
    --*) ;;
    -*) case "\$1" in *f*) fail=1 ;; esac ;;
    *) url="\$1" ;;
  esac
  shift
done
printf '%s\n' "\$url" >> "$tmp/requests"
f="$tmp/net/\$(printf '%s' "\$url" | tr '/:?=&' '_____')"
if [ -f "\$f" ]; then cp "\$f" "\${out:-/dev/stdout}"; exit 0; fi
if [ -f "\$f.404" ]; then
  [ "\$fail" = 1 ] && exit 22
  cp "$PLACEHOLDER" "\${out:-/dev/stdout}"; exit 0
fi
exit 6
EOF
# Homebrew's metadata: $tmp/brew/<name>.json is one formula's JSON.
cat > "$tmp/bin/brew" <<EOF
#!/bin/bash
[ "\$1" = info ] || exit 1
shift
cask=0 names=()
for a in "\$@"; do
  case "\$a" in --cask) cask=1 ;; --*) ;; *) names+=("\$a") ;; esac
done
if [ "\$cask" = 1 ]; then echo '{"formulae":[],"casks":[]}'; exit 0; fi
printf '{"formulae":['
sep=""
for n in "\${names[@]}"; do
  [ -f "$tmp/brew/\$n.json" ] || continue
  printf '%s' "\$sep"; cat "$tmp/brew/\$n.json"; sep=","
done
printf '],"casks":[]}\n'
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/brew"

export UPDATETOOLS_LIB_ONLY=1
# shellcheck source=../updatetools
source "$ROOT/updatetools"
# Sourcing puts Homebrew's bin dir first (brew shellenv); only the fakes stay.
export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
trap 'cleanup; rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

# Image bytes go through printf into files: a shell variable cannot hold the
# NUL bytes an .ico starts with.
img() { case "$1" in png) printf '\211PNG\r\n\032\n%s' "$2" ;; ico) printf '\000\000\001\000%s' "$2" ;; esac; }
net() { img "$2" "$3" > "$tmp/net/$(printf '%s' "$1" | tr '/:?=&' '_____')"; }
net404() { : > "$tmp/net/$(printf '%s' "$1" | tr '/:?=&' '_____').404"; }
formula() { # NAME HOMEPAGE STABLE HEAD
  printf '{"name":"%s","full_name":"%s","homepage":"%s","urls":{"stable":{"url":"%s"},"head":%s}}' \
    "$1" "$1" "$2" "$3" "$( [ -n "$4" ] && printf '{"url":"%s"}' "$4" || printf null)" > "$tmp/brew/$1.json"
}
DDG=https://icons.duckduckgo.com/ip3

formula c-ares https://c-ares.org/ https://github.com/c-ares/c-ares/releases/download/v1.34.9/c-ares-1.34.9.tar.gz ""
net "$DDG/c-ares.org.ico" ico c-ares-favicon
formula pgbackrest https://pgbackrest.org https://github.com/pgbackrest/pgbackrest/releases/download/release/2.60.0/pgbackrest-2.60.0.tar.gz ""
net404 "$DDG/pgbackrest.org.ico"
net "https://github.com/pgbackrest.png?size=128" png pgbackrest-org-avatar
formula simdutf https://simdutf.github.io/simdutf/ https://github.com/simdutf/simdutf/archive/refs/tags/v9.3.2.tar.gz https://github.com/simdutf/simdutf.git
net404 "$DDG/simdutf.github.io.ico"
net "https://github.com/simdutf.png?size=128" png simdutf-org-avatar
formula libomp https://openmp.llvm.org/ https://github.com/llvm/llvm-project/releases/download/llvmorg-23.1.4/llvm-project-23.1.4.src.tar.xz ""
net404 "$DDG/openmp.llvm.org.ico"
net "$DDG/llvm.org.ico" ico llvm-favicon
net "https://github.com/llvm.png?size=128" png llvm-org-avatar
formula nowhere https://nowhere.example/ https://nowhere.example/nowhere-1.0.tar.gz ""
net404 "$DDG/nowhere.example.ico"
formula libssh2 https://libssh2.org/ https://libssh2.org/download/libssh2-1.11.1.tar.gz https://github.com/libssh2/libssh2.git
net404 "$DDG/libssh2.org.ico"
net "https://github.com/libssh2.png?size=128" png libssh2-org-avatar
formula stale https://stale.example/ https://stale.example/stale-1.0.tar.gz ""
net "$DDG/stale.example.ico" ico stale-real-favicon

# An earlier version cached the placeholder for stale.example and ghost.example.
C="$XDG_CACHE_HOME/updatetools/icons"
mkdir -p "$C"
cp "$PLACEHOLDER" "$C/stale.example"
cp "$PLACEHOLDER" "$C/ghost.example"

# The plan's logos.
P="$tmp/plan"; mkdir -p "$P/icons"
ut_plan_formula_icons "$P" c-ares pgbackrest simdutf libomp nowhere >/dev/null 2>&1
icon_is() { # FILE-BASE png|ico TEXT
  local f
  img "$2" "$3" > "$tmp/want"
  for f in "$1".png "$1".ico "$1".jpg "$1".webp; do
    [ -f "$f" ] && { cmp -s "$f" "$tmp/want"; return; }
  done
  return 1
}
icon_is "$P/icons/c-ares" ico c-ares-favicon && pass "plan: a site with an icon shows it" \
  || fail "plan: a site with an icon shows it"
icon_is "$P/icons/simdutf" png simdutf-org-avatar && pass "plan: <org>.github.io with no icon shows the GitHub org's avatar" \
  || fail "plan: <org>.github.io with no icon shows the GitHub org's avatar"
icon_is "$P/icons/libomp" ico llvm-favicon && pass "plan: a subdomain with no icon shows its parent domain's icon" \
  || fail "plan: a subdomain with no icon shows its parent domain's icon"
icon_is "$P/icons/pgbackrest" png pgbackrest-org-avatar && pass "plan: a site with no icon shows the avatar of the GitHub org its source comes from" \
  || fail "plan: a site with no icon shows the avatar of the GitHub org its source comes from"
ls "$P/icons/nowhere".* >/dev/null 2>&1 && fail "plan: with no icon anywhere there is no logo file ($(ls "$P/icons"))" \
  || pass "plan: with no icon anywhere there is no logo file"
if grep -rl 'duckduckgo-grey-placeholder' "$P" "$C" >/dev/null 2>&1; then
  fail "plan: the placeholder is never anyone's logo ($(grep -rl 'duckduckgo-grey-placeholder' "$P" "$C" | tr '\n' ' '))"
else
  pass "plan: the placeholder is never anyone's logo"
fi

# The run's record (no plan icons): logos come from Homebrew's cached metadata.
printf '%s\n' 'libssh2|libssh2|1.11.0|1.11.1||' 'stale|stale|1.0|1.1||' 'nowhere|nowhere|1.0|1.1||' > "$tmp/updates"
UT_PLAN_DIR=""
printf '[%s]' "$(ut_web_updates "$tmp/updates" 2>/dev/null)" > "$tmp/updates.json"
"$PY" -I - "$tmp/updates.json" <<'PY' || failures=$((failures + 1))
import base64, json, sys
fails = 0
def ok(name, cond, why=''):
    global fails
    print(('ok - ' if cond else 'not ok - ') + name + ('' if cond else ' (%s)' % (why,)))
    if not cond: fails += 1
try:
    ups = {u['n']: u for u in json.load(open(sys.argv[1]))}
except Exception as e:
    print('not ok - the run record is JSON (%s)' % e); sys.exit(1)
def img(n):
    u = ups.get(n, {}).get('img', '')
    return base64.b64decode(u.split(',', 1)[1]) if u.startswith('data:') else None
ok("record: a site with no icon shows the avatar of the GitHub org its source comes from (Homebrew's head URL)",
   img('libssh2') == b'\x89PNG\r\n\x1a\nlibssh2-org-avatar', img('libssh2'))
ok('record: a placeholder an earlier version cached is fetched again, not shown',
   img('stale') == b'\x00\x00\x01\x00stale-real-favicon', img('stale'))
ok('record: with no icon anywhere there is no logo (a monogram)', img('nowhere') is None, img('nowhere'))
sys.exit(1 if fails else 0)
PY

# The History panel serves no placeholder either.
printf '%s' https://ghost.example/ > "$C/ghost.url"; : > "$C/ghost.meta"; printf ghost > "$C/ghost.name"
export UPDATETOOLS_HISTORY_FILE="$tmp/history"
printf '%s\n' '{"v":1,"id":"1-1","at":1,"sec":5,"mode":"dashboard","out":"ok","steps":[],"up":[{"k":"ghost","n":"ghost","o":"1","w":"2"},{"k":"libssh2","n":"libssh2","o":"1","w":"2"}]}' > "$UPDATETOOLS_HISTORY_FILE"
WEB_DIR="$tmp/web"; mkdir -p "$WEB_DIR"
ut_history_serve 2>/dev/null
"$PY" -I - "$WEB_DIR" <<'PY' || failures=$((failures + 1))
import json, os, sys
web = sys.argv[1]
up = {u['k']: u for r in json.load(open(os.path.join(web, 'history.json')))['runs'] for u in r['up']}
g = up.get('ghost', {})
good = 'img' not in g
print(('ok' if good else 'not ok') + ' - history: a placeholder an earlier version cached is not served as a logo' + ('' if good else ' (%s)' % g))
l = up.get('libssh2', {})
p = os.path.join(web, l.get('img', 'none'))
good2 = os.path.isfile(p) and open(p, 'rb').read() == b'\x89PNG\r\n\x1a\nlibssh2-org-avatar'
print(('ok' if good2 else 'not ok') + " - history: the logo found through the fallbacks is the one served" + ('' if good2 else ' (%s)' % l))
sys.exit(0 if good and good2 else 1)
PY

if [ "$failures" -eq 0 ]; then
  echo "all site icon tests passed"
  exit 0
fi
echo "$failures test(s) failed"
exit 1
