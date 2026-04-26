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
local Logger = require 'ImmichLogger'
local Errors = require 'ImmichErrors'

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

-- Merge newly-resolved mappings (from the Immich library importPaths flow)
-- into the existing list. We match by `immich` prefix: any existing entry
-- with the same prefix is replaced; new ones are appended. Empty local
-- paths are skipped so the user can leave importPaths unmapped.
local function mergeMappings(existing, fresh)
	local byImmich = {}
	local out = {}
	for _, m in ipairs(existing or {}) do
		byImmich[m.immich] = #out + 1
		table.insert(out, m)
	end
	for _, m in ipairs(fresh or {}) do
		if m.immich and m.immich ~= '' and m.local_ and m.local_ ~= '' then
			local idx = byImmich[m.immich]
			if idx then
				out[idx] = m
			else
				byImmich[m.immich] = #out + 1
				table.insert(out, m)
			end
		end
	end
	return out
end

-- Modal dialog: shows each Immich library and its importPaths with an
-- editable local-path field plus Browse… button. On OK we merge the
-- resolved entries into the persisted pathMappings. Must be invoked
-- inside an LrFunctionContext so the property table has an owner.
local function presentLibraryMappingDialog(context, f, libraries, currentMappings)
	-- Pre-fill local paths from existing mappings (match by immich prefix).
	local byImmich = {}
	for _, m in ipairs(currentMappings or {}) do
		byImmich[m.immich] = m.local_
	end

	local props = LrBinding.makePropertyTable(context)
	-- Build keyed properties: row_<i>_local for each importPath row.
	local rows = {}
	local rowCount = 0
	local libCount = 0
	for _, lib in ipairs(libraries or {}) do
		libCount = libCount + 1
		local paths = lib.importPaths or {}
		if #paths == 0 then
			-- Still show the library so the user knows it exists.
			rowCount = rowCount + 1
			local key = 'row_' .. rowCount .. '_local'
			props[key] = ''
			table.insert(rows, { lib = lib, importPath = nil, key = key })
		else
			for _, p in ipairs(paths) do
				rowCount = rowCount + 1
				local key = 'row_' .. rowCount .. '_local'
				props[key] = byImmich[p] or ''
				table.insert(rows, { lib = lib, importPath = p, key = key })
			end
		end
	end

	if rowCount == 0 then
		LrDialogs.message('No libraries found',
			'Immich returned no external libraries. Internal uploads still need a manual mapping ' ..
			'(typically /usr/src/app/upload/library → your local mount).', 'info')
		return nil
	end

	local viewRows = {
		f:row {
			f:static_text { title = 'Library', width_in_chars = 18, font = '<system/bold>' },
			f:static_text { title = 'Immich import path', width_in_chars = 38, font = '<system/bold>' },
			f:static_text { title = 'Local path (as Lightroom sees it)', width_in_chars = 38, font = '<system/bold>' },
		},
	}
	for _, r in ipairs(rows) do
		local localKey = r.key
		local browseFn = function()
			local LrFileUtils = import 'LrFileUtils'
			local result = LrDialogs.runOpenPanel{
				title = 'Pick local folder for ' .. (r.importPath or r.lib.name or ''),
				canChooseFiles = false,
				canChooseDirectories = true,
				allowsMultipleSelection = false,
			}
			if result and result[1] then
				props[localKey] = result[1]
			end
		end
		table.insert(viewRows, f:row {
			f:static_text { title = r.lib.name or '?', width_in_chars = 18 },
			f:static_text {
				title = r.importPath or '(no importPaths configured)',
				width_in_chars = 38,
			},
			f:edit_field {
				value = LrView.bind { key = localKey, bind_to_object = props },
				width_in_chars = 32,
				enabled = r.importPath ~= nil,
				immediate = true,
			},
			f:push_button {
				title = 'Browse…',
				enabled = r.importPath ~= nil,
				action = browseFn,
			},
		})
	end

	local contents = f:column {
		spacing = f:control_spacing(),
		f:static_text {
			title = ('Found %d librar%s with %d import path%s. ' ..
				'For each Immich import path, set the same folder as Lightroom sees it. ' ..
				'No files are downloaded — both Immich and Lightroom point at the same physical files.'):format(
				libCount, libCount == 1 and 'y' or 'ies',
				rowCount, rowCount == 1 and '' or 's'),
			width_in_chars = 100,
			height_in_lines = 3,
		},
		unpack(viewRows),
	}

	local ok = LrDialogs.presentModalDialog{
		title = 'Map Immich libraries to local paths',
		contents = contents,
		actionVerb = 'Save mappings',
	}
	if ok ~= 'ok' then return nil end

	local fresh = {}
	for _, r in ipairs(rows) do
		if r.importPath then
			local localP = props[r.key]
			if localP and localP:match('%S') then
				table.insert(fresh, {
					label = r.lib.name or '',
					immich = r.importPath,
					local_ = localP,
				})
			end
		end
	end
	return fresh
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

	-- Fetch libraries from Immich and present a per-importPath mapping dialog.
	-- After the user saves, we merge results into the persisted pathMappings
	-- and refresh the visible text area so they can review/edit further.
	local function fetchLibrariesAndMap()
		LrFunctionContext.postAsyncTaskWithContext('ImmichSyncFetchLibraries', function(context)
			if not propertyTable.serverUrl or propertyTable.serverUrl == ''
				or not propertyTable.apiKey or propertyTable.apiKey == '' then
				LrDialogs.message('Missing credentials',
					'Set the Immich server URL and API key first, then click "Test connection".', 'warning')
				return
			end
			local api = ImmichAPI.new{
				serverUrl = propertyTable.serverUrl,
				apiKey = propertyTable.apiKey,
			}
			local libs, err = api:listLibraries()
			if err then
				LrDialogs.message('Could not fetch libraries',
					'Immich returned: ' .. Errors.format(err), 'critical')
				return
			end
			local current = textToMappings(propertyTable.mappingsText)
			local fresh = presentLibraryMappingDialog(context, f, libs, current)
			if fresh == nil then return end
			local merged = mergeMappings(current, fresh)
			Settings.setPathMappings(merged)
			propertyTable.mappingsText = mappingsToText(merged)
			LrDialogs.message('Path mappings updated',
				('Saved %d mapping%s. Lightroom and Immich now point at the same physical files — no downloads.'):format(
					#merged, #merged == 1 and '' or 's'), 'info')
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
					title = 'Translate Immich storage paths to the paths Lightroom sees.\n' ..
						'No files are downloaded — Lightroom and Immich must reference the same physical files.\n' ..
						'Click "Fetch libraries from Immich…" to discover importPaths automatically, or edit below.',
					height_in_lines = 3,
					fill_horizontal = 1,
				},
			},
			f:row {
				f:push_button {
					title = 'Fetch libraries from Immich…',
					action = fetchLibrariesAndMap,
				},
				f:static_text {
					title = 'Reads /api/libraries and lets you assign each importPath a local folder.',
					fill_horizontal = 1,
				},
			},
			f:row {
				f:static_text {
					title = 'Advanced (raw): one mapping per line, tab-separated: label<TAB>immich<TAB>local',
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
