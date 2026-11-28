--[[
  Sync the currently-selected collection with its linked Immich album.

  Flow:
    1. Resolve link from catalog-scoped MappingStore (and verify server URL).
    2. Ask the user for direction first (so Cancel is instant).
    3. Fetch album assets and refresh cached album name if renamed.
    4. Build a fresh CatalogIndex (using batchGetRawMetadata when available).
    5. Compute diff (resolving un-matched LR photos via Immich metadata search
       when syncing Lightroom → Immich).
    6. Show the preview. Retry starts a fresh analysis with the same direction.
    7. Optionally prompt for download fallback on unmapped Immich assets.
    8. Apply changes with progress reporting and log the outcome.
]]

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrProgressScope = import 'LrProgressScope'
local LrPrefs = import 'LrPrefs'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Settings = require 'Settings'
local MappingStore = require 'MappingStore'
local ImmichAPI = require 'ImmichAPI'
local PathMapper = require 'PathMapper'
local CatalogIndex = require 'CatalogIndex'
local SyncEngine = require 'SyncEngine'
local CatalogImport = require 'CatalogImport'
local Paths = require 'Paths'
local Errors = require 'Errors'
local Dialogs = require 'Dialogs'
local RetryDialog = require 'RetryDialog'
local Logger = require 'Logger'

local function extensionIndex(name)
	local idx
	for i = #name, 1, -1 do
		local c = name:sub(i, i)
		if c == '.' then idx = i; break end
		if c == '/' or c == '\\' then break end
	end
	return idx
end

local function uniqueChildPath(folder, fileName)
	local candidate = LrPathUtils.child(folder, fileName)
	if not LrFileUtils.exists(candidate) then return candidate end

	local dot = extensionIndex(fileName)
	local stem = dot and fileName:sub(1, dot - 1) or fileName
	local ext = dot and fileName:sub(dot) or ''
	for i = 1, 9999 do
		candidate = LrPathUtils.child(folder, ('%s-%d%s'):format(stem, i, ext))
		if not LrFileUtils.exists(candidate) then return candidate end
	end
	local suffix = (type(os) == 'table' and os.time) and os.time() or 0
	return LrPathUtils.child(folder, stem .. '-' .. tostring(suffix) .. ext)
end

local function writeBinary(path, bytes)
	if not io or not io.open then
		return nil, Errors.make('io_unavailable', 'Lightroom did not expose binary file writing')
	end
	local file, openErr = io.open(path, 'wb')
	if not file then
		return nil, Errors.make('file_open_failed', 'Could not open file for writing: ' .. tostring(openErr), path)
	end
	local ok, writeResult, writeErr = pcall(function() return file:write(bytes) end)
	file:close()
	if not ok or not writeResult then
		return nil, Errors.make('file_write_failed', tostring(writeErr or writeResult), path)
	end
	return path, nil
end

local function defaultDownloadFolder()
	local saved = Settings.getDownloadFolder()
	if saved ~= '' then return saved end
	return LrPathUtils.getStandardFilePath('pictures') or ''
end

local function downloadEntriesFromWarnings(diff, assetById)
	local entries = {}
	local videoCount = 0
	for _, warning in ipairs(diff.warnings.unmappableImmich or {}) do
		local asset = assetById[warning.assetId] or {}
		if asset.type == 'VIDEO' then videoCount = videoCount + 1 end
		local leaf = (asset.originalFileName and asset.originalFileName ~= '')
			and asset.originalFileName
			or (warning.path and LrPathUtils.leafName(warning.path))
		table.insert(entries, {
			assetId = warning.assetId,
			fileName = Dialogs.sanitizeFileName(leaf, tostring(warning.assetId) .. '.jpg'),
			originalPath = warning.path,
		})
	end
	return entries, videoCount
end

local function ensureDirectory(folder)
	if not folder or folder == '' then
		return false, 'No download folder selected.'
	end
	local exists = LrFileUtils.exists(folder)
	if exists == 'directory' then
		return true, nil
	elseif exists then
		return false, 'Selected path exists and is not a directory: ' .. folder
	end
	local created = LrFileUtils.createAllDirectories(folder)
	if created or LrFileUtils.exists(folder) == 'directory' then
		return true, nil
	end
	return false, 'Could not create download folder: ' .. folder
