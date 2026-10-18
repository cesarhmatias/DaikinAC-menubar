#!/bin/bash
# Builds the app, runs the offline checks and zips it for a release:
# dist/DaikinAC-menubar-<version>.zip and its SHA-256. Nothing is uploaded.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
bash scripts/build.sh
APP="dist/DaikinAC-menubar.app"
"$APP/Contents/MacOS/DaikinACMenubar" --self-check
python3 scripts/privacy-check.py
# The binary must not carry local paths or any denied term.
if strings "$APP/Contents/MacOS/DaikinACMenubar" | grep -qE '/[U]sers/|/private/var/|/var/[f]olders/'; then
  echo "Release binary contains a local path." >&2; exit 1
fi
if [ -f .local/deny.txt ]; then
  while IFS= read -r term; do
    [ -z "$term" ] || [ "${term:0:1}" = "#" ] && continue
    if strings "$APP/Contents/MacOS/DaikinACMenubar" | grep -qiF -- "$term"; then echo "Release binary contains a denied term." >&2; exit 1; fi
  done < .local/deny.txt
fi
ZIP="dist/DaikinAC-menubar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
printf 'Release archive: %s\n' "$ZIP"
