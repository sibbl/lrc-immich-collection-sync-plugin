# Immich Sync for Lightroom Classic

This repository builds the **Immich Sync** Lightroom Classic plugin.

It keeps a **Lightroom collection** and an **Immich album** in sync **on demand**,
in **either direction**. Normally it does this by matching paths to the same
files on disk, without uploading, moving, or renaming anything. If an Immich
asset has no usable local path, you can explicitly confirm a fallback download
and import during **Immich → Lightroom** sync.

## What this plugin does

- Syncs **membership only** between a Lightroom collection and an Immich album
- Works in both directions: **Immich → Lightroom** and **Lightroom → Immich**
- Uses **path mappings** to match the same physical files as seen by Immich and
  Lightroom
- Can import already-local files into the Lightroom catalog during
   **Immich → Lightroom** sync when the mapped file exists but is not in the
   catalog yet
- Can optionally download unmapped Immich originals after confirmation, save
   them to a folder you choose, import them into Lightroom, and remember that
   folder for next time

## What this plugin does not do

- No file upload
- No automatic file download; downloads only happen after you confirm the
   fallback during **Immich → Lightroom** sync
- No metadata sync
- No background/live sync
- No automatic album or collection creation
- No file copying during catalog import; Lightroom is pointed at the existing
   mapped file

You create the album in Immich and the collection in Lightroom, then link them.

## Before you start

This plugin only works when **Immich and Lightroom can both see the same photo
files**.

Typical current Immich Docker example:

- Immich sees `/data/library/sebastian/2024/IMG_0001.JPG`
- Lightroom sees `/Volumes/photos/immich/library/sebastian/2024/IMG_0001.JPG`

Those are the same file, just through different path prefixes. The plugin needs
you to configure that translation once.

## Install

### Build from source

```sh
./test.sh
./build.sh
```

That produces:

`dist/lrc-immich-collection-sync-plugin.lrplugin/`

### Add the plugin to Lightroom Classic

1. Open **File > Plug-in Manager…**
2. Click **Add**
3. Select `dist/lrc-immich-collection-sync-plugin.lrplugin`

If Lightroom still shows errors from an older version of the plugin, remove the
old plugin entry from Plug-in Manager and add the new bundle again.

## Configure the plugin

Open **File > Plug-in Manager…** and select **Immich Sync**.

### 1. Enter server settings

- **Immich server URL**
- **API key**

Then click **Test connection**.

### 2. Configure path mappings

Use **Choose path mappings…** in the Plugin Manager. It refreshes External
Library paths from Immich when your server settings are filled in, then opens a
folder-chooser dialog. The dialog also shows common **uploaded/user library**
roots because Immich's `/api/libraries` endpoint returns external libraries,
not the default upload library.

For most Docker setups, one global mapping is enough for all users:

```text
uploaded | /data/library/ | /Volumes/photos/immich/library/
```

That covers paths such as `/data/library/sebastian/...` and
`/data/library/another-user/...`. Add per-user rows only if different users or
storage labels are physically stored under different host paths; longest-prefix
matching lets those specific rows override the global one.

In the dialog:

- click **Choose…** to pick the local folder Lightroom sees for an Immich path
- click **Clear** to remove a saved mapping
- save when the rows look right; the Plugin Manager then shows a read-only
   summary of the current mappings

The mapping logic is still the same under the hood: each saved entry is a
`label + immich prefix + local prefix` triple, and the **longest matching
prefix wins**.

For more examples, see [`docs/path-mapping.md`](docs/path-mapping.md).

## How to use it

### Menu entries

All actions live under `Library > Plug-in Extras`.

- **Immich: Link selected collection to album…**
- **Immich: Sync…**
- **Immich: Unlink selected collection**

## First-time workflow

### Step 1: Create or choose a normal Lightroom collection

Select a **regular collection** in Lightroom.

Smart collections are not supported.

### Step 2: Create or choose an album in Immich

Create the target album in Immich if it does not already exist.

### Step 3: Link the collection to the album

1. Select the collection in Lightroom
2. Open **Library > Plug-in Extras > Immich: Link selected collection to album…**
3. Pick the Immich album
4. Click **Link**

This stores the relationship between that Lightroom collection and that Immich
album.

### Step 4: Run a sync

1. Select the linked collection
2. Open **Library > Plug-in Extras > Immich: Sync…**
3. Choose a direction:
   - **Immich → Lightroom** = make the collection match the album
   - **Lightroom → Immich** = make the album match the collection
4. Click **Analyze**
5. Review the preview
6. Click **Apply**