end

local function promptDownloadFolder(context, f, count, videoCount)
	local props = LrBinding.makePropertyTable(context)
	props.folder = defaultDownloadFolder()

	local bodyText = 'You can download the original files from Immich, save them to a folder, import them into the Lightroom catalog, and add them to this collection. Cancel skips downloading and applies only mapped changes.'
	if videoCount > 0 then
		bodyText = bodyText .. ('\n\nNote: %d of these unmapped assets %s video%s. Large videos are buffered in memory during download and may take longer or fail if very large.'):format(
			videoCount, videoCount == 1 and 'is a' or 'are', videoCount == 1 and '' or 's')
	end

	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text {
			title = ('%d Immich asset%s could not be mapped to a local path.'):format(
				count, count == 1 and '' or 's'),
			font = '<system/bold>',
		},
		f:static_text {
			title = bodyText,
			width_in_chars = 72,
			height_in_lines = videoCount > 0 and 6 or 4,
		},
		f:row {
			f:static_text { title = 'Save to', width = 80 },
			f:edit_field { value = LrView.bind 'folder', width_in_chars = 46, immediate = true },
			f:push_button {
				title = 'Choose…',
				action = function()
					local result = LrDialogs.runOpenPanel{
						title = 'Choose folder for downloaded Immich originals',
						canChooseFiles = false,
						canChooseDirectories = true,
						canCreateDirectories = true,
						allowsMultipleSelection = false,
					}
					if result and result[1] then props.folder = result[1] end
				end,
			},
		},
	}

	local result = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Download unmapped assets?',
		contents = contents,
		actionVerb = 'Download & import',
	}
	if result ~= 'ok' then return nil end

	local okDir, dirErr = ensureDirectory(props.folder)
	if not okDir then
		LrDialogs.message('Immich Collection Sync', dirErr .. '\nSkipping downloads.', 'warning')
		return nil
	end
	Settings.setDownloadFolder(props.folder)
	return props.folder
end

