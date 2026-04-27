--[[
  SyncEngine — pure diff computation + injectable apply step.

  Concepts:
    - A "link" pairs a Lightroom collection C with an Immich album A.
    - For each run the user picks a direction D:
        'lr_to_immich'  : Immich gets aligned to Lightroom.
        'immich_to_lr'  : Lightroom gets aligned to Immich.
    - We never silently drop items; unresolvable ones surface as warnings.

  computeDiff parameters (all required unless noted):
    direction        'lr_to_immich' | 'immich_to_lr'
    collectionPhotos array of LrPhoto-like objects (the collection's members)
    albumAssets      array of { id, originalPath } from Immich
    pathMapper       PathMapper instance
    catalogIndex     CatalogIndex instance

  Returns a table:
    {
      direction,
      toAddRemote   = { assetId… },            -- add to Immich album
      toRemoveRemote= { assetId… },            -- remove from Immich album
      toAddLocal    = { LrPhoto… },            -- add to LR collection
			toImportLocal = { {assetId, localPath} … }, -- import file, then add to LR collection
			toDownloadLocal = { {assetId, fileName, originalPath} … }, -- download, import, add
      toRemoveLocal = { LrPhoto… },            -- remove from LR collection
      warnings = {
        unmappableImmich = { {assetId, path, reason} … },
				missingLocal     = { {assetId, localPath} … },     -- mapped but inaccessible / unsafe
        unmappableLocal  = { {photoPath, reason} … },      -- LR photo outside any mapping
      },
      summary  = { addCount, removeCount, warningCount }
    }

  Only one side's add/remove lists are populated — the one matching the
  chosen direction. The other is set to empty tables for convenience.
]]

local M = {}

local function newSet()  return {} end
local function setAdd(s, v) s[v] = true end
local function setHas(s, v) return s[v] == true end

local function makeError(code, message, details)
	return { code = code, message = message, details = details }
end

local function fileExists(opts, path)
	if not opts.fileExists then return true end
	local ok, exists = pcall(opts.fileExists, path)
	return ok and exists and true or false
end

local function setDiff(a, b)
	local out = {}
	for v in pairs(a) do
		if not setHas(b, v) then table.insert(out, v) end
	end
	table.sort(out)
	return out
end

function M.computeDiff(opts)
	assert(opts.direction == 'lr_to_immich' or opts.direction == 'immich_to_lr',
		'direction must be lr_to_immich or immich_to_lr')
	assert(opts.pathMapper, 'pathMapper required')
	assert(opts.catalogIndex, 'catalogIndex required')

	local pathMapper = opts.pathMapper
	local catalogIndex = opts.catalogIndex

	local warnings = {
		unmappableImmich = {},
		missingLocal = {},
		unmappableLocal = {},
	}

	-- Resolve Immich album assets → catalog photos keyed by assetId.
	--   remoteAssetIdSet = set of assetIds that have a resolvable LrPhoto.
	--   remoteAssetIdToPhoto = assetId -> LrPhoto.
	--   remoteAssetIdToLocalPath = assetId -> local path for importable files
	--     that are not in the Lightroom catalog yet.
	local remoteAssetIdSet = newSet()
	local remoteAssetIdToPhoto = {}
	local remoteAssetIdToLocalPath = {}
	for _, asset in ipairs(opts.albumAssets or {}) do
		local localPath, reason = pathMapper:immichToLocal(asset.originalPath)
		if not localPath then
			table.insert(warnings.unmappableImmich, {
				assetId = asset.id, path = asset.originalPath, reason = reason,
			})
		else
			local photo = catalogIndex:lookup(localPath)
			if not photo then
				if opts.direction == 'immich_to_lr' and fileExists(opts, localPath) then
					remoteAssetIdToLocalPath[asset.id] = localPath
				else
					table.insert(warnings.missingLocal, {
						assetId = asset.id,
						localPath = localPath,
						reason = opts.direction == 'immich_to_lr'
							and 'mapped file is not accessible locally'
							or 'asset is not in the Lightroom catalog',
					})
				end
			else
				setAdd(remoteAssetIdSet, asset.id)
				remoteAssetIdToPhoto[asset.id] = photo
			end
		end
	end

	-- Resolve Lightroom collection photos → Immich assetIds via the album we
	-- just indexed. We only accept a match if the LR photo's path maps into
	-- a known mapping AND the resulting Immich path appears in the album's
	-- asset list. Photos whose path is outside any mapping get a warning.
	local albumAssetsByLocalPath = {}
	for _, asset in ipairs(opts.albumAssets or {}) do
		local localPath = pathMapper:immichToLocal(asset.originalPath)
		if localPath then
			local Paths = require 'Paths'
			albumAssetsByLocalPath[Paths.foldForCompare(localPath)] = asset
		end
	end

	local Paths = require 'Paths'
	local localAssetIdSet = newSet()
	local localAssetIdToPhoto = {}
	local collectionPhotosOutsideAlbum = {}   -- path-mapped LR photos not in album
	for _, photo in ipairs(opts.collectionPhotos or {}) do
		local photoPath = photo:getRawMetadata('path')
		local immichPath, reason = pathMapper:localToImmich(photoPath)
		if not immichPath then
			table.insert(warnings.unmappableLocal, {
				photoPath = photoPath, reason = reason,
			})
		else
			local match = albumAssetsByLocalPath[Paths.foldForCompare(photoPath)]
			if match then
				setAdd(localAssetIdSet, match.id)
				localAssetIdToPhoto[match.id] = photo
			else
				table.insert(collectionPhotosOutsideAlbum, photo)
			end
		end
	end

	local toAddRemote = {}
	local toRemoveRemote = {}
	local toAddLocal = {}
	local toImportLocal = {}
	local toRemoveLocal = {}

	if opts.direction == 'lr_to_immich' then
		-- Add every LR photo to Immich whose mapped-to Immich asset is NOT in
		-- the album. That requires that the LR photo's file ALREADY exists as
		-- an Immich asset; we only have such IDs via the album query, so
		-- photos outside the album with no prior Immich record cannot be
		-- added by a membership sync — surface them as warnings instead.
		for _, photo in ipairs(collectionPhotosOutsideAlbum) do
			table.insert(warnings.missingLocal, {
				photoPath = photo:getRawMetadata('path'),
				reason = 'photo in LR collection has no matching Immich asset; upload to Immich first',
			})
		end
		-- Remove from Immich album every asset whose LrPhoto is NOT in the LR collection.
		for _, assetId in ipairs(setDiff(remoteAssetIdSet, localAssetIdSet)) do
			table.insert(toRemoveRemote, assetId)
		end
	else -- immich_to_lr
		-- Add to LR collection every Immich-resolved photo not already there.
		for _, assetId in ipairs(setDiff(remoteAssetIdSet, localAssetIdSet)) do
			table.insert(toAddLocal, remoteAssetIdToPhoto[assetId])
		end
		-- Import files that exist locally but are not in the Lightroom catalog yet,
		-- then add the imported LrPhoto objects to the collection during apply.
		local importAssetIds = {}
		for assetId in pairs(remoteAssetIdToLocalPath) do table.insert(importAssetIds, assetId) end
		table.sort(importAssetIds)
		for _, assetId in ipairs(importAssetIds) do
			table.insert(toImportLocal, {
				assetId = assetId,
				localPath = remoteAssetIdToLocalPath[assetId],
			})
		end
		-- Remove from LR collection every photo that is not in the album
		-- (and whose path is mapped; unmappable ones are warnings, not deletions).
		for _, photo in ipairs(collectionPhotosOutsideAlbum) do
			table.insert(toRemoveLocal, photo)
		end
	end

	local warningCount = #warnings.unmappableImmich
		+ #warnings.missingLocal
		+ #warnings.unmappableLocal

	return {
		direction = opts.direction,
		toAddRemote = toAddRemote,
		toRemoveRemote = toRemoveRemote,
		toAddLocal = toAddLocal,
		toImportLocal = toImportLocal,
		toRemoveLocal = toRemoveLocal,
		warnings = warnings,
		summary = {
			addCount = #toAddRemote + #toAddLocal + #toImportLocal,
			removeCount = #toRemoveRemote + #toRemoveLocal,
			warningCount = warningCount,
		},
	}
end

-- applyDiff runs the requested mutations. This function is not pure: it
-- invokes the Immich API and Lightroom catalog. Deps are injected so tests
-- can drive it without Lightroom.
--
-- deps = {
--   immichApi,        -- ImmichAPI instance
--   albumId,          -- string
--   collection,       -- LR collection with addPhotos/removePhotos
--   importPhotos,     -- optional function(paths)->{LrPhoto…}; required for toImportLocal
--   downloadAsset,    -- optional function(assetId)->bytes,err; required for toDownloadLocal
--   saveDownloadedAsset, -- optional function(entry,bytes)->localPath,err
--   fileExists,       -- optional function(path)->boolean
--   withWriteAccess,  -- function(name, fn) wrapping LR mutations
--   progress,         -- optional { setPortionComplete=f, isCanceled=f, setCaption=f }
-- }
function M.applyDiff(diff, deps)
	assert(deps.immichApi, 'immichApi required')
	assert(deps.albumId, 'albumId required')
	assert(deps.collection, 'collection required')
	assert(deps.withWriteAccess, 'withWriteAccess required')

	local result = {
		removedRemote = 0, addedRemote = 0,
		removedLocal = 0,  addedLocal = 0, importedLocal = 0, downloadedLocal = 0,
		errors = {},
	}
	local progress = deps.progress

	local function step(caption)
		if progress and progress.setCaption then progress.setCaption(caption) end
		if progress and progress.isCanceled and progress.isCanceled() then return true end
		return false
	end

	if #diff.toRemoveRemote > 0 then
		if step('Removing assets from Immich album…') then return result end
		local _, err = deps.immichApi:removeAssetsFromAlbum(deps.albumId, diff.toRemoveRemote)
		if err then
			table.insert(result.errors, { op = 'remote_remove', err = err })
		else
			result.removedRemote = #diff.toRemoveRemote
		end
	end

	if #diff.toAddRemote > 0 then
		if step('Adding assets to Immich album…') then return result end
		local _, err = deps.immichApi:addAssetsToAlbum(deps.albumId, diff.toAddRemote)
		if err then
			table.insert(result.errors, { op = 'remote_add', err = err })
		else
			result.addedRemote = #diff.toAddRemote
		end
	end

	local toImportLocal = diff.toImportLocal or {}
	local toDownloadLocal = diff.toDownloadLocal or {}
	local downloadedImportEntries = {}

	if #toDownloadLocal > 0 then
		if step('Downloading unmapped Immich assets…') then return result end
		if not deps.downloadAsset or not deps.saveDownloadedAsset then
			table.insert(result.errors, {
				op = 'local_download',
				err = makeError('download_unavailable', 'Download/import functions were not provided'),
			})
		else
			for _, entry in ipairs(toDownloadLocal) do
				if progress and progress.isCanceled and progress.isCanceled() then return result end
				local okDownload, bytes, downloadErr = pcall(deps.downloadAsset, entry.assetId)
				if not okDownload then
					table.insert(result.errors, {
						op = 'local_download',
						err = makeError('download_failed', tostring(bytes), entry),
					})
				elseif downloadErr or bytes == nil then
					table.insert(result.errors, {
						op = 'local_download',
						err = downloadErr or makeError('download_failed', 'No data returned for asset ' .. tostring(entry.assetId), entry),
					})
				else
					local ok, localPath, saveErr = pcall(deps.saveDownloadedAsset, entry, bytes)
					if not ok then
						table.insert(result.errors, {
							op = 'local_download',
							err = makeError('save_failed', tostring(localPath), entry),
						})
					elseif saveErr or not localPath then
						table.insert(result.errors, {
							op = 'local_download',
							err = saveErr or makeError('save_failed', 'Could not save downloaded asset', entry),
						})
					else
						result.downloadedLocal = result.downloadedLocal + 1
						table.insert(downloadedImportEntries, {
							assetId = entry.assetId,
							localPath = localPath,
						})
					end
				end
			end
		end
	end

	-- Import photos into the Lightroom catalog BEFORE entering
	-- withWriteAccessDo. catalog:addPhoto is a yielding operation and
	-- Lightroom does not allow yielding inside a write-access block.
	local importedPhotos = {}
	if #toImportLocal > 0 or #downloadedImportEntries > 0 then
		if step('Importing files into Lightroom catalog…') then return result end
		local pathsToImport = {}
		for _, entry in ipairs(toImportLocal) do
			if fileExists(deps, entry.localPath) then
				table.insert(pathsToImport, entry.localPath)
			else
				table.insert(result.errors, {
					op = 'local_import',
					err = makeError('file_missing', 'Local file is not accessible: ' .. tostring(entry.localPath), entry),
				})
			end
		end
		for _, entry in ipairs(downloadedImportEntries) do
			if fileExists(deps, entry.localPath) then
				table.insert(pathsToImport, entry.localPath)
			else
				table.insert(result.errors, {
					op = 'local_import',
					err = makeError('file_missing', 'Downloaded file is not accessible: ' .. tostring(entry.localPath), entry),
				})
			end
		end

		if #pathsToImport > 0 then
			if not deps.importPhotos then
				table.insert(result.errors, {
					op = 'local_import',
					err = makeError('import_unavailable', 'Lightroom catalog import function was not provided'),
				})
			else
				local ok, importedOrErr = pcall(deps.importPhotos, pathsToImport)
				if not ok then
					table.insert(result.errors, {
						op = 'local_import',
						err = makeError('import_failed', tostring(importedOrErr)),
					})
				elseif importedOrErr then
					for _, photo in ipairs(importedOrErr) do table.insert(importedPhotos, photo) end
					result.importedLocal = #importedOrErr
				end
			end
		end
	end

	-- Now do collection mutations inside write-access (non-yielding).
	local needsWriteAccess = #diff.toAddLocal > 0 or #importedPhotos > 0
		or #diff.toRemoveLocal > 0
	if needsWriteAccess then
		if step('Updating Lightroom collection…') then return result end
		deps.withWriteAccess('Immich sync', function()
			local photosToAdd = {}
			for _, photo in ipairs(importedPhotos) do table.insert(photosToAdd, photo) end
			for _, photo in ipairs(diff.toAddLocal) do table.insert(photosToAdd, photo) end
			if #photosToAdd > 0 then
				deps.collection:addPhotos(photosToAdd)
				result.addedLocal = #photosToAdd
			end
			if #diff.toRemoveLocal > 0 then
				deps.collection:removePhotos(diff.toRemoveLocal)
				result.removedLocal = #diff.toRemoveLocal
			end
		end)
	end

	return result
end

return M
