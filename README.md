# Immich Collection Sync for Lightroom Classic

Keep **Lightroom Classic collections** and **Immich albums** in sync on demand — without uploading or duplicating files.

Both Lightroom and Immich reference the same physical files on disk (for example, on a NAS) via path-prefix mappings. If an Immich asset is not yet in your Lightroom catalog, the plugin imports the existing local file in place; if an asset has no mapped local path, you can optionally confirm a download fallback during **Immich → Lightroom** sync.

## Features

- **Bidirectional album ↔ collection sync** (remembers your last chosen direction per collection)
  - **Immich → Lightroom**: mirrors an Immich album into a Lightroom collection (imports already-local files into the catalog if needed, and offers an optional download fallback for unmapped assets)
  - **Lightroom → Immich**: mirrors a Lightroom collection into an Immich album (looks up matching Immich assets by mapped path and adds/removes album membership)
- **Two-way metadata sync** — sync star ratings, favorites ↔ pick flags, captions ↔ descriptions, GPS coordinates, and keywords ↔ Immich tags (+ Immich people → `People/<name>`) with a preview and optional overwrite toggle
- **Immich Smart Search inside Lightroom** — run AI/CLIP search queries (*"sunset over mountains"*) and gather all matching local catalog photos into an `Immich search results` collection
- **Open linked album & create share links** — jump straight to a linked Immich album in your browser or generate a share link (with optional expiry/password)
- **Owned and shared Immich albums** supported
- **Preview before applying** — inspect counts, active path mappings, and warnings before touching your catalog or album

> **What this plugin does not do:** file uploads, background live sync, smart collections, or automatic album/collection creation for links.

---

## Install

### Option 1: Download a release

1. Download `lrc-immich-collection-sync-plugin.lrplugin.zip` from the [Releases](https://github.com/sibbl/lrc-immich-collection-sync-plugin/releases) page and unzip it.
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
- `asset.read` — look up assets, smart search, and download unmapped originals
- `asset.update`, `tag.create`, `tag.asset` — push metadata and keywords in **Sync metadata…**
- `sharedLink.create` — create album share links
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

- **Link selected collection to album…** — pair a regular (non-smart) Lightroom collection with an Immich album.
- **Sync…** — choose **Immich → Lightroom** or **Lightroom → Immich**, review the preview, and click **Apply**. In **Immich → Lightroom** mode, unmapped Immich assets can optionally be downloaded to a remembered folder (tracked to avoid duplicate downloads).
- **Sync metadata…** — select one or more photos (or a collection), pick direction and metadata fields (ratings, favorites, captions, GPS, keywords/people), preview changes, and apply.
- **Smart search in Lightroom…** — enter an Immich Smart/CLIP search query to collect matching catalog photos under `Immich search results`.
- **Open linked album in browser** — open the active collection's linked Immich album in your default browser.
- **Create album share link…** — generate a public Immich share link for the linked album (with optional expiry/password).
- **Unlink selected collection** — remove the stored link without changing the collection or album.

---

## Troubleshooting

- **`missing locally` warning in Preview**: The preview prints `immichPath → localPath`. Check that your NAS/drive is mounted and that the translated local path matches the actual file on disk (watch out for extra subfolders like `/library/library/`).
- **`not found on Immich` warning (`Lightroom → Immich`)**: The photo's local path maps to an Immich path that Immich has not indexed yet. Upload or scan the file in Immich first, then sync again.
- **Immich album shows `0 assets fetched` while `assetCount > 0`**: Check that your Immich API key has `album.read` and `asset.read` permissions and that your user has access to the album's assets.
- **Need detailed logs?** Enable **Enable debug logging** under **Diagnostics** in Plug-in Manager, run an action again, and click **Show log file**.

---

## Limitations

- Only **regular collections** are supported (Smart Collections cannot have photos manually added or removed).
- Lightroom SDK 3.0 does not provide a cross-platform encrypted keychain API, so the plugin stores the API key in Lightroom preferences in plaintext. Use a dedicated, least-privilege Immich API key.

---

## Development

```sh
./test.sh          # run Lua 5.1 unit tests (requires luajit or lua5.1)
luacheck src tests # static Lua 5.1 linting (optional)
./build.sh         # build dist/lrc-immich-collection-sync-plugin.lrplugin/
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
