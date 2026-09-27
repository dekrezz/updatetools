#!/usr/bin/env bash
# --self-update installs the released version the Homebrew formula pins, and
# only when the downloaded tarball matches the formula's sha256.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/updatetools-selfupdate.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export UPDATETOOLS_LIB_ONLY=1
mkdir -p "$HOME"
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

TAG="2099.01.02"
# Release tarball fixture, laid out like a GitHub tag archive.
mkdir -p "$tmp/src/updatetools-$TAG"
cat > "$tmp/src/updatetools-$TAG/updatetools" <<'EOF'
#!/usr/bin/env bash
# Licensed under the Apache License, Version 2.0 (the "License");
# UPDATETOOLS_REV=dev
echo released
EOF
(cd "$tmp/src" && tar -czf "$tmp/release.tar.gz" "updatetools-$TAG")
good_sha="$(shasum -a 256 "$tmp/release.tar.gz" | awk '{print $1}')"

write_formula() {  # $1 sha256
  cat > "$tmp/formula.rb" <<EOF
class Updatetools < Formula
  desc "test"
  url "https://github.com/dekrezz/updatetools/archive/refs/tags/$TAG.tar.gz"
  sha256 "$1"
end
EOF
}

# Fake network: serve fixtures by URL, record every URL requested. FIXTURES, not
# tmp: the function under test has its own `local tmp`, visible to this mock.
FIXTURES="$tmp"
fetched="$tmp/fetched"
curl() {
  local url="" out="" a
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -o) out="$1"; shift ;;
      -*) ;;
      *) url="$a" ;;
    esac
  done
  printf '%s\n' "$url" >> "$FIXTURES/fetched"
  case "$url" in
    */Formula/updatetools.rb) cp "$FIXTURES/formula.rb" "$out" ;;
    */archive/refs/tags/"$TAG".tar.gz) cp "$FIXTURES/release.tar.gz" "$out" ;;
    *) return 22 ;;
  esac
}

target="$tmp/bin/updatetools"
mkdir -p "$tmp/bin"
updatetools_resolve_self() { printf '%s\n' "$target"; }
reset_target() { printf '#!/usr/bin/env bash\necho old\n' > "$target"; : > "$fetched"; }

# ---------------------------------------------------------------------------
reset_target
write_formula "$good_sha"
out="$( (updatetools_self_update) 2>&1 )"; rc=$?
assert_eq "verified release installs" "0" "$rc"
assert_contains "installed file is the release" "$(cat "$target")" "echo released"
assert_contains "installed copy is stamped with the tag" "$(cat "$target")" "# UPDATETOOLS_REV=$TAG"
assert_contains "output names the release" "$out" "$TAG"
assert_not_contains "main is never downloaded" "$(cat "$fetched")" "/main/updatetools"
if [ -x "$target" ]; then pass "installed copy is executable"; else fail "installed copy is executable"; fi

reset_target
write_formula "0000000000000000000000000000000000000000000000000000000000000000"
out="$( (updatetools_self_update) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then pass "checksum mismatch fails"; else fail "checksum mismatch fails"; fi
assert_contains "checksum mismatch is explained" "$out" "sha256"
assert_contains "mismatch leaves the installed copy alone" "$(cat "$target")" "echo old"

reset_target
printf 'class Updatetools < Formula\nend\n' > "$tmp/formula.rb"
out="$( (updatetools_self_update) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then pass "formula without a release pin fails"; else fail "formula without a release pin fails"; fi
assert_contains "unpinned formula leaves the installed copy alone" "$(cat "$target")" "echo old"

reset_target
rm -rf "$tmp/src/updatetools-$TAG/updatetools"
printf 'x\n' > "$tmp/src/updatetools-$TAG/README"
(cd "$tmp/src" && tar -czf "$tmp/release.tar.gz" "updatetools-$TAG")
write_formula "$(shasum -a 256 "$tmp/release.tar.gz" | awk '{print $1}')"
out="$( (updatetools_self_update) 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then pass "release without the script fails"; else fail "release without the script fails"; fi
assert_contains "missing script leaves the installed copy alone" "$(cat "$target")" "echo old"

if [ "$failures" -ne 0 ]; then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all self-update checks passed"
