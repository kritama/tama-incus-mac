#!/bin/sh
# Install both tama-incus-mac and tim from this repository into one prefix.
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
     [ -L "$prefix/bin/tama-incus-mac" ] ||
     [ -L "$prefix/bin/tim" ]; then
    echo "Refusing to install through symlink destinations" >&2
    exit 1
  fi
  for destination in "$prefix/bin/tama-incus-mac" "$prefix/bin/tim"; do
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

daemon_src=.build/release/tama-incus-mac
client_src=.build/release/tim
if [ ! -x "$daemon_src" ] || [ ! -x "$client_src" ]; then
  echo "Release build did not produce both tama-incus-mac and tim" >&2
  exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/tama-incus-mac-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
cp "$daemon_src" "$stage/tama-incus-mac"
cp "$client_src" "$stage/tim"
chmod 755 "$stage/tama-incus-mac" "$stage/tim"
codesign --force --sign - --entitlements Packaging/virtualization.entitlements "$stage/tama-incus-mac"
codesign --force --sign - "$stage/tim"
codesign --verify --strict "$stage/tama-incus-mac"
codesign --verify --strict "$stage/tim"
daemon_entitlements=$(codesign -d --entitlements :- "$stage/tama-incus-mac" 2>/dev/null || true)
case "$daemon_entitlements" in
  *com.apple.security.virtualization*) ;;
  *)
    echo "Staged daemon is missing the virtualization entitlement" >&2
    exit 1
    ;;
esac
client_entitlements=$(codesign -d --entitlements :- "$stage/tim" 2>/dev/null || true)
case "$client_entitlements" in
  *com.apple.security.virtualization*)
    echo "tim must not receive the virtualization entitlement" >&2
    exit 1
    ;;
esac

mkdir -p "$prefix/bin"
validate_destinations
cp "$stage/tama-incus-mac" "$prefix/bin/tama-incus-mac"
cp "$stage/tim" "$prefix/bin/tim"
chmod 755 "$prefix/bin/tama-incus-mac" "$prefix/bin/tim"
codesign --verify --strict "$prefix/bin/tama-incus-mac"
codesign --verify --strict "$prefix/bin/tim"
"$prefix/bin/tama-incus-mac" --help >/dev/null
"$prefix/bin/tim" --help >/dev/null

echo "Installed tama-incus-mac and tim into $prefix/bin"
echo "Local source installation requires Swift. These ad-hoc signatures are not notarized."
echo "Runtime state was not modified. Launchd installation remains explicit."
