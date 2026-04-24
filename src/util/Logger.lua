--[[
  Logger.lua — thin wrapper around LrLogger so modules don't have to import it
  directly. Safe to require from both the LR runtime and unit tests (tests
  stub `import` in tests/mocks/_bootstrap.lua).
]]

local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'

local M = {}

local logger = LrLogger('ImmichSync')

function M.enable()
	logger:enable('logfile')
end

function M.disable()
	logger:disable()
end

function M.info(msg)  logger:info(tostring(msg))  end
function M.warn(msg)  logger:warn(tostring(msg))  end
function M.error(msg) logger:error(tostring(msg)) end
function M.trace(msg) logger:trace(tostring(msg)) end

function M.logFilePath()
	-- LrLogger writes to <preferences>/LrClassicLogs/<name>.log on recent LR versions.
	local dir = LrPathUtils.getStandardFilePath('documents')
	return LrPathUtils.child(dir, 'LrClassicLogs/ImmichSync.log')
end

return M
