-- Keep the user's selection across attempts. Each attempt owns its progress
-- scope and preview bindings, and finishes before Lightroom starts the next.
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrBinding = import 'LrBinding'
local LrView = import 'LrView'

local Settings = require 'Settings'
local PathMappingDialog = require 'PathMappingDialog'

local M = {}

function M.run(name, prepare, attempt)
	local selection
	local function run(context)
		selection = selection or prepare(context)
		if selection and attempt(context, selection) == 'retry' then
			LrFunctionContext.postAsyncTaskWithContext(name, run)
		end
	end
	LrFunctionContext.postAsyncTaskWithContext(name, run)
end

local function addMappingButton(context, f)
	return f:push_button {
		title = 'Add path mapping…',
		action = function(button)
			if PathMappingDialog.addCustomMapping(context, f) then
				-- The SDK accepts any view in the enclosing dialog here.
				-- https://lrc.mcor.dev/modules/LrDialogs.html#LrDialogs.stopModalWithResult
				LrDialogs.stopModalWithResult(button, 'other')
			end
		end,
	}
end

function M.problem(context, title, message, canAddMapping)
	local result
	if canAddMapping then
		local f = LrView.osFactory()
		result = LrDialogs.presentModalDialog {
			title = title,
			contents = f:column { f:static_text { title = message, width_in_chars = 72, height_in_lines = -1 } },
			accessoryView = addMappingButton(context, f),
			actionVerb = 'Retry',
			cancelVerb = 'Close',
		}
	else
		result = LrDialogs.confirm(title, message, 'Retry', 'Close')
	end
	if result == 'ok' or result == 'other' then return 'retry' end
end

function M.requirePathMappings(context)
	local mappings = Settings.getPathMappings()
	if #mappings > 0 then return mappings end
	return nil, M.problem(context, 'Immich Collection Sync — No path mappings',
		'Add a path mapping to match Immich storage paths to folders in Lightroom.', true)
end

function M.preview(context, options)
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	props.preview = options.text
	local views = {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text { title = options.heading, font = '<system/bold>' },
		f:edit_field {
			value = LrView.bind 'preview',
			width_in_chars = options.width,
			height_in_lines = options.height,
			enabled = true,
		},
	}
	if options.canAddMapping then
		table.insert(views, addMappingButton(context, f))
	end

	local result = LrDialogs.presentModalDialog {
		title = options.title,
		contents = f:column(views),
		actionVerb = options.hasChanges and 'Apply' or 'Close',
		cancelVerb = options.hasChanges and 'Cancel' or '< exclude >',
		-- otherVerb returns 'other' independently of Apply or Close.
		-- https://lrc.mcor.dev/modules/LrDialogs.html#LrDialogs.presentModalDialog
		otherVerb = options.hasDiagnostics and 'Retry' or nil,
	}
	if result == 'other' then return 'retry' end
	if result == 'ok' and options.hasChanges then return 'apply' end
end

return M
