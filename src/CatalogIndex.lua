--[[
  CatalogIndex — build a map from local filesystem path to LrPhoto.

  Lightroom's SDK does not expose `findPhotoByPath`, so we iterate the whole
  catalog once and cache the result. The cache is intentionally short-lived:
  each sync run gets a fresh index to reflect new imports.

  Construction parameters:
      photos       array of LrPhoto-like objects (required)
      caseFold     function(string)->string   (required; provide by caller so
                   we don't depend on util.Paths here — keeps this pure and
                   testable without globals)
]]

local M = {}
M.__index = M

function M.new(photos, caseFold)
	assert(caseFold, 'caseFold function required')
	local self = setmetatable({}, M)
	self._byPath = {}
	self._duplicates = {}

	for _, photo in ipairs(photos or {}) do
		local path = photo:getRawMetadata('path')
		if path ~= nil and path ~= '' then
			local key = caseFold(path)
			if self._byPath[key] then
				self._duplicates[key] = true
			else
				self._byPath[key] = photo
			end
		end
	end

	self._caseFold = caseFold
	return self
end

-- Look up a photo by local path. Returns (photo, isDuplicate). If duplicate
-- the caller should surface a warning because path-based matching is
-- ambiguous — catalogs should not contain duplicates, but they sometimes do.
function M:lookup(localPath)
	if localPath == nil or localPath == '' then return nil, false end
	local key = self._caseFold(localPath)
	return self._byPath[key], self._duplicates[key] == true
end

function M:size()
	local n = 0
	for _ in pairs(self._byPath) do n = n + 1 end
	return n
end

return M
