#!/usr/bin/env bash
# Build the distributable Lightroom Classic plugin bundle from src/.
#
# Ships plain .lua sources (not luac bytecode): keeps the plugin debuggable
# and avoids a Lua-version mismatch between the build host and Lightroom's
# embedded Lua 5.1.
set -euo pipefail
cd "$(dirname "$0")"

OUT="dist/lrc-immich-collection-sync-plugin.lrplugin"
LEGACY_OUT="dist/immich-sync.lrplugin"
rm -rf "$OUT" "$LEGACY_OUT"
mkdir -p "$OUT"

echo "Copying sources → $OUT"
cp -R src/* "$OUT/"

if [ ! -f "$OUT/Info.lua" ]; then
    echo "ERROR: $OUT/Info.lua missing." >&2
    exit 1
fi

echo "Build complete: $OUT"
echo
echo "To install in Lightroom Classic:"
echo "  File > Plug-in Manager… > Add > select $OUT"
