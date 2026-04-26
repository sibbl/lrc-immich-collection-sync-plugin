--[[
  Loader used by dotted compatibility aliases such as `vendor.JSON.lua`.

  Why this exists:
    * Plain Lua 5.1 `require 'vendor.JSON'` resolves via package.path to
      `vendor/JSON.lua` and works fine in tests.
    * Lightroom's toolkit loader appears to sometimes treat `vendor.JSON`
      as a literal script name instead, so we provide alias files with dots
      in their filenames and have them explicitly load the real nested file.
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