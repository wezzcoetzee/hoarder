#!/usr/bin/env bash
# Renders the README screenshots into docs/screenshots from a made-up report, so no real paths ship.
# Each scripts/screenshots/states/<name>.json becomes docs/screenshots/<name>.png (keys: Snapshot.State).
# The menu bar label is taken from the overview shot.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HoarderApp
app="$(swift build -c release --show-bin-path)/HoarderApp"
out=docs/screenshots
mkdir -p "$out"

# "Scanned just now" in the footer.
report="$(mktemp -t hoarder-report).json"
trap 'rm -f "$report"' EXIT
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.scannedAt = $now' scripts/screenshots/report.json > "$report"

for state in scripts/screenshots/states/*.json; do
  name="$(basename "$state" .json)"
  "$app" --snapshot "$report" "$out/$name.png" "$state"
  if [ "$name" = overview ]; then
    mv "$out/$name-menubar.png" "$out/menubar.png"
  else
    rm "$out/$name-menubar.png"
  fi
done
ls "$out"
