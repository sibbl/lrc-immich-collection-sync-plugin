local SmartSearch = require 'SmartSearch'
local PathMapper = require 'PathMapper'
local CatalogIndex = require 'CatalogIndex'
local Paths = require 'Paths'

local function makePhoto(id, path)
	return {
		localIdentifier = id,
		_path = path,
		getRawMetadata = function(self, key) if key == 'path' then return self._path end end,
	}
end

describe('SmartSearch', function()
	it('buildCollectionName trims, collapses whitespace, replaces slashes, and caps length', function()
		assertEq(SmartSearch.buildCollectionName('  sunset / beach  '), 'sunset - beach')
		assertEq(SmartSearch.buildCollectionName('   '), 'Search')
		local long = string.rep('a', 80)
		local capped = SmartSearch.buildCollectionName(long)
		assertEq(#capped, 60)
		assertTrue(capped:sub(-3) == '...')
	end)

	it('matchResults resolves mapped and downloaded assets in relevance order without duplicates', function()
		Paths._setOS('linux')
		local mapper = PathMapper.new{ { immich = '/data/', local_ = '/nas/' } }
		local p1 = makePhoto(1, '/nas/library/a.jpg')
		local p2 = makePhoto(2, '/downloads/b.jpg')
		local idx = CatalogIndex.new({ p1, p2 }, function(p) return Paths.normalizeKey(p) end)

		local res = SmartSearch.matchResults({
			{ id = 'A1', originalPath = '/data/library/a.jpg' },
			{ id = 'A1-DUP', originalPath = '/data/library/a.jpg' }, -- same local file
			{ id = 'A2', originalPath = '/unmapped/b.jpg' },          -- matched via downloadedPaths
			{ id = 'A3', originalPath = '/unmapped/c.jpg' },          -- unmapped
			{ id = 'A4', originalPath = '/data/library/missing.jpg' },-- mapped but not in catalog
		}, mapper, idx, { A2 = '/downloads/b.jpg' })

		assertEq(res.totalResults, 5)
		assertEq(#res.matchedPhotos, 2)
		assertEq(res.matchedPhotos[1], p1)
		assertEq(res.matchedPhotos[2], p2)
		assertEq(res.unmappedCount, 1)
		assertEq(res.notInCatalogCount, 1)
	end)
end)
