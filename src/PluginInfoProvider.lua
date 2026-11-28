--[[
  PluginInfoProvider — Plugin Manager settings UI.

  Shows server URL, API key (with plaintext storage notice), "Test connection"
  button, chooser-based path mappings (Immich prefix <-> Local prefix) plus an
  "Add custom mapping…" dialog, read-only mapping summary, and diagnostics.
  No per-preset settings because this plugin registers no Export/Publish
  services.
]]

local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrShell = import 'LrShell'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Settings = require 'Settings'
local ImmichAPI = require 'ImmichAPI'
local Logger = require 'Logger'
local Errors = require 'Errors'
local PathMappingChoices = require 'PathMappingChoices'
local PathMappingDialog = require 'PathMappingDialog'

local M = {}

local function updateMappingSummary(propertyTable, mappings)
	propertyTable.mappingSummary = PathMappingChoices.summarizeMappings(mappings)
end

-- Modal dialog: shows built-in Immich upload roots, external library
-- importPaths, and any previously saved mappings with browse-only local-folder
-- pickers inside a scrollable container. On OK we replace the persisted
-- pathMappings with the chosen rows.
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
			'No path-mappable Immich roots are available yet. Check the server settings or add a custom mapping.', 'info')
		return nil
	end

	local colLibW = 210
	local colImmichW = 220
	local colLocalW = 250
	local btnChooseW = 85
	local btnClearW = 65
	local dialogW = 920

	local viewRows = {
		spacing = f:control_spacing(),
		f:row {
			spacing = 8,
			f:static_text { title = 'Library', width = colLibW, font = '<system/bold>' },
			f:static_text { title = 'Immich path prefix', width = colImmichW, font = '<system/bold>' },
			f:static_text { title = 'Selected local folder', width = colLocalW, font = '<system/bold>' },
			f:static_text { title = 'Actions', width = btnChooseW + btnClearW + 8, font = '<system/bold>' },
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
			spacing = 8,
			f:static_text { title = r.name or '?', width = colLibW, height_in_lines = 2 },
			f:static_text {
				title = r.importPath or '(no import path reported)',
				width = colImmichW,
				truncation = 'middle',
			},
			f:static_text {
				title = LrView.bind { key = r.displayKey, bind_to_object = props },
				width = colLocalW,
				height_in_lines = 2,
				truncation = 'middle',
			},
			f:push_button {
				title = 'Choose…',
				width = btnChooseW,
				enabled = r.importPath ~= nil,
				action = chooseFn,
			},
			f:push_button {
				title = 'Clear',
				width = btnClearW,
				enabled = r.importPath ~= nil,
				action = clearFn,
			},
		})
	end

	local infoColumn = {
		spacing = f:control_spacing(),
		f:static_text {
			title = ('Found %d external librar%s. Also showing the default Immich data folder roots and any saved mappings. ' ..
				'Choose the local folder Lightroom sees for each Immich path.'):format(
				model.libraryCount, model.libraryCount == 1 and 'y' or 'ies'),
			width = dialogW,
			height_in_lines = 2,
		},
		f:static_text {
			title = 'Tip: mapping /data/ to your mounted Immich data folder automatically covers all uploaded assets (both /data/library/ and /data/upload/). Use "Add custom mapping…" for per-user overrides or custom mounts.',
			width = dialogW,
			height_in_lines = 2,
		},
	}
	if model.librariesWithoutImportPaths > 0 then
		table.insert(infoColumn, f:static_text {
			title = ('Immich reported %d librar%s without import paths; those cannot be mapped automatically until Immich exposes their paths.'):format(
				model.librariesWithoutImportPaths,
				model.librariesWithoutImportPaths == 1 and 'y' or 'ies'),
			width = dialogW,
			height_in_lines = 2,
		})
	end
	if dialogNotice and dialogNotice ~= '' then
		table.insert(infoColumn, f:static_text {
			title = dialogNotice,
			width = dialogW,
			height_in_lines = 3,
		})
	end

	-- Nest infoColumn and scrolled_view as distinct children so Lua never
	-- truncates multiple unpack() calls inside one table constructor.
	local scrollHeight = math.min(math.max(#rows * 44 + 44, 180), 420)
	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:column(infoColumn),
		f:separator { fill_horizontal = 1 },
		f:scrolled_view {
			width = dialogW,
			height = scrollHeight,
			horizontal_scroller = true,
			vertical_scroller = true,
			f:column(viewRows),
		},
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
		if propertyTable.logEnabled then
			Logger.enable()
			Logger.info('Debug logging enabled')
		else
			Logger.info('Debug logging disabled')
			Logger.disable()
		end
	end)

	local bind = LrView.bind

	local function testConnection()
		LrFunctionContext.postAsyncTaskWithContext('ImmichSyncTestConnection', function()
			propertyTable.connectionStatus = 'Testing…'
			Logger.info('Testing connection to Immich server')
			local api = ImmichAPI.new{
				serverUrl = propertyTable.serverUrl,
				apiKey = propertyTable.apiKey,
				logger = Logger,
			}
			local _, err = api:ping()
			if err then
				local msg = 'FAILED: ' .. Errors.format(err)
				Logger.error('Connection test ping failed: ' .. msg)
				propertyTable.connectionStatus = msg
				return
			end
			local me, err2 = api:getMe()
			if err2 then
				local msg = 'Ping OK but auth failed: ' .. Errors.format(err2)
				Logger.error('Connection test auth failed: ' .. msg)
				propertyTable.connectionStatus = msg
			else
				local who = (me and (me.email or me.name)) or 'unknown'
				Logger.info('Connection test succeeded as ' .. tostring(who))
				propertyTable.connectionStatus = ('OK — signed in as %s'):format(who)
			end
		end)
	end

	local function choosePathMappings()
		LrFunctionContext.postAsyncTaskWithContext('ImmichSyncChoosePathMappings', function(context)
			local current = Settings.getPathMappings()
			local libs = {}
			local dialogNotice = nil

			local url = Settings.getServerUrl()
			local key = Settings.getApiKey()
			if url ~= '' and key ~= '' then
				local api = ImmichAPI.new{
					serverUrl = url,
					apiKey = key,
					logger = Logger,
				}
				local fetched, err = api:listLibraries()
				if err then
					Logger.warn('Failed to refresh Immich libraries: ' .. Errors.format(err))
					dialogNotice = 'Could not refresh external libraries from Immich (' .. Errors.format(err) .. '). ' ..
						'The dialog still shows built-in uploaded-library roots and your already-saved mappings.'
				else
					libs = fetched or {}
					Logger.info(('Fetched %d external Immich libraries'):format(#libs))
				end
			else
				dialogNotice = 'Set the Immich server URL and API key to refresh external libraries automatically. ' ..
					'The dialog still lets you choose folders for built-in uploaded-library roots and any already-saved mappings.'
			end

			local resolved = presentLibraryMappingDialog(context, f, libs, current, dialogNotice)
			if resolved == nil then return end
			Settings.setPathMappings(resolved)
			updateMappingSummary(propertyTable, resolved)
			Logger.info(('Saved %d path mappings'):format(#resolved))
			LrDialogs.message('Path mappings updated',
				PathMappingChoices.summarizeMappings(resolved), 'info')
		end)
	end

	local function addCustomMapping()
		LrFunctionContext.postAsyncTaskWithContext('ImmichSyncAddCustomMapping', function(context)
			local updated = PathMappingDialog.addCustomMapping(context, f)
			if not updated then return end
			updateMappingSummary(propertyTable, updated)
			LrDialogs.message('Path mappings updated',
				PathMappingChoices.summarizeMappings(updated), 'info')
		end)
	end

	local function showLogFile()
		local logPath = Logger.logFilePath()
		if LrFileUtils.exists(logPath) then
			LrShell.revealInShell(logPath)
			return
		end
		local parentDir = LrPathUtils.parent(logPath)
		if parentDir and LrFileUtils.exists(parentDir) then
			LrDialogs.message('Log file not created yet',
				'No ImmichSync.log file exists yet. Enable debug logging and run an action first.\n\nExpected path:\n' .. logPath,
				'info')
			LrShell.revealInShell(parentDir)
		else
			LrDialogs.message('Log file not created yet',
				'No ImmichSync.log file exists yet. Enable debug logging and run an action first.\n\nExpected path:\n' .. logPath,
				'info')
		end
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
				f:static_text { title = '', width = 120 },
				f:static_text {
					title = 'Note: Lightroom SDK 3.0 stores plugin preferences (including the API key) in plaintext. Use a scoped Immich API key.',
					width_in_chars = 68,
					height_in_lines = 2,
					font = '<system/small>',
				},
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
						'Normal sync matches existing files on disk without transferring data; during Immich → Lightroom sync you can optionally confirm a download fallback for unmapped assets.',
					height_in_lines = 3,
					fill_horizontal = 1,
				},
			},
			f:row {
				f:push_button {
					title = 'Choose path mappings…',
					action = choosePathMappings,
				},
				f:push_button {
					title = 'Add custom mapping…',
					action = addCustomMapping,
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
					action = showLogFile,
				},
			},
		},
	}
end

return M
