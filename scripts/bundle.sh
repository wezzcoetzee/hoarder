#!/usr/bin/env bash
# Builds dist/Hoarder.app from the HoarderApp target. Notifications and Open at login only work
# from the bundle. Pass --install to copy it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HoarderApp
app=dist/Hoarder.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/HoarderApp" "$app/Contents/MacOS/HoarderApp"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

if [ "${1:-}" = --install ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Hoarder.app
  cp -R "$app" ~/Applications/
  app=~/Applications/Hoarder.app
fi
echo "$app"
