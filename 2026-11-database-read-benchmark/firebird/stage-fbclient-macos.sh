#!/usr/bin/env bash
# Stages a usable Firebird 5 client directory on macOS without installing Firebird.
# Input: the official package Firebird-5.0.4.1812-0-macos-x64.pkg from
# https://github.com/FirebirdSQL/firebird/releases/tag/v5.0.4 (check its SHA-256 against the release).
# Output: <target>/lib/libfbclient.dylib, usable as FireDAC VendorLib.
# The package's libraries reference each other via @rpath, which only resolves inside the
# installed framework; this script rewrites those references to @loader_path and re-signs ad hoc.
set -euo pipefail
pkg="${1:?usage: stage-fbclient.sh <Firebird-*.pkg> <target-dir>}"
target="${2:?usage: stage-fbclient.sh <Firebird-*.pkg> <target-dir>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkgutil --expand-full "$pkg" "$work/x"
rm -rf "$target"
cp -R "$work/x/Firebird.pkg/Payload/Versions/A/Resources" "$target"
for f in "$target"/lib/*.dylib "$target"/plugins/*.dylib "$target"/intl/*.dylib; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  case "$f" in
    "$target"/lib/*) prefix='@loader_path/' ;;
    *) prefix='@loader_path/../lib/' ;;
  esac
  for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep '^@rpath/lib/' || true); do
    install_name_tool -change "$dep" "$prefix${dep#@rpath/lib/}" "$f"
  done
  codesign -f -s - "$f" 2>/dev/null
done
echo "VendorLib: $target/lib/libfbclient.dylib"
