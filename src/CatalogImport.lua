--[[
  CatalogImport — compatibility wrapper for importing existing local files into
  the Lightroom catalog.

  Some Lightroom Classic runtimes expose LrCatalog:addPhoto(path), while
  catalog:addPhotos(paths) is not consistently available. Keep the SDK-specific
  probing here so menu code stays thin and SyncEngine can keep receiving a
  simple importPhotos(paths) dependency.
]]

local M = {}

function M.importPhotos(catalog, paths)
	assert(catalog, 'catalog required')
	paths = paths or {}

	if type(catalog.addPhotos) == 'function' then
		local imported = catalog:addPhotos(paths)
		if imported == nil then return {} end
		return imported
	end

	if type(catalog.addPhoto) ~= 'function' then
		error('Lightroom catalog exposes neither addPhotos(paths) nor addPhoto(path)')
	end

	local imported = {}
	for _, path in ipairs(paths) do
		local photo = catalog:addPhoto(path)
		if photo ~= nil then table.insert(imported, photo) end
	end
	return imported
end

return M