# Path mapping

Immich stores photos at paths visible to the Immich process (e.g. inside
the Docker container: `/data/library/...` on current installs, or
`/usr/src/app/upload/library/...` on older installs). Lightroom sees those same
files through a host-OS path (e.g. `/Volumes/nas/immich/library/...` on macOS
with an NFS mount). The plugin needs to translate between these two worlds.
Normal sync never transfers bytes; an explicit download/import fallback exists
only for unmapped Immich assets during **Immich → Lightroom** sync.

## Mapping entry

Each mapping is a triple `(label, immich-prefix, local-prefix)`. The
label is cosmetic. Prefixes are always stored and compared with a single
trailing `/` and forward slashes.

## Longest-prefix wins

When multiple mappings match a path, the one with the longer `immich`
(or `local_`) prefix wins. This lets a user override a sub-tree:

```text
internal   /upload/              /Volumes/nas/immich/
external   /upload/library/2024  /Volumes/extern-2024
```

Looking up `/upload/library/2024/IMG_1.jpg` yields
`/Volumes/extern-2024/IMG_1.jpg` — the more specific rule wins.

## Case-folding policy

The host OS decides. macOS and Windows are case-insensitive (HFS+/APFS
default, NTFS default); Linux is case-sensitive. We fold **only** for
comparison; the original-case paths are always the ones we return.
`util.Paths._setOS(os)` lets tests pin the behavior.

## Separator normalization

Windows backslashes are converted to forward slashes everywhere. Users
may enter prefixes with either separator.

## Unmappable paths

If a path has no matching prefix, lookup returns `nil, 'no-mapping'` and
the sync engine surfaces it as a warning; the path is **never silently
dropped**. Typical causes:

- An external library whose Immich prefix is not configured.
- Local photos that live outside any mapping (e.g. on an internal SSD
  unrelated to Immich).
- A mapping typo.

Fix by adding a mapping in the Plugin Manager settings and re-running.
For **Immich → Lightroom**, you can also choose to download unmapped originals
after the preview confirmation; the plugin asks for a destination folder,
remembers it, imports the downloaded files into Lightroom, and then adds them to
the collection.

## Worked examples

### Typical Docker + NFS setup

```text
Mapping: uploaded   /data/library/   /Volumes/nas/immich/library/

Immich path:  /data/library/sebastian/2024-04/IMG_42.jpg
Local path:   /Volumes/nas/immich/library/sebastian/2024-04/IMG_42.jpg
```

Usually this **one global uploaded-library mapping** covers all users and
storage labels below `/data/library/`. You only need per-user rows when those
subfolders are mounted from different host locations. Longest-prefix matching
lets a per-user row override the global row:

```text
uploaded      /data/library/             /Volumes/nas/immich/library/
sebastian-ssd /data/library/sebastian/   /Volumes/fast-ssd/sebastian/
```

### Two external libraries

```text
uploaded    /data/library/                 /Volumes/nas/immich/library/
ext-family  /family-photos/                /Volumes/family/
ext-scan    /scans/                        /Volumes/archive/scans/
```

### Legacy Docker upload path

```text
legacy-upload   /usr/src/app/upload/library/   /Volumes/nas/immich/library/
```

### Running Immich and Lightroom on the same host

```text
internal    /home/me/immich-library/   /home/me/immich-library/
```

Identical prefixes are legal; the mapping just passes through.

## Discovering libraries from Immich

Immich External Libraries can have one or more `importPaths` — each is a path
the Immich process scans for photos. The plugin can fetch these automatically.
Immich's API also has a default upload library for each user, but those uploaded
asset roots are not returned as external-library `importPaths`, so the dialog
adds common uploaded/user-library roots itself.

1. Open `File > Plug-in Manager… > Immich Sync`.
2. In **Path Mappings**, click **Choose path mappings…**.
3. The dialog lists common uploaded/user-library roots first, then every
  external library and every `importPath`, plus any previously saved mappings
  that Immich is not currently reporting. For each row, click **Choose…** to
  pick the folder Lightroom uses for that same physical location, or **Clear**
  to remove the saved mapping.
4. Click **Save mappings**. The Plugin Manager then shows a read-only summary of
  the saved mappings.

For current Docker installs, map `/data/library/` to the host folder behind
`${UPLOAD_LOCATION}/library`. For older installs, map
`/usr/src/app/upload/library/`. A single `/data/library/` row is usually the
right answer for all users; use per-user rows only as overrides.

The ideal setup remains: **one physical photo on your NAS, referenced from both
Immich and Lightroom**. The download fallback is for cases where a path is truly
unmapped or not locally mounted.
