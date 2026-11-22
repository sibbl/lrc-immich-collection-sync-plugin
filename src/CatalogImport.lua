--[[
  CatalogImport — compatibility wrapper for importing existing local files into
  the Lightroom catalog.

  Some Lightroom Classic runtimes expose LrCatalog:addPhoto(path), while
  catalog:addPhotos(paths) is not consistently available. This helper must be
  called from inside catalog:withWriteAccessDo(...) or a related write-access
  gate; the SDK requires write access for catalog imports.

  In the addPhoto(path) fallback loop, each file is protected individually via
  opts.yieldSafePcall (LrTasks.pcall in LR) so one unsupported/corrupted file
  never aborts the batch or loses earlier imported LrPhoto objects.

  Returns: (importedPhotos, failures)
    importedPhotos : array of LrPhoto
    failures       : array of { path = string, err = string }
]]

local M = {}

function M.importPhotos(catalog, paths, opts)
	assert(catalog, 'catalog required')
	paths = paths or {}
	opts = opts or {}

	if #paths == 0 then return {}, {} end

	local yieldSafePcall = opts.yieldSafePcall or pcall
	local progress = opts.progress

	if type(catalog.addPhotos) == 'function' then
		local imported = catalog:addPhotos(paths)
		if imported == nil then return {}, {} end
		return imported, {}
	end

	if type(catalog.addPhoto) ~= 'function' then
		error('Lightroom catalog exposes neither addPhotos(paths) nor addPhoto(path)')
	end

	local imported = {}
	local failures = {}
	local total = #paths
	for i, path in ipairs(paths) do
		if progress and progress.isCanceled and progress.isCanceled() then
			break
		end
		if progress and progress.setPortionComplete then
			progress.setPortionComplete(i - 1, total)
		end
		local ok, photoOrErr = yieldSafePcall(function() return catalog:addPhoto(path) end)
		if ok then
			if photoOrErr ~= nil then
				table.insert(imported, photoOrErr)
			else
				table.insert(failures, { path = path, err = 'Lightroom returned nil for imported photo' })
			end
		else
			table.insert(failures, { path = path, err = tostring(photoOrErr) })
		end
		if progress and progress.setPortionComplete then
			progress.setPortionComplete(i, total)
		end
	end
	return imported, failures
end

return M
