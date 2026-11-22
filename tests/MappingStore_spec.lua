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

	it('isolates collection IDs across different catalogs with legacy fallback', function()
		local backend = {}
		local legacy = MappingStore.new(backend)
		legacy:set(10, { albumId = 'legacy-album' })

		local catA = MappingStore.new(backend, { catalogId = '/catalogs/A.lrcat' })
		local catB = MappingStore.new(backend, { catalogId = '/catalogs/B.lrcat' })

		-- Legacy unscoped entry is still visible until overwritten.
		assertEq(catA:get(10).albumId, 'legacy-album')

		catA:set(10, { albumId = 'album-A' })
		catB:set(10, { albumId = 'album-B' })
		assertEq(catA:get(10).albumId, 'album-A')
		assertEq(catB:get(10).albumId, 'album-B')
	end)

	it('tracks downloaded assets per catalog', function()
		local backend = {}
		local catA = MappingStore.new(backend, { catalogId = '/A.lrcat' })
		local catB = MappingStore.new(backend, { catalogId = '/B.lrcat' })
		catA:setDownloadedAsset('asset-1', '/downloads/img1.jpg')
		assertEq(catA:getDownloadedAssets()['asset-1'], '/downloads/img1.jpg')
		assertNil(catB:getDownloadedAssets()['asset-1'])
	end)

	it('remembers lastDirection per collection and preserves it across updates', function()
		local s = MappingStore.new({}, { catalogId = '/A.lrcat' })
		s:set(5, { albumId = 'alb-1', albumName = 'Old Name' })
		s:setLastDirection(5, 'lr_to_immich')
		assertEq(s:get(5).lastDirection, 'lr_to_immich')
		-- Renaming album preserves lastDirection.
		s:set(5, { albumId = 'alb-1', albumName = 'New Name' })
		assertEq(s:get(5).lastDirection, 'lr_to_immich')
		assertEq(s:get(5).albumName, 'New Name')
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
