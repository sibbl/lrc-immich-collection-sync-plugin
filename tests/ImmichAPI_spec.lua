local JSON = require 'JSON'
local Paths = require 'Paths'

-- Build a fake HTTP adapter so ImmichAPI can be tested without LrHttp.
local function fakeHttp(responses)
	local calls = {}
	local i = 0
	local adapter = {
		calls = calls,
		request = function(method, url, headers, body, timeout)
			i = i + 1
			table.insert(calls, {
				method = method, url = url, headers = headers, body = body, timeout = timeout,
			})
			local r = responses[i] or responses[#responses]
			if not r then return nil, nil end
			return r.body, r.headers
		end,
	}
	return adapter
end

describe('ImmichAPI', function()
	local ImmichAPI

	it('loads under mocked LR globals', function()
		ImmichAPI = require 'ImmichAPI'
		assertTrue(ImmichAPI ~= nil)
	end)

	it('trims whitespace on serverUrl and apiKey', function()
		local http = fakeHttp{ { body = '{"res":"pong"}', headers = { status = 200 } } }
		local api = ImmichAPI.new{
			serverUrl = '  https://host/  ',
			apiKey = '  secret-key \n',
			http = http,
			sleep = function() end,
		}
		local r, err = api:ping()
		assertNil(err)
		assertEq(r.res, 'pong')
		assertEq(http.calls[1].url, 'https://host/api/server/ping')
		local foundKey
		for _, kv in ipairs(http.calls[1].headers) do
			if kv.field == 'x-api-key' then foundKey = kv.value end
		end
		assertEq(foundKey, 'secret-key')
	end)

	it('listAlbums merges owned and shared albums without duplicates', function()
		local http = fakeHttp{
			{ body = '[{"id":"A1","albumName":"Owned"}]', headers = { status = 200 } },
			{ body = '[{"id":"A1","albumName":"Owned"},{"id":"A2","albumName":"Shared","shared":true}]',
			  headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x/', apiKey = 'K', http = http, sleep = function() end }
		local albums, err = api:listAlbums()
		assertNil(err)
		assertEq(http.calls[1].url, 'https://x/api/albums')
		assertEq(http.calls[2].url, 'https://x/api/albums?shared=true')
		assertEq(#albums, 2)
		assertEq(albums[1].id, 'A1')
		assertEq(albums[2].id, 'A2')
	end)

	it('retries on 500 then succeeds', function()
		local http = fakeHttp{
			{ body = '', headers = { status = 500 } },
			{ body = '', headers = { status = 500 } },
			{ body = '{"res":"pong"}', headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end, maxRetries = 3 }
		local r, err = api:ping()
		assertNil(err); assertEq(r.res, 'pong')
		assertEq(#http.calls, 3)
	end)

	it('returns network error when HTTP response headers are nil or missing status', function()
		local http = fakeHttp{ { body = nil, headers = nil } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end, maxRetries = 1 }
		local r, err = api:getAlbum('ALB')
		assertNil(r)
		assertEq(err.code, 'network')
		assertEq(#http.calls, 2)
	end)

	it('handles string respHeaders.error without crashing', function()
		local http = fakeHttp{ { body = nil, headers = { error = 'connection refused' } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end, maxRetries = 0 }
		local r, err = api:ping()
		assertNil(r)
		assertEq(err.code, 'network')
		assertTrue(err.message:match('connection refused') ~= nil)
	end)

	it('returns bad_response when getAlbum receives non-JSON HTML', function()
		local http = fakeHttp{ { body = '<html>Login</html>', headers = { status = 200 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local r, err = api:getAlbum('ALB')
		assertNil(r)
		assertEq(err.code, 'bad_response')
	end)

	it('getAlbum falls back to paginated POST /api/search/metadata when inline assets are omitted', function()
		local http = fakeHttp{
			{ body = '{"id":"ALB","albumName":"Vacation","assetCount":3,"assets":[]}', headers = { status = 200 } },
			{ body = '{"assets":{"items":[{"id":"A1","originalPath":"/data/library/1.jpg"},{"id":"A2","originalPath":"/data/library/2.jpg"}],"nextPage":"2"}}',
			  headers = { status = 200 } },
			{ body = '{"assets":{"items":[{"id":"A3","originalPath":"/data/library/3.jpg"}],"nextPage":null}}',
			  headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local album, err = api:getAlbum('ALB')
		assertNil(err)
		assertEq(album._assetsSource, 'search/metadata')
		assertEq(#album.assets, 3)
		assertEq(album.assets[1].id, 'A1')
		assertEq(album.assets[3].id, 'A3')
		assertEq(http.calls[2].method, 'POST')
		assertEq(http.calls[2].url, 'https://x/api/search/metadata')
		local req1 = JSON:decode(http.calls[2].body)
		assertDeepEq(req1.albumIds, { 'ALB' })
		assertEq(req1.page, 1)
		local req2 = JSON:decode(http.calls[3].body)
		assertEq(req2.page, 2)
	end)

	it('returns a structured error on 4xx', function()
		local http = fakeHttp{ { body = '', headers = { status = 401 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'bad',
			http = http, sleep = function() end }
		local r, err = api:getMe()
		assertNil(r)
		assertEq(err.code, 'http_401')
	end)

	it('findAssetByOriginalPath queries /api/search/metadata and falls back to filename', function()
		Paths._setOS('macos')
		local http = fakeHttp{
			{ body = '{"assets":{"items":[]}}', headers = { status = 200 } },
			{ body = '{"assets":{"items":[{"id":"TRASH","originalPath":"/data/library/A.JPG","isTrashed":true},{"id":"OK1","originalPath":"/data/library/A.JPG","isTrashed":false}]}}',
			  headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local asset, err = api:findAssetByOriginalPath('/data/library/a.jpg')
		assertNil(err)
		assertEq(asset.id, 'OK1')
		assertEq(http.calls[1].url, 'https://x/api/search/metadata')
		assertEq(http.calls[2].url, 'https://x/api/search/metadata')
	end)

	it('chunks addAssetsToAlbum and parses per-asset success/error responses', function()
		local http = fakeHttp{
			{ body = '[{"id":"a","success":true},{"id":"b","success":false,"error":"duplicate"}]',
			  headers = { status = 200 } },
			{ body = '[{"id":"c","success":false,"error":"not_found"}]',
			  headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end, batchSize = 2 }
		local r, err = api:addAssetsToAlbum('ALB', { 'a', 'b', 'c' })
		assertNil(err)
		assertEq(#http.calls, 2)
		assertEq(http.calls[1].method, 'PUT')
		assertEq(http.calls[1].url, 'https://x/api/albums/ALB/assets')
		assertEq(r.added, 2) -- 'a' succeeded and 'b' was duplicate (idempotent)
		assertEq(#r.failed, 1)
		assertEq(r.failed[1].id, 'c')
		assertEq(r.failed[1].error, 'not_found')
	end)

	it('does not POST when asset list is empty', function()
		local http = fakeHttp{}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local r, err = api:addAssetsToAlbum('ALB', {})
		assertNil(err); assertEq(r.added, 0)
		assertEq(#http.calls, 0)
	end)

	it('listLibraries decodes array with importPaths', function()
		local http = fakeHttp{ { body = '[{"id":"L1","name":"NAS","importPaths":["/mnt/nas/photos","/mnt/nas/scans"]}]',
			headers = { status = 200 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local libs, err = api:listLibraries()
		assertNil(err)
		assertEq(http.calls[1].method, 'GET')
		assertEq(http.calls[1].url, 'https://x/api/libraries')
		assertEq(#libs, 1)
		assertEq(libs[1].name, 'NAS')
		assertDeepEq(libs[1].importPaths, { '/mnt/nas/photos', '/mnt/nas/scans' })
	end)

	it('listLibraries surfaces auth errors', function()
		local http = fakeHttp{ { body = '', headers = { status = 401 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'bad',
			http = http, sleep = function() end }
		local libs, err = api:listLibraries()
		assertNil(libs)
		assertEq(err.code, 'http_401')
	end)

	it('downloadAsset fetches original bytes with binary headers and longer timeout', function()
		local http = fakeHttp{ { body = 'BINARY-DATA', headers = { status = 200 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local bytes, err = api:downloadAsset('ASSET')
		assertNil(err)
		assertEq(bytes, 'BINARY-DATA')
		assertEq(http.calls[1].method, 'GET')
		assertEq(http.calls[1].url, 'https://x/api/assets/ASSET/original')
		assertTrue(http.calls[1].timeout >= 180)
		local accept
		for _, kv in ipairs(http.calls[1].headers) do
			if kv.field == 'Accept' then accept = kv.value end
		end
		assertEq(accept, '*/*')
	end)

	it('albumUrl builds browser URL from normalized serverUrl', function()
		local api = ImmichAPI.new{ serverUrl = 'https://photos.example.com/', apiKey = 'k',
			http = fakeHttp{}, sleep = function() end }
		assertEq(api:albumUrl('ALB-1'), 'https://photos.example.com/albums/ALB-1')
		assertNil(api:albumUrl(''))
	end)

	it('searchSmart paginates POST /api/search/smart and skips trashed items', function()
		local http = fakeHttp{
			{ body = '{"assets":{"items":[{"id":"1","originalPath":"/data/1.jpg"},{"id":"T","originalPath":"/data/t.jpg","isTrashed":true}],"nextPage":"2"}}',
			  headers = { status = 200 } },
			{ body = '{"assets":{"items":[{"id":"2","originalPath":"/data/2.jpg"}],"nextPage":null}}',
			  headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local items, err = api:searchSmart('sunset', { maxResults = 100 })
		assertNil(err)
		assertEq(#items, 2)
		assertEq(items[1].id, '1')
		assertEq(items[2].id, '2')
		assertEq(http.calls[1].url, 'https://x/api/search/smart')
		assertTrue(http.calls[1].timeout >= 60)
	end)

	it('createAlbumSharedLink posts ALBUM share payload and returns full URL', function()
		local http = fakeHttp{ { body = '{"id":"SL1","key":"abc123"}', headers = { status = 201 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://photos.example.com/', apiKey = 'k',
			http = http, sleep = function() end }
		local res, err = api:createAlbumSharedLink('ALB-1', { allowDownload = true, password = 'pw' })
		assertNil(err)
		assertEq(res.url, 'https://photos.example.com/share/abc123')
		local req = JSON:decode(http.calls[1].body)
		assertEq(req.type, 'ALBUM')
		assertEq(req.albumId, 'ALB-1')
		assertEq(req.password, 'pw')
	end)

	it('getAsset, updateAsset, upsertTags, and assignTagsToAsset hit expected Immich endpoints', function()
		local http = fakeHttp{
			{ body = '{"id":"A1","isFavorite":true}', headers = { status = 200 } },
			{ body = '{"id":"A1"}', headers = { status = 200 } },
			{ body = '[{"id":"T1","value":"travel"}]', headers = { status = 200 } },
			{ body = '[{"id":"A1","success":true}]', headers = { status = 200 } },
		}
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local asset, err1 = api:getAsset('A1')
		assertNil(err1); assertEq(asset.isFavorite, true)
		local _, err2 = api:updateAsset('A1', { rating = 5, description = 'hi' })
		assertNil(err2); assertEq(http.calls[2].method, 'PUT')
		local tags, err3 = api:upsertTags({ 'travel' })
		assertNil(err3); assertEq(tags[1].id, 'T1')
		local _, err4 = api:assignTagsToAsset({ 'T1' }, 'A1')
		assertNil(err4); assertEq(http.calls[4].url, 'https://x/api/tags/assets')
	end)
end)
