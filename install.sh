#!/bin/bash
# Installs the latest Tally release into ~/Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/Sha-Dox/Tally/master/install.sh | bash
set -euo pipefail

REPO="Sha-Dox/Tally"
DEST="$HOME/Applications"

if [[ "$(uname)" != "Darwin" ]]; then echo "Tally runs on macOS only." >&2; exit 1; fi
major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 26 )); then echo "Tally needs macOS 26 or later (this Mac has $(sw_vers -productVersion))." >&2; exit 1; fi

echo "Finding the latest release…"
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
if [[ -z "$url" ]]; then echo "Couldn't find a release to download." >&2; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $(basename "$url")…"
curl -fsSL "$url" -o "$tmp/Tally.zip"
ditto -x -k "$tmp/Tally.zip" "$tmp"

pkill -x Tally 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Tally.app"
mv "$tmp/Tally.app" "$DEST/"
# The build isn't notarized, so clear the download quarantine flag.
xattr -dr com.apple.quarantine "$DEST/Tally.app" 2>/dev/null || true

open "$DEST/Tally.app"
echo "Tally is installed in $DEST and running. Look for it in your menu bar."
