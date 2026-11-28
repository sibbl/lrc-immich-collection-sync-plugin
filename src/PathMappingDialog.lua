-- Custom prefix editor shared by the Plug-in Manager and path warnings.
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'

local PathMappingChoices = require 'PathMappingChoices'
local Settings = require 'Settings'
local Logger = require 'Logger'

local M = {}

-- Modal dialog for adding (or overriding) a custom Immich prefix -> local folder mapping.
function M.addCustomMapping(context, f)
	local props = LrBinding.makePropertyTable(context)
	props.label = ''
	props.immich = ''
	props.local_ = ''

	local contents = f:column {
		spacing = f:control_spacing(),
		bind_to_object = props,
		f:static_text {
			title = 'Add a custom Immich storage path prefix (for example a per-user override like /data/library/alice/ or a custom container mount). Longest matching prefix wins.',
			width_in_chars = 76,
			height_in_lines = 3,
		},
		f:row {
			f:static_text { title = 'Label', width = 120 },
			f:edit_field {
				value = LrView.bind 'label',
				width_in_chars = 44,
				immediate = true,
				placeholder_string = 'e.g. Alice SSD override',
			},
		},
		f:row {
			f:static_text { title = 'Immich prefix', width = 120 },
			f:edit_field {
				value = LrView.bind 'immich',
				width_in_chars = 44,
				immediate = true,
				placeholder_string = '/data/library/alice/',
			},
		},
		f:row {
			f:static_text { title = 'Local folder', width = 120 },
			f:edit_field {
				value = LrView.bind 'local_',
				width_in_chars = 36,
				immediate = true,
				placeholder_string = '/Volumes/photos/alice/',
			},
			f:push_button {
				title = 'Choose…',
				action = function()
					local result = LrDialogs.runOpenPanel{
						title = 'Choose local folder for custom Immich prefix',
						canChooseFiles = false,
						canChooseDirectories = true,
						canCreateDirectories = true,
						allowsMultipleSelection = false,
					}
					if result and result[1] then props.local_ = result[1] end
				end,
			},
		},
	}

	local ok = LrDialogs.presentModalDialog{
		title = 'Add custom path mapping',
		contents = contents,
		actionVerb = 'Add mapping',
	}
	if ok ~= 'ok' then return nil end
	local entry = {
		label = props.label,
		immich = props.immich,
		local_ = props.local_,
	}
	local updated, err = PathMappingChoices.upsertMapping(Settings.getPathMappings(), entry)
	if not updated then
		LrDialogs.message('Invalid path mapping', err, 'warning')
		return nil
	end
	Settings.setPathMappings(updated)
	Logger.info(('Added custom path mapping %s -> %s'):format(entry.immich, entry.local_))
	return updated
end

return M
