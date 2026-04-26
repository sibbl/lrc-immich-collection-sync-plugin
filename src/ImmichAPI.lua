--[[
  ImmichAPI — minimal JSON-only client for the endpoints we actually need.

  Design goals:
    * Zero file transfer. No multipart.
    * Injectable `http` dependency so it is trivially unit-testable.
    * Retry with exponential backoff on 429/5xx.

  Constructor: ImmichAPI.new{ serverUrl, apiKey, http, sleep, maxRetries }
      http (optional)       table with post/get/delete returning body, headers
                            (defaults to a wrapper around LrHttp)
      sleep (optional)      function(seconds) for backoff (defaults to a noop
                            for tests; LR wrapper injects LrTasks.sleep)
      maxRetries (optional) defaults to 3
]]

local Errors = require 'ImmichErrors'
local JSON = require 'ImmichJSON'

local M = {}
M.__index = M

local function trimSlash(s)
	if s == nil then return '' end
	return (s:gsub('/+$', ''))
end

-- Build the default HTTP adapter lazily so requiring this module does not
-- pull LrHttp during unit tests (where `import` is a mock).
--
-- LrHttp.post signature (verified from Adobe SDK and reference plugins):
--     LrHttp.post(url, body, headers, method?, timeout?)
-- Where `method` is an optional verb override ('PUT', 'DELETE', ...).
local HTTP_TIMEOUT_SECONDS = 30

local function defaultHttp()
	local LrHttp = import 'LrHttp'
	return {
		request = function(method, url, headers, body)
			if method == 'GET' then
				return LrHttp.get(url, headers, HTTP_TIMEOUT_SECONDS)
			end
			return LrHttp.post(url, body or '', headers, method, HTTP_TIMEOUT_SECONDS)
		end,
	}
end

local function defaultSleep()
	local ok, LrTasks = pcall(import, 'LrTasks')
	if ok and LrTasks and LrTasks.sleep then
		return function(s) LrTasks.sleep(s) end
	end
	return function(_) end
end

function M.new(opts)
	assert(opts, 'opts required')
	local self = setmetatable({}, M)
	self.serverUrl = trimSlash(opts.serverUrl or '')
	self.apiKey = opts.apiKey or ''
	self.http = opts.http or defaultHttp()
	self.sleep = opts.sleep or defaultSleep()
	self.maxRetries = opts.maxRetries or 3
	return self
end

function M:_headers(extraJson)
	local h = {
		{ field = 'x-api-key', value = self.apiKey },
		{ field = 'Accept',    value = 'application/json' },
	}
	if extraJson then
		table.insert(h, { field = 'Content-Type', value = 'application/json' })
	end
	return h
end

-- Internal: run a request with retries. Returns (body, headers, err).
function M:_request(method, path, body)
	local url = self.serverUrl .. path
	local attempts = 0
	while true do
		attempts = attempts + 1
		local respBody, respHeaders = self.http.request(
			method, url, self:_headers(body ~= nil), body)
		local status = respHeaders and tonumber(respHeaders.status) or nil
		-- Lightroom sometimes surfaces an `error` key on headers for network
		-- failures rather than a status code.
		if respHeaders and respHeaders.error then
			if attempts <= self.maxRetries then
				self.sleep(math.min(2 ^ (attempts - 1), 8))
			else
				return nil, respHeaders, Errors.make('network',
					'Network error: ' .. tostring(respHeaders.error.name or 'unknown'))
			end
		elseif status and (status == 429 or status >= 500) then
			if attempts <= self.maxRetries then
				self.sleep(math.min(2 ^ (attempts - 1), 8))
			else
				return respBody, respHeaders, Errors.make('http_' .. status,
					'HTTP ' .. status .. ' after ' .. attempts .. ' attempts')
			end
		elseif status and status >= 400 then
			return respBody, respHeaders, Errors.make('http_' .. status,
				'HTTP ' .. status, respBody)
		else
			return respBody, respHeaders, nil
		end
	end
end

local function decode(body)
	if body == nil or body == '' then return nil end
	local ok, value = pcall(function() return JSON:decode(body) end)
	if not ok then return nil end
	return value
end

-- Public endpoints --------------------------------------------------------

function M:ping()
	local body, _, err = self:_request('GET', '/api/server/ping')
	if err then return nil, err end
	local data = decode(body)
	if not data or data.res ~= 'pong' then
		return nil, Errors.make('bad_response', 'Unexpected /server/ping response')
	end
	return data, nil
end

function M:getMe()
	local body, _, err = self:_request('GET', '/api/users/me')
	if err then return nil, err end
	return decode(body), nil
end

function M:listAlbums()
	local body, _, err = self:_request('GET', '/api/albums')
	if err then return nil, err end
	local data = decode(body)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Expected array of albums')
	end
	return data, nil
end

-- Returns array of libraries: { id, name, ownerId, importPaths = {…}, … }.
-- In current Immich API (/api/libraries) this lists *external* libraries —
-- those with one or more `importPaths` mapped to filesystem paths inside
-- the Immich server/container. We use these importPaths to seed local
-- path-mapping entries so users do not need to look up paths manually.
function M:listLibraries()
	local body, _, err = self:_request('GET', '/api/libraries')
	if err then return nil, err end
	local data = decode(body)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Expected array of libraries')
	end
	return data, nil
end

-- Returns { id, albumName, assets = { {id, originalPath, originalFileName, checksum}, … } }
function M:getAlbum(albumId)
	local body, _, err = self:_request('GET',
		'/api/albums/' .. albumId .. '?withoutAssets=false')
	if err then return nil, err end
	return decode(body), nil
end

function M:addAssetsToAlbum(albumId, assetIds)
	if #assetIds == 0 then return { added = 0 }, nil end
	local body = JSON:encode({ ids = assetIds })
	local respBody, _, err = self:_request('PUT',
		'/api/albums/' .. albumId .. '/assets', body)
	if err then return nil, err end
	return decode(respBody) or { added = #assetIds }, nil
end

function M:removeAssetsFromAlbum(albumId, assetIds)
	if #assetIds == 0 then return { removed = 0 }, nil end
	local body = JSON:encode({ ids = assetIds })
	local respBody, _, err = self:_request('DELETE',
		'/api/albums/' .. albumId .. '/assets', body)
	if err then return nil, err end
	return decode(respBody) or { removed = #assetIds }, nil
end

return M
