--[[
  Compatibility shim for the retired "Import from Immich" menu.

  The rewritten plugin syncs album/collection membership for files that already
  exist locally, with an optional confirmation-gated download fallback for
  unmapped assets during Immich → Lightroom sync.
]]

local LrDialogs = import 'LrDialogs'

LrDialogs.message(
	'Import menu retired',
	'The old "Import from Immich" menu entry is no longer used.\n\n'
		.. 'Immich Collection Sync works by mapping Immich storage paths to the '
		.. 'matching local folders Lightroom already sees (with an optional '
		.. 'download fallback during Immich → Lightroom sync for unmapped assets).\n\n'
		.. 'Use File > Plug-in Manager… > Immich Collection Sync to set path mappings, '
		.. 'then link a Lightroom collection to an Immich album and run '
		.. 'Library > Plug-in Extras > Immich Collection Sync: Sync….',
	'info'
)
