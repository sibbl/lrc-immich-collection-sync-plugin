local JSON = require 'JSON'

-- Build a fake HTTP adapter so ImmichAPI can be tested without LrHttp.
local function fakeHttp(responses)
	local calls = {}
	local i = 0
	local adapter = {
		calls = calls,
		request = function(method, url, headers, body)
			i = i + 1
			table.insert(calls, { method = method, url = url, headers = headers, body = body })
			local r = responses[i] or responses[#responses]
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

	it('ping returns decoded body on 200', function()
		local api = ImmichAPI.new{
			serverUrl = 'https://host',
			apiKey = 'k',
			http = fakeHttp{ { body = '{"res":"pong"}', headers = { status = 200 } } },
			sleep = function() end,
		}
		local r, err = api:ping()
		assertNil(err)
		assertEq(r.res, 'pong')
	end)

	it('sets x-api-key header and correct URL', function()
		local http = fakeHttp{ { body = '[]', headers = { status = 200 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x/', apiKey = 'K', http = http, sleep = function() end }
		api:listAlbums()
		assertEq(http.calls[1].url, 'https://x/api/albums')
		local foundKey
		for _, kv in ipairs(http.calls[1].headers) do
			if kv.field == 'x-api-key' then foundKey = kv.value end
		end
		assertEq(foundKey, 'K')
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

	it('returns a structured error on 4xx', function()
		local http = fakeHttp{ { body = '', headers = { status = 401 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'bad',
			http = http, sleep = function() end }
		local r, err = api:getMe()
		assertNil(r)
		assertEq(err.code, 'http_401')
	end)

	it('encodes album-asset add payload', function()
		local http = fakeHttp{ { body = '{}', headers = { status = 200 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		api:addAssetsToAlbum('ALB', { 'a', 'b' })
		assertEq(http.calls[1].method, 'PUT')
		assertEq(http.calls[1].url, 'https://x/api/albums/ALB/assets')
		local decoded = JSON:decode(http.calls[1].body)
		assertDeepEq(decoded.ids, { 'a', 'b' })
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

	it('downloadAsset fetches original bytes with binary-friendly headers', function()
		local http = fakeHttp{ { body = 'BINARY-DATA', headers = { status = 200 } } }
		local api = ImmichAPI.new{ serverUrl = 'https://x', apiKey = 'k',
			http = http, sleep = function() end }
		local bytes, err = api:downloadAsset('ASSET')
		assertNil(err)
		assertEq(bytes, 'BINARY-DATA')
		assertEq(http.calls[1].method, 'GET')
		assertEq(http.calls[1].url, 'https://x/api/assets/ASSET/original')
		local accept
		for _, kv in ipairs(http.calls[1].headers) do
			if kv.field == 'Accept' then accept = kv.value end
		end
		assertEq(accept, '*/*')
	end)
end)
