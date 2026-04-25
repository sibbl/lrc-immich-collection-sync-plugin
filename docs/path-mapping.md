# Path mapping

Immich stores photos at paths visible to the Immich process (e.g. inside
the Docker container: `/usr/src/app/upload/library/...`). Lightroom sees
those same files through a host-OS path (e.g. `/Volumes/nas/immich/library/...`
on macOS with an NFS mount). The plugin needs to translate between these
two worlds and never transfers bytes.

## Mapping entry

Each mapping is a triple `(label, immich-prefix, local-prefix)`. The
label is cosmetic. Prefixes are always stored and compared with a single
trailing `/` and forward slashes.

## Longest-prefix wins

When multiple mappings match a path, the one with the longer `immich`
(or `local_`) prefix wins. This lets a user override a sub-tree:

```
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

## Worked examples

### Typical Docker + NFS setup

```
Mapping: internal   /usr/src/app/upload/library/   /Volumes/nas/immich/library/

Immich path:  /usr/src/app/upload/library/2024-04/IMG_42.jpg
Local path:   /Volumes/nas/immich/library/2024-04/IMG_42.jpg
```

### Two external libraries

```
internal    /usr/src/app/upload/library/   /Volumes/nas/immich/library/
ext-family  /family-photos/                /Volumes/family/
ext-scan    /scans/                        /Volumes/archive/scans/
```

### Running Immich and Lightroom on the same host

```
internal    /home/me/immich-library/   /home/me/immich-library/
```

Identical prefixes are legal; the mapping just passes through.

## Discovering libraries from Immich

Immich External Libraries can have one or more `importPaths` — each is a
path the Immich process scans for photos. The plugin can fetch these
automatically:

1. Open `File > Plug-in Manager… > Immich Sync`.
2. In **Path Mappings**, click **Fetch libraries from Immich…**.
3. The dialog lists every library and every `importPath`. For each row,
   either type the matching local path or click **Browse…** to pick the
   folder Lightroom uses for that same physical location.
4. Click **Save mappings**. Resolved entries are merged into the existing
   mappings (matched by Immich prefix); rows left blank are skipped so
   you can configure libraries incrementally.

Internal uploads (`/usr/src/app/upload/library/…` for the default Docker
deployment) are not returned by `/api/libraries`; add that mapping
manually in the raw text area if your collection contains internally
uploaded assets.

The whole point: **one physical photo on your NAS, referenced from both
Immich and Lightroom**. The sync engine never transfers files — it only
edits album/collection membership.
