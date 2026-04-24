# Future: multi-server support

## Why

Agencies and power users often run multiple Immich instances — production
vs. staging, personal vs. family library, self-host vs. hosted. Today
the plugin stores a single global server URL / API key.

## Proposal

Move server credentials from global `LrPrefs` to a **per-mapping** field:
the collection↔album mapping stored by `MappingStore` already contains a
`serverUrl` field; we also store `apiKey` there, encrypted if/when we
integrate a platform keychain.

Settings UI gains a **Servers** section (above Path Mappings) where users
can define named server profiles:

```
name        url                            api key
personal    https://immich.sibbl.de        ****
family      https://immich.family.example  ****
```

The Link-collection dialog then asks which server, fetches albums, and
stores `{ serverName, albumId, albumName }` in the mapping.

## Migration

On first load of the new schema:

1. If `LrPrefs.serverUrl` is non-empty, create a default server profile
   named `default` with that URL / apiKey.
2. Rewrite any existing `collectionMappings` to point at `default`.
3. Leave the legacy global fields in place for one release so downgrade
   is possible.

## Risks

- Plaintext API keys multiplied by N servers increase the blast radius
  if a catalog backup leaks prefs. Ship platform-keychain support in the
  same release if possible.
- UI complexity: need to prevent orphan mappings when a server profile
  is deleted. Add a confirmation + cascade option.

## Implementation outline

1. Introduce `Servers.lua` with CRUD over `LrPrefs.servers` JSON blob.
2. Extend `MappingStore` schema: `{ serverName = '…', albumId = '…', …}`.
3. Add a per-link server picker in `LinkCollectionDialog`.
4. Teach `SyncDialog` to build an `ImmichAPI` from the mapping's server
   profile, not the global settings.
5. Migration routine that runs once on plugin load.
6. Specs for `Servers_spec.lua` and schema migration.
