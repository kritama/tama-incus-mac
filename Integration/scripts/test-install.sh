#!/bin/sh
# Verifies the single local install command in an isolated prefix.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
prefix=$(mktemp -d "${TMPDIR:-/tmp}/tama-incus-mac-prefix.XXXXXX")
sentinel=$(mktemp -d "${TMPDIR:-/tmp}/tama-incus-mac-state.XXXXXX")
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

# A redirected destination must be refused before either executable is copied.
# Test each executable separately and compare the existing sibling as well.
for kind in bin daemon client dangling; do
  unsafe="$prefix/unsafe-$kind"
  outside="$sentinel/outside-$kind"
  mkdir -p "$unsafe" "$outside"
  printf 'outside daemon\n' > "$outside/tama-incus-mac"
  printf 'outside client\n' > "$outside/tim"
  if [ "$kind" = bin ]; then
    ln -s "$outside" "$unsafe/bin"
  else
    mkdir "$unsafe/bin"
    printf 'existing daemon\n' > "$unsafe/bin/tama-incus-mac"
    printf 'existing client\n' > "$unsafe/bin/tim"
    case "$kind" in
      daemon)
        rm "$unsafe/bin/tama-incus-mac"
        ln -s "$outside/tama-incus-mac" "$unsafe/bin/tama-incus-mac"
        ;;
      client)
        rm "$unsafe/bin/tim"
        ln -s "$outside/tim" "$unsafe/bin/tim"
        ;;
      dangling)
        rm "$unsafe/bin/tim"
        ln -s "$outside/missing" "$unsafe/bin/tim"
        ;;
    esac
  fi
  if sh Packaging/install-local.sh --prefix "$unsafe" >"$prefix/refused-$kind.err" 2>&1; then
    echo "symlink destination $kind was accepted" >&2
    exit 1
  fi
  grep -q 'Refusing to install through symlink destinations' "$prefix/refused-$kind.err"
  test "$(cat "$outside/tama-incus-mac")" = 'outside daemon'
  test "$(cat "$outside/tim")" = 'outside client'
  if [ "$kind" = client ] || [ "$kind" = dangling ]; then
    test "$(cat "$unsafe/bin/tama-incus-mac")" = 'existing daemon'
  fi
  if [ "$kind" = daemon ]; then
    test "$(cat "$unsafe/bin/tim")" = 'existing client'
  fi
  test ! -e "$outside/missing"
done

sh Packaging/install-local.sh --prefix "$prefix"
test -x "$prefix/bin/tama-incus-mac"
test -x "$prefix/bin/tim"
codesign --verify --strict "$prefix/bin/tama-incus-mac"
codesign --verify --strict "$prefix/bin/tim"
codesign -d --entitlements :- "$prefix/bin/tama-incus-mac" 2>/dev/null | grep -q 'com.apple.security.virtualization'
if codesign -d --entitlements :- "$prefix/bin/tim" 2>/dev/null | grep -q 'com.apple.security.virtualization'; then
  echo "installed tim has the virtualization entitlement" >&2
  exit 1
fi
"$prefix/bin/tim" --help | grep -q 'runtime status'
"$prefix/bin/tama-incus-mac" --help | grep -q 'tama-incus-mac serve'
"$prefix/bin/tama-incus-mac" capabilities | grep -q 'apple-vz'
after=$(stat -f '%m %z' "$sentinel/marker")
test "$before" = "$after"
if [ "$home_state_absent" -eq 1 ] && [ -e "${HOME}/.tama/incus-mac" ]; then
  echo "install created the normal state directory" >&2
  exit 1
fi
echo "isolated prefix install verified"
