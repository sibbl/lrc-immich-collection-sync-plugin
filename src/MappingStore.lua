--[[
  MappingStore — pure wrapper around a prefs-like table that exposes CRUD
  over collection<->album mappings and catalog-scoped downloaded-asset tracking.
  Kept separate from Settings so it can be unit-tested with an injected table.

  Keys are optionally scoped by `opts.catalogId` (e.g. `catalog:getPath()`)
  because `LrPrefs` is global across Lightroom catalogs while
  `collection.localIdentifier` is only unique within a single catalog.
  Reads transparently fall back to legacy unscoped numeric keys for backwards
  compatibility.

  Mapping value shape:
    { albumId = 'uuid', albumName = 'Holidays', serverUrl = 'https://…', linkedAt = 'ISO8601' }
]]

local JSON = require 'JSON'

local M = {}
M.__index = M

-- `backend` must expose [key] read/write, like LrPrefs.prefsForPlugin().
-- `opts` (optional): { catalogId = string }
function M.new(backend, opts)
	local self = setmetatable({}, M)
	self.backend = backend
	opts = opts or {}
	self.catalogId = (opts.catalogId and opts.catalogId ~= '') and tostring(opts.catalogId) or nil
	return self
end

function M:_key(collectionLocalId)
	local id = tostring(collectionLocalId)
	if self.catalogId then
		return self.catalogId .. '::' .. id
	end
	return id
end

function M:_readJsonTable(prefKey)
	local raw = self.backend[prefKey]
	if raw == nil or raw == '' then return {} end
	local ok, value = pcall(function() return JSON:decode(raw) end)
	if not ok or type(value) ~= 'table' then return {} end
	return value
end

function M:_writeJsonTable(prefKey, tbl)
	self.backend[prefKey] = JSON:encode(tbl)
end

function M:_readAll()
	return self:_readJsonTable('collectionMappings')
end

function M:_writeAll(tbl)
	self:_writeJsonTable('collectionMappings', tbl)
end

function M:get(collectionLocalId)
	local all = self:_readAll()
	local scoped = all[self:_key(collectionLocalId)]
	if scoped ~= nil then return scoped end
	if self.catalogId then
		-- Backwards-compatible read for links saved before catalog scoping.
		return all[tostring(collectionLocalId)]
	end
	return nil
end

function M:set(collectionLocalId, info)
	assert(type(info) == 'table', 'mapping info must be a table')
	assert(info.albumId and info.albumId ~= '', 'albumId required')
	local all = self:_readAll()
	local existing = all[self:_key(collectionLocalId)]
		or (self.catalogId and all[tostring(collectionLocalId)] or nil)
	all[self:_key(collectionLocalId)] = {
		albumId = info.albumId,
		albumName = info.albumName or '',
		serverUrl = info.serverUrl or '',
		linkedAt = info.linkedAt or (existing and existing.linkedAt) or os.date('!%Y-%m-%dT%H:%M:%SZ'),
		lastDirection = info.lastDirection or (existing and existing.lastDirection) or nil,
	}
	-- Migrate away from legacy unscoped key when writing under a catalogId.
	if self.catalogId then
		all[tostring(collectionLocalId)] = nil
	end
	self:_writeAll(all)
end

function M:setLastDirection(collectionLocalId, direction)
	if direction ~= 'immich_to_lr' and direction ~= 'lr_to_immich' then return end
	local existing = self:get(collectionLocalId)
	if not existing or not existing.albumId then return end
	self:set(collectionLocalId, {
		albumId = existing.albumId,
		albumName = existing.albumName,
		serverUrl = existing.serverUrl,
		linkedAt = existing.linkedAt,
		lastDirection = direction,
	})
end

function M:remove(collectionLocalId)
	local all = self:_readAll()
	all[self:_key(collectionLocalId)] = nil
	if self.catalogId then
		all[tostring(collectionLocalId)] = nil
	end
	self:_writeAll(all)
end

function M:all()
	return self:_readAll()
end

-- Downloaded-asset tracking -------------------------------------------------
-- Tracks `assetId -> localPath` per catalog so previously downloaded unmapped
-- assets are matched on subsequent syncs instead of being downloaded again.
function M:_downloadScopeKey()
	return self.catalogId or '__default__'
end

function M:getDownloadedAssets()
	local all = self:_readJsonTable('downloadedAssets')
	local scoped = all[self:_downloadScopeKey()]
	if type(scoped) ~= 'table' then return {} end
	local copy = {}
	for k, v in pairs(scoped) do copy[k] = v end
	return copy
end

function M:setDownloadedAsset(assetId, localPath)
	if not assetId or assetId == '' or not localPath or localPath == '' then return end
	local all = self:_readJsonTable('downloadedAssets')
	local scopeKey = self:_downloadScopeKey()
	if type(all[scopeKey]) ~= 'table' then all[scopeKey] = {} end
	all[scopeKey][tostring(assetId)] = tostring(localPath)
	self:_writeJsonTable('downloadedAssets', all)
end

return M
