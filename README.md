# lrc-immich-collection-sync-plugin

`lrc-immich-collection-sync-plugin` is the repository/project name.
The Lightroom Classic plugin it builds is still called **Immich Sync**.

Keep a Lightroom Classic collection in sync with an Immich album — both
directions, on demand, **without ever moving photo files**. Both sides
are expected to see the same files on disk, and you tell the plugin how
Immich's paths relate to your host paths.

## The goal in one sentence

> Manage albums in Immich all year, come back to Lightroom, and have
> those albums available as collections you can sync in either direction.

## How it works

1. Enter your Immich server URL, API key, and path-prefix mappings
   (Immich path prefix → local path prefix) in the Plugin Manager.
2. Select a Lightroom collection, pick an Immich album, and link them.
3. Open **Library > Plug-in Extras > Immich: Sync…**, choose a direction
   (LR→Immich or Immich→LR), review the preview, and apply.

The plugin **never** uploads, downloads, renames, or deletes any photo
file. It only edits *membership*: which photos are in which collection
or album.

## Install

1. Build the plugin (see below) or download `lrc-immich-collection-sync-plugin.lrplugin` from
   a CI release artifact.
2. In Lightroom Classic: `File > Plug-in Manager… > Add`, then select
   the `lrc-immich-collection-sync-plugin.lrplugin` folder.
3. In the Plugin Manager under **Immich Sync**, enter server URL + API
   key and click **Test connection**.
4. Add at least one path mapping — see [docs/path-mapping.md](docs/path-mapping.md).

If Lightroom still shows errors mentioning `ImportConfiguration.lua` or
`PluginInfo.lua`, it is still referencing the **old pre-v4 plugin**. Remove
that old entry from the Plug-in Manager and add the current
`lrc-immich-collection-sync-plugin.lrplugin` bundle again.

## Quick start menus

- `Library > Plug-in Extras > Immich: Link selected collection to album…`
- `Library > Plug-in Extras > Immich: Sync…`
- `Library > Plug-in Extras > Immich: Unlink selected collection`

## Build from source

```sh
./test.sh          # run unit tests (needs luajit or lua5.1)
./build.sh         # produces dist/lrc-immich-collection-sync-plugin.lrplugin/
```

Then install `dist/lrc-immich-collection-sync-plugin.lrplugin/` in Lightroom via the Plugin Manager.

## Limitations (on purpose)

- No upload. No download. No metadata sync yet — see
  [docs/future/01-metadata-sync.md](docs/future/01-metadata-sync.md).
- Smart collections are rejected: their membership is derived from
  rules, so "adding" a photo is a category error.
- The API key is stored in Lightroom preferences in plaintext. SDK 3.0
  does not offer a reliable encrypted-storage API.

## Documentation

- [docs/architecture.md](docs/architecture.md) — module map.
- [docs/ux-flow.md](docs/ux-flow.md) — screens and decisions.
- [docs/path-mapping.md](docs/path-mapping.md) — mapping rules and examples.
- [docs/lightroom-sdk-notes.md](docs/lightroom-sdk-notes.md) — SDK facts with sources.
- [docs/testing.md](docs/testing.md) — test harness.
- [docs/future/](docs/future/) — concrete plans for follow-up features.
- [AGENTS.md](AGENTS.md) — entry point for humans and AI agents.

## Credits

- [Jeffrey Friedl for JSON.lua](http://regex.info/blog/lua/json)
- [Enrique García Cota for inspect.lua](https://github.com/kikito/inspect.lua)
- [Min Idzelis](https://github.com/midzelis/mi.Immich.Publisher) and
  [Ben Machek](https://github.com/bmachek/lrc-immich-plugin) whose prior
  work mapped out the Immich API surface this plugin reuses.
