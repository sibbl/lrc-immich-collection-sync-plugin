--[[
  ImmichAPI — minimal client for the Immich REST endpoints we need.

  Design goals:
    * Zero uploads. No multipart.
    * Injectable `http` transport and `sleep` function so it is unit-testable.
    * Retry with exponential backoff on network errors, 429, and 5xx.
    * Batching + per-asset result checking for album membership updates.

  Constructor: ImmichAPI.new{ serverUrl, apiKey, http, sleep, maxRetries, batchSize, logger }
      http (optional)       table with request(method, url, headers, body, timeout)
                            returning body, headers (defaults to LrHttp adapter)
      sleep (optional)      function(seconds) for backoff (defaults to LrTasks.sleep)
      maxRetries (optional) defaults to 3
      batchSize (optional)  defaults to 250
      logger (optional)     { info, warn, error, trace }
]]

local Errors = require 'Errors'
local JSON = require 'JSON'
local Paths = require 'Paths'

local M = {}
M.__index = M

local function trim(s)
	if s == nil then return '' end
	return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function trimSlash(s)
	return (trim(s):gsub('/+$', ''))
end

local HTTP_TIMEOUT_SECONDS = 30
local SEARCH_TIMEOUT_SECONDS = 60
local DOWNLOAD_TIMEOUT_SECONDS = 180
local DEFAULT_BATCH_SIZE = 250
local MAX_SMART_SEARCH_RESULTS = 1250

