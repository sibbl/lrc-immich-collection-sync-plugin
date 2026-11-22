--[[
  Compatibility shim for the retired "Immich import configuration" menu.

  v4 intentionally removed the old import/download workflow. Configuration
  now lives in the Plugin Manager under "Immich Collection Sync".
]]

local LrDialogs = import 'LrDialogs'

LrDialogs.message(
	'Configuration moved',
	'The old import configuration dialog was removed.\n\n'
		.. 'Use File > Plug-in Manager… > Immich Collection Sync to configure:\n'
		.. '• Immich server URL\n'
		.. '• API key\n'
		.. '• Path mappings (including fetched Immich libraries and custom prefixes)\n\n'
		.. 'Normal sync references the same physical files on disk; an optional '
		.. 'download fallback is offered during Immich → Lightroom sync for '
		.. 'unmapped assets.',
	'info'
)
