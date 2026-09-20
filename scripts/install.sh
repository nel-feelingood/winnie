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

# A first install has no sprites yet; later ones keep whatever the user has put there.
SPRITES="$HOME/Library/Application Support/Winnie/Sprites"
if [ -z "$(ls -A "$SPRITES" 2>/dev/null)" ]; then
    swift scripts/import-sprites.swift
fi
open "$TARGET"
echo "Installed $TARGET"
