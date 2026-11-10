#!/bin/bash
# Builds the app, copies it to /Applications (replacing an older copy) and opens it.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications/DiscordActivity.app"
pkill -x DiscordActivity 2>/dev/null || true
rm -rf "$DEST"
cp -R build/DiscordActivity.app "$DEST"
open "$DEST"
echo "Instalada en $DEST. Busca su icono en la barra de menú."