The plugin will only change album/collection membership. In **Immich → Lightroom**
mode it may also import already-local mapped files into the Lightroom catalog so
they can be added to the collection. If some Immich assets are unmapped, the
preview will warn you. After clicking **Apply**, the plugin asks whether to
download those originals, lets you choose the destination folder, remembers that
folder, imports the downloaded files, and adds them to the collection.

## Your current situation: empty album + empty collection

You’re already most of the way there 🎯

If you have:

- an **empty album** in Immich
- an **empty collection** in Lightroom
- working connection + path mapping

then the next step is:

1. Select the Lightroom collection
2. Use **Immich: Link selected collection to album…**
3. Choose the album you created in Immich
4. Use **Immich: Sync…**

If **both sides are still empty**, sync will do nothing — which is correct.

After linking, you have two normal ways to work:

### If you want Immich to drive the collection

1. Add photos to the album in Immich
2. In Lightroom, select the linked collection
3. Run **Immich: Sync…**
4. Choose **Immich → Lightroom**

Result: the collection gets those photos added or removed to match the album.
If an Immich asset maps to a local file that exists but is not in the Lightroom
catalog yet, the plugin imports that existing file into the catalog first. If an
asset is unmapped, the plugin can download/import it only after you explicitly
confirm the fallback and choose a save folder.

### If you want Lightroom to drive the album

1. Add photos to the Lightroom collection
2. In Lightroom, select the linked collection
3. Run **Immich: Sync…**
4. Choose **Lightroom → Immich**

Result: the Immich album gets those assets added or removed to match the
collection.

## Day-to-day usage

This plugin is **on demand**, not automatic.

Typical workflow:

1. Make changes on one side
2. Select the linked Lightroom collection
3. Run **Immich: Sync…**
4. Choose which side should win for this run
5. Review the preview
6. Apply

You can re-run sync whenever you want.

## What the preview means

Before applying, the plugin shows a summary such as:

- items to add on one side
- files to import into the Lightroom catalog, for **Immich → Lightroom**
- unmapped Immich assets that can optionally be downloaded/imported after Apply
- items to remove on one side
- warnings

Warnings are important. Common ones are:

- **unmapped Immich path** — no path mapping matches an Immich asset path
- **missing locally** — the mapped local file is not available to Lightroom
- **LR photo outside any mapping** — a Lightroom photo is not under a configured
   local prefix

Nothing is silently guessed away; if a path cannot be matched, the plugin tells
you.

## Unlinking

Use **Library > Plug-in Extras > Immich: Unlink selected collection** to remove
the saved link.

This does **not** change the collection or the album. It only removes the
association between them.

## Troubleshooting

### “This collection is not linked”

Select the collection, then use `Library > Plug-in Extras > Immich: Link selected collection to album…`.

### “No albums found on the Immich server”

Check that:

- the server URL is correct
- the API key is correct
- the user can see albums in Immich

### Photos do not match even though the sync runs

This is almost always a path-mapping problem.

Check:

- the Immich prefix is correct
- the local prefix is the path Lightroom sees
- the correct local folder was chosen for that Immich path in the dialog
- the files really exist locally at the mapped path

### Photos are in Immich but not in the Lightroom catalog yet

Use **Immich → Lightroom** sync. If the mapped local files exist, the plugin
imports them into the Lightroom catalog and then adds them to the linked
collection.

If the preview shows **missing locally**, Lightroom cannot access the mapped
file path. Fix the mount/path mapping first, then run sync again.

### Lightroom still complains after updating the plugin

Remove the plugin from **Plug-in Manager**, quit Lightroom completely, reopen
it, and add the current plugin bundle again.

## Limitations

- Only **regular collections** are supported
- Only **membership sync** is supported
- The plugin stores the API key in Lightroom preferences as plaintext because
   Lightroom SDK 3.0 does not provide a reliable encrypted storage API for this
   plugin

## Documentation

- [`docs/path-mapping.md`](docs/path-mapping.md) — path translation rules and examples
- [`docs/architecture.md`](docs/architecture.md) — module overview
- [`docs/lightroom-sdk-notes.md`](docs/lightroom-sdk-notes.md) — Lightroom SDK quirks and sources
- [`AGENTS.md`](AGENTS.md) — contributor/agent guide

## Development

```sh
./test.sh
./build.sh
```

## Credits

- [Jeffrey Friedl for JSON.lua](http://regex.info/blog/lua/json)
- [Enrique García Cota for inspect.lua](https://github.com/kikito/inspect.lua)
- [Min Idzelis](https://github.com/midzelis/mi.Immich.Publisher)
- [Ben Machek](https://github.com/bmachek/lrc-immich-plugin)
