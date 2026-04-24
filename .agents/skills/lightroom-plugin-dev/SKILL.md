---
name: lightroom-plugin-dev
description: >-
  Rules, SDK gotchas, and testing conventions for developing Lightroom Classic
  plugins in this repository. Load this file WHENEVER you are about to read
  or modify anything under `src/`, `tests/`, or any `.lua` file, or when
  answering questions about Lightroom SDK behavior.
---

# Lightroom Classic plugin development — rules for this repo

Lightroom Classic's SDK documentation is sparse and partially out of date.
The rules below are **verified** against reference implementations and the
SDK reference; sources live in [../../../docs/lightroom-sdk-notes.md](../../../docs/lightroom-sdk-notes.md).

## Language & runtime

- **Lua 5.1 only.** No `goto`, no integer division `//`, no `~=` as bitwise.
  Use `luajit` or `lua5.1` for running tests; they share 5.1 semantics.
- No LuaJIT-specific features in `src/` — the plugin runs under plain 5.1
  inside Lightroom.

## Info.lua

- Declare each top-level key **once**. Declaring `LrLibraryMenuItems` twice
  is a silent bug in Lua (second assignment wins); the old plugin hit this
  and lost its Import menu entries.
- This plugin intentionally registers **no** `LrExportServiceProvider` and
  **no** `LrPublishServiceProvider`. Do not add them without reading
  `docs/future/03-published-service-mode.md` first — there are hard SDK
  limits that make publish-driven two-way sync impossible.

## Catalog access

- `LrCatalog:findPhotoByPath` **does not exist**. Build a path → LrPhoto
  index via `catalog:getAllPhotos()` + `photo:getRawMetadata('path')` —
  that is what `CatalogIndex.lua` does.
- Any mutation (adding/removing photos from a collection, creating
  collections, writing metadata) **must** be wrapped in
  `catalog:withWriteAccessDo(actionName, fn)`. Forgetting this raises at
  runtime with a non-obvious error.
- `collection:addPhotos{photos}` and `collection:removePhotos{photos}` are
  idempotent and safe to call with already-member / already-absent photos.

## UI

- Settings UI lives in `PluginInfoProvider.sectionsForTopOfDialog(f, props)`
  rendered inside the Plugin Manager. It is the **only** place to store
  global plugin config in this plugin.
- Menu-item scripts (`src/menu/*.lua`) execute when the menu is picked.
  Wrap interactive work in `LrFunctionContext.postAsyncTaskWithContext`
  so the UI remains responsive and so we get automatic progress/error
  handling.
- `LrDialogs.presentModalDialog{ contents = f:column{...} }` returns
  `'ok'` or `'cancel'`. Never build your own modal dialog loops.

## HTTP

- `LrHttp.post(url, body, headers, method?, timeout?)` — the 4th arg is
  the verb override for `PUT`/`DELETE`. We use this in `ImmichAPI.lua`.
- `LrHttp.get(url, headers, timeout?)`.
- Headers are an **array of tables**: `{ { field = 'x-api-key', value = '…' }, … }`.
- No native multipart in this plugin (we never upload binaries). Keep it
  that way.

## Credentials

- `LrPasswords` is not reliably present in SDK 3.0. We store the API key
  in `LrPrefs` as plaintext and document the limitation in the UI.
- When adding support for a platform keychain, gate it behind a feature
  flag and fall back to `LrPrefs` (see `docs/future/04-multi-server-support.md`).

## Testing

- Unit tests use the harness in `tests/mocks/_bootstrap.lua`, which stubs
  `import` to serve pre-registered Lua tables. **Every spec file should be
  runnable in isolation** and should not touch global state beyond the
  baseline `resetLrMocks()` call in the bootstrap.
- If a module under `src/` cannot be unit-tested because it needs Lightroom
  directly, extract the non-Lightroom logic into a sibling module and unit-
  test that instead. The rule is: **pure logic is always testable.**
- Run `./test.sh` before every commit. CI enforces the same.

## Common mistakes to avoid

1. Using `os.getenv` or `os.execute` — Lightroom's Lua sandbox restricts
   these on some platforms. Use `LrShell` and LR file APIs instead.
2. Calling Lightroom APIs from inside an HTTP callback that Lr is waiting
   on — always dispatch via `LrTasks.startAsyncTask` or
   `postAsyncTaskWithContext`.
3. Forgetting that LR property tables are observable: setting a field on
   `propertyTable` fires observers, and `addObserver` only fires on
   subsequent changes, not immediately.
4. Relying on iteration order of `pairs()` over tables. Sort explicitly
   whenever user-visible order matters.

## When in doubt

Prefer patterns already used in `src/`. When introducing a new SDK call
this repo has not used before, cite the source (Adobe docs, known-working
reference plugin URL) in a code comment.
