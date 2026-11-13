#!/usr/bin/env bash
# Builds dist/Hoarder.app, dist/Hoarder-<version>.zip and dist/Hoarder-<version>.dmg.
# Usage: scripts/package.sh [version]   (defaults to 0.1.0; the release workflow passes the tag without its v)
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-0.1.0}"
HOARDER_VERSION="$version" scripts/bundle.sh

app=dist/Hoarder.app
zip="dist/Hoarder-$version.zip"
dmg="dist/Hoarder-$version.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --keepParent "$app" "$zip"

# The shortcut must be an absolute path: ~ would expand to the build machine's home.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Hoarder -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null

echo "$zip"
echo "$dmg"
