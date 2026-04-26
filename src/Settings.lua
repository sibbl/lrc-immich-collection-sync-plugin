--[[
  Settings — read/write plugin preferences via LrPrefs.

  Schema (all keys on `LrPrefs.prefsForPlugin()`):
    serverUrl            string
    apiKey               string
    pathMappings         string (JSON array of {immich, local_, label})
    collectionMappings   string (JSON object: collectionLocalId -> {albumId, albumName, serverUrl, linkedAt})
    logEnabled           boolean

  All non-scalar values are stored as JSON strings because LrPrefs is not a
  reliable home for deeply nested Lua tables across Lightroom versions.
]]

local LrPrefs = import 'LrPrefs'
local JSON = require 'vendor/JSON'

local M = {}

local function prefs()
	return LrPrefs.prefsForPlugin()
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

function M.getServerUrl() return prefs().serverUrl or '' end
function M.setServerUrl(v) prefs().serverUrl = v or '' end

function M.getApiKey() return prefs().apiKey or '' end
function M.setApiKey(v) prefs().apiKey = v or '' end

function M.getLogEnabled() return prefs().logEnabled and true or false end
function M.setLogEnabled(v) prefs().logEnabled = v and true or false end

-- Path mappings -------------------------------------------------------------
-- Returns an array of { immich, local_, label } tables.
function M.getPathMappings()
	return readJson('pathMappings', {})
end

function M.setPathMappings(list)
	writeJson('pathMappings', list or {})
end

-- Collection mappings ------------------------------------------------------
-- Returns a table keyed by collection localIdentifier (number) serialized as
-- string. Stored-as-JSON keeps keys as strings so we normalize on read/write.
function M.getCollectionMappings()
	return readJson('collectionMappings', {})
end

function M.setCollectionMapping(collectionLocalId, info)
	local all = M.getCollectionMappings()
	all[tostring(collectionLocalId)] = info
	writeJson('collectionMappings', all)
end

function M.removeCollectionMapping(collectionLocalId)
	local all = M.getCollectionMappings()
	all[tostring(collectionLocalId)] = nil
	writeJson('collectionMappings', all)
end

function M.getCollectionMapping(collectionLocalId)
	local all = M.getCollectionMappings()
	return all[tostring(collectionLocalId)]
end

return M
