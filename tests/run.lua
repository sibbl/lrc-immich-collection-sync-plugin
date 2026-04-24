--[[
  Tiny test runner. Usage:
      luajit tests/run.lua
  Discovers every `tests/*_spec.lua` file, runs all top-level `describe`
  blocks, and exits non-zero if any test fails.
]]

require 'tests.mocks._bootstrap'

local passed, failed = 0, 0
local failures = {}
local currentSuite

function _G.describe(name, fn)
	currentSuite = name
	fn()
	currentSuite = nil
end

function _G.it(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed = passed + 1
		io.write('.')
	else
		failed = failed + 1
		table.insert(failures, { suite = currentSuite, test = name, err = err })
		io.write('F')
	end
	io.flush()
end

function _G.assertEq(a, b, msg)
	if a ~= b then
		error((msg or 'values differ') ..
			('\n  expected: %s\n  actual:   %s'):format(tostring(b), tostring(a)), 2)
	end
end

function _G.assertTrue(v, msg)
	if not v then error(msg or 'expected truthy value, got falsy', 2) end
end

function _G.assertNil(v, msg)
	if v ~= nil then error((msg or 'expected nil') ..
		('\n  actual: %s'):format(tostring(v)), 2) end
end

function _G.assertDeepEq(a, b, msg)
	local function eq(x, y)
		if type(x) ~= type(y) then return false end
		if type(x) ~= 'table' then return x == y end
		for k, v in pairs(x) do if not eq(v, y[k]) then return false end end
		for k, v in pairs(y) do if not eq(v, x[k]) then return false end end
		return true
	end
	if not eq(a, b) then
		local inspect = require 'vendor.inspect'
		error((msg or 'tables differ') ..
			('\n  expected: %s\n  actual:   %s'):format(inspect(b), inspect(a)), 2)
	end
end

-- Discover specs.
local specs = {}
local p = io.popen('ls tests/*_spec.lua 2>/dev/null')
if p then
	for line in p:lines() do table.insert(specs, line) end
	p:close()
end
table.sort(specs)
if #specs == 0 then
	io.write('No specs found.\n')
	os.exit(0)
end

for _, path in ipairs(specs) do
	io.write('\n' .. path:match('([^/]+)%.lua$') .. ' ')
	dofile(path)
end

io.write(('\n\n%d passed, %d failed\n'):format(passed, failed))
for _, f in ipairs(failures) do
	io.write(('\n[FAIL] %s :: %s\n%s\n'):format(f.suite or '?', f.test, f.err))
end
os.exit(failed == 0 and 0 or 1)
