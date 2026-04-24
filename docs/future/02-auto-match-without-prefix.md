# Future: auto-match without prefix configuration

## Why

Path-prefix mapping is the cleanest approach when it applies, but some
users can't easily produce a single prefix rule — e.g. libraries split
across many mount points with different semantics, or Immich's external-
library mode pointing at a directory tree that Lightroom sees by a
completely different path.

## Proposal

When `PathMapper:immichToLocal` returns `nil, 'no-mapping'`, attempt a
secondary lookup in `CatalogIndex` keyed on a **filename + size +
dateTaken** triple.

## Data model

`CatalogIndex` gains a second map:
```
byFingerprint[fileName .. '|' .. fileSize .. '|' .. capturedAtIsoMinute] = LrPhoto
```

- `fileName` is `photo:getFormattedMetadata('fileName')`.
- `fileSize` is `photo:getRawMetadata('fileSize')`.
- `capturedAtIsoMinute` trims seconds from `dateTimeOriginal` to survive
  sub-second EXIF rounding differences.

On the Immich side, the album asset already carries `originalFileName`
and `exifInfo.fileSizeInByte` and `exifInfo.dateTimeOriginal`.

## UX

A new checkbox in the Plugin Manager settings: "Fall back to filename +
size + date match when a path is unmapped". Off by default because false
positives are possible (two different RAW files with same name, size,
minute). Preview dialog labels fallback matches as `(fuzzy match)` so
the user sees them before applying.

## Risks

- Collisions: two photos that genuinely differ but have identical
  filename/size/minute. Mitigation: if the fingerprint map has a
  duplicate, refuse to use it and surface a warning instead.
- Performance: computing the fingerprint index touches `fileSize`, which
  is fast (no disk read — LR caches it).

## Implementation outline

1. Extend `CatalogIndex.new(photos, caseFold, {fingerprint=true})` to
   accept an opt-in flag and build the second map when enabled.
2. Teach `SyncEngine.computeDiff` to consult the fingerprint map after
   the path map fails, and to tag those matches in the result struct.
3. New settings checkbox.
4. Specs for fingerprint index + fuzzy-match flow.

## Estimated size

Small-medium. One focused session plus tests.
