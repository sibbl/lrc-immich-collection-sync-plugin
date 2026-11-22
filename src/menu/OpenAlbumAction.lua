--[[
  Open the linked Immich album for the currently-selected Lightroom collection
  in the user's default web browser.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrPrefs = import 'LrPrefs'

local Settings = require 'Settings'
local MappingStore = require 'MappingStore'
local ImmichAPI = require 'ImmichAPI'
local Dialogs = require 'Dialogs'
local Logger = require 'Logger'

LrFunctionContext.postAsyncTaskWithContext('ImmichOpenAlbum', function()
	if not Dialogs.requireCredentials() then return end
	local collection, reason = Dialogs.activeCollection()
	if not collection then
		LrDialogs.message('Immich Collection Sync', reason, 'info')
		return
	end

	local catalog = LrApplication.activeCatalog()
	local store = MappingStore.new(LrPrefs.prefsForPlugin(), { catalogId = Dialogs.catalogId(catalog) })
	local link = store:get(collection.localIdentifier)
	if not link or not link.albumId then
		LrDialogs.message('Immich Collection Sync',
			'This collection is not linked. Use Library > Plug-in Extras > Immich Collection Sync: Link selected collection to album… first.',
			'info')
		return
	end

	local serverUrl = (link.serverUrl and link.serverUrl ~= '') and link.serverUrl or Settings.getServerUrl()
	local api = ImmichAPI.new{ serverUrl = serverUrl, apiKey = Settings.getApiKey() }
	local url = api:albumUrl(link.albumId)
	if not url then
		LrDialogs.message('Immich Collection Sync', 'Could not build album URL — check Server URL in Plug-in Manager.', 'warning')
		return
	end

	Logger.info('Opening Immich album in browser: ' .. url)
	-- LrHttp.openUrlInBrowser is the SDK-standard cross-platform browser launcher.
	LrHttp.openUrlInBrowser(url)
end)
