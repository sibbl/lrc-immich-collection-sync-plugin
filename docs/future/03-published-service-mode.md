# Future: Publish Service hybrid mode

## When this becomes relevant

Today (SDK 3.0) the Lightroom Publish Service API is strictly push and
does not fire callbacks on user drag-in/drag-out. That rules out using a
Publish Service as the primitive for bidirectional sync.

If Adobe ever adds a callback along the lines of
`publishServiceProvider.didModifyPublishedCollection(collection, addedPhotos, removedPhotos)`
— or even just exposes the "this published collection is out of sync"
signal — we can layer a Publish Service UI on top of the existing
`SyncEngine`, giving users the native Lightroom published-collection
experience while keeping the diff/apply logic unchanged.

## Proposal

Register an `LrPublishServiceProvider` whose:

- `processRenderedPhotos` is a no-op (we still do not transfer files).
- `imports`/`exports` are disabled.
- On the new callback, it calls `SyncEngine.applyDiff` with a diff
  derived from Lightroom's own add/remove lists.
- On user "Publish" click with direction `LR → Immich`, it calls
  `SyncEngine.applyDiff` for that direction.
- A side-bar refresh menu item triggers `Immich → LR`.

## Decision gate

Do **not** start this work unless / until:

1. Adobe ships a Publish Service callback that fires on drag-in/drag-out, or
2. A community-confirmed workaround (polling, collection observer) proves
   reliable across Lightroom versions for at least six months.

## Non-goals

- Do not build this as a replacement for the menu flow. Menu + plain
  collection is simpler, documented, and works today. Publish Service
  mode would be an alternative UI on top of the same engine.
