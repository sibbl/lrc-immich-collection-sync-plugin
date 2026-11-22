# Future: bidirectional metadata sync

## Why

Users already manage photos in Immich year-round (ratings on mobile,
captions when sharing). When they come back to Lightroom, those changes
should appear without manual re-entry — and the reverse: Lightroom edits
to star ratings, color labels, and keywords should flow to Immich for
anyone viewing the library remotely.

## Scope

| Field | Lightroom API | Immich field | Notes |
| --- | --- | --- | --- |
| Star rating (0–5) | `photo:getRawMetadata('rating')` / `:setRawMetadata` | `/assets/{id}.rating` (when configured) | Immich has optional rating support; confirm version. |
| Color label | `photo:getRawMetadata('colorNameForLabel')` | ⚠️ Immich has no native color label. Option: store in a keyword-like tag. | Propose `lr:color=red` convention. |
| Keywords / Tags | `photo:getRawMetadata('keywordTags')` + `photo:addKeyword`/`removeKeyword` | `/assets/{id}/tags` | Straight set-union diff. |
| Caption / Title | `photo:getRawMetadata('caption')` / `title` | `exifInfo.description`, `originalFileName` | Caption → description; title is file-name-ish, skip. |
| GPS | `photo:getRawMetadata('gps')` | `exifInfo.latitude` / `longitude` | Read-only from LR unless user explicitly toggles "write metadata to Immich GPS". Lightroom already writes GPS to sidecar; usually Immich picks it up. |
| Date taken | Raw EXIF. **Never** sync — corrupts originals. | — | Out of scope. |

## Conflict model

Each field is synced **per direction per run**, same as membership sync:
the user picks LR→Immich or Immich→LR. There is no merge. This matches
the mental model users already learned from the membership flow.

## Data model addition

Extend `MappingStore` entries with:
```
{ …, metadata = { lastSyncedAt = 'ISO', fields = { rating=true, keywords=true, … } } }
```
A per-link checkbox grid in the Sync dialog lets the user opt into which
fields to sync.

## Implementation outline

1. Expand `ImmichAPI` with `getAssetMetadata(assetId)` and
   `updateAssetMetadata(assetId, patch)`.
2. New module `MetadataEngine.lua`:
   - `computeMetadataDiff{direction, collectionPhotos, albumAssets, pathMapper, catalogIndex, fields}`.
   - Returns `{ toUpdateRemote = {assetId → patch}, toUpdateLocal = {photo → patch} }`.
3. New dialog section in `SyncDialog.lua` to pick which fields to sync.
4. New specs under `tests/MetadataEngine_spec.lua`.

## Risks

- Keyword taxonomies can differ between LR and Immich. We sync strings
  verbatim; collapsing hierarchies (`Location|Germany|Berlin` vs flat
  `Berlin`) is a separate follow-up.
- Immich API surface for metadata writes has evolved across versions —
  check the minimum supported Immich version before committing.
- Propagating a caption to Immich must not overwrite a user-entered
  Immich caption when the LR caption is empty. Add an explicit
  "prefer non-empty source" rule.

## Estimated size

Medium. Plan on 3–5 sessions: 1 for API work, 1 for engine + tests, 1
for UI, 1–2 for edge cases and validation against a real Immich.