-- Build the default HTTP adapter lazily so requiring this module does not
-- pull LrHttp during unit tests (where `import` is a mock).
--
-- LrHttp.post signature (verified from Adobe SDK and reference plugins):
--     LrHttp.post(url, body, headers, method?, timeout?)
-- Where `method` is an optional verb override ('PUT', 'DELETE', ...).
local function defaultHttp()
	local LrHttp = import 'LrHttp'
	return {
		request = function(method, url, headers, body, timeout)
			local t = timeout or HTTP_TIMEOUT_SECONDS
			if method == 'GET' then
				return LrHttp.get(url, headers, t)
			end
			return LrHttp.post(url, body or '', headers, method, t)
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

local function formatHeaderError(errObj)
	if type(errObj) == 'table' then
		return tostring(errObj.name or errObj.message or 'unknown')
	end
	return tostring(errObj or 'unknown')
end

local function leafNameOf(path)
	if not path or path == '' then return nil end
	local norm = Paths.normalizeSeparators(path)
	local leaf = norm:match('([^/]+)$')
	if leaf and leaf ~= '' then return leaf end
	return nil
end

function M.new(opts)
	assert(opts, 'opts required')
	local self = setmetatable({}, M)
	self.serverUrl = trimSlash(opts.serverUrl or '')
	self.apiKey = trim(opts.apiKey or '')
	self.http = opts.http or defaultHttp()
	self.sleep = opts.sleep or defaultSleep()
	self.maxRetries = opts.maxRetries or 3
	self.batchSize = opts.batchSize or DEFAULT_BATCH_SIZE
	self.logger = opts.logger
	return self
end

function M:_log(level, msg)
	if self.logger and type(self.logger[level]) == 'function' then
		self.logger[level](msg)
	end
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

function M:_downloadHeaders()
	return {
		{ field = 'x-api-key', value = self.apiKey },
		{ field = 'Accept',    value = '*/*' },
	}
end

-- Internal: run a request with retries. Returns (body, headers, err).
function M:_request(method, path, body, headersOverride, timeout)
	if self.serverUrl == '' then
		return nil, nil, Errors.make('bad_config', 'Immich server URL is empty')
	end
	local url = self.serverUrl .. path
	local attempts = 0
	while true do
		attempts = attempts + 1
		local respBody, respHeaders = self.http.request(
			method, url, headersOverride or self:_headers(body ~= nil), body, timeout)
		local status = respHeaders and tonumber(respHeaders.status) or nil

		-- Lightroom sometimes surfaces an `error` key on headers for network
		-- failures rather than a status code, or returns nil headers on failure.
		if respHeaders and respHeaders.error then
			local errName = formatHeaderError(respHeaders.error)
			if attempts <= self.maxRetries then
				self:_log('warn', ('ImmichAPI %s %s network error (%s), retry %d/%d'):format(
					method, path, errName, attempts, self.maxRetries))
				self.sleep(math.min(2 ^ (attempts - 1), 8))
			else
				self:_log('error', ('ImmichAPI %s %s failed after %d attempts: %s'):format(
					method, path, attempts, errName))
				return nil, respHeaders, Errors.make('network', 'Network error: ' .. errName)
			end
		elseif status == nil then
			if attempts <= self.maxRetries then
				self:_log('warn', ('ImmichAPI %s %s returned no HTTP status, retry %d/%d'):format(
					method, path, attempts, self.maxRetries))
				self.sleep(math.min(2 ^ (attempts - 1), 8))
			else
				self:_log('error', ('ImmichAPI %s %s returned no HTTP status after %d attempts'):format(
					method, path, attempts))
				return nil, respHeaders, Errors.make('network',
					'No HTTP response received (check server URL or network connection)')
			end
		elseif status == 429 or status >= 500 then
			if attempts <= self.maxRetries then
				self:_log('warn', ('ImmichAPI %s %s HTTP %d, retry %d/%d'):format(
					method, path, status, attempts, self.maxRetries))
				self.sleep(math.min(2 ^ (attempts - 1), 8))
			else
				self:_log('error', ('ImmichAPI %s %s HTTP %d after %d attempts'):format(
					method, path, status, attempts))
				return respBody, respHeaders, Errors.make('http_' .. status,
					'HTTP ' .. status .. ' after ' .. attempts .. ' attempts')
			end
		elseif status >= 400 then
			self:_log('warn', ('ImmichAPI %s %s HTTP %d'):format(method, path, status))
			return respBody, respHeaders, Errors.make('http_' .. status,
				'HTTP ' .. status, respBody)
		elseif status < 200 or status >= 300 then
			self:_log('warn', ('ImmichAPI %s %s unexpected HTTP %d'):format(method, path, status))
			return respBody, respHeaders, Errors.make('http_' .. status,
				'Unexpected HTTP status ' .. status, respBody)
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
	if type(data) ~= 'table' or data.res ~= 'pong' then
		return nil, Errors.make('bad_response', 'Unexpected /server/ping response')
	end
	return data, nil
end

function M:getMe()
	local body, _, err = self:_request('GET', '/api/users/me')
	if err then return nil, err end
	local data = decode(body)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Unexpected /users/me response')
	end
	return data, nil
end

-- Lists owned albums and albums shared with the user, deduplicated by id.
function M:listAlbums()
	local body, _, err = self:_request('GET', '/api/albums')
	if err then return nil, err end
	local owned = decode(body)
	if type(owned) ~= 'table' then
		return nil, Errors.make('bad_response', 'Expected array of albums')
	end

	local merged = {}
	local seen = {}
	for _, album in ipairs(owned) do
		if album.id and not seen[album.id] then
			seen[album.id] = true
			table.insert(merged, album)
		end
	end

	local sharedBody, _, sharedErr = self:_request('GET', '/api/albums?shared=true')
	if sharedErr then
		self:_log('warn', 'Could not fetch shared albums: ' .. Errors.format(sharedErr))
	else
		local shared = decode(sharedBody)
		if type(shared) == 'table' then
			for _, album in ipairs(shared) do
				if album.id and not seen[album.id] then
					seen[album.id] = true
					table.insert(merged, album)
				end
			end
		end
	end

	return merged, nil
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

-- Queries POST /api/search/metadata and returns (items, nil, assetsBox) or (nil, err).
function M:searchMetadata(query)
	local body = JSON:encode(query or {})
	local respBody, _, err = self:_request('POST', '/api/search/metadata', body)
	if err then return nil, err, nil end
	local data = decode(respBody)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Unexpected /search/metadata response'), nil
	end
	if type(data.assets) == 'table' and type(data.assets.items) == 'table' then
		return data.assets.items, nil, data.assets
	end
	if type(data.items) == 'table' then
		return data.items, nil, data
	end
	return {}, nil, data.assets or data
end

-- Paginate POST /api/search/metadata with albumIds to fetch all assets in an
-- album. Used as an automatic fallback when GET /api/albums/{id} omits inline
-- assets (as in newer Immich API versions or certain shared albums).
function M:getAlbumAssetsViaSearch(albumId)
	local pageSize = 500
	local maxPages = 100
	local page = 1
	local all = {}
	local seen = {}

	while page <= maxPages do
		local items, err, box = self:searchMetadata({
			albumIds = { albumId },
			page = page,
			size = pageSize,
		})
		if err then return nil, err end
		if not items or #items == 0 then break end

		local addedThisPage = 0
		for _, item in ipairs(items) do
			if item.id and not seen[item.id] then
				seen[item.id] = true
				table.insert(all, item)
				addedThisPage = addedThisPage + 1
			end
		end
		-- Guard against servers that ignore `page` and repeat page 1.
		if addedThisPage == 0 then break end

		local hasMore = false
		if type(box) == 'table' then
			if box.nextPage ~= nil and tostring(box.nextPage) ~= '' then
				hasMore = true
				page = tonumber(box.nextPage) or (page + 1)
			elseif box.hasNextPage == true then
				hasMore = true
				page = page + 1
			elseif type(box.totalPages) == 'number' and page < box.totalPages then
				hasMore = true
				page = page + 1
			end
		end
		if not hasMore then break end
	end

	return all, nil
end

-- Returns { id, albumName, assetCount, assets = { {id, originalPath, originalFileName, checksum, type}, … } }
-- If GET /api/albums/{id}?withoutAssets=false omits or returns an empty assets
-- array while assetCount > 0 (newer Immich versions), falls back to paginating
-- POST /api/search/metadata with albumIds.
function M:getAlbum(albumId)
	local body, _, err = self:_request('GET',
		'/api/albums/' .. albumId .. '?withoutAssets=false')
	if err then return nil, err end
	local data = decode(body)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Unexpected /albums response')
	end

	local inlineCount = type(data.assets) == 'table' and #data.assets or 0
	local reportedCount = tonumber(data.assetCount) or 0
	if inlineCount > 0 then
		data._assetsSource = 'album'
		return data, nil
	end

	if reportedCount > 0 or data.assets == nil then
		self:_log('info', ('GET /api/albums/%s returned %d inline assets (assetCount=%d); trying POST /api/search/metadata fallback'):format(
			tostring(albumId), inlineCount, reportedCount))
		local searched, searchErr = self:getAlbumAssetsViaSearch(albumId)
		if searchErr then
			self:_log('warn', 'Album asset search fallback failed: ' .. Errors.format(searchErr))
			data.assets = data.assets or {}
			data._assetsFallbackError = searchErr
		else
			data.assets = searched or {}
			data._assetsSource = 'search/metadata'
			self:_log('info', ('Album asset search fallback returned %d assets'):format(#data.assets))
		end
	else
		data.assets = data.assets or {}
		data._assetsSource = 'album'
	end

	return data, nil
end

-- Look up a non-trashed Immich asset by its Immich-side originalPath.
-- Tries exact `originalPath` search first, then falls back to searching by
-- `originalFileName` and matching the normalized path (handles case differences
-- on macOS/Windows hosts). Returns (asset, nil) if found, (nil, nil) if not
-- found, or (nil, err) on API failure.
function M:findAssetByOriginalPath(immichPath)
	if immichPath == nil or immichPath == '' then return nil, nil end
	local targetKey = Paths.normalizeKey(immichPath)

	local function pickMatch(items)
		for _, item in ipairs(items or {}) do
			if item.id and not item.isTrashed and item.originalPath then
				if Paths.normalizeKey(item.originalPath) == targetKey then
					return item
				end
			end
		end
		return nil
	end

	local items, err = self:searchMetadata({ originalPath = immichPath, size = 10 })
	if err then return nil, err end
	local matched = pickMatch(items)
	if matched then return matched, nil end

	local leaf = leafNameOf(immichPath)
	if leaf then
		local byName, err2 = self:searchMetadata({ originalFileName = leaf, size = 50 })
		if err2 then return nil, err2 end
		matched = pickMatch(byName)
		if matched then return matched, nil end
	end

	return nil, nil
end

-- Downloads the original asset bytes from GET /api/assets/{id}/original.
-- Uses a longer timeout because originals (RAWs / videos) can be large.
-- The caller is responsible for writing the returned binary string to disk.
function M:downloadAsset(assetId)
	if assetId == nil or assetId == '' then
		return nil, Errors.make('bad_request', 'assetId is required')
	end
	local body, _, err = self:_request('GET',
		'/api/assets/' .. assetId .. '/original', nil, self:_downloadHeaders(), DOWNLOAD_TIMEOUT_SECONDS)
	if err then return nil, err end
	return body, nil
end

local function mutateAlbumAssets(self, method, albumId, assetIds, countKey, allowDuplicate)
	if #assetIds == 0 then return { [countKey] = 0, failed = {} }, nil end

	local totalSucceeded = 0
	local failed = {}
	local batchSize = self.batchSize

	for startIdx = 1, #assetIds, batchSize do
		local batch = {}
		local endIdx = math.min(startIdx + batchSize - 1, #assetIds)
		for i = startIdx, endIdx do
			table.insert(batch, assetIds[i])
		end

		local body = JSON:encode({ ids = batch })
		local respBody, _, err = self:_request(method,
			'/api/albums/' .. albumId .. '/assets', body)
		if err then return nil, err end

		local decoded = decode(respBody)
		if type(decoded) == 'table' and #decoded > 0 and type(decoded[1]) == 'table' and decoded[1].id ~= nil then
			for _, item in ipairs(decoded) do
				if item.success == true or (allowDuplicate and item.error == 'duplicate') then
					totalSucceeded = totalSucceeded + 1
				else
					table.insert(failed, {
						id = item.id,
						error = item.error or 'unknown',
					})
				end
			end
		else
			totalSucceeded = totalSucceeded + #batch
		end
	end

	return { [countKey] = totalSucceeded, failed = failed }, nil
end

function M:addAssetsToAlbum(albumId, assetIds)
	return mutateAlbumAssets(self, 'PUT', albumId, assetIds or {}, 'added', true)
end

function M:removeAssetsFromAlbum(albumId, assetIds)
	return mutateAlbumAssets(self, 'DELETE', albumId, assetIds or {}, 'removed', false)
end

-- Browser URL for an Immich album.
function M:albumUrl(albumId)
	if self.serverUrl == '' or albumId == nil or albumId == '' then return nil end
	return self.serverUrl .. '/albums/' .. tostring(albumId)
end

-- Run an Immich CLIP / smart search via POST /api/search/smart.
-- opts (optional): { maxResults = 500, pageSize = 250, timeout = 60 }
-- Returns (assetsArray, nil) or (nil, err).
function M:searchSmart(query, opts)
	local q = trim(query)
	if q == '' then
		return nil, Errors.make('bad_request', 'Search query is required')
	end
	opts = opts or {}
	local maxResults = math.min(tonumber(opts.maxResults) or 500, MAX_SMART_SEARCH_RESULTS)
	local pageSize = math.min(tonumber(opts.pageSize) or 250, maxResults)
	local timeout = tonumber(opts.timeout) or SEARCH_TIMEOUT_SECONDS

	local all = {}
	local seen = {}
	local page = 1
	local maxPages = 20

	while page <= maxPages and #all < maxResults do
		local reqBody = JSON:encode({ query = q, page = page, size = pageSize })
		local respBody, _, err = self:_request('POST', '/api/search/smart', reqBody, nil, timeout)
		if err then return nil, err end
		local data = decode(respBody)
		if type(data) ~= 'table' then
			return nil, Errors.make('bad_response', 'Unexpected /search/smart response')
		end
		local box = type(data.assets) == 'table' and data.assets or data
		local items = type(box.items) == 'table' and box.items or {}
		if #items == 0 then break end

		local added = 0
		for _, item in ipairs(items) do
			if item.id and not item.isTrashed and not seen[item.id] then
				seen[item.id] = true
				table.insert(all, item)
				added = added + 1
				if #all >= maxResults then break end
			end
		end
		if added == 0 then break end

		local nextPage = box.nextPage and tonumber(box.nextPage) or nil
		if nextPage and nextPage > page then
			page = nextPage
		elseif box.hasNextPage == true then
			page = page + 1
		else
			break
		end
	end

	return all, nil
end

-- Create a public Immich shared link for an album via POST /api/shared-links.
-- opts (optional): { allowDownload = true, allowUpload = false, showMetadata = true,
--                    password = string, expiresAt = ISO8601, description = string }
-- Returns ({ id, key, url, raw }, nil) or (nil, err).
function M:createAlbumSharedLink(albumId, opts)
	if albumId == nil or albumId == '' then
		return nil, Errors.make('bad_request', 'albumId is required')
	end
	opts = opts or {}
	local payload = {
		type = 'ALBUM',
		albumId = tostring(albumId),
		allowDownload = opts.allowDownload ~= false,
		allowUpload = opts.allowUpload == true,
		showMetadata = opts.showMetadata ~= false,
	}
	if opts.password and trim(opts.password) ~= '' then
		payload.password = trim(opts.password)
	end
	if opts.expiresAt and trim(opts.expiresAt) ~= '' then
		payload.expiresAt = trim(opts.expiresAt)
	end
	if opts.description and trim(opts.description) ~= '' then
		payload.description = trim(opts.description)
	end

	local respBody, _, err = self:_request('POST', '/api/shared-links', JSON:encode(payload))
	if err then return nil, err end
	local data = decode(respBody)
	if type(data) ~= 'table' or not data.key or data.key == '' then
		return nil, Errors.make('bad_response', 'Unexpected /shared-links response (missing key)')
	end
	return {
		id = data.id,
		key = data.key,
		url = self.serverUrl .. '/share/' .. tostring(data.key),
		raw = data,
	}, nil
end

-- Fetch full asset details (including exifInfo, tags, people) via GET /api/assets/{id}.
function M:getAsset(assetId)
	if assetId == nil or assetId == '' then
		return nil, Errors.make('bad_request', 'assetId is required')
	end
	local respBody, _, err = self:_request('GET', '/api/assets/' .. tostring(assetId))
	if err then return nil, err end
	local data = decode(respBody)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Unexpected /assets response')
	end
	return data, nil
end

-- Update metadata fields on an Immich asset via PUT /api/assets/{id}.
function M:updateAsset(assetId, fields)
	if assetId == nil or assetId == '' then
		return nil, Errors.make('bad_request', 'assetId is required')
	end
	if type(fields) ~= 'table' then
		return nil, Errors.make('bad_request', 'fields table is required')
	end
	local body = {}
	for _, key in ipairs({ 'isFavorite', 'rating', 'description', 'latitude', 'longitude' }) do
		if fields[key] ~= nil then
			body[key] = fields[key]
		end
	end
	if next(body) == nil then return { updated = false }, nil end

	local respBody, _, err = self:_request('PUT', '/api/assets/' .. tostring(assetId), JSON:encode(body))
	if err then return nil, err end
	return decode(respBody) or { updated = true }, nil
end

-- Upsert Immich tags by name/path via PUT /api/tags. Returns array of { id, name, value }.
function M:upsertTags(tagNames)
	if type(tagNames) ~= 'table' or #tagNames == 0 then return {}, nil end
	local respBody, _, err = self:_request('PUT', '/api/tags', JSON:encode({ tags = tagNames }))
	if err then return nil, err end
	local data = decode(respBody)
	if type(data) ~= 'table' then
		return nil, Errors.make('bad_response', 'Unexpected /tags response')
	end
	return data, nil
end

-- Assign tag IDs to an asset via PUT /api/tags/assets.
function M:assignTagsToAsset(tagIds, assetId)
	if type(tagIds) ~= 'table' or #tagIds == 0 then return { assigned = 0 }, nil end
	if assetId == nil or assetId == '' then
		return nil, Errors.make('bad_request', 'assetId is required')
	end
	local respBody, _, err = self:_request('PUT', '/api/tags/assets',
		JSON:encode({ tagIds = tagIds, assetIds = { tostring(assetId) } }))
	if err then return nil, err end
	return decode(respBody) or { assigned = #tagIds }, nil
end

return M
