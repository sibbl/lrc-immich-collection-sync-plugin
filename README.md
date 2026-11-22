# Immich Collection Sync for Lightroom Classic

Keep a **Lightroom Classic collection** and an **Immich album** in sync on demand, in either direction — without uploading or duplicating files.

Both Lightroom and Immich reference the same physical files on disk (for example, on a NAS) via a simple path-prefix mapping. If an Immich asset is not yet in your Lightroom catalog, the plugin imports the existing local file in place; if an asset has no mapped local path, you can optionally confirm a download fallback during **Immich → Lightroom** sync.

## Features

- **Bidirectional, on-demand membership sync**
  - **Immich → Lightroom**: mirrors an Immich album into a Lightroom collection (imports already-local files into the catalog if needed, and offers an optional download fallback for unmapped assets)
  - **Lightroom → Immich**: mirrors a Lightroom collection into an Immich album (looks up matching Immich assets by mapped path and adds/removes album membership)
- **Owned and shared Immich albums** supported
- **Preview before applying**: shows counts, active path mappings, and warnings before touching your catalog or album
- **Zero uploads, no file moving/renaming**

> **What this plugin does not do:** file uploads, metadata sync (ratings/keywords/captions), background live sync, smart collections, or automatic album/collection creation.

---

## Install

### Option 1: Download a release

1. Download `lrc-immich-collection-sync-plugin.lrplugin.zip` from the [Releases](https://github.com/sibbl/lrc-immich-plugin/releases) page and unzip it.
2. In Lightroom Classic, open **File > Plug-in Manager…**, click **Add**, and select `lrc-immich-collection-sync-plugin.lrplugin`.

### Option 2: Build from source

Requires `luajit` (or `lua5.1`) to run unit tests.

```sh
./test.sh
./build.sh
```

This creates `dist/lrc-immich-collection-sync-plugin.lrplugin/`. Add it via **File > Plug-in Manager… > Add**.

> **Updating the plugin:** After replacing an installed `.lrplugin` folder, quit and reopen Lightroom Classic completely so it refreshes its cached plugin scripts.

---

## Setup

Open **File > Plug-in Manager…** and select **Immich Collection Sync**.

### 1. Server URL & API key

1. Enter your **Immich Server URL** (e.g. `https://immich.example.com`) and **API key**.
2. Click **Test connection** to verify connectivity and authentication.

Recommended Immich API key scopes:

- `album.read`, `album.write` — list albums, read album membership, add/remove album assets
- `asset.read` — look up assets and download unmapped originals (if you use the download fallback)
- `library.read` — discover External Library paths automatically
- `user.read` — show your signed-in account in **Test connection**

### 2. Path mappings

Immich and Lightroom usually see the same files under different folder prefixes. For example:

| Side | Path |
| --- | --- |
| Immich (Docker) | `/data/library/alice/2024/IMG_0001.JPG` |
| Lightroom (macOS) | `/Volumes/photos/immich/library/alice/2024/IMG_0001.JPG` |

Click **Choose path mappings…** to assign the local folder Lightroom sees for each Immich path:

- **Immich data folder (`/data/`)** — maps your mounted Immich data folder (e.g. `/Volumes/photos/immich/`), automatically covering both `/data/library/` and `/data/upload/`.
- **External libraries** — fetched automatically from Immich when server credentials are set.
- **Add custom mapping…** — add per-user overrides or custom container mounts; when multiple prefixes match, the **longest matching prefix wins**.

Make sure `/data/` points to the root of your Immich data folder (not `/data/library` inside it), otherwise paths will double-nest (e.g. `…/library/library/…`). See [docs/path-mapping.md](docs/path-mapping.md) for more examples.

---

## Usage

All actions live under **Library > Plug-in Extras**:

1. **Link a collection to an album** (once per pair)
   - Select a regular (non-smart) Lightroom collection in the sidebar.
   - Choose **Immich Collection Sync: Link selected collection to album…**, pick the Immich album, and click **Link**.
2. **Sync** (whenever you want)
   - Select the linked collection and choose **Immich Collection Sync: Sync…**.
   - Pick the direction (**Immich → Lightroom** or **Lightroom → Immich**) and click **Analyze**.
   - Review the preview (add/remove/import counts and any warnings), then click **Apply**.
   - In **Immich → Lightroom** mode, if any Immich assets have no matching path mapping, you can optionally confirm downloading their originals to a chosen folder (which is remembered and tracked to avoid duplicate downloads on future runs).
3. **Unlink** (optional)
   - Choose **Immich Collection Sync: Unlink selected collection**. Both the Lightroom collection and Immich album remain untouched.

---

## Troubleshooting

- **`missing locally` warning in Preview**: The preview prints `immichPath → localPath`. Check that your NAS/drive is mounted and that the translated local path matches the actual file on disk (watch out for extra subfolders like `/library/library/`).
- **`not found on Immich` warning (`Lightroom → Immich`)**: The photo's local path maps to an Immich path that Immich has not indexed yet. Upload or scan the file in Immich first, then sync again.
- **Immich album shows `0 assets fetched` while `assetCount > 0`**: Check that your Immich API key has `album.read` and `asset.read` permissions and that your user has access to the album's assets.
- **Need detailed logs?** Enable **Enable debug logging** under **Diagnostics** in Plug-in Manager, run sync again, and click **Show log file**.

---

## Limitations

- Only **regular collections** are supported (Smart Collections cannot have photos manually added or removed).
- Lightroom SDK 3.0 does not provide a cross-platform encrypted keychain API, so the plugin stores the API key in Lightroom preferences in plaintext. Use a dedicated, least-privilege Immich API key.

---

## Development

```sh
./test.sh    # run Lua 5.1 unit tests (requires luajit or lua5.1)
./build.sh   # build dist/lrc-immich-collection-sync-plugin.lrplugin/
```

Developer documentation lives in [`docs/`](docs/):

- [docs/architecture.md](docs/architecture.md) — module layout and responsibilities
- [docs/path-mapping.md](docs/path-mapping.md) — prefix translation rules and examples
- [docs/lightroom-sdk-notes.md](docs/lightroom-sdk-notes.md) — verified Lightroom Classic SDK quirks
- [docs/testing.md](docs/testing.md) — headless Lua test harness

## Credits

- [Jeffrey Friedl for JSON.lua](http://regex.info/blog/lua/json)
- [Min Idzelis](https://github.com/midzelis/mi.Immich.Publisher)
- [Ben Machek](https://github.com/bmachek/lrc-immich-plugin)
