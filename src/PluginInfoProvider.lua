--[[
  PluginInfoProvider — Plugin Manager settings UI.

  Shows server URL, API key, "Test connection" button, and an editable list
  of path mappings (Immich prefix <-> Local prefix). No per-preset settings
  because this plugin registers no Export/Publish services.
]]

local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrShell = import 'LrShell'

local Settings = require 'Settings'
local ImmichAPI = require 'ImmichAPI'
local Logger = require 'util.Logger'
local Errors = require 'util.Errors'

local M = {}

-- Serialize path mappings to a human-editable multi-line text string so we
-- can use a single text area widget rather than a complex dynamic table
-- widget (LrView has no native table; doing it as rows-of-fields is brittle).
--
-- Format: one mapping per line, as
--     <label>\t<immichPrefix>\t<localPrefix>
-- Blank lines and lines starting with '#' are ignored.
local function mappingsToText(list)
	local lines = {
		'# Format: <label><TAB><immich prefix><TAB><local prefix>',
		'# Lines starting with # are ignored. Example:',
		'# internal\t/usr/src/app/upload/library/\t/Volumes/nas/immich/library/',
	}
	for _, m in ipairs(list or {}) do
		table.insert(lines, ('%s\t%s\t%s'):format(m.label or '', m.immich or '', m.local_ or ''))
	end
	return table.concat(lines, '\n')
end

local function textToMappings(text)
	local out = {}
	for line in (text or ''):gmatch('[^\r\n]+') do
		if line:sub(1, 1) ~= '#' and line:match('%S') then
			local label, immich, localP = line:match('([^\t]*)\t([^\t]+)\t([^\t]+)')
			if immich and localP then
				table.insert(out, {
					label = label or '',
					immich = immich,
					local_ = localP,
				})
			end
		end
	end
	return out
end

function M.sectionsForTopOfDialog(f, propertyTable)
	-- Seed propertyTable from persisted settings.
	propertyTable.serverUrl = Settings.getServerUrl()
	propertyTable.apiKey = Settings.getApiKey()
	propertyTable.mappingsText = mappingsToText(Settings.getPathMappings())
	propertyTable.logEnabled = Settings.getLogEnabled()
	propertyTable.connectionStatus = ''

	-- Persist on any change.
	propertyTable:addObserver('serverUrl', function() Settings.setServerUrl(propertyTable.serverUrl) end)
	propertyTable:addObserver('apiKey',    function() Settings.setApiKey(propertyTable.apiKey) end)
	propertyTable:addObserver('mappingsText', function()
		Settings.setPathMappings(textToMappings(propertyTable.mappingsText))
	end)
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
					title = 'Translate Immich storage paths to the paths Lightroom sees.\nOne mapping per line, tab-separated: label<TAB>immich<TAB>local',
					height_in_lines = 2,
					fill_horizontal = 1,
				},
			},
			f:row {
				f:edit_field {
					value = bind 'mappingsText',
					width_in_chars = 80,
					height_in_lines = 8,
					immediate = true,
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
