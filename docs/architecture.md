# Architecture

```text
                      ┌───────────────────────────┐
                      │  Plugin Manager settings  │
                      │  (PluginInfoProvider.lua) │
                      │                           │
                      │  • server URL / API key   │
                      │  • path mappings (text)   │
                      │  • enable logging         │
                      └────────────┬──────────────┘
                                   │ reads/writes
                                   ▼
                          ┌─────────────────┐
                          │   Settings.lua  │  ── LrPrefs JSON blobs
                          └────────┬────────┘
                                   │
    ┌──────────────────────────────┼──────────────────────────────┐
    │                              │                              │
    ▼                              ▼                              ▼
menu/LinkCollectionDialog.lua  menu/UnlinkAction.lua       menu/SyncDialog.lua
    │                              │                              │
    └──────────────┬───────────────┘                              │
                   ▼                                              ▼
             MappingStore.lua      PathMapper.lua          CatalogIndex.lua
             (collection → album)  (immich ↔ local)        (path → LrPhoto)
                   │                      │                      │
                   └──────────────────────┼──────────────────────┘
                                          ▼
                                  SyncEngine.lua
                         (computeDiff, applyDiff — pure-ish)
                                          │
                                          ▼
                                   ImmichAPI.lua
                             (ping, listAlbums, getAlbum,
                              add/remove album assets)
```

## Module responsibilities

### Pure, unit-testable

- **PathMapper** — translates Immich ↔ local paths by longest-prefix match.
  Host-OS case-folding policy. No globals, no I/O.
- **MappingStore** — CRUD over a JSON blob in `LrPrefs` keyed by LR
  collection `localIdentifier`. Injectable backend makes it trivially
  testable.
- **CatalogIndex** — builds a `path → LrPhoto` map from a given list of
  photos. Caller injects case-folding. Caller passes photos; the LR
  catalog call lives outside the module.
- **ImmichAPI** — the only HTTP client. Constructor takes an injectable
  `http` transport and `sleep` function, making retry/backoff testable.
- **SyncEngine.computeDiff** — pure. Given collection photos, album
  assets, a PathMapper, and a CatalogIndex, returns a diff for the chosen
  direction with explicit warnings for unresolvable items. For
  **Immich → Lightroom**, mapped files that exist locally but are not in
  the Lightroom catalog become `toImportLocal` entries.
- **SyncEngine.applyDiff** — injectable mutation step. It can also process
  caller-approved `toDownloadLocal` entries by downloading asset bytes, saving
  them outside the catalog write lock, importing the saved files, and adding the
  imported photos to the Lightroom collection.

### LR-coupled

- **PluginInfoProvider** — Plugin Manager UI.
- **menu/LinkCollectionDialog** — album-picker + persist mapping.
- **menu/UnlinkAction** — remove mapping.
- **menu/SyncDialog** — ties it all together: fetch album, build index,
  ask direction, preview, apply. It injects Lightroom file-existence checks
  and `catalog:addPhotos(paths)` so Immich→Lightroom can import existing
  local files into the catalog before adding them to the collection. When
  unmapped Immich assets remain, it asks for explicit confirmation and a
  destination folder before enabling the download/import fallback.
- **Init.lua** — logger bootstrap only.

### Infrastructure

- **util/Paths** — pure path helpers. Tested.
- **util/Logger** — thin LrLogger wrapper.
- **util/Errors** — structured error type + renderer.
- **vendor/JSON.lua**, **vendor/inspect.lua** — upstream-maintained libs.

## Why no Publish Service?

Lightroom's Publish Service API is strictly push (LR → remote) and does
not fire callbacks when the user drags photos in/out of a published
collection. That makes bidirectional sync fundamentally impossible to
implement on top of Publish Services. See
[../docs/lightroom-sdk-notes.md](lightroom-sdk-notes.md) for sources.

## Why membership-only?

Membership changes are cheap and deterministic: two finite ID sets, set
difference in both directions. The normal catalog import we perform is
Lightroom registering an already-local mapped file during **Immich →
Lightroom** sync. Download/import is deliberately limited to an explicit
fallback for unmapped assets after preview confirmation and destination-folder
selection. We still do not upload, move, rename, transform, or continuously sync
files. Broader file-transfer features remain out of scope. See
[future/00-roadmap.md](future/00-roadmap.md).
