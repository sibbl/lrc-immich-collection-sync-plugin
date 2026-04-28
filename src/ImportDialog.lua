--[[
  Compatibility shim for the retired "Import from Immich Collection Sync" menu.

  The rewritten plugin does not download or import files from Immich Collection Sync. It only
  syncs album/collection membership for files that already exist locally.
]]

local LrDialogs = import 'LrDialogs'

LrDialogs.message(
	'Import/download removed',
	'The old "Import from Immich Collection Sync" workflow is no longer supported.\n\n'
		.. 'Immich Collection Sync now works by mapping Immich storage paths to the '
		.. 'matching local folders Lightroom already sees. One physical photo, '
		.. 'referenced from both systems — no downloading required.\n\n'
		.. 'Use File > Plug-in Manager… > Immich Collection Sync to set path mappings, '
		.. 'then link a Lightroom collection to an Immich album and run '
		.. 'Library > Plug-in Extras > Immich Collection Sync: Sync….',
	'info'
)