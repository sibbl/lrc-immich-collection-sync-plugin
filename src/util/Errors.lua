--[[
  Errors — consistent error rendering and a tiny result helper.

  We treat ImmichAPI / SyncEngine return values as (value, err) pairs where
  `err` is a table { code, message, details } for programmatic handling and
  a human-readable `.message`.
]]

local M = {}

function M.make(code, message, details)
	return { code = code, message = message, details = details }
end

function M.format(err)
	if err == nil then return '' end
	if type(err) == 'string' then return err end
	if err.message then
		if err.code then return ('[%s] %s'):format(err.code, err.message) end
		return err.message
	end
	return tostring(err)
end

return M
