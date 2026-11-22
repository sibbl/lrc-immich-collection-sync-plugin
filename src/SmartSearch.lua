--[[
  SmartSearch — pure helpers for matching Immich Smart/CLIP search results
  against a local Lightroom catalog using PathMapper + CatalogIndex.

  No Lightroom SDK dependencies — fully unit-testable.
]]

local M = {}

-- Build a tidy Lightroom collection name from a raw search query: collapse
-- whitespace, strip hierarchy "/" separators, trim, and cap length.
function M.buildCollectionName(query)
	local name = tostring(query or '')
	name = name:gsub('%s+', ' ')
	name = name:gsub('/', '-')
	name = name:gsub('^%s+', ''):gsub('%s+$', '')
	if #name > 60 then
		name = name:sub(1, 57) .. '...'
	end
	if name == '' then
		name = 'Search'
	end
	return name
end

-- Resolve Immich search assets into local catalog LrPhoto objects, preserving
-- Immich's relevance order and deduplicating photos.
--
-- Returns:
--   {
--     matchedPhotos     = { LrPhoto, ... },
--     totalResults      = number,
--     unmappedCount     = number,
--     notInCatalogCount = number,
--   }
function M.matchResults(searchAssets, pathMapper, catalogIndex, downloadedPaths)
	assert(pathMapper, 'pathMapper required')
	assert(catalogIndex, 'catalogIndex required')
	downloadedPaths = downloadedPaths or {}

	local matchedPhotos = {}
	local seenPhotos = {}
	local unmappedCount = 0
	local notInCatalogCount = 0
	local list = searchAssets or {}

	for _, asset in ipairs(list) do
		local localPath = pathMapper:immichToLocal(asset.originalPath)
		if not localPath and asset.id and downloadedPaths[asset.id] then
			localPath = downloadedPaths[asset.id]
		end

		if not localPath then
			unmappedCount = unmappedCount + 1
		else
			local photo = catalogIndex:lookup(localPath)
			if not photo then
				notInCatalogCount = notInCatalogCount + 1
			else
				local dedupKey = photo.localIdentifier or photo
				if not seenPhotos[dedupKey] then
					seenPhotos[dedupKey] = true
					table.insert(matchedPhotos, photo)
				end
			end
		end
	end

	return {
		matchedPhotos = matchedPhotos,
		totalResults = #list,
		unmappedCount = unmappedCount,
		notInCatalogCount = notInCatalogCount,
	}
end

return M
