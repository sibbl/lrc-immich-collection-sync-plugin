# Roadmap

Items listed in rough priority order. Each sub-document is a concrete
implementation plan — agents can pick one up without starting from
scratch.

## Near-term (worth doing next)

1. [Metadata sync](01-metadata-sync.md) — ratings, color labels, keywords,
   GPS, captions. Two-way, bounded surface area, big user value.
2. [Auto-match without prefix](02-auto-match-without-prefix.md) — fall
   back to filename + size + dateTaken when path mapping fails, so users
   with complex setups get partial benefit without configuring every
   path.

## Medium-term

3. [Multi-server support](04-multi-server-support.md) — per-collection
   server/key instead of a global one; useful for agencies or people
   running prod + staging Immich instances.

## Speculative

4. [Published-service hybrid mode](03-published-service-mode.md) — if
   Adobe ever exposes drag-in/drag-out callbacks, offer a Publish Service
   UI on top of the same sync engine.

## Explicitly out of scope

- **Uploading or downloading photo files.** This plugin is deliberately a
  membership-sync tool. File transfer is handled by Immich's own clients
  and Lightroom's Import. Conflating the two is where the previous plugin
  design became unmaintainable.
- **Syncing Develop settings.** Lightroom's `.xmp` sidecars are the right
  channel for that; not a job for an Immich plugin.
- **Smart collections.** Their membership is derived from rules, so
  "adding" a photo is a category error.
