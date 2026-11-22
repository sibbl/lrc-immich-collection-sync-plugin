--[[
  Unlink the currently-selected collection from its Immich album.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'

local MappingStore = require 'MappingStore'
local Dialogs = require 'Dialogs'
local Logger = require 'Logger'

LrFunctionContext.postAsyncTaskWithContext('ImmichUnlinkCollection', function()
	local collection, reason = Dialogs.activeCollection()
	if not collection then
		LrDialogs.message('Immich Collection Sync', reason, 'info')
		return
	end

	local catalog = LrApplication.activeCatalog()
	local store = MappingStore.new(LrPrefs.prefsForPlugin(), { catalogId = Dialogs.catalogId(catalog) })
	local info = store:get(collection.localIdentifier)
	if not info then
		LrDialogs.message('Immich Collection Sync',
			('"%s" is not linked to any Immich album.'):format(collection:getName()), 'info')
		return
	end

	local choice = LrDialogs.confirm(
		'Immich Collection Sync — Unlink',
		('Unlink "%s" from Immich album "%s"? The collection and album are left unchanged; only the link is removed.'):format(
			collection:getName(), info.albumName or ''),
		'Unlink', 'Cancel')
	if choice == 'ok' then
		store:remove(collection.localIdentifier)
		Logger.info(('Unlinked collection "%s" (id=%s) from Immich album "%s"'):format(
			collection:getName(), tostring(collection.localIdentifier), tostring(info.albumName or '')))
		LrDialogs.message('Immich Collection Sync', 'Link removed.', 'info')
	end
end)
