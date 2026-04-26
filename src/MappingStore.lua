--[[
  MappingStore — pure wrapper around a prefs-like table that exposes CRUD
  over collection<->album mappings. Kept separate from Settings so it can be
  unit-tested with an injected table.

  Mapping value shape:
    { albumId = 'uuid', albumName = 'Holidays', serverUrl = 'https://…', linkedAt = 'ISO8601' }
]]

local JSON = require 'vendor/JSON'

local M = {}
M.__index = M

-- `backend` must expose [key] read/write, like LrPrefs.prefsForPlugin().
function M.new(backend)
	local self = setmetatable({}, M)
	self.backend = backend
	return self
end

function M:_readAll()
	local raw = self.backend.collectionMappings
	if raw == nil or raw == '' then return {} end
	local ok, value = pcall(function() return JSON:decode(raw) end)
	if not ok or type(value) ~= 'table' then return {} end
	return value
end

function M:_writeAll(tbl)
	self.backend.collectionMappings = JSON:encode(tbl)
end

function M:get(collectionLocalId)
	local all = self:_readAll()
	return all[tostring(collectionLocalId)]
end

function M:set(collectionLocalId, info)
	assert(type(info) == 'table', 'mapping info must be a table')
	assert(info.albumId and info.albumId ~= '', 'albumId required')
	local all = self:_readAll()
	all[tostring(collectionLocalId)] = {
		albumId = info.albumId,
		albumName = info.albumName or '',
		serverUrl = info.serverUrl or '',
		linkedAt = info.linkedAt or os.date('!%Y-%m-%dT%H:%M:%SZ'),
	}
	self:_writeAll(all)
end

function M:remove(collectionLocalId)
	local all = self:_readAll()
	all[tostring(collectionLocalId)] = nil
	self:_writeAll(all)
end

function M:all()
	return self:_readAll()
end

return M
