--[[
  SyncEngine — pure diff computation + injectable apply step.

  Concepts:
    - A "link" pairs a Lightroom collection C with an Immich album A.
    - For each run the user picks a direction D:
        'lr_to_immich'  : Immich gets aligned to Lightroom.
        'immich_to_lr'  : Lightroom gets aligned to Immich.
    - We never silently drop items; unresolvable ones surface as warnings.

  computeDiff parameters (all required unless noted):
    direction          'lr_to_immich' | 'immich_to_lr'
    collectionPhotos   array of LrPhoto-like objects (the collection's members)
    albumAssets        array of { id, originalPath } from Immich
    pathMapper         PathMapper instance
    catalogIndex       CatalogIndex instance
    fileExists         optional function(path)->boolean
    downloadedPaths    optional map[assetId]->localPath for previously downloaded
                       unmapped assets (avoids re-downloading duplicates)
    resolveRemoteAsset optional function(immichPath)->asset,err used in
                       lr_to_immich to find Immich assets not yet in the album
    progress           optional { setCaption=f, setPortionComplete=f, isCanceled=f }

  Returns a table (or nil, 'canceled' if canceled via progress):
    {
      direction,
      toAddRemote     = { assetId… },              -- add to Immich album
      toRemoveRemote  = { assetId… },              -- remove from Immich album
      toAddLocal      = { LrPhoto… },              -- add to LR collection
      toImportLocal   = { {assetId, localPath}… }, -- import file, then add to LR collection
      toDownloadLocal = { {assetId, fileName, originalPath}… }, -- download, import, add
      toRemoveLocal   = { LrPhoto… },              -- remove from LR collection
      warnings = {
        unmappableImmich = { {assetId, path, reason}… },
        missingLocal     = { {assetId, localPath, reason}… },
        missingRemote    = { {photoPath, immichPath, reason}… },
        unmappableLocal  = { {photoPath, reason}… },
        duplicateLocal   = { {assetId, localPath, reason}… },
      },
      summary  = { addCount, removeCount, warningCount }
    }

  Only one side's add/remove lists are populated — the one matching the
  chosen direction. The other is set to empty tables for convenience.
]]

local Paths = require 'Paths'
local Errors = require 'Errors'

local M = {}

local function newSet()  return {} end
local function setAdd(s, v) s[v] = true end
local function setHas(s, v) return s[v] == true end

local function makeError(code, message, details)
	return Errors.make(code, message, details)
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
	local downloadedPaths = opts.downloadedPaths or {}
	local progress = opts.progress

	local warnings = {
		unmappableImmich = {},
		missingLocal = {},
		missingRemote = {},
		unmappableLocal = {},
		duplicateLocal = {},
	}

	-- Resolve Immich album assets → catalog photos keyed by assetId.
	--   remoteAssetIdSet         = set of assetIds that have a resolvable LrPhoto.
	--   remoteAssetIdToPhoto     = assetId -> LrPhoto.
	--   remoteAssetIdToLocalPath = assetId -> local path for importable files
	--                              that are not in the Lightroom catalog yet.
	--   albumAssetsByLocalKey    = normalized local path -> asset (used to match
	--                              collection photos back to album assets).
	local remoteAssetIdSet = newSet()
	local remoteAssetIdToPhoto = {}
	local remoteAssetIdToLocalPath = {}
	local albumAssetsByLocalKey = {}

	for _, asset in ipairs(opts.albumAssets or {}) do
		local localPath, reason = pathMapper:immichToLocal(asset.originalPath)
		local usedDownloaded = false
		if not localPath and asset.id and downloadedPaths[asset.id] then
			local trackedPath = downloadedPaths[asset.id]
			local trackedPhoto = catalogIndex:lookup(trackedPath)
			if trackedPhoto or fileExists(opts, trackedPath) then
				localPath = trackedPath
				usedDownloaded = true
			end
		end

		if not localPath then
			table.insert(warnings.unmappableImmich, {
				assetId = asset.id, path = asset.originalPath, reason = reason,
			})
		else
			albumAssetsByLocalKey[Paths.normalizeKey(localPath)] = asset
			local photo, isDuplicate = catalogIndex:lookup(localPath)
			if isDuplicate then
				table.insert(warnings.duplicateLocal, {
					assetId = asset.id,
					localPath = localPath,
					reason = 'multiple Lightroom catalog entries share this path',
				})
			end
			if not photo then
				if opts.direction == 'immich_to_lr' and fileExists(opts, localPath) then
					remoteAssetIdToLocalPath[asset.id] = localPath
				elseif not usedDownloaded then
					table.insert(warnings.missingLocal, {
						assetId = asset.id,
						immichPath = asset.originalPath,
						localPath = localPath,
						reason = opts.direction == 'immich_to_lr'
							and 'mapped file is not accessible locally'
							or 'asset is not in the Lightroom catalog',
					})
				else
					table.insert(warnings.unmappableImmich, {
						assetId = asset.id, path = asset.originalPath, reason = reason,
					})
				end
			else
				setAdd(remoteAssetIdSet, asset.id)
				remoteAssetIdToPhoto[asset.id] = photo
			end
		end
	end

	-- Resolve Lightroom collection photos → Immich album assets.
	-- Uses Paths.normalizeKey so Windows backslashes match forward-slash
	-- PathMapper outputs consistently.
	local localAssetIdSet = newSet()
	local collectionPhotosOutsideAlbum = {}
	for _, photo in ipairs(opts.collectionPhotos or {}) do
		local photoPath = photo:getRawMetadata('path')
		local match = photoPath and albumAssetsByLocalKey[Paths.normalizeKey(photoPath)] or nil
		if match then
			setAdd(localAssetIdSet, match.id)
		else
			local immichPath, reason = pathMapper:localToImmich(photoPath)
			if not immichPath then
				table.insert(warnings.unmappableLocal, {
					photoPath = photoPath, reason = reason,
				})
			else
				table.insert(collectionPhotosOutsideAlbum, {
					photo = photo,
					photoPath = photoPath,
					immichPath = immichPath,
				})
			end
		end
	end

	local toAddRemote = {}
	local toRemoveRemote = {}
	local toAddLocal = {}
	local toImportLocal = {}
	local toRemoveLocal = {}

	if opts.direction == 'lr_to_immich' then
		-- Resolve LR collection photos that are not yet in the Immich album by
		-- querying Immich for their mapped originalPath (when a resolver is
		-- provided). Assets found on Immich are queued into toAddRemote; ones
		-- not found surface as missingRemote warnings.
		local toAddRemoteSet = newSet()
		local totalLookup = #collectionPhotosOutsideAlbum
		for i, entry in ipairs(collectionPhotosOutsideAlbum) do
			if progress then
				if progress.isCanceled and progress.isCanceled() then
					return nil, 'canceled'
				end
				if progress.setPortionComplete and totalLookup > 0 then
					progress.setPortionComplete(i - 1, totalLookup)
				end
				if progress.setCaption then
					progress.setCaption(('Looking up Immich assets (%d/%d)…'):format(i, totalLookup))
				end
			end

			if opts.resolveRemoteAsset then
				local resolvedAsset, resolveErr = opts.resolveRemoteAsset(entry.immichPath)
				if resolveErr then
					table.insert(warnings.missingRemote, {
						photoPath = entry.photoPath,
						immichPath = entry.immichPath,
						reason = 'Immich lookup failed: ' .. Errors.format(resolveErr),
					})
				elseif resolvedAsset and resolvedAsset.id then
					if not setHas(remoteAssetIdSet, resolvedAsset.id) then
						setAdd(toAddRemoteSet, resolvedAsset.id)
					end
				else
					table.insert(warnings.missingRemote, {
						photoPath = entry.photoPath,
						immichPath = entry.immichPath,
						reason = 'photo in LR collection has no matching Immich asset; upload to Immich first',
					})
				end
			else
				table.insert(warnings.missingRemote, {
					photoPath = entry.photoPath,
					immichPath = entry.immichPath,
					reason = 'photo in LR collection has no matching Immich asset; upload to Immich first',
				})
			end

			if progress and progress.setPortionComplete and totalLookup > 0 then
				progress.setPortionComplete(i, totalLookup)
			end
		end

		for assetId in pairs(toAddRemoteSet) do
			table.insert(toAddRemote, assetId)
		end
		table.sort(toAddRemote)

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
		for _, entry in ipairs(collectionPhotosOutsideAlbum) do
			table.insert(toRemoveLocal, entry.photo)
		end
	end

	local matchedCount = 0
	for _ in pairs(localAssetIdSet) do matchedCount = matchedCount + 1 end

	local warningCount = #warnings.unmappableImmich
		+ #warnings.missingLocal
		+ #warnings.missingRemote
		+ #warnings.unmappableLocal
		+ #warnings.duplicateLocal

	return {
		direction = opts.direction,
		toAddRemote = toAddRemote,
		toRemoveRemote = toRemoveRemote,
		toAddLocal = toAddLocal,
		toImportLocal = toImportLocal,
		toDownloadLocal = {},
		toRemoveLocal = toRemoveLocal,
		warnings = warnings,
		summary = {
			addCount = #toAddRemote + #toAddLocal + #toImportLocal,
			removeCount = #toRemoveRemote + #toRemoveLocal,
			warningCount = warningCount,
			matchedCount = matchedCount,
			albumAssetCount = #(opts.albumAssets or {}),
			collectionPhotoCount = #(opts.collectionPhotos or {}),
		},
	}, nil
end

-- applyDiff runs the requested mutations. This function is not pure: it
-- invokes the Immich API and Lightroom catalog. Deps are injected so tests
-- can drive it without Lightroom.
--
-- deps = {
--   immichApi,           -- ImmichAPI instance
--   albumId,             -- string
--   collection,          -- LR collection with addPhotos/removePhotos
--   importPhotos,        -- optional function(paths)->{LrPhoto…}, {failures…}
--   downloadAsset,       -- optional function(assetId)->bytes,err
--   saveDownloadedAsset, -- optional function(entry,bytes)->localPath,err
--   onAssetDownloaded,   -- optional function(assetId, localPath)
--   yieldSafePcall,      -- optional function(func,...)->ok,... ; use LrTasks.pcall in LR runtime
--   fileExists,          -- optional function(path)->boolean
--   withWriteAccess,     -- function(name, fn) -> status ('executed'|'aborted'|nil)
--   progress,            -- optional { setPortionComplete=f, isCanceled=f, setCaption=f }
-- }
function M.applyDiff(diff, deps)
	assert(deps.immichApi, 'immichApi required')
	assert(deps.albumId, 'albumId required')
	assert(deps.collection, 'collection required')
	assert(deps.withWriteAccess, 'withWriteAccess required')

	local result = {
		removedRemote = 0, addedRemote = 0,
		removedLocal = 0,  addedLocal = 0, importedLocal = 0, downloadedLocal = 0,
		canceled = false,
		errors = {},
	}
	local progress = deps.progress
	local yieldSafePcall = deps.yieldSafePcall or pcall

	local function step(caption)
		if progress and progress.setCaption then progress.setCaption(caption) end
		if progress and progress.isCanceled and progress.isCanceled() then
			result.canceled = true
			return true
		end
		return false
	end

	if #diff.toRemoveRemote > 0 then
		if step('Removing assets from Immich album…') then return result end
		local resp, err = deps.immichApi:removeAssetsFromAlbum(deps.albumId, diff.toRemoveRemote)
		if err then
			table.insert(result.errors, { op = 'remote_remove', err = err })
		else
			result.removedRemote = (type(resp) == 'table' and type(resp.removed) == 'number')
				and resp.removed or #diff.toRemoveRemote
			if type(resp) == 'table' and type(resp.failed) == 'table' then
				for _, f in ipairs(resp.failed) do
					table.insert(result.errors, {
						op = 'remote_remove',
						err = makeError('remote_item_failed',
							('Failed to remove asset %s: %s'):format(tostring(f.id), tostring(f.error)), f),
					})
				end
			end
		end
	end

	if #diff.toAddRemote > 0 then
		if step('Adding assets to Immich album…') then return result end
		local resp, err = deps.immichApi:addAssetsToAlbum(deps.albumId, diff.toAddRemote)
		if err then
			table.insert(result.errors, { op = 'remote_add', err = err })
		else
			result.addedRemote = (type(resp) == 'table' and type(resp.added) == 'number')
				and resp.added or #diff.toAddRemote
			if type(resp) == 'table' and type(resp.failed) == 'table' then
				for _, f in ipairs(resp.failed) do
					table.insert(result.errors, {
						op = 'remote_add',
						err = makeError('remote_item_failed',
							('Failed to add asset %s: %s'):format(tostring(f.id), tostring(f.error)), f),
					})
				end
			end
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
			local totalDownloads = #toDownloadLocal
			for i, entry in ipairs(toDownloadLocal) do
				if progress and progress.isCanceled and progress.isCanceled() then
					result.canceled = true
					return result
				end
				if progress and progress.setCaption then
					progress.setCaption(('Downloading %d of %d: %s'):format(
						i, totalDownloads, tostring(entry.fileName or entry.assetId)))
				end
				if progress and progress.setPortionComplete then
					progress.setPortionComplete(i - 1, totalDownloads)
				end

				local okDownload, bytes, downloadErr = yieldSafePcall(deps.downloadAsset, entry.assetId)
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
					local ok, localPath, saveErr = yieldSafePcall(deps.saveDownloadedAsset, entry, bytes)
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
						if deps.onAssetDownloaded then
							yieldSafePcall(deps.onAssetDownloaded, entry.assetId, localPath)
						end
						table.insert(downloadedImportEntries, {
							assetId = entry.assetId,
							localPath = localPath,
						})
					end
				end

				if progress and progress.setPortionComplete then
					progress.setPortionComplete(i, totalDownloads)
				end
			end
		end
	end

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

	-- Catalog imports must run inside withWriteAccessDo, but they may yield.
	-- Therefore we keep them inside the write gate and use LrTasks.pcall (injected
	-- as yieldSafePcall) instead of Lua's plain pcall.
	local needsWriteAccess = #diff.toAddLocal > 0 or #pathsToImport > 0 or #diff.toRemoveLocal > 0
	if needsWriteAccess then
		if step(#pathsToImport > 0 and 'Importing files and updating Lightroom collection…' or 'Updating Lightroom collection…') then
			return result
		end
		local writeStatus = deps.withWriteAccess('Immich sync', function()
			local importedPhotos = {}
			local photosToAdd = {}

			if #pathsToImport > 0 then
				if not deps.importPhotos then
					table.insert(result.errors, {
						op = 'local_import',
						err = makeError('import_unavailable', 'Lightroom catalog import function was not provided'),
					})
				else
					local ok, importedOrErr, importFailures = yieldSafePcall(deps.importPhotos, pathsToImport)
					if not ok then
						table.insert(result.errors, {
							op = 'local_import',
							err = makeError('import_failed', tostring(importedOrErr)),
						})
					else
						if type(importedOrErr) == 'table' then
							for _, photo in ipairs(importedOrErr) do table.insert(importedPhotos, photo) end
							result.importedLocal = #importedOrErr
						end
						if type(importFailures) == 'table' then
							for _, fail in ipairs(importFailures) do
								table.insert(result.errors, {
									op = 'local_import',
									err = makeError('import_failed',
										('Could not import %s: %s'):format(tostring(fail.path), tostring(fail.err)), fail),
								})
							end
						end
					end
				end
			end

			for _, photo in ipairs(importedPhotos) do table.insert(photosToAdd, photo) end
			for _, photo in ipairs(diff.toAddLocal) do table.insert(photosToAdd, photo) end
			if #photosToAdd > 0 then
				local okAdd, addErr = yieldSafePcall(function() deps.collection:addPhotos(photosToAdd) end)
				if okAdd then
					result.addedLocal = #photosToAdd
				else
					table.insert(result.errors, {
						op = 'local_add',
						err = makeError('collection_add_failed', tostring(addErr)),
					})
				end
			end
			if #diff.toRemoveLocal > 0 then
				local okRem, remErr = yieldSafePcall(function() deps.collection:removePhotos(diff.toRemoveLocal) end)
				if okRem then
					result.removedLocal = #diff.toRemoveLocal
				else
					table.insert(result.errors, {
						op = 'local_remove',
						err = makeError('collection_remove_failed', tostring(remErr)),
					})
				end
			end
		end)
		if writeStatus == 'aborted' or writeStatus == false then
			table.insert(result.errors, {
				op = 'local_write',
				err = makeError('write_access_aborted',
					'Lightroom could not acquire catalog write access (catalog busy). Please retry.'),
			})
		end
	end

	return result
end

return M
