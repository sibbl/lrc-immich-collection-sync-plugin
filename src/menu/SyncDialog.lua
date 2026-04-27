--[[
  Sync the currently-selected collection with its linked Immich album.

  Flow:
    1. Resolve link from MappingStore.
    2. Fetch album assets.
    3. Build a fresh CatalogIndex from the active catalog.
    4. Ask the user for a direction.
    5. Show a diff preview dialog (counts + warnings).
    6. On confirm, apply.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
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

local function extensionIndex(name)
	local idx
	for i = #name, 1, -1 do
		local c = name:sub(i, i)
		if c == '.' then idx = i; break end
		if c == '/' or c == '\\' then break end
	end
	return idx
end

local function sanitizeFileName(name, fallback)
	name = name or fallback or 'immich-asset'
	name = tostring(name):gsub('[\\/:*?"<>|]', '_')
	if name == '' then name = fallback or 'immich-asset' end
	return name
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
	for _, warning in ipairs(diff.warnings.unmappableImmich or {}) do
		local asset = assetById[warning.assetId] or {}
		local leaf = asset.originalFileName or (warning.path and LrPathUtils.leafName(warning.path))
		table.insert(entries, {
			assetId = warning.assetId,
			fileName = sanitizeFileName(leaf, warning.assetId .. '.jpg'),
			originalPath = warning.path,
		})
	end
	return entries
end

local function promptDownloadFolder(context, f, count)
	local props = LrBinding.makePropertyTable(context)
	props.folder = defaultDownloadFolder()

	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text {
			title = ('%d Immich asset%s could not be mapped to a local path.'):format(
				count, count == 1 and '' or 's'),
			font = '<system/bold>',
		},
		f:static_text {
			title = 'You can download the original files from Immich, save them to a folder, import them into the Lightroom catalog, and add them to this collection. Cancel skips downloading and applies only mapped changes.',
			width_in_chars = 72,
			height_in_lines = 4,
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
		title = 'Immich Sync — Download unmapped assets?',
		contents = contents,
		actionVerb = 'Download & import',
	}
	if result ~= 'ok' then return nil end
	if not props.folder or props.folder == '' then
		LrDialogs.message('Immich Sync', 'No download folder selected; skipping downloads.', 'warning')
		return nil
	end
	Settings.setDownloadFolder(props.folder)
	return props.folder
end

LrFunctionContext.postAsyncTaskWithContext('ImmichSyncDialog', function(context)
	if not Dialogs.requireCredentials() then return end
	local collection, reason = Dialogs.activeCollection()
	if not collection then
		LrDialogs.message('Immich Sync', reason, 'info')
		return
	end

	local store = MappingStore.new(LrPrefs.prefsForPlugin())
	local link = store:get(collection.localIdentifier)
	if not link then
		LrDialogs.message('Immich Sync',
			'This collection is not linked. Use Library > Plug-in Extras > Immich: Link selected collection… first.',
			'info')
		return
	end

	local catalog = LrApplication.activeCatalog()
	local progress = LrProgressScope{
		title = ('Immich Sync: %s'):format(collection:getName()),
		functionContext = context,
	}
	progress:setCancelable(true)

	progress:setCaption('Fetching Immich album…')
	local api = ImmichAPI.new{
		serverUrl = Settings.getServerUrl(),
		apiKey = Settings.getApiKey(),
	}
	local album, err = api:getAlbum(link.albumId)
	if err then
		progress:done()
		LrDialogs.message('Immich Sync', 'Failed to fetch album: ' .. Errors.format(err), 'critical')
		return
	end
	local assetById = {}
	for _, asset in ipairs(album.assets or {}) do
		if asset.id then assetById[asset.id] = asset end
	end

	progress:setCaption('Indexing Lightroom catalog…')
	local allPhotos = catalog:getAllPhotos()
	local caseFold = function(p) return Paths.foldForCompare(Paths.normalizeSeparators(p) or '') end
	local catalogIndex = CatalogIndex.new(allPhotos, caseFold)

	progress:setCaption('Reading collection…')
	local collectionPhotos = collection:getPhotos()

	local pathMapper = PathMapper.new(Settings.getPathMappings())

	-- Ask direction.
	progress:setCaption('Waiting for direction selection…')
	local properties = LrBinding.makePropertyTable(context)
	properties.direction = 'immich_to_lr'
	local f = LrView.osFactory()
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
		title = 'Immich Sync — Direction',
		contents = directionDialog,
		actionVerb = 'Analyze',
	}
	if choice ~= 'ok' then progress:done(); return end

	progress:setCaption('Computing diff…')
	local diff = SyncEngine.computeDiff{
		direction = properties.direction,
		collectionPhotos = collectionPhotos,
		albumAssets = album.assets or {},
		pathMapper = pathMapper,
		catalogIndex = catalogIndex,
		fileExists = function(path) return LrFileUtils.exists(path) end,
	}

	-- Preview.
	local previewLines = {}
	local function addLine(s) table.insert(previewLines, s) end
	addLine(('Direction: %s'):format(properties.direction == 'lr_to_immich'
		and 'Lightroom → Immich' or 'Immich → Lightroom'))
	addLine('')
	if properties.direction == 'lr_to_immich' then
		addLine(('Add to Immich album:    %d'):format(#diff.toAddRemote))
		addLine(('Remove from Immich album: %d'):format(#diff.toRemoveRemote))
	else
		addLine(('Import into Lightroom catalog:   %d'):format(#(diff.toImportLocal or {})))
		addLine(('Add to Lightroom collection:    %d'):format(#diff.toAddLocal + #(diff.toImportLocal or {})))
		addLine(('Remove from Lightroom collection: %d'):format(#diff.toRemoveLocal))
	end
	addLine('')
	addLine(('Warnings: %d'):format(diff.summary.warningCount))
	if properties.direction == 'immich_to_lr' and #(diff.warnings.unmappableImmich or {}) > 0 then
		addLine(('Download option after Apply: %d unmapped Immich asset%s'):format(
			#diff.warnings.unmappableImmich,
			#diff.warnings.unmappableImmich == 1 and '' or 's'))
	end
	if diff.summary.warningCount > 0 then
		for i, w in ipairs(diff.warnings.unmappableImmich) do
			if i <= 5 then addLine(('  unmapped Immich path: %s'):format(w.path)) end
		end
		if #diff.warnings.unmappableImmich > 5 then
			addLine(('  … and %d more unmapped Immich paths'):format(#diff.warnings.unmappableImmich - 5))
		end
		for i, w in ipairs(diff.warnings.missingLocal) do
			if i <= 5 then addLine(('  missing locally: %s'):format(w.localPath or w.photoPath or '?')) end
		end
		if #diff.warnings.missingLocal > 5 then
			addLine(('  … and %d more missing-local'):format(#diff.warnings.missingLocal - 5))
		end
		for i, w in ipairs(diff.warnings.unmappableLocal) do
			if i <= 5 then addLine(('  LR photo outside any mapping: %s'):format(w.photoPath)) end
		end
		if #diff.warnings.unmappableLocal > 5 then
			addLine(('  … and %d more LR-path warnings'):format(#diff.warnings.unmappableLocal - 5))
		end
	end

	progress:setCaption('Waiting for confirmation…')
	local previewChoice = LrDialogs.confirm(
		'Immich Sync — Preview',
		table.concat(previewLines, '\n'),
		'Apply', 'Cancel')
	if previewChoice ~= 'ok' then progress:done(); return end

	if properties.direction == 'immich_to_lr' and #(diff.warnings.unmappableImmich or {}) > 0 then
		local entries = downloadEntriesFromWarnings(diff, assetById)
		local folder = promptDownloadFolder(context, f, #entries)
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
			return CatalogImport.importPhotos(catalog, paths)
		end,
		downloadAsset = function(assetId)
			return api:downloadAsset(assetId)
		end,
		saveDownloadedAsset = function(entry, bytes)
			local folder = diff.downloadFolder or Settings.getDownloadFolder()
			if folder == '' then
				return nil, Errors.make('download_folder_missing', 'No download folder selected')
			end
			local path = uniqueChildPath(folder, sanitizeFileName(entry.fileName, entry.assetId .. '.jpg'))
			return writeBinary(path, bytes)
		end,
		withWriteAccess = function(name, fn)
			catalog:withWriteAccessDo(name, fn)
		end,
		progress = {
			setCaption = function(s) progress:setCaption(s) end,
			isCanceled = function() return progress:isCanceled() end,
		},
	})
	progress:done()

	local lines = {
		('Added to Immich:     %d'):format(result.addedRemote),
		('Removed from Immich: %d'):format(result.removedRemote),
		('Downloaded:         %d'):format(result.downloadedLocal or 0),
		('Imported to LR:      %d'):format(result.importedLocal or 0),
		('Added to LR:         %d'):format(result.addedLocal),
		('Removed from LR:     %d'):format(result.removedLocal),
	}
	if #result.errors > 0 then
		table.insert(lines, '')
		table.insert(lines, 'Errors:')
		for _, e in ipairs(result.errors) do
			table.insert(lines, ('  [%s] %s'):format(e.op, Errors.format(e.err)))
		end
	end
	LrDialogs.message('Immich Sync — done', table.concat(lines, '\n'), 'info')
end)
