--[[
  Paths.lua — pure path helpers. No LR dependencies so it is trivial to unit
  test. Case-folding policy matches the host OS convention used by Lightroom:
  case-sensitive on Linux, case-insensitive on macOS and Windows.
]]

local M = {}

-- OS detection without LrSystemInfo so the module works in headless tests.
local function detectOS()
	local sep = package.config:sub(1, 1)
	if sep == '\\' then return 'windows' end
	-- Heuristic: Darwin exposes /System directory, Linux does not.
	local f = io.open('/System/Library/CoreServices/SystemVersion.plist', 'r')
	if f then f:close(); return 'macos' end
	return 'linux'
end

M.os = detectOS()

-- Override for tests.
function M._setOS(os)
	assert(os == 'macos' or os == 'linux' or os == 'windows', 'invalid os')
	M.os = os
end

function M.isCaseInsensitive()
	return M.os == 'macos' or M.os == 'windows'
end

-- Replace backslashes with forward slashes so all comparisons use one form.
function M.normalizeSeparators(p)
	if p == nil then return nil end
	return (p:gsub('\\', '/'))
end

-- Remove trailing slashes (but keep a single slash for root).
function M.stripTrailingSlash(p)
	if p == nil or p == '' then return p end
	if p == '/' then return p end
	local stripped = p:gsub('/+$', '')
	return stripped
end

-- Ensure a directory-style path ends with exactly one '/'.
function M.ensureTrailingSlash(p)
	if p == nil or p == '' then return '/' end
	if p:sub(-1) == '/' then return p end
	return p .. '/'
end

-- Canonical form for prefix comparison: forward slashes, single trailing slash.
function M.asPrefix(p)
	return M.ensureTrailingSlash(M.normalizeSeparators(p))
end

-- Fold case if host OS is case-insensitive. Used only for COMPARISON, never
-- stored. Callers keep original-case paths.
function M.foldForCompare(p)
	if p == nil then return nil end
	if M.isCaseInsensitive() then return p:lower() end
	return p
end

-- Does `full` start with `prefix` (both already normalized)? Case-insensitive
-- on mac/windows.
function M.startsWith(full, prefix)
	if full == nil or prefix == nil then return false end
	local a = M.foldForCompare(full)
	local b = M.foldForCompare(prefix)
	return a:sub(1, #b) == b
end

return M
