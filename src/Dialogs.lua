--[[
  Helpers shared by menu-driven dialogs. Centralizes "read the currently-
  selected Lightroom collection" and pre-flight checks so the menu scripts
  stay tiny.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'

local Settings = require 'Settings'

local M = {}

-- Returns the currently-selected (non-smart) LrCollection, or nil + reason.
function M.activeCollection()
	local catalog = LrApplication.activeCatalog()
	local sources = catalog:getActiveSources() or {}
	for _, src in ipairs(sources) do
		if type(src) == 'table' and src.type then
			local t = src:type()
			if t == 'LrCollection' then return src end
		end
	end
	return nil, 'Please select a non-smart Lightroom collection in the sidebar first.'
end

-- Returns true iff server URL and API key are set.
function M.hasCredentials()
	return Settings.getServerUrl() ~= '' and Settings.getApiKey() ~= ''
end

function M.requireCredentials()
	if M.hasCredentials() then return true end
	LrDialogs.message(
		'Immich Collection Sync — not configured',
		'Please set your Immich server URL and API key in\nFile > Plug-in Manager… > Immich Collection Sync.',
		'info')
	return false
end

return M
