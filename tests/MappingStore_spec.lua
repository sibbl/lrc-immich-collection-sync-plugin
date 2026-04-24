local MappingStore = require 'MappingStore'

describe('MappingStore', function()
	it('round-trips a mapping through a fake prefs backend', function()
		local backend = {}
		local s = MappingStore.new(backend)
		s:set(42, { albumId = 'a1', albumName = 'Holidays', serverUrl = 'https://x' })
		local got = s:get(42)
		assertEq(got.albumId, 'a1')
		assertEq(got.albumName, 'Holidays')
		assertEq(got.serverUrl, 'https://x')
		assertTrue(got.linkedAt and #got.linkedAt > 0)
	end)

	it('normalizes numeric and string collection IDs', function()
		local s = MappingStore.new({})
		s:set(7, { albumId = 'a' })
		assertEq(s:get('7').albumId, 'a')
	end)

	it('remove deletes the entry', function()
		local s = MappingStore.new({})
		s:set(1, { albumId = 'a' })
		s:remove(1)
		assertNil(s:get(1))
	end)

	it('tolerates corrupt JSON blobs', function()
		local backend = { collectionMappings = 'not json {{' }
		local s = MappingStore.new(backend)
		assertDeepEq(s:all(), {})
	end)

	it('rejects mappings without albumId', function()
		local s = MappingStore.new({})
		local ok = pcall(function() s:set(1, {}) end)
		assertEq(ok, false)
	end)
end)
