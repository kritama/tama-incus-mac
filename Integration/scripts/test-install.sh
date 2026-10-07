#!/bin/sh
# Verifies the single local install command in an isolated prefix.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
prefix=$(mktemp -d "${TMPDIR:-/tmp}/macus-prefix.XXXXXX")
sentinel=$(mktemp -d "${TMPDIR:-/tmp}/macus-state.XXXXXX")
trap 'rm -rf "$prefix" "$sentinel"' EXIT INT TERM
printf 'keep\n' > "$sentinel/marker"
chmod 700 "$sentinel"
before=$(stat -f '%m %z' "$sentinel/marker")
home_state_absent=0
if [ ! -e "${HOME}/.tama/incus-mac" ]; then
  home_state_absent=1
fi

if sh Packaging/install-local.sh --prefix relative >"$prefix/relative-prefix.err" 2>&1; then
  echo "relative prefix was accepted" >&2
  exit 1
fi

# Redirected or non-file destinations must fail before copying or building.
for kind in bin executable dangling directory; do
  unsafe="$prefix/unsafe-$kind"
  outside="$sentinel/outside-$kind"
  mkdir -p "$unsafe" "$outside"
  printf 'outside macus\n' > "$outside/macus"
  if [ "$kind" = bin ]; then
    ln -s "$outside" "$unsafe/bin"
  else
    mkdir "$unsafe/bin"
    case "$kind" in
      executable) ln -s "$outside/macus" "$unsafe/bin/macus" ;;
      dangling) ln -s "$outside/missing" "$unsafe/bin/macus" ;;
      directory) mkdir "$unsafe/bin/macus" ;;
    esac
  fi
  if sh Packaging/install-local.sh --prefix "$unsafe" >"$prefix/refused-$kind.err" 2>&1; then
    echo "unsafe destination $kind was accepted" >&2
    exit 1
  fi
  grep -q 'Refusing' "$prefix/refused-$kind.err"
  test "$(cat "$outside/macus")" = 'outside macus'
  test ! -e "$outside/missing"
done

sh Packaging/install-local.sh --prefix "$prefix"
test -x "$prefix/bin/macus"
test ! -e "$prefix/bin/tama-incus-mac"
test ! -e "$prefix/bin/tim"
codesign --verify --strict "$prefix/bin/macus"
codesign -d --entitlements :- "$prefix/bin/macus" 2>/dev/null | grep -q 'com.apple.security.virtualization'
"$prefix/bin/macus" --help | grep -q 'runtime status'
"$prefix/bin/macus" --help | grep -q 'serve'
"$prefix/bin/macus" capabilities | grep -q 'apple-vz'
after=$(stat -f '%m %z' "$sentinel/marker")
test "$before" = "$after"
if [ "$home_state_absent" -eq 1 ] && [ -e "${HOME}/.tama/incus-mac" ]; then
  echo "install created the normal state directory" >&2
  exit 1
fi
echo "isolated prefix install verified"
