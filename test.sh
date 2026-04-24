#!/usr/bin/env bash
# Run the pure-Lua unit test suite with LuaJIT (Lua 5.1 compatible).
# Lightroom Classic embeds Lua 5.1, so running under LuaJIT / lua5.1 gives us
# the same language semantics without needing Lightroom.
set -euo pipefail

cd "$(dirname "$0")"

if command -v luajit >/dev/null 2>&1; then
    LUA=luajit
elif command -v lua5.1 >/dev/null 2>&1; then
    LUA=lua5.1
else
    echo "ERROR: neither luajit nor lua5.1 found in PATH." >&2
    echo "Install with:  brew install luajit    OR    apt install lua5.1" >&2
    exit 1
fi

exec "$LUA" tests/run.lua
