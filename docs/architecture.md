# Architecture

```
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
  direction with explicit warnings for unresolvable items.

### LR-coupled
- **PluginInfoProvider** — Plugin Manager UI.
- **menu/LinkCollectionDialog** — album-picker + persist mapping.
- **menu/UnlinkAction** — remove mapping.
- **menu/SyncDialog** — ties it all together: fetch album, build index,
  ask direction, preview, apply.
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
difference in both directions. File transfer is not — it raises a whole
universe of correctness questions (dedup, re-imports, edit propagation,
originals vs. renditions) that we deliberately defer. See
[future/00-roadmap.md](future/00-roadmap.md).
