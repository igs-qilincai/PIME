#!/bin/bash
# Install PIME.app into ~/Library/Input Methods and register it.
#
# Usage: install.sh [path/to/PIME.app]
#
# Written with assistance from Claude Code (Claude Opus 5.5).

set -euo pipefail

APP_SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/PIME.app}"
DEST_DIR="$HOME/Library/Input Methods"
DEST="$DEST_DIR/PIME.app"

if [ ! -d "$APP_SRC" ]; then
    echo "$APP_SRC not found. Run scripts/build_app.sh first." >&2
    exit 1
fi

# Quit the running instance so that the new one gets loaded. Its Python
# backend exits by itself once its stdin is closed.
pkill -x PIME || true
sleep 1

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
"$DEST/Contents/MacOS/PIME" --install
# Start it now. The system launcher (imklaunchagent) may not know a newly
# installed input method until the next login.
open -g "$DEST"

echo "Installed $DEST"
echo "If 新酷音 (PIME) is not in the input menu yet, add it in"
echo "System Settings > Keyboard > Text Input > Input Sources (Chinese, Traditional)."
