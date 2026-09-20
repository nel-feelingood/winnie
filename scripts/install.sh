#!/bin/bash
# Builds Winnie and installs it into /Applications, replacing the running copy.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
TARGET="/Applications/Winnie.app"

pkill -x Winnie 2>/dev/null || true
sleep 1
rm -rf "$TARGET"
# ditto keeps the code signature and extended attributes intact.
ditto build/Winnie.app "$TARGET"
open "$TARGET"
echo "Installed $TARGET"
