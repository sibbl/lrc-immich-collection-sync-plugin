--[[
  Unlink the currently-selected collection from its Immich album.
]]

local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'

local MappingStore = require 'MappingStore'
local Dialogs = require 'Dialogs'

local collection, reason = Dialogs.activeCollection()
if not collection then
	LrDialogs.message('Immich Collection Sync', reason, 'info')
	return
end

local store = MappingStore.new(LrPrefs.prefsForPlugin())
local info = store:get(collection.localIdentifier)
if not info then
	LrDialogs.message('Immich Collection Sync',
		('"%s" is not linked to any Immich album.'):format(collection:getName()), 'info')
	return
end

local choice = LrDialogs.confirm(
	'Immich Collection Sync — Unlink',
	('Unlink "%s" from Immich Collection Sync album "%s"? The collection and album are left unchanged; only the link is removed.'):format(
		collection:getName(), info.albumName or ''),
	'Unlink', 'Cancel')
if choice == 'ok' then
	store:remove(collection.localIdentifier)
	LrDialogs.message('Immich Collection Sync', 'Link removed.', 'info')
end
