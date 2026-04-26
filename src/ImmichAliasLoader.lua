--[[
  Explicit file loader for helper modules that live in subdirectories.

  Lightroom Classic's plugin `require` behavior is stricter than plain Lua
  5.1: nested module names like `vendor.JSON` or `ui.Dialogs` can fail at
  runtime even though they work fine in tests. To keep the codebase
  organized *and* keep runtime module names simple, top-level wrapper
  modules (e.g. `ImmichJSON.lua`) call into this loader and load the real
  nested file directly.
]]

local M = {}

local function pluginRoot()
	if _PLUGIN and _PLUGIN.path then
		return _PLUGIN.path
	end
	return './src'
end

function M.load(relativePath)
	local fullPath = pluginRoot() .. '/' .. relativePath
	local chunk, err = loadfile(fullPath)
	if not chunk then error(err, 2) end
	return chunk()
end

return M