--[[
  Two-way metadata sync between selected Lightroom photos (or the active
  collection's photos) and their matching Immich assets.

  Matches photos via configured PathMappings -> POST /api/search/metadata ->
  GET /api/assets/{id}, shows a preview of exact per-field changes before
  applying, and runs pure diff/apply logic in MetadataEngine.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrProgressScope = import 'LrProgressScope'

local Settings = require 'Settings'
local ImmichAPI = require 'ImmichAPI'
local PathMapper = require 'PathMapper'
local MetadataEngine = require 'MetadataEngine'
local Dialogs = require 'Dialogs'
local Errors = require 'Errors'
local Logger = require 'Logger'

local function buildPreviewText(direction, totalPhotos, matchedCount, unmappedCount, notFoundCount, lookupErrors, diff)
	local lines = {}
	local function add(s) table.insert(lines, s) end
	local fc = diff.summary.fieldCounts or {}

	add(('Direction: %s'):format(direction == 'lr_to_immich'
		and 'Lightroom → Immich' or 'Immich → Lightroom'))
	add(('Photos checked: %d  (matched on Immich: %d, unmapped: %d, not found: %d)'):format(
		totalPhotos, matchedCount, unmappedCount, notFoundCount))
	add('')
	add(('Photos to update:  %d'):format(diff.summary.updateCount))
	add(('Already up to date: %d'):format(diff.summary.unchangedCount))
	add('')
	add('Planned field updates:')
	add(('  • Ratings:            %d'):format(fc.rating or 0))
	add(('  • Favorites / Flags:  %d'):format(fc.favorite or 0))
	add(('  • Captions:           %d'):format(fc.caption or 0))
	add(('  • GPS coordinates:    %d'):format(fc.gps or 0))
	add(('  • Keywords / Tags:    %d'):format(fc.keywords or 0))

	if #lookupErrors > 0 then
		add('')
		add(('Lookup errors (%d):'):format(#lookupErrors))
		for i, msg in ipairs(lookupErrors) do
			if i <= 10 then add('  ' .. msg) end
		end
		if #lookupErrors > 10 then
			add(('  … and %d more'):format(#lookupErrors - 10))
		end
	end

	return table.concat(lines, '\n')
end

LrFunctionContext.postAsyncTaskWithContext('ImmichMetadataSync', function(context)
	if not Dialogs.requireCredentials() then return end

	local configuredMappings = Settings.getPathMappings()
	if #configuredMappings == 0 then
		LrDialogs.message('Immich Collection Sync',
			'No path mappings configured yet. Configure them in File > Plug-in Manager… > Immich Collection Sync first.',
			'warning')
		return
	end

	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos() or {}
	local scopeLabel = ('%d selected photo%s'):format(#photos, #photos == 1 and '' or 's')
	if #photos == 0 then
		local collection = Dialogs.activeCollection()
		if collection then
			photos = collection:getPhotos() or {}
			scopeLabel = ('%d photo%s in collection "%s"'):format(
				#photos, #photos == 1 and '' or 's', collection:getName())
		end
	end
	if #photos == 0 then
		LrDialogs.message('Immich Collection Sync — Sync metadata',
			'Select one or more photos (or a non-empty regular collection) first.', 'info')
		return
	end

	local saved = Settings.getMetadataSyncPrefs()
	local props = LrBinding.makePropertyTable(context)
	props.direction = saved.direction
	props.rating = saved.rating
	props.favorite = saved.favorite
	props.caption = saved.caption
	props.gps = saved.gps
	props.keywords = saved.keywords
	props.overwrite = saved.overwrite

	local f = LrView.osFactory()
	local optionsDialog = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text { title = 'Scope: ' .. scopeLabel, font = '<system/bold>' },
		f:separator { fill_horizontal = 1 },
		f:static_text { title = 'Direction', font = '<system/bold>' },
		f:radio_button {
			title = 'Immich → Lightroom  (pull Immich metadata into Lightroom)',
			value = LrView.bind 'direction', checked_value = 'immich_to_lr',
		},
		f:radio_button {
			title = 'Lightroom → Immich  (push Lightroom metadata to Immich)',
			value = LrView.bind 'direction', checked_value = 'lr_to_immich',
		},
		f:separator { fill_horizontal = 1 },
		f:static_text { title = 'Fields to sync', font = '<system/bold>' },
		f:checkbox { title = 'Star ratings (1–5)', value = LrView.bind 'rating' },
		f:checkbox { title = 'Favorites ↔ Pick flag', value = LrView.bind 'favorite' },
		f:checkbox { title = 'Captions ↔ Immich description', value = LrView.bind 'caption' },
		f:checkbox { title = 'GPS coordinates', value = LrView.bind 'gps' },
		f:checkbox { title = 'Keywords ↔ Immich tags (+ People → People/<name> on pull, additive)', value = LrView.bind 'keywords' },
		f:separator { fill_horizontal = 1 },
		f:checkbox {
			title = 'Overwrite existing non-empty values (otherwise only fill empty fields)',
			value = LrView.bind 'overwrite',
		},
	}

	local choice = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Sync metadata',
		contents = optionsDialog,
		actionVerb = 'Analyze',
	}
	if choice ~= 'ok' then return end

	if not (props.rating or props.favorite or props.caption or props.gps or props.keywords) then
		LrDialogs.message('Immich Collection Sync', 'Select at least one metadata field to sync.', 'info')
		return
	end

	Settings.setMetadataSyncPrefs({
		direction = props.direction,
		rating = props.rating,
		favorite = props.favorite,
		caption = props.caption,
		gps = props.gps,
		keywords = props.keywords,
		overwrite = props.overwrite,
	})

	local progress = LrProgressScope{
		title = 'Immich Metadata Sync',
		functionContext = context,
	}
	progress:setCancelable(true)
	local progressAdapter = {
		setCaption = function(s) progress:setCaption(s) end,
		setPortionComplete = function(done, total) progress:setPortionComplete(done, total) end,
		isCanceled = function() return progress:isCanceled() end,
	}

	local api = ImmichAPI.new{
		serverUrl = Settings.getServerUrl(),
		apiKey = Settings.getApiKey(),
		logger = Logger,
	}
	local pathMapper = PathMapper.new(configuredMappings)

	Logger.info(('Starting metadata sync (%s) for %d photos'):format(props.direction, #photos))

	local matchedPairs = {}
	local unmappedCount = 0
	local notFoundCount = 0
	local lookupErrors = {}
	local total = #photos

	for i, photo in ipairs(photos) do
		if progress:isCanceled() then
			progress:done()
			Logger.info('Metadata sync canceled during lookup')
			return
		end
		progress:setCaption(('Looking up Immich metadata (%d/%d)…'):format(i, total))
		progress:setPortionComplete(i - 1, total)

		local localPath = photo:getRawMetadata('path')
		local immichPath = pathMapper:localToImmich(localPath)
		if not immichPath then
			unmappedCount = unmappedCount + 1
		else
			local found, findErr = api:findAssetByOriginalPath(immichPath)
			if findErr then
				table.insert(lookupErrors, tostring(immichPath) .. ': ' .. Errors.format(findErr))
			elseif not found or not found.id then
				notFoundCount = notFoundCount + 1
			else
				local fullAsset, infoErr = api:getAsset(found.id)
				if infoErr then
					table.insert(lookupErrors, tostring(immichPath) .. ': ' .. Errors.format(infoErr))
				elseif fullAsset and not fullAsset.isTrashed then
					table.insert(matchedPairs, { photo = photo, asset = fullAsset })
				else
					notFoundCount = notFoundCount + 1
				end
			end
		end

		progress:setPortionComplete(i, total)
	end

	local diff = MetadataEngine.computeDiff{
		direction = props.direction,
		pairs = matchedPairs,
		fields = {
			rating = props.rating,
			favorite = props.favorite,
			caption = props.caption,
			gps = props.gps,
			keywords = props.keywords,
		},
		overwrite = props.overwrite,
	}

	local previewText = buildPreviewText(
		props.direction, total, #matchedPairs, unmappedCount, notFoundCount, lookupErrors, diff)
	local previewProps = LrBinding.makePropertyTable(context)
	previewProps.preview = previewText

	local previewContents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = previewProps,
		f:static_text {
			title = diff.summary.updateCount > 0
				and 'Review planned metadata changes before applying.'
				or 'No metadata changes to apply.',
			font = '<system/bold>',
		},
		f:edit_field {
			value = LrView.bind 'preview',
			width_in_chars = 80,
			height_in_lines = 16,
			enabled = true,
		},
	}

	progress:setCaption('Waiting for confirmation…')
	if diff.summary.updateCount == 0 then
		LrDialogs.presentModalDialog{
			title = 'Immich Collection Sync — Metadata already up to date',
			contents = previewContents,
			actionVerb = 'Close',
			cancelVerb = '< exclude >',
		}
		progress:done()
		return
	end

	local confirm = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Metadata preview',
		contents = previewContents,
		actionVerb = 'Apply',
		cancelVerb = 'Cancel',
	}
	if confirm ~= 'ok' then progress:done(); return end

	local result = MetadataEngine.applyDiff(diff, {
		immichApi = api,
		catalog = catalog,
		withWriteAccess = function(name, fn)
			return catalog:withWriteAccessDo(name, fn, { timeout = 30 })
		end,
		yieldSafePcall = function(fn, ...) return LrTasks.pcall(fn, ...) end,
		progress = progressAdapter,
	})
	progress:done()

	Logger.info(('Metadata sync finished: updatedLocal=%d updatedRemote=%d errors=%d canceled=%s'):format(
		result.updatedLocal, result.updatedRemote, #result.errors, tostring(result.canceled)))

	local summaryLines = {
		('Updated in Lightroom: %d'):format(result.updatedLocal),
		('Updated in Immich:    %d'):format(result.updatedRemote),
	}
	if result.canceled then
		table.insert(summaryLines, '')
		table.insert(summaryLines, 'Metadata sync was canceled before finishing.')
	end
	if #result.errors > 0 then
		table.insert(summaryLines, '')
		table.insert(summaryLines, 'Errors:')
		for _, e in ipairs(result.errors) do
			table.insert(summaryLines, ('  [%s] %s'):format(e.op, Errors.format(e.err)))
		end
	end

	LrDialogs.message('Immich Collection Sync — Metadata sync done',
		table.concat(summaryLines, '\n'),
		#result.errors > 0 and 'warning' or 'info')
end)
