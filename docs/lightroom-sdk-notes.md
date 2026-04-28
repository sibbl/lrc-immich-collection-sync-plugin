# Lightroom Classic SDK notes

All statements below are verified from the source URLs listed; anything
marked ⚠️ is based on reverse-engineering of reference plugins because the
official documentation is silent.

## Primary sources

- Adobe Lightroom Classic SDK landing page — <https://developer.adobe.com/lightroom-classic/>
- Lightroom Classic SDK Guide (PDF) — distributed alongside the SDK download.
- Reference plugins used for verification:
  - `bmachek/lrc-immich-plugin` (prior state of this repo) —
    <https://github.com/bmachek/lrc-immich-plugin>
  - `midzelis/mi.Immich.Publisher` —
    <https://github.com/midzelis/mi.Immich.Publisher>

## Runtime

| Fact | Source |
| --- | --- |
| Lightroom Classic embeds Lua **5.1** | Adobe SDK Guide; also confirmed by lack of 5.2+ features in every reference plugin. |
| Plugins are loaded from a folder named `*.lrplugin` containing `Info.lua`. | Adobe SDK Guide §2. |
| In practice, Lightroom's plugin loader is stricter than plain Lua: keep runtime `require` names simple and root-level (`require 'JSON'`, `require 'Paths'`). Do not rely on `package` being available at runtime. | Observed in Lightroom Classic during this rewrite; old working plugin also used flat root-level modules. |

## Info.lua keys

| Key | Notes |
| --- | --- |
| `LrSdkVersion` / `LrSdkMinimumVersion` | We target `3.0`. |
| `LrToolkitIdentifier` | Unique reverse-DNS-ish string. Ours: `de.sibbl.lrc-immich-collection-sync-plugin`. |
| `LrPluginName` | User-visible name. |
| `LrInitPlugin` | Path to an init script, runs on load. |
| `LrPluginInfoProvider` | Path to a module returning a table with `sectionsForTopOfDialog` / `sectionsForBottomOfDialog`. |
| `LrLibraryMenuItems` | **Array** of `{ title, file }` entries added under `Library > Plug-in Extras`. ⚠️ Declaring this key twice at top level causes the first declaration to be silently dropped — the old plugin hit this (see `immich-plugin.lrplugin/Info.lua` lines 27 and 48). |
| `LrPluginInfoURL` | Shown on the Plugin Manager detail pane. |

## Catalog & collections

| Fact | Source |
| --- | --- |
| `catalog:getAllPhotos()` returns the entire catalog. Fine for indexing at the start of a sync run; may be slow on very large catalogs. | SDK reference. |
| `photo:getRawMetadata('path')` returns the absolute file path. | SDK reference `LrPhoto`. |
| There is **no** `findPhotoByPath` method. Build your own index. | Reverse-engineered: no occurrence in any reference plugin; confirmed absent in SDK reference. |
| Any catalog mutation **must** be inside `catalog:withWriteAccessDo(name, fn)`. | SDK reference `LrCatalog`; used pervasively in bmachek `PublishTask.lua`. |
| `catalog:addPhoto(path)` imports an existing local file into the Lightroom catalog. Some Lightroom Classic runtimes do **not** expose `catalog:addPhotos(paths)`, so production code must fall back to one-by-one `addPhoto`. | Current Lightroom runtime error reported against Lightroom Classic 15.2.1; historical repo implementations: old `ImportServiceProvider.lua` used `catalog:addPhoto(destinationPath)`, while some old sync code used `catalog:addPhotos(photosToAdd)`. |
| ⚠️ `catalog:addPhoto` / `catalog:addPhotos` can yield, **and** they must still be called inside `catalog:withWriteAccessDo` or `withProlongedWriteAccessDo`. If you need protected error handling around them, use `LrTasks.pcall(...)` rather than Lua's plain `pcall(...)`, which is not yield-safe. | SDK reference for `LrCatalog:addPhoto` requires write access; SDK reference for `LrTasks.pcall` says it allows yielding inside the protected call. The earlier runtime error `AgEventLoop.yieldToScheduler called when yielding is not allowed` is consistent with wrapping `addPhoto` in plain `pcall`. |
| `collection:addPhotos(photos)` / `:removePhotos(photos)` are idempotent. | SDK reference `LrCollection`. |
| `catalog:getActiveSources()` returns currently-selected sidebar sources (folders, collections, sets). Filter by `src:type() == 'LrCollection'`. | SDK reference `LrCatalog`. |

