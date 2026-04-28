# Agents & contributors guide

This file is the entry point for both humans and AI agents working in this
repository. Read it first before touching code.

## What this repo is

A **Lightroom Classic** plugin that keeps the membership of an Immich album
in sync with a Lightroom collection — bidirectionally, on demand, without
ever transferring photo files. Both sides are expected to see the same
files on disk; the plugin translates Immich storage paths to Lightroom-
visible paths using a user-configured prefix mapping table.

The plugin registers **no export or publish service**. Everything is driven
by menu items under `Library > Plug-in Extras > Immich Collection Sync: …`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/` | The single source of truth for the plugin. `build.sh` copies this verbatim into `dist/lrc-immich-collection-sync-plugin.lrplugin/`. |
| `tests/` | Pure-Lua 5.1 unit tests. Run with `./test.sh` (needs `luajit` or `lua5.1`). |
| `docs/` | Design notes. Start with `docs/architecture.md`. Future work lives under `docs/future/`. |
| `.agents/skills/` | Skill files that agents should load when touching specific kinds of work. |
| `build.sh` / `build.bat` | Build the `.lrplugin` bundle. |
| `test.sh` | Run unit tests. |
| `dist/` | Build output. Gitignored. |

## Before you change code

1. Read `docs/architecture.md` — the module responsibilities are intentional;
   do not move business logic into UI layers.
2. Read `docs/lightroom-sdk-notes.md` — the SDK has real gotchas, all with
   source URLs. In particular: **Publish Services are one-way**, there is
   **no `LrCatalog:findPhotoByPath`**, and `LrLibraryMenuItems` must be
   declared **once** in `Info.lua`.
3. If you are working with anything Lightroom-SDK-shaped, load
   `.agents/skills/lightroom-plugin-dev/SKILL.md` first.

## Dev loop

```sh
./test.sh            # run unit tests (fast, no Lightroom needed)
./build.sh           # produce dist/lrc-immich-collection-sync-plugin.lrplugin/
# In Lightroom: File > Plug-in Manager… > Add > select dist/lrc-immich-collection-sync-plugin.lrplugin
```

## Style

- Pure-logic modules (`PathMapper`, `MappingStore`, `SyncEngine`,
  `CatalogIndex`, `ImmichAPI`) must stay unit-testable. Inject LR
  dependencies through constructor opts, never reach for globals.
- Menu scripts under `src/menu/` are thin. They orchestrate dialogs and
  delegate to the pure modules above.
- No `printf`-style error reporting. Use the `(value, err)` convention
  where `err` is an `util.Errors.make(code, message, details)` table.

## Scope discipline

The plugin is deliberately narrow: **album ↔ collection membership only**.
Anything beyond that — metadata sync, matching without prefix mapping,
multi-server, background sync — is tracked as a future initiative under
`docs/future/`. Do not expand scope in unrelated PRs.
