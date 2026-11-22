--[[
  Immich Collection Sync — Lightroom Classic plugin manifest.

  This plugin provides bidirectional membership sync between an Immich album
  and a Lightroom Classic collection. Normally both sides reference the same
  physical files on disk through user-configured path-prefix mappings; an
  optional confirmation-gated download fallback is available for unmapped
  assets during Immich → Lightroom sync.

  Menu-driven (no Publish Service), because the Lightroom Publish SDK does
  not fire callbacks when a user drags photos in/out of a published
  collection. See docs/lightroom-sdk-notes.md for sources.
]]

return {

	LrSdkVersion = 3.0,
	LrSdkMinimumVersion = 3.0,

	LrToolkitIdentifier = 'de.sibbl.lrc-immich-collection-sync-plugin',
	LrPluginName = 'Immich Collection Sync',

	LrInitPlugin = 'Init.lua',
	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	-- Single declaration of LrLibraryMenuItems (array). Declaring it twice
	-- in the old plugin silently dropped the first declaration.
	LrLibraryMenuItems = {
		{
			title = 'Immich Collection Sync: Link selected collection to album…',
			file = 'menu/LinkCollectionDialog.lua',
		},
		{
			title = 'Immich Collection Sync: Unlink selected collection',
			file = 'menu/UnlinkAction.lua',
		},
		{
			title = 'Immich Collection Sync: Sync…',
			file = 'menu/SyncDialog.lua',
		},
	},

	LrPluginInfoURL = 'https://github.com/sibbl/lrc-immich-collection-sync-plugin',

	VERSION = { major = 4, minor = 0, revision = 0, build = 0 },
}
