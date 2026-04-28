--[[
  PluginInfoProvider — Plugin Manager settings UI.

  Shows server URL, API key, "Test connection" button, and chooser-based path
	mappings (Immich prefix <-> Local prefix) with a read-only summary in the
	Plugin Manager. No per-preset settings
  because this plugin registers no Export/Publish services.
]]

local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrShell = import 'LrShell'

local Settings = require 'Settings'
local ImmichAPI = require 'ImmichAPI'
local Logger = require 'Logger'
local Errors = require 'Errors'
local PathMappingChoices = require 'PathMappingChoices'

local M = {}

local function updateMappingSummary(propertyTable, mappings)
	propertyTable.mappingSummary = PathMappingChoices.summarizeMappings(mappings)
end

-- Modal dialog: shows each Immich library and its importPaths with an
-- browse-only local-folder picker. On OK we replace the persisted pathMappings
-- with the chosen rows. Must be invoked
-- inside an LrFunctionContext so the property table has an owner.
local function presentLibraryMappingDialog(context, f, libraries, currentMappings, dialogNotice)
	local model = PathMappingChoices.buildRows(libraries, currentMappings)
	local rows = model.rows
	local props = LrBinding.makePropertyTable(context)
	for i, row in ipairs(rows) do
		row.key = 'row_' .. i .. '_local'
		row.displayKey = 'row_' .. i .. '_display'
		props[row.key] = row.local_ or ''
		props[row.displayKey] = props[row.key] ~= '' and props[row.key] or '(not selected)'
	end

	if #rows == 0 then
		LrDialogs.message('No libraries found',
			'No path-mappable Immich roots are available yet. Check the server settings or try again after Immich reports libraries.', 'info')
		return nil
	end

	local viewRows = {
		f:row {
			f:static_text { title = 'Library', width_in_chars = 18, font = '<system/bold>' },
			f:static_text { title = 'Immich import path', width_in_chars = 38, font = '<system/bold>' },
			f:static_text { title = 'Selected local folder', width_in_chars = 38, font = '<system/bold>' },
		},
	}
	for _, r in ipairs(rows) do
		local chooseFn = function()
			local result = LrDialogs.runOpenPanel{
				title = 'Choose local folder for ' .. (r.importPath or r.name or ''),
				canChooseFiles = false,
				canChooseDirectories = true,
				canCreateDirectories = true,
				allowsMultipleSelection = false,
			}
			if result and result[1] then
				props[r.key] = result[1]
				props[r.displayKey] = result[1]
			end
		end
		local clearFn = function()
			props[r.key] = ''
			props[r.displayKey] = '(not selected)'
		end
		table.insert(viewRows, f:row {
			f:static_text { title = r.name or '?', width_in_chars = 18 },
			f:static_text {
				title = r.importPath or '(no import path reported)',
				width_in_chars = 38,
			},
			f:static_text {
				title = LrView.bind { key = r.displayKey, bind_to_object = props },
				width_in_chars = 32,
				height_in_lines = 2,
				truncation = 'middle',
			},
			f:push_button {
				title = 'Choose…',
				enabled = r.importPath ~= nil,
				action = chooseFn,
			},
			f:push_button {
				title = 'Clear',
				enabled = r.importPath ~= nil,
				action = clearFn,
			},
		})
	end

	local infoRows = {
		f:static_text {
			title = ('Found %d external librar%s. Also showing common Immich uploaded-assets roots and any saved mappings. ' ..
				'Choose the local folder Lightroom sees for each Immich path.'):format(
				model.libraryCount, model.libraryCount == 1 and 'y' or 'ies'),
			width_in_chars = 100,
			height_in_lines = 3,
		},
		f:static_text {
			title = 'Tip: one /data/library/ mapping usually covers all uploaded user libraries and storage labels. Add per-user rows only as longer-prefix overrides when users are stored on different host paths.',
			width_in_chars = 100,
			height_in_lines = 2,
		},
	}
	if model.librariesWithoutImportPaths > 0 then
		table.insert(infoRows, f:static_text {
			title = ('Immich reported %d librar%s without import paths; those cannot be mapped until Immich exposes their paths.'):format(
				model.librariesWithoutImportPaths,
				model.librariesWithoutImportPaths == 1 and 'y' or 'ies'),
			width_in_chars = 100,
			height_in_lines = 2,
		})
	end
	if dialogNotice and dialogNotice ~= '' then
		table.insert(infoRows, f:static_text {
			title = dialogNotice,
			width_in_chars = 100,
			height_in_lines = 3,
		})
	end

	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		unpack(infoRows),
		unpack(viewRows),
	}

	local ok = LrDialogs.presentModalDialog{
		title = 'Choose path mappings',
		contents = contents,
		actionVerb = 'Save mappings',
	}
	if ok ~= 'ok' then return nil end
	return PathMappingChoices.rowsToMappings(rows, function(row) return props[row.key] end)
end

