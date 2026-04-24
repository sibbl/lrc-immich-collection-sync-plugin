# UX flow

One primary loop: **configure once, link per collection, sync on demand**.

## Step 1 — Configure (once)

`File > Plug-in Manager… > Immich Sync`

Three sections:

1. **Immich Server** — Server URL, API key, "Test connection" button with
   inline status feedback.
2. **Path Mappings** — free-form text area. One mapping per line, tab-
   separated:
   ```
   label<TAB>immich-prefix<TAB>local-prefix
   internal<TAB>/usr/src/app/upload/library/<TAB>/Volumes/nas/immich/library/
   external-2024<TAB>/photos-2024/<TAB>/Volumes/photos/2024/
   ```
   Lines starting with `#` are ignored. Trailing slashes are normalized.
   Longest prefix wins at lookup time. See [path-mapping.md](path-mapping.md).
3. **Diagnostics** — enable debug logging, reveal the log file.

## Step 2 — Link a collection to an album (once per collection)

1. In the Library module, select a **non-smart collection** in the sidebar.
2. `Library > Plug-in Extras > Immich: Link selected collection to album…`
3. Pick an album from the sorted list. Relinking overwrites the existing
   mapping.

## Step 3 — Sync (any time)

1. Select the linked collection.
2. `Library > Plug-in Extras > Immich: Sync…`
3. Choose direction:
   - **Immich → Lightroom** — mirror the Immich album into the LR
     collection. Adds locally-available photos that the album contains
     but the collection does not; removes collection photos that are
     not in the album.
   - **Lightroom → Immich** — mirror the LR collection into the Immich
     album. Adds Immich assets whose path is in the collection; removes
     album assets whose path is not in the collection.
4. The **preview dialog** shows counts and the first 5 warnings of each
   class. Cancel or Apply.
5. After apply, a summary dialog reports counts and any API errors.

## Step 4 — Unlink (rare)

`Library > Plug-in Extras > Immich: Unlink selected collection`. Leaves
the collection and album both untouched — only the stored mapping is
removed.

## Design decisions

- **Explicit direction per run**: the alternative (automatic union merge)
  silently promotes accidents to changes on both systems. Making the user
  pick is safer and only takes one extra click.
- **Preview dialog is mandatory**: even a small diff surfaces before we
  call the API or touch the catalog.
- **Warnings, never silence**: unmappable Immich paths, missing local
  files, and LR photos outside any mapping appear in the preview. The
  sync proceeds for the resolvable subset.
- **No smart-collection support**: smart collections regenerate from
  rules, so "adding" a photo is ill-defined. We reject them up front.
