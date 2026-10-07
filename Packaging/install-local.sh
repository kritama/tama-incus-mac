#!/bin/sh
# Install the unified macus executable into one prefix.
# Requires Swift. Ad-hoc signatures are development signatures, not notarization.
# Does not create runtime state or install a launch agent.
set -eu

prefix="${HOME}/.local"
if [ "$#" -eq 0 ]; then
  :
elif [ "$#" -eq 2 ] && [ "$1" = "--prefix" ]; then
  prefix=$2
else
  echo "usage: Packaging/install-local.sh [--prefix ABSOLUTE_PATH]" >&2
  exit 2
fi
case "$prefix" in
  /*) ;;
  *)
    echo "prefix must be an absolute path" >&2
    exit 2
    ;;
esac
if [ -L "$prefix" ]; then
  echo "Refusing to install through a symlink prefix" >&2
  exit 1
fi

validate_destinations() {
  if [ -L "$prefix/bin" ] ||
     [ -L "$prefix/bin/macus" ]; then
    echo "Refusing to install through symlink destinations" >&2
    exit 1
  fi
  for destination in "$prefix/bin/macus"; do
    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
      echo "Refusing a non-file executable destination" >&2
      exit 1
    fi
  done
}
validate_destinations

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
swift build -c release -Xswiftc -warnings-as-errors

binary_src=.build/release/macus
if [ ! -x "$binary_src" ]; then
  echo "Release build did not produce macus" >&2
  exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/macus-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
cp "$binary_src" "$stage/macus"
chmod 755 "$stage/macus"
codesign --force --sign - --entitlements Packaging/virtualization.entitlements "$stage/macus"
codesign --verify --strict "$stage/macus"
entitlements=$(codesign -d --entitlements :- "$stage/macus" 2>/dev/null || true)
case "$entitlements" in
  *com.apple.security.virtualization*) ;;
  *)
    echo "Staged macus is missing the virtualization entitlement" >&2
    exit 1
    ;;
esac

mkdir -p "$prefix/bin"
validate_destinations
cp "$stage/macus" "$prefix/bin/macus"
chmod 755 "$prefix/bin/macus"
codesign --verify --strict "$prefix/bin/macus"
"$prefix/bin/macus" --help >/dev/null

echo "Installed macus into $prefix/bin"
echo "Local source installation requires Swift. These ad-hoc signatures are not notarized."
echo "Runtime state was not modified. Launchd installation remains explicit."
