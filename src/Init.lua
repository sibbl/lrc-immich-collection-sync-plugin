--[[
  Init.lua — runs once when the plugin is (re)loaded.

  Keep this script 100% self-contained with NO `require` calls: Lightroom's
  `LrInitPlugin` hook runs very early during plugin bootstrap and can fail
  with "Could not load toolkit script" when invoking `require`.
]]

local LrLogger = import 'LrLogger'
local LrPrefs = import 'LrPrefs'

local prefs = LrPrefs.prefsForPlugin()

local logger = LrLogger('ImmichSync')
if prefs.logEnabled then
	logger:enable('logfile')
else
	logger:disable()
end

logger:info('Immich Collection Sync plugin loaded')
