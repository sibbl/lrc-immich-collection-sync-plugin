--[[
  Create a public Immich shared link for the linked album of the currently-
  selected Lightroom collection.
]]

local LrApplication = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrHttp = import 'LrHttp'
local LrPrefs = import 'LrPrefs'

local Settings = require 'Settings'
local MappingStore = require 'MappingStore'
local ImmichAPI = require 'ImmichAPI'
local Dialogs = require 'Dialogs'
local Errors = require 'Errors'
local Logger = require 'Logger'

local function expiresIsoFromDays(days)
	if not days or days <= 0 then return nil end
	local now = os.time()
	return os.date('!%Y-%m-%dT%H:%M:%SZ', now + days * 86400)
end

LrFunctionContext.postAsyncTaskWithContext('ImmichShareAlbum', function(context)
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

	local props = LrBinding.makePropertyTable(context)
	props.allowDownload = true
	props.showMetadata = true
	props.allowUpload = false
	props.expiryDays = 0
	props.password = ''
	props.description = ''

	local f = LrView.osFactory()
	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text {
			title = ('Create Immich share link for album "%s"'):format(link.albumName or link.albumId),
			font = '<system/bold>',
		},
		f:checkbox { title = 'Allow downloads', value = LrView.bind 'allowDownload' },
		f:checkbox { title = 'Show photo metadata (EXIF)', value = LrView.bind 'showMetadata' },
		f:checkbox { title = 'Allow guests to upload', value = LrView.bind 'allowUpload' },
		f:row {
			f:static_text { title = 'Expires after', width = 110 },
			f:popup_menu {
				value = LrView.bind 'expiryDays',
				items = {
					{ title = 'Never', value = 0 },
					{ title = '24 hours', value = 1 },
					{ title = '7 days', value = 7 },
					{ title = '30 days', value = 30 },
				},
			},
		},
		f:row {
			f:static_text { title = 'Password (optional)', width = 110 },
			f:password_field { value = LrView.bind 'password', width_in_chars = 30, immediate = true },
		},
		f:row {
			f:static_text { title = 'Description (optional)', width = 110 },
			f:edit_field { value = LrView.bind 'description', width_in_chars = 30, immediate = true },
		},
	}

	local choice = LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Create album share link',
		contents = contents,
		actionVerb = 'Create link',
	}
	if choice ~= 'ok' then return end

	local api = ImmichAPI.new{
		serverUrl = Settings.getServerUrl(),
		apiKey = Settings.getApiKey(),
		logger = Logger,
	}
	local created, err = api:createAlbumSharedLink(link.albumId, {
		allowDownload = props.allowDownload,
		showMetadata = props.showMetadata,
		allowUpload = props.allowUpload,
		password = props.password,
		expiresAt = expiresIsoFromDays(props.expiryDays),
		description = props.description,
	})
	if err then
		Logger.error('Failed to create album share link: ' .. Errors.format(err))
		LrDialogs.message('Immich Collection Sync — Share link failed',
			'Could not create share link: ' .. Errors.format(err)
				.. '\n\nEnsure your Immich API key includes the sharedLink.create permission.',
			'critical')
		return
	end

	Logger.info('Created Immich album share link: ' .. created.url)

	local resultProps = LrBinding.makePropertyTable(context)
	resultProps.url = created.url
	local resultDialog = f:column {
		spacing = f:control_spacing(),
		bind_to_object = resultProps,
		f:static_text {
			title = ('Share link created for "%s":'):format(link.albumName or link.albumId),
			font = '<system/bold>',
		},
		f:edit_field {
			value = LrView.bind 'url',
			width_in_chars = 58,
			enabled = true,
		},
		f:push_button {
			title = 'Open in browser',
			action = function() LrHttp.openUrlInBrowser(created.url) end,
		},
	}

	LrDialogs.presentModalDialog{
		title = 'Immich Collection Sync — Share link ready',
		contents = resultDialog,
		actionVerb = 'Done',
		cancelVerb = '< exclude >',
	}
end)
