--[[
  CatalogIndex — build a map from local filesystem path to LrPhoto.

  Lightroom's SDK does not expose `findPhotoByPath`, so we iterate the whole
  catalog once and cache the result. The cache is intentionally short-lived:
  each sync run gets a fresh index to reflect new imports.

  Virtual copies share the exact same `path` metadata as their master photo in
  Lightroom. When both exist, CatalogIndex prefers the master photo
  (`isVirtualCopy == false`) and only marks a path as a duplicate when two
  distinct master photos (or two virtual copies without a master) collide.

  Construction parameters:
      photos       array of LrPhoto-like objects (required)
      caseFold     function(string)->string   (required; provide by caller so
                   we don't depend on Paths here — keeps this pure and
                   testable without globals)
      opts         optional table:
                     metadataByPhoto  map[LrPhoto] -> { path, isVirtualCopy }
                                      (from catalog:batchGetRawMetadata)
                     progress         optional { isCanceled=f, setPortionComplete=f }
]]

local M = {}
M.__index = M

local PROGRESS_STRIDE = 250

local function readPhotoMeta(photo, metadataByPhoto)
	if metadataByPhoto and metadataByPhoto[photo] then
		local meta = metadataByPhoto[photo]
		return meta.path, meta.isVirtualCopy == true
	end
	local path = photo:getRawMetadata('path')
	local isVirtual = photo:getRawMetadata('isVirtualCopy') == true
	return path, isVirtual
end

function M.new(photos, caseFold, opts)
	assert(caseFold, 'caseFold function required')
	opts = opts or {}
	local metadataByPhoto = opts.metadataByPhoto
	local progress = opts.progress

	local self = setmetatable({}, M)
	self._byPath = {}
	self._isVirtualByPath = {}
	self._duplicates = {}
	self._caseFold = caseFold

	local list = photos or {}
	local total = #list

	for i, photo in ipairs(list) do
		if progress and (i % PROGRESS_STRIDE == 0 or i == total) then
			if progress.setPortionComplete then
				progress.setPortionComplete(i, total)
			end
			if progress.isCanceled and progress.isCanceled() then
				return nil, 'canceled'
			end
		end

		local path, isVirtual = readPhotoMeta(photo, metadataByPhoto)
		if path ~= nil and path ~= '' then
			local key = caseFold(path)
			local existing = self._byPath[key]
			if not existing then
				self._byPath[key] = photo
				self._isVirtualByPath[key] = isVirtual
			else
				local existingIsVirtual = self._isVirtualByPath[key] == true
				if existingIsVirtual and not isVirtual then
					-- Prefer the master photo over a virtual copy; clear any
					-- virtual-only duplicate flag since we now have a unique master.
					self._byPath[key] = photo
					self._isVirtualByPath[key] = false
					self._duplicates[key] = nil
				elseif not existingIsVirtual and isVirtual then
					-- Virtual copy of an already-indexed master: ignore without
					-- marking as an ambiguous duplicate.
				else
					-- Two masters (or two virtual copies with no master) share
					-- the same filesystem path.
					self._duplicates[key] = true
				end
			end
		end
	end

	return self, nil
end

-- Build a CatalogIndex from an LrCatalog, using catalog:batchGetRawMetadata
-- when available (SDK 5.0+) for dramatically faster indexing on large catalogs.
function M.buildFromCatalog(catalog, caseFold, progress)
	assert(catalog, 'catalog required')
	assert(caseFold, 'caseFold function required')

	if progress and progress.isCanceled and progress.isCanceled() then
		return nil, 'canceled'
	end

	local allPhotos = catalog:getAllPhotos() or {}
	if progress and progress.isCanceled and progress.isCanceled() then
		return nil, 'canceled'
	end

	local metadataByPhoto = nil
	if #allPhotos > 0 and type(catalog.batchGetRawMetadata) == 'function' then
		-- LrCatalog:batchGetRawMetadata(photos, keys) — Adobe Lightroom SDK 5.0+
		metadataByPhoto = catalog:batchGetRawMetadata(allPhotos, { 'path', 'isVirtualCopy' })
	end

	return M.new(allPhotos, caseFold, {
		metadataByPhoto = metadataByPhoto,
		progress = progress,
	})
end

-- Look up a photo by local path. Returns (photo, isDuplicate). If duplicate
-- the caller should surface a warning because path-based matching is
-- ambiguous — catalogs should not contain duplicate masters, but they
-- sometimes do.
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