## Publish services — what they can **not** do

| Limitation | Source |
| --- | --- |
| Publish services are strictly push (LR → remote). There is no API for the remote to push membership changes back. | Adobe SDK Guide §Publishing; absence of any such API in SDK reference. |
| Lightroom does **not** invoke the plugin when the user drags photos in/out of a published collection. | [mi.Immich.Publisher README — Known Issues](https://github.com/midzelis/mi.Immich.Publisher#known-issues) documents exactly this. |
| `rendition:recordPublishedPhotoId(id)` is how you mark a photo as published, but it only fires during export rendition processing — never from a menu-triggered flow. | bmachek `PublishTask.lua`. |

→ **Conclusion**: use plain collections + menu-triggered sync. Publish
services are the wrong primitive for bidirectional workflows.

## HTTP

| Fact | Source |
| --- | --- |
| `LrHttp.get(url, headers, timeout?)` returns `body, responseHeaders`. | SDK reference `LrHttp`. |
| `LrHttp.get` can return binary response bodies; write downloaded Immich originals with `io.open(path, 'wb')` before importing via `catalog:addPhotos(paths)`. | Historical repo implementation: old `ImmichAPI.lua:downloadAsset` used `LrHttp.get`, and old `ImportServiceProvider.lua` wrote the returned bytes with `io.open(..., 'wb')`. |
| `LrHttp.post(url, body, headers, method?, timeout?)` — the 4th arg is a verb override (`PUT`, `DELETE`, …). | bmachek `ImmichAPI.lua:784` uses `LrHttp.post(url, body, reqhdrs, 'PUT', 15)`. |
| `headers` is an array of `{ field=..., value=... }` tables. | SDK reference. |
| `responseHeaders.status` holds the HTTP status code; `responseHeaders.error` is set on network failure. | SDK reference. |
| There is **no** native multipart; plugins hand-roll boundaries. The old plugin used a **static** boundary string, which is a correctness bug. | bmachek `ImmichAPI.lua:774` marked `FIXMEASTHISISSTATICFORNOWBUTSHOULDBERANDOM`. |

## Credentials

| Fact | Source |
| --- | --- |
| `LrPasswords` is absent or unreliable in SDK 3.0. No reference plugin uses it. We store API keys in `LrPrefs` and document the limitation in the UI. | Negative result from grep across reference plugins. |

## Tasks, progress, cancellation

| Fact | Source |
| --- | --- |
| Interactive menu work must run in a task. Use `LrFunctionContext.postAsyncTaskWithContext(name, fn)`. | bmachek `SyncDialog.lua`. |
| `LrProgressScope{ title, functionContext }` attaches a cancel-able progress bar to a task. Use `:setCaption(s)`, `:setPortionComplete(done, total)`, `:isCanceled()`, `:done()`. | SDK reference. |

## Logging

| Fact | Source |
| --- | --- |
| `LrLogger('Name'):enable('logfile')` writes to `<Documents>/LrClassicLogs/Name.log` on macOS and a similar path on Windows. | SDK reference; confirmed by bmachek `util.lua`. |

## Things we deliberately do **not** rely on

- Custom metadata fields (`LrMetadataProvider`) — they survive across
  catalog exports but not rebuilds, and we don't need persistent per-photo
  state: the album↔collection link already lives in `LrPrefs`.
- `LrPasswords` — see above.
- Publish services — see above.
