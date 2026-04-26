--[[
  PathMapper — translate between Immich storage paths and local filesystem
  paths using a user-configured list of prefix mappings. Longest prefix
  wins. Pure module, fully unit-tested.

  Mapping table entry shape:
    { immich = '/usr/src/app/upload/library/', local_ = '/Volumes/nas/immich/library/', label = 'internal' }

  Note: `local` is a Lua keyword, so the field is named `local_` on the wire.
]]

local Paths = require 'util/Paths'

local M = {}
M.__index = M

-- Create a new mapper from a list of mapping tables. Order is irrelevant —
-- lookup always picks the longest matching prefix.
function M.new(mappings)
	local self = setmetatable({}, M)
	self.mappings = {}
	for _, m in ipairs(mappings or {}) do
		local immich = Paths.asPrefix(m.immich)
		local localP = Paths.asPrefix(m.local_)
		if immich and localP and immich ~= '/' and localP ~= '/' then
			table.insert(self.mappings, {
				immich = immich,
				local_ = localP,
				label = m.label,
			})
		end
	end
	-- Pre-sort descending by immich prefix length so the first match wins in
	-- iteration.
	table.sort(self.mappings, function(a, b) return #a.immich > #b.immich end)
	self._localSorted = {}
	for _, m in ipairs(self.mappings) do
		table.insert(self._localSorted, m)
	end
	table.sort(self._localSorted, function(a, b) return #a.local_ > #b.local_ end)
	return self
end

-- Translate an Immich-side path to the corresponding local path. Returns
-- nil, reason on failure.
function M:immichToLocal(immichPath)
	if immichPath == nil or immichPath == '' then
		return nil, 'empty-path'
	end
	local normalized = Paths.normalizeSeparators(immichPath)
	for _, m in ipairs(self.mappings) do
		if Paths.startsWith(normalized, m.immich) then
			local rest = normalized:sub(#m.immich + 1)
			return m.local_ .. rest, nil
		end
	end
	return nil, 'no-mapping'
end

-- Translate a local path to the Immich-side path. Returns nil, reason on
-- failure.
function M:localToImmich(localPath)
	if localPath == nil or localPath == '' then
		return nil, 'empty-path'
	end
	local normalized = Paths.normalizeSeparators(localPath)
	for _, m in ipairs(self._localSorted) do
		if Paths.startsWith(normalized, m.local_) then
			local rest = normalized:sub(#m.local_ + 1)
			return m.immich .. rest, nil
		end
	end
	return nil, 'no-mapping'
end

-- Convenience accessor used by UI layers to render/validate mappings.
function M:list()
	local out = {}
	for _, m in ipairs(self.mappings) do
		table.insert(out, { immich = m.immich, local_ = m.local_, label = m.label })
	end
	return out
end

return M