function M.sectionsForTopOfDialog(f, propertyTable)
	-- Seed propertyTable from persisted settings.
	propertyTable.serverUrl = Settings.getServerUrl()
	propertyTable.apiKey = Settings.getApiKey()
	propertyTable.logEnabled = Settings.getLogEnabled()
	propertyTable.connectionStatus = ''
	updateMappingSummary(propertyTable, Settings.getPathMappings())

	-- Persist on any change.
	propertyTable:addObserver('serverUrl', function() Settings.setServerUrl(propertyTable.serverUrl) end)
	propertyTable:addObserver('apiKey',    function() Settings.setApiKey(propertyTable.apiKey) end)
	propertyTable:addObserver('logEnabled', function()
		Settings.setLogEnabled(propertyTable.logEnabled)
		if propertyTable.logEnabled then Logger.enable() else Logger.disable() end
	end)

	local bind = LrView.bind

	local function testConnection()
		LrFunctionContext.postAsyncTaskWithContext('ImmichSyncTestConnection', function()
			propertyTable.connectionStatus = 'Testing…'
			local api = ImmichAPI.new{
				serverUrl = propertyTable.serverUrl,
				apiKey = propertyTable.apiKey,
			}
			local _, err = api:ping()
			if err then
				propertyTable.connectionStatus = 'FAILED: ' .. Errors.format(err)
				return
			end
			local me, err2 = api:getMe()
			if err2 then
				propertyTable.connectionStatus = 'Ping OK but auth failed: ' .. Errors.format(err2)
			else
				propertyTable.connectionStatus = ('OK — signed in as %s'):format(
					(me and (me.email or me.name)) or 'unknown')
			end
		end)
	end

	local function choosePathMappings()
		LrFunctionContext.postAsyncTaskWithContext('ImmichSyncChoosePathMappings', function(context)
			local current = Settings.getPathMappings()
			local libs = {}
			local dialogNotice = nil

			if propertyTable.serverUrl and propertyTable.serverUrl ~= ''
				and propertyTable.apiKey and propertyTable.apiKey ~= '' then
				local api = ImmichAPI.new{
					serverUrl = propertyTable.serverUrl,
					apiKey = propertyTable.apiKey,
				}
				local fetched, err = api:listLibraries()
				if err then
					dialogNotice = 'Could not refresh external libraries from Immich Collection Sync (' .. Errors.format(err) .. '). ' ..
						'The dialog still shows built-in uploaded-library roots and your already-saved mappings.'
				else
					libs = fetched or {}
				end
			else
				dialogNotice = 'Set the Immich server URL and API key to refresh external libraries automatically. ' ..
					'The dialog still lets you choose folders for built-in uploaded-library roots and any already-saved mappings.'
			end

			local resolved = presentLibraryMappingDialog(context, f, libs, current, dialogNotice)
			if resolved == nil then return end
			Settings.setPathMappings(resolved)
			updateMappingSummary(propertyTable, resolved)
			LrDialogs.message('Path mappings updated',
				PathMappingChoices.summarizeMappings(resolved), 'info')
		end)
	end

	return {
		{
			title = 'Immich Server',
			bind_to_object = propertyTable,

			f:row {
				f:static_text { title = 'Server URL', width = 120 },
				f:edit_field { value = bind 'serverUrl', width_in_chars = 40, immediate = true,
					placeholder_string = 'https://immich.example.com' },
			},
			f:row {
				f:static_text { title = 'API key', width = 120 },
				f:password_field { value = bind 'apiKey', width_in_chars = 40, immediate = true },
			},
			f:row {
				f:push_button { title = 'Test connection', action = testConnection },
				f:static_text { title = bind 'connectionStatus', width_in_chars = 50,
					fill_horizontal = 1 },
			},
		},
		{
			title = 'Path Mappings',
			bind_to_object = propertyTable,

			f:row {
				f:static_text {
					title = 'Translate Immich storage paths to the folders Lightroom sees.\n' ..
						'Choose folders in the dialog below; the Plugin Manager shows a read-only summary of the saved mappings.\n' ..
						'No files are downloaded — Lightroom and Immich must reference the same physical files.',
					height_in_lines = 3,
					fill_horizontal = 1,
				},
			},
			f:row {
				f:push_button {
					title = 'Choose path mappings…',
					action = choosePathMappings,
				},
				f:static_text {
					title = 'Refreshes Immich libraries when possible and lets you choose local folders in a browse-only dialog.',
					fill_horizontal = 1,
				},
			},
			f:row {
				f:static_text {
					title = bind 'mappingSummary',
					fill_horizontal = 1,
					width_in_chars = 100,
					height_in_lines = 6,
				},
			},
		},
		{
			title = 'Diagnostics',
			bind_to_object = propertyTable,

			f:row {
				f:checkbox { value = bind 'logEnabled', title = 'Enable debug logging' },
				f:push_button {
					title = 'Show log file',
					action = function() LrShell.revealInShell(Logger.logFilePath()) end,
				},
			},
		},
	}
end

return M
