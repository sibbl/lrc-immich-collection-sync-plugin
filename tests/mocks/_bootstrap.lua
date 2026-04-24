--[[
  Test bootstrap — installs minimal stubs for Lightroom SDK globals so the
  `src/*.lua` modules can be require()'d under plain Lua 5.1 / LuaJIT.

  The stubs are intentionally dumb: tests override behavior on a per-spec
  basis using `_G.<name> = <override>` before requiring the module under test.
]]

-- test.sh `cd`s to the repository root before invoking us, so relative paths
-- resolve correctly. For ad-hoc invocation (`luajit tests/run.lua`) run from
-- the repository root as well.
package.path = table.concat({
	'./src/?.lua',
	'./src/?/init.lua',
	'./tests/?.lua',
	package.path,
}, ';')

-- Stub `import` to return pre-registered modules from _G.__lr_imports.
_G.__lr_imports = _G.__lr_imports or {}

function _G.import(name)
	local mod = _G.__lr_imports[name]
	if mod == nil then
		error('no mock registered for LR module: ' .. name, 2)
	end
	return mod
end

-- Register a mock for a module name (e.g., 'LrPrefs'). Overwrites any
-- previous registration so each spec can replace the behavior.
function _G.registerLrMock(name, impl)
	_G.__lr_imports[name] = impl
end

-- Reset all mocks to a known minimal baseline.
function _G.resetLrMocks()
	_G.__lr_imports = {}
	-- LrPrefs: single shared plugin-prefs table.
	local prefsTable = {}
	registerLrMock('LrPrefs', {
		prefsForPlugin = function() return prefsTable end,
		_reset = function() for k in pairs(prefsTable) do prefsTable[k] = nil end end,
	})
	registerLrMock('LrLogger', function() return {
		enable = function() end, disable = function() end,
		info = function() end, warn = function() end,
		error = function() end, trace = function() end,
	} end)
	registerLrMock('LrHttp', {
		get = function() error('LrHttp.get not stubbed for this test') end,
		post = function() error('LrHttp.post not stubbed for this test') end,
	})
	registerLrMock('LrTasks', { sleep = function() end })
	registerLrMock('LrPathUtils', {
		child = function(a, b) return a .. '/' .. b end,
		getStandardFilePath = function() return '/tmp' end,
	})
end

_G.resetLrMocks()
