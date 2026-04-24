--[[
  Init.lua — runs once when the plugin is (re)loaded.

  We intentionally keep this minimal: no global state, no side-effects beyond
  bootstrapping the logger. Settings are read lazily from LrPrefs where needed.
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

logger:info('Immich Sync plugin loaded')
