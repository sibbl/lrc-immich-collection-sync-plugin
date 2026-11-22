--[[
  Run an Immich Smart/CLIP search from Lightroom Classic and place all locally
  matched catalog photos into a Lightroom collection under "Immich search
  results".

  Matches Immich assets via configured PathMappings + CatalogIndex (plus any
  previously downloaded unmapped assets), so it works across your entire
  mapped NAS/local library without requiring Lightroom uploads.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrProgressScope = import 'LrProgressScope'
local LrPrefs = import 'LrPrefs'

local Settings = require 'Settings'
local MappingStore = require 'MappingStore'
local ImmichAPI = require 'ImmichAPI'
local PathMapper = require 'PathMapper'
local CatalogIndex = require 'CatalogIndex'
local SmartSearch = require 'SmartSearch'
local Paths = require 'Paths'
local Dialogs = require 'Dialogs'
local Errors = require 'Errors'
local Logger = require 'Logger'

LrFunctionContext.postAsyncTaskWithContext('ImmichSmartSearch', function(context)
	if not Dialogs.requireCredentials() then return end

	local props = LrBinding.makePropertyTable(context)
	props.query = ''
	props.maxResults = 250

	local f = LrView.osFactory()
	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text {
			title = 'Search your Immich library with AI/CLIP Smart Search and collect matching Lightroom photos.',
			width_in_chars = 68,
			height_in_lines = 2,
		},
		f:row {
			f:static_text { title = 'Search query', width = 100 },
			f:edit_field {
				value = LrView.bind 'query',
				width_in_chars = 44,
				immediate = true,
				placeholder_string = 'e.g. sunset over mountains, red bicycle',
			},
		},
		f:row {
			f:static_text { title = 'Max results', width = 100 },
			f:popup_menu {
				value = LrView.bind 'maxResults',
				items = {
					{ title = '100', value = 100 },
					{ title = '250', value = 250 },
					{ title = '500', value = 500 },
					{ title = '1000', value = 1000 },
				},
			},
		},
	}

	local choice = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Smart search',
		contents = contents,
		actionVerb = 'Search',
	}
	if choice ~= 'ok' then return end

	local query = (props.query or ''):gsub('^%s+', ''):gsub('%s+$', '')
	if query == '' then
		LrDialogs.message('Immich Collection Sync', 'Please enter a search query.', 'info')
		return
	end

	local configuredMappings = Settings.getPathMappings()
	if #configuredMappings == 0 then
		LrDialogs.message('Immich Collection Sync',
			'No path mappings configured yet. Configure them in File > Plug-in Manager… > Immich Collection Sync first.',
			'warning')
		return
	end

	local progress = LrProgressScope{
		title = ('Immich Smart Search: %s'):format(query),
		functionContext = context,
	}
	progress:setCancelable(true)
	local progressAdapter = {
		setCaption = function(s) progress:setCaption(s) end,
		setPortionComplete = function(done, total) progress:setPortionComplete(done, total) end,
		isCanceled = function() return progress:isCanceled() end,
	}

	Logger.info(('Running Immich smart search: query="%s" maxResults=%d'):format(query, props.maxResults))
	progress:setCaption(('Searching Immich for "%s"…'):format(query))

	local api = ImmichAPI.new{
		serverUrl = Settings.getServerUrl(),
		apiKey = Settings.getApiKey(),
		logger = Logger,
	}
	local searchAssets, err = api:searchSmart(query, { maxResults = props.maxResults })
	if err then
		progress:done()
		Logger.error('Smart search failed: ' .. Errors.format(err))
		LrDialogs.message('Immich Collection Sync — Smart search failed', Errors.format(err), 'critical')
		return
	end
	if progress:isCanceled() then progress:done(); return end
	if #searchAssets == 0 then
		progress:done()
		LrDialogs.message('Immich Collection Sync — No results',
			('No photos in Immich matched "%s".'):format(query), 'info')
		return
	end

	progress:setCaption('Indexing Lightroom catalog…')
	local catalog = LrApplication.activeCatalog()
	local caseFold = function(p) return Paths.normalizeKey(p or '') end
	local catalogIndex, idxErr = CatalogIndex.buildFromCatalog(catalog, caseFold, progressAdapter)
	if not catalogIndex then
		progress:done()
		if idxErr ~= 'canceled' then Logger.error('Catalog indexing failed: ' .. tostring(idxErr)) end
		return
	end

	local store = MappingStore.new(LrPrefs.prefsForPlugin(), { catalogId = Dialogs.catalogId(catalog) })
	local pathMapper = PathMapper.new(configuredMappings)
	local match = SmartSearch.matchResults(searchAssets, pathMapper, catalogIndex, store:getDownloadedAssets())

	Logger.info(('Smart search "%s": total=%d matched=%d unmapped=%d notInCatalog=%d'):format(
		query, match.totalResults, #match.matchedPhotos, match.unmappedCount, match.notInCatalogCount))

	if #match.matchedPhotos == 0 then
		progress:done()
		LrDialogs.message('Immich Collection Sync — No catalog matches',
			('Immich returned %d result%s for "%s", but none matched photos in this Lightroom catalog.\n\n'
				.. '• Unmapped Immich paths: %d\n'
				.. '• Mapped, but not imported in Lightroom: %d'):format(
				match.totalResults, match.totalResults == 1 and '' or 's', query,
				match.unmappedCount, match.notInCatalogCount),
			'info')
		return
	end

	local collectionName = SmartSearch.buildCollectionName(query)
	progress:setCaption(('Updating collection "%s"…'):format(collectionName))

	local set, collection
	local okSet, statusSet = LrTasks.pcall(function()
		return catalog:withWriteAccessDo('Immich search collection set', function()
			set = catalog:createCollectionSet('Immich search results', nil, true)
		end, { timeout = 30 })
	end)
	local okCol, statusCol = LrTasks.pcall(function()
		return catalog:withWriteAccessDo('Immich search: ' .. collectionName, function()
			collection = catalog:createCollection(collectionName, set, true)
		end, { timeout = 30 })
	end)
	local okAdd, statusAdd = LrTasks.pcall(function()
		return catalog:withWriteAccessDo('Immich search results: ' .. collectionName, function()
			if collection then
				local existing = collection:getPhotos()
				if existing and #existing > 0 then
					collection:removePhotos(existing)
				end
				collection:addPhotos(match.matchedPhotos)
			end
		end, { timeout = 30 })
	end)
	progress:done()

	if not okSet or not okCol or not okAdd or not collection
		or statusSet == 'aborted' or statusCol == 'aborted' or statusAdd == 'aborted' then
		Logger.error('Smart search collection creation failed')
		LrDialogs.message('Immich Collection Sync — Smart search',
			'Matched photos, but Lightroom could not create or update the search results collection (catalog busy). Please retry.',
			'warning')
		return
	end

	catalog:setActiveSources({ collection })
	catalog:setSelectedPhotos(match.matchedPhotos[1], match.matchedPhotos)

	LrDialogs.showBezel(('%d photo%s → "%s"'):format(
		#match.matchedPhotos, #match.matchedPhotos == 1 and '' or 's', collectionName))
end)
