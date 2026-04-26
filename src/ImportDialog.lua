--[[
  Compatibility shim for the retired "Import from Immich" menu.

  The rewritten plugin does not download or import files from Immich. It only
  syncs album/collection membership for files that already exist locally.
]]

local LrDialogs = import 'LrDialogs'

LrDialogs.message(
	'Import/download removed',
	'The old "Import from Immich" workflow is no longer supported.\n\n'
		.. 'Immich Sync now works by mapping Immich storage paths to the '
		.. 'matching local folders Lightroom already sees. One physical photo, '
		.. 'referenced from both systems — no downloading required.\n\n'
		.. 'Use File > Plug-in Manager… > Immich Sync to set path mappings, '
		.. 'then link a Lightroom collection to an Immich album and run '
		.. 'Library > Plug-in Extras > Immich: Sync….',
	'info'
)