--[[
  Helpers shared by menu-driven dialogs. Centralizes "read the currently-
  selected Lightroom collection", filename sanitization, and pre-flight checks
  so the menu scripts stay tiny and pure helpers remain unit-testable.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'

local Settings = require 'Settings'

local M = {}

-- Pure helper: pick the single regular (non-smart) LrCollection from a list of
-- active sources. Returns (collection, nil) or (nil, reason).
function M.pickSingleRegularCollection(sources)
	local regular = {}
	local sawSmart = false

	for _, src in ipairs(sources or {}) do
		if type(src) == 'table' and type(src.type) == 'function' then
			local t = src:type()
			if t == 'LrCollection' then
				local isSmart = type(src.isSmartCollection) == 'function' and src:isSmartCollection() == true
				if isSmart then
					sawSmart = true
				else
					table.insert(regular, src)
				end
			end
		end
	end

	if #regular > 1 then
		return nil, 'Multiple collections are selected. Please select a single regular Lightroom collection.'
	end
	if #regular == 1 then
		return regular[1], nil
	end
	if sawSmart then
		return nil, 'Smart collections are not supported. Please select a regular (non-smart) Lightroom collection.'
	end
	return nil, 'Please select a regular (non-smart) Lightroom collection in the sidebar first.'
end

-- Returns the currently-selected single regular LrCollection, or nil + reason.
function M.activeCollection()
	local catalog = LrApplication.activeCatalog()
	local sources = catalog:getActiveSources() or {}
	return M.pickSingleRegularCollection(sources)
end

-- Returns a catalog identifier suitable for scoping MappingStore keys per
-- catalog. Falls back to nil if the catalog exposes no path.
function M.catalogId(catalog)
	catalog = catalog or LrApplication.activeCatalog()
	if catalog and type(catalog.getPath) == 'function' then
		local ok, path = pcall(function() return catalog:getPath() end)
		if ok and path and path ~= '' then return path end
	end
	return nil
end

-- Sanitize a downloaded filename so it cannot contain path separators,
-- control characters, reserved characters, or '.' / '..' traversal segments.
function M.sanitizeFileName(name, fallback)
	fallback = fallback or 'immich-asset'
	local raw = (name ~= nil and tostring(name) ~= '') and tostring(name) or fallback
	local cleaned = raw:gsub('[%z\1-\31\\/:*?"<>|]', '_')
	cleaned = cleaned:gsub('^%s+', ''):gsub('%s+$', '')
	if cleaned == '' or cleaned == '.' or cleaned == '..' then
		cleaned = fallback:gsub('[%z\1-\31\\/:*?"<>|]', '_')
		if cleaned == '' or cleaned == '.' or cleaned == '..' then
			cleaned = 'immich-asset'
		end
	end
	return cleaned
end

-- Normalize a server URL for comparison (trim whitespace, strip trailing slashes, lowercase scheme/host).
function M.normalizeServerUrl(url)
	if not url then return '' end
	local s = tostring(url):gsub('^%s+', ''):gsub('%s+$', ''):gsub('/+$', '')
	return s:lower()
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
