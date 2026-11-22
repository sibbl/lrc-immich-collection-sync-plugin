--[[
  Link selected Lightroom collection to an Immich album.

  Menu-item entry point. The presence of this file in Info.lua's
  LrLibraryMenuItems causes Lightroom to execute it when the user picks the
  menu entry. We run the interactive work in an async task so the UI stays
  responsive.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrPrefs = import 'LrPrefs'

local Settings = require 'Settings'
local MappingStore = require 'MappingStore'
local ImmichAPI = require 'ImmichAPI'
local Dialogs = require 'Dialogs'
local Errors = require 'Errors'
local Logger = require 'Logger'

LrFunctionContext.postAsyncTaskWithContext('ImmichLinkCollection', function(context)
	if not Dialogs.requireCredentials() then return end
	local collection, reason = Dialogs.activeCollection()
	if not collection then
		LrDialogs.message('Immich Collection Sync', reason, 'info')
		return
	end

	local api = ImmichAPI.new{
		serverUrl = Settings.getServerUrl(),
		apiKey = Settings.getApiKey(),
		logger = Logger,
	}
	local albums, err = api:listAlbums()
	if err then
		Logger.error('Failed to list albums: ' .. Errors.format(err))
		LrDialogs.message('Immich Collection Sync — could not fetch albums', Errors.format(err), 'critical')
		return
	end
	if #albums == 0 then
		LrDialogs.message('Immich Collection Sync', 'No albums found on the Immich server.', 'info')
		return
	end

	table.sort(albums, function(a, b)
		return (a.albumName or ''):lower() < (b.albumName or ''):lower()
	end)

	local items = {}
	for _, a in ipairs(albums) do
		local suffix = a.shared and ', shared' or ''
		table.insert(items, {
			title = ('%s  (%d assets%s)'):format(a.albumName or '(unnamed)', a.assetCount or 0, suffix),
			value = a.id,
		})
	end

	local catalog = LrApplication.activeCatalog()
	local properties = LrBinding.makePropertyTable(context)
	local store = MappingStore.new(LrPrefs.prefsForPlugin(), { catalogId = Dialogs.catalogId(catalog) })
	local existing = store:get(collection.localIdentifier)
	properties.selectedAlbumId = existing and existing.albumId or items[1].value

	local f = LrView.osFactory()
	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = properties,
		f:static_text {
			title = ('Link collection: "%s"'):format(collection:getName()),
			font = '<system/bold>',
		},
		f:static_text {
			title = 'Pick an Immich album (includes owned and shared albums). The link is stored per-collection and can be changed later.',
			width_in_chars = 60,
			height_in_lines = 2,
		},
		f:popup_menu {
			value = LrView.bind 'selectedAlbumId',
			items = items,
			width_in_chars = 50,
		},
	}

	local result = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Link collection',
		contents = contents,
		actionVerb = 'Link',
	}

	if result ~= 'ok' then return end

	local chosen
	for _, a in ipairs(albums) do
		if a.id == properties.selectedAlbumId then chosen = a; break end
	end
	if not chosen then return end

	store:set(collection.localIdentifier, {
		albumId = chosen.id,
		albumName = chosen.albumName,
		serverUrl = Settings.getServerUrl(),
	})

	Logger.info(('Linked collection "%s" (id=%s) to Immich album "%s" (id=%s)'):format(
		collection:getName(), tostring(collection.localIdentifier),
		tostring(chosen.albumName or ''), tostring(chosen.id)))

	LrDialogs.message(
		'Immich Collection Sync',
		('Linked "%s" to Immich album "%s".\nUse Library > Plug-in Extras > Immich Collection Sync: Sync… to sync.'):format(
			collection:getName(), chosen.albumName or ''),
		'info')
end)
