#!/bin/bash

if [ -d "immich-export.lrplugin" ]; then
    echo "Build directory already exists."
else
    echo "Creating immich-export.lrplugin"
    mkdir "immich-export.lrplugin"
fi

echo "Compiling LUA files"
if [ -d "immich-plugin.lrplugin" ]; then
    cd immich-plugin.lrplugin || exit
    for f in *.lua; do
        if [ -f "$f" ]; then
            luac -o "../immich-export.lrplugin/$f" "$f"
        fi
    done
    cd ..

    echo "Copying icons"
    cp -r "immich-plugin.lrplugin/icons" "immich-export.lrplugin/"
else
    echo "immich-plugin.lrplugin directory not found."
fi
