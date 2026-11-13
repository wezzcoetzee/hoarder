#!/usr/bin/env bash
# Builds dist/Hoarder.app from the HoarderApp target. Notifications and Open at login only work
# from the bundle. Pass --install to copy it into ~/Applications. Set HOARDER_VERSION to stamp the
# bundle version (scripts/package.sh does this for releases).
#
# The hoarder CLI goes into Resources as hoarder-darwin-<arch>, which the app copies onto Mac devices.
# Linux devices download theirs from the release; to test unreleased changes, put CI's
# hoarder-linux-<arch> builds in dist/linux and they are bundled and copied instead.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HoarderApp
swift build -c release --product hoarder
app=dist/Hoarder.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/HoarderApp" "$app/Contents/MacOS/HoarderApp"
cp Support/Info.plist "$app/Contents/Info.plist"
if [ -n "${HOARDER_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $HOARDER_VERSION" \
    -c "Set :CFBundleVersion $HOARDER_VERSION" \
    "$app/Contents/Info.plist"
fi
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$(swift build -c release --show-bin-path)/hoarder" "$app/Contents/Resources/hoarder-darwin-$(uname -m)"
for linux in dist/linux/hoarder-linux-*; do
  [ -f "$linux" ] && cp "$linux" "$app/Contents/Resources/"
done
codesign --force --sign - "$app"

if [ "${1:-}" = --install ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Hoarder.app
  cp -R "$app" ~/Applications/
  app=~/Applications/Hoarder.app
fi
echo "$app"
