--[[
  Compatibility shim for the retired "Immich import configuration" menu.

  v4 intentionally removed the old import/download workflow. Configuration
  now lives in the Plugin Manager under "Immich Sync".
]]

local LrDialogs = import 'LrDialogs'

LrDialogs.message(
	'Configuration moved',
	'The old import configuration dialog was removed.\n\n'
		.. 'Use File > Plug-in Manager… > Immich Sync to configure:\n'
		.. '• Immich server URL\n'
		.. '• API key\n'
		.. '• Path mappings (including fetched Immich libraries)\n\n'
		.. 'This plugin never downloads photos. Lightroom and Immich are '
		.. 'expected to reference the same physical files on disk.',
	'info'
)