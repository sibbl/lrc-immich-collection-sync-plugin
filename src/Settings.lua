--[[
  Settings — read/write plugin preferences via LrPrefs.

  Schema (all keys on `LrPrefs.prefsForPlugin()`):
    serverUrl            string
    apiKey               string
    pathMappings         string (JSON array of {immich, local_, label})
    downloadFolder       string (last folder chosen for download+import fallback)
    collectionMappings   string (owned by MappingStore)
    downloadedAssets     string (owned by MappingStore)
    logEnabled           boolean

  All non-scalar values are stored as JSON strings because LrPrefs is not a
  reliable home for deeply nested Lua tables across Lightroom versions.
]]

local LrPrefs = import 'LrPrefs'
local JSON = require 'JSON'

local M = {}

local function prefs()
	return LrPrefs.prefsForPlugin()
end

local function trim(v)
	if v == nil then return '' end
	return (tostring(v):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function readJson(key, default)
	local raw = prefs()[key]
	if raw == nil or raw == '' then return default end
	local ok, value = pcall(function() return JSON:decode(raw) end)
	if not ok or value == nil then return default end
	return value
end

local function writeJson(key, value)
	prefs()[key] = JSON:encode(value)
end

function M.getServerUrl() return trim(prefs().serverUrl) end
function M.setServerUrl(v) prefs().serverUrl = trim(v) end

function M.getApiKey() return trim(prefs().apiKey) end
function M.setApiKey(v) prefs().apiKey = trim(v) end

function M.getLogEnabled() return prefs().logEnabled and true or false end
function M.setLogEnabled(v) prefs().logEnabled = v and true or false end

function M.getDownloadFolder() return trim(prefs().downloadFolder) end
function M.setDownloadFolder(v) prefs().downloadFolder = trim(v) end

-- Path mappings -------------------------------------------------------------
-- Returns an array of { immich, local_, label } tables.
function M.getPathMappings()
	return readJson('pathMappings', {})
end

function M.setPathMappings(list)
	writeJson('pathMappings', list or {})
end

return M