local function buildPreviewText(ctx)
	local direction = ctx.direction
	local album = ctx.album or {}
	local albumName = ctx.albumName or ''
	local collectionName = ctx.collectionName or ''
	local diff = ctx.diff
	local pathMappings = ctx.pathMappings or {}
	local catalogSize = ctx.catalogSize or 0
	local logEnabled = ctx.logEnabled == true

	local fetchedAssets = #(album.assets or {})
	local reportedCount = tonumber(album.assetCount)
	local lines = {}
	local function addLine(s) table.insert(lines, s) end

	addLine(('Collection: %s (%d photo%s in collection; %d in LR catalog)'):format(
		collectionName,
		diff.summary.collectionPhotoCount or 0,
		(diff.summary.collectionPhotoCount or 0) == 1 and '' or 's',
		catalogSize))
	if reportedCount ~= nil then
		addLine(('Immich album: %s (%d asset%s fetched; Immich reports assetCount=%d)'):format(
			albumName, fetchedAssets, fetchedAssets == 1 and '' or 's', reportedCount))
	else
		addLine(('Immich album: %s (%d asset%s fetched)'):format(
			albumName, fetchedAssets, fetchedAssets == 1 and '' or 's'))
	end
	addLine(('Direction: %s'):format(direction == 'lr_to_immich'
		and 'Lightroom → Immich' or 'Immich → Lightroom'))
	addLine(('Matched on both sides: %d'):format(diff.summary.matchedCount or 0))
	if #pathMappings == 0 then
		addLine('Active path mappings: none configured')
	else
		local mapSummaries = {}
		for _, m in ipairs(pathMappings) do
			table.insert(mapSummaries, ('%s → %s'):format(m.immich or '?', m.local_ or '?'))
		end
		addLine(('Active path mappings (%d): %s'):format(#pathMappings, table.concat(mapSummaries, ', ')))
	end
	addLine('')

	if reportedCount and reportedCount > 0 and fetchedAssets == 0 then
		addLine(('DIAGNOSTIC: Immich reports %d asset%s in "%s", but returned 0 asset records!'):format(
			reportedCount, reportedCount == 1 and '' or 's', albumName))
		if album._assetsFallbackError then
			addLine('  Fallback POST /api/search/metadata failed: ' .. Errors.format(album._assetsFallbackError))
		end
		addLine('  Likely causes:')
		addLine('  • Your Immich API key is missing permissions (needs album.read + asset.read)')
		addLine('  • This is a shared album whose assets are not visible to this API key')
		addLine('  • Enable Debug logging in Plug-in Manager and re-run to inspect ImmichSync.log')
		addLine('')
	elseif fetchedAssets == 0 and (diff.summary.collectionPhotoCount or 0) == 0 then
		addLine('Note: Both the Immich album (0 assets) and the Lightroom collection (0 photos) are empty.')
		addLine('')
	end

	if direction == 'lr_to_immich' then
		addLine(('Add to Immich album:      %d'):format(#diff.toAddRemote))
		addLine(('Remove from Immich album: %d'):format(#diff.toRemoveRemote))
	else
		addLine(('Import into Lightroom catalog:    %d'):format(#(diff.toImportLocal or {})))
		addLine(('Add to Lightroom collection:      %d'):format(#diff.toAddLocal + #(diff.toImportLocal or {})))
		addLine(('Remove from Lightroom collection: %d'):format(#diff.toRemoveLocal))
	end

	addLine('')
	addLine(('Warnings: %d'):format(diff.summary.warningCount))
	if direction == 'immich_to_lr' and #(diff.warnings.unmappableImmich or {}) > 0 then
		addLine(('Download option after Apply: %d unmapped Immich asset%s'):format(
			#diff.warnings.unmappableImmich,
			#diff.warnings.unmappableImmich == 1 and '' or 's'))
	end

	local function appendWarnings(list, label, formatFn, limit)
		limit = limit or 20
		for i, w in ipairs(list or {}) do
			if i <= limit then addLine(('  %s: %s'):format(label, formatFn(w))) end
		end
		if list and #list > limit then
			addLine(('  … and %d more %s'):format(#list - limit, label))
		end
	end

	if diff.summary.warningCount > 0 then
		appendWarnings(diff.warnings.unmappableImmich, 'unmapped Immich path',
			function(w) return tostring(w.path or w.assetId or '?') end)
		appendWarnings(diff.warnings.missingLocal, 'missing locally', function(w)
			if w.immichPath and w.localPath then
				return ('%s  →  %s'):format(w.immichPath, w.localPath)
			end
			return tostring(w.localPath or w.photoPath or '?')
		end)
		appendWarnings(diff.warnings.missingRemote, 'not found on Immich', function(w)
			if w.immichPath then
				return ('%s  (LR: %s)'):format(w.immichPath, tostring(w.photoPath or '?'))
			end
			return tostring(w.photoPath or '?')
		end)
		appendWarnings(diff.warnings.unmappableLocal, 'LR photo outside any mapping',
			function(w) return tostring(w.photoPath or '?') end)
		appendWarnings(diff.warnings.duplicateLocal, 'duplicate catalog path',
			function(w) return tostring(w.localPath or '?') end)
	end

	addLine('')
	if logEnabled then
		addLine('Debug log: ' .. Logger.logFilePath())
	else
		addLine('Tip: Enable "Debug logging" in File > Plug-in Manager… > Immich Collection Sync for detailed logs.')
	end

	return table.concat(lines, '\n')
end

local function presentPreviewDialog(context, previewText, hasChanges, hasDiagnostics, warnings)
	local heading
	local title
	if hasChanges then
		title = 'Immich Collection Sync — Preview'
		heading = 'Review the planned changes below before applying.'
	elseif hasDiagnostics then
		title = 'Immich Collection Sync — Nothing to apply (check warnings)'
		heading = 'Resolve the warnings below, then click Retry to check again.'
	else
		title = 'Immich Collection Sync — Already in sync'
		heading = 'Collection and album are already in sync (no changes to apply).'
	end

	return RetryDialog.preview(context, {
		title = title,
		heading = heading,
		text = previewText,
		width = 88,
		height = 20,
		hasChanges = hasChanges,
		hasDiagnostics = hasDiagnostics,
		canAddMapping = #warnings.unmappableImmich > 0 or #warnings.unmappableLocal > 0
			or #warnings.missingLocal > 0 or #warnings.missingRemote > 0,
	})
end

local function chooseSync(context)
	if not Dialogs.requireCredentials() then return end
	local collection, reason = Dialogs.activeCollection()
	if not collection then
		LrDialogs.message('Immich Collection Sync', reason, 'info')
		return
	end

	local catalog = LrApplication.activeCatalog()
	local store = MappingStore.new(LrPrefs.prefsForPlugin(), { catalogId = Dialogs.catalogId(catalog) })
	local link = store:get(collection.localIdentifier)
	if not link then
		LrDialogs.message('Immich Collection Sync',
			'This collection is not linked. Use Library > Plug-in Extras > Immich Collection Sync: Link selected collection to album… first.',
			'info')
		return
	end

	-- Warn if the plugin's server URL has changed since this collection was linked.
	local configuredUrl = Settings.getServerUrl()
	if link.serverUrl and link.serverUrl ~= ''
		and Dialogs.normalizeServerUrl(link.serverUrl) ~= Dialogs.normalizeServerUrl(configuredUrl) then
		local proceed = LrDialogs.confirm(
			'Immich Collection Sync — Server URL changed',
			('This collection was linked on "%s", but the configured server is now "%s".\n\nContinue syncing with the current server, or cancel and re-link the collection?'):format(
				link.serverUrl, configuredUrl),
			'Continue', 'Cancel')
		if proceed ~= 'ok' then return end
	end

	local f = LrView.osFactory()

	-- Ask direction FIRST so clicking Cancel does not waste time fetching the
	-- album or indexing a large Lightroom catalog. Pre-select the last
	-- direction used for this linked collection.
	local properties = LrBinding.makePropertyTable(context)
	properties.direction = (link.lastDirection == 'lr_to_immich') and 'lr_to_immich' or 'immich_to_lr'
	local directionDialog = f:column {
		spacing = f:control_spacing(),
		bind_to_object = properties,
		f:static_text { title = ('Collection: "%s"'):format(collection:getName()), font = '<system/bold>' },
		f:static_text { title = ('Immich album: "%s"'):format(link.albumName or '') },
		f:separator { fill_horizontal = 1 },
		f:static_text { title = 'Direction', font = '<system/bold>' },
		f:radio_button {
			title = 'Immich → Lightroom  (mirror album into collection)',
			value = LrView.bind 'direction', checked_value = 'immich_to_lr',
		},
		f:radio_button {
			title = 'Lightroom → Immich  (mirror collection into album)',
			value = LrView.bind 'direction', checked_value = 'lr_to_immich',
		},
	}
	local choice = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Direction',
		contents = directionDialog,
		actionVerb = 'Analyze',
	}
	if choice ~= 'ok' then return end

	store:setLastDirection(collection.localIdentifier, properties.direction)

	Logger.info(('Starting sync (%s) for collection "%s" (id=%s) <-> album "%s" (id=%s)'):format(
		properties.direction, collection:getName(), tostring(collection.localIdentifier),
		tostring(link.albumName or ''), tostring(link.albumId)))

	return {
		collection = collection, catalog = catalog, store = store, link = link,
		direction = properties.direction,
		api = ImmichAPI.new{ serverUrl = configuredUrl, apiKey = Settings.getApiKey(), logger = Logger },
	}
end

local function sync(context, selection)
	local collection, catalog = selection.collection, selection.catalog
	local store, link = selection.store, selection.link
	local direction, api = selection.direction, selection.api
	local progress = LrProgressScope{
		title = ('Immich Collection Sync: %s'):format(collection:getName()),
		functionContext = context,
	}
	progress:setCancelable(true)

	local progressAdapter = {
		setCaption = function(s) progress:setCaption(s) end,
		setPortionComplete = function(done, total) progress:setPortionComplete(done, total) end,
		isCanceled = function() return progress:isCanceled() end,
	}

	progress:setCaption('Fetching Immich album…')
	local album, err = api:getAlbum(link.albumId)
	if progress:isCanceled() then progress:done(); return end
	if err then
		progress:done()
		Logger.error('Failed to fetch album: ' .. Errors.format(err))
		return RetryDialog.problem(context, 'Immich Collection Sync — Could not fetch album', Errors.format(err))
	end

	-- Refresh stored albumName if the album was renamed in Immich.
	local liveAlbumName = (album.albumName and album.albumName ~= '') and album.albumName or (link.albumName or '')
	if liveAlbumName ~= '' and liveAlbumName ~= link.albumName then
		store:set(collection.localIdentifier, {
			albumId = link.albumId,
			albumName = liveAlbumName,
			serverUrl = link.serverUrl ~= '' and link.serverUrl or api.serverUrl,
			linkedAt = link.linkedAt,
		})
		link.albumName = liveAlbumName
	end

	local assetById = {}
	for _, asset in ipairs(album.assets or {}) do
		if asset.id then assetById[asset.id] = asset end
	end

	progress:setCaption('Indexing Lightroom catalog…')
	local caseFold = function(p) return Paths.normalizeKey(p or '') end
	local catalogIndex, indexErr = CatalogIndex.buildFromCatalog(catalog, caseFold, progressAdapter)
	if not catalogIndex then
		progress:done()
		if indexErr ~= 'canceled' then
			Logger.error('Catalog indexing failed: ' .. tostring(indexErr))
		end
		return
	end

	progress:setCaption('Reading collection…')
	local collectionPhotos = collection:getPhotos()
	if progress:isCanceled() then progress:done(); return end

	local configuredMappings = Settings.getPathMappings()
	local pathMapper = PathMapper.new(configuredMappings)
	local downloadedPaths = store:getDownloadedAssets()

	Logger.info(('Album "%s" fetched: inline/total=%d assetCount=%s source=%s; catalog=%d; collection=%d; mappings=%d'):format(
		liveAlbumName, #(album.assets or {}), tostring(album.assetCount),
		tostring(album._assetsSource or 'unknown'), catalogIndex:size(),
		#(collectionPhotos or {}), #configuredMappings))

	progress:setCaption('Computing diff…')
	local diff, diffErr = SyncEngine.computeDiff{
		direction = direction,
		collectionPhotos = collectionPhotos,
		albumAssets = album.assets or {},
		pathMapper = pathMapper,
		catalogIndex = catalogIndex,
		fileExists = function(path) return LrFileUtils.exists(path) end,
		downloadedPaths = downloadedPaths,
		resolveRemoteAsset = direction == 'lr_to_immich'
			and function(immichPath) return api:findAssetByOriginalPath(immichPath) end
			or nil,
		progress = progressAdapter,
	}
	if not diff then
		progress:done()
		if diffErr == 'canceled' then Logger.info('Sync canceled during analysis') end
		return
	end

	Logger.info(('Diff computed: add=%d remove=%d matched=%d warnings=%d'):format(
		diff.summary.addCount, diff.summary.removeCount,
		diff.summary.matchedCount or 0, diff.summary.warningCount))

	local hasUnmappedDownloads = direction == 'immich_to_lr'
		and #(diff.warnings.unmappableImmich or {}) > 0
	local hasChanges = diff.summary.addCount > 0 or diff.summary.removeCount > 0 or hasUnmappedDownloads
	local hasDiagnostics = diff.summary.warningCount > 0
		or ((tonumber(album.assetCount) or 0) > 0 and #(album.assets or {}) == 0)

	local previewText = buildPreviewText{
		direction = direction,
		album = album,
		albumName = liveAlbumName,
		collectionName = collection:getName(),
		diff = diff,
		pathMappings = configuredMappings,
		catalogSize = catalogIndex:size(),
		logEnabled = Settings.getLogEnabled(),
	}
	progress:setCaption('Waiting for confirmation…')
	local previewChoice = presentPreviewDialog(context, previewText, hasChanges, hasDiagnostics, diff.warnings)
	if progress:isCanceled() then progress:done(); return end
	if previewChoice ~= 'apply' then progress:done(); return previewChoice end

	if hasUnmappedDownloads then
		local entries, videoCount = downloadEntriesFromWarnings(diff, assetById)
		local folder = promptDownloadFolder(context, LrView.osFactory(), #entries, videoCount)
		if folder then
			diff.toDownloadLocal = entries
			diff.downloadFolder = folder
		else
			diff.toDownloadLocal = {}
		end
	end

	progress:setCaption('Applying changes…')
	local result = SyncEngine.applyDiff(diff, {
		immichApi = api,
		albumId = link.albumId,
		collection = collection,
		fileExists = function(path) return LrFileUtils.exists(path) end,
		importPhotos = function(paths)
			return CatalogImport.importPhotos(catalog, paths, {
				yieldSafePcall = function(fn, ...) return LrTasks.pcall(fn, ...) end,
				progress = progressAdapter,
			})
		end,
		downloadAsset = function(assetId)
			return api:downloadAsset(assetId)
		end,
		saveDownloadedAsset = function(entry, bytes)
			local folder = diff.downloadFolder or Settings.getDownloadFolder()
			local okDir, dirErr = ensureDirectory(folder)
			if not okDir then
				return nil, Errors.make('download_folder_missing', dirErr)
			end
			local path = uniqueChildPath(folder, Dialogs.sanitizeFileName(entry.fileName, tostring(entry.assetId) .. '.jpg'))
			return writeBinary(path, bytes)
		end,
		onAssetDownloaded = function(assetId, localPath)
			store:setDownloadedAsset(assetId, localPath)
		end,
		withWriteAccess = function(name, fn)
			return catalog:withWriteAccessDo(name, fn, { timeout = 15 })
		end,
		yieldSafePcall = function(fn, ...)
			return LrTasks.pcall(fn, ...)
		end,
		progress = progressAdapter,
	})
	progress:done()

	Logger.info(('Sync finished: addedRemote=%d removedRemote=%d downloaded=%d imported=%d addedLocal=%d removedLocal=%d errors=%d canceled=%s'):format(
		result.addedRemote, result.removedRemote, result.downloadedLocal or 0,
		result.importedLocal or 0, result.addedLocal, result.removedLocal,
		#result.errors, tostring(result.canceled)))

	local lines = {
		('Added to Immich:     %d'):format(result.addedRemote),
		('Removed from Immich: %d'):format(result.removedRemote),
		('Downloaded:          %d'):format(result.downloadedLocal or 0),
		('Imported to LR:      %d'):format(result.importedLocal or 0),
		('Added to LR:         %d'):format(result.addedLocal),
		('Removed from LR:     %d'):format(result.removedLocal),
	}
	if result.canceled then
		table.insert(lines, '')
		table.insert(lines, 'Sync was canceled before all steps completed.')
	end
	if #result.errors > 0 then
		table.insert(lines, '')
		table.insert(lines, 'Errors:')
		for _, e in ipairs(result.errors) do
			local formatted = ('  [%s] %s'):format(e.op, Errors.format(e.err))
			Logger.error('Sync error: ' .. formatted)
			table.insert(lines, formatted)
		end
		if not result.canceled then
			table.insert(lines, '\nRetry opens a new preview of the remaining changes.')
			return RetryDialog.problem(context, 'Immich Collection Sync — Sync finished with errors', table.concat(lines, '\n'))
		end
	end
	LrDialogs.message('Immich Collection Sync — done', table.concat(lines, '\n'),
		#result.errors > 0 and 'warning' or 'info')
end

RetryDialog.run('ImmichSyncDialog', chooseSync, sync)
