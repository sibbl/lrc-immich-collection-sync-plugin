local PathMappingChoices = require 'PathMappingChoices'

describe('PathMappingChoices', function()
	it('buildRows includes built-in /data/ roots, libraries, and saved-only mappings without duplicates', function()
		local model = PathMappingChoices.buildRows({
			{ name = 'Family', importPaths = { '/family' } },
		}, {
			{ label = 'Uploaded override', immich = '/data/', local_ = '/Volumes/photos/immich/' },
			{ label = 'Family saved', immich = '/family/', local_ = '/Volumes/family/' },
			{ label = 'Custom', immich = '/custom/', local_ = '/Volumes/custom/' },
		})

		assertEq(model.libraryCount, 1)
		assertEq(model.librariesWithoutImportPaths, 0)
		assertEq(model.rows[1].importPath, '/data/')
		assertEq(model.rows[1].local_, '/Volumes/photos/immich/')

		local seen = {}
		local familyCount = 0
		for _, row in ipairs(model.rows) do
			seen[row.importPath] = row
			if row.importPath == '/family/' then familyCount = familyCount + 1 end
		end
		-- Trailing-slash difference (/family vs /family/) must deduplicate and retain saved local_.
		assertEq(familyCount, 1)
		assertEq(seen['/family/'].local_, '/Volumes/family/')
		assertTrue(seen['/usr/src/app/upload/'] ~= nil)
		assertTrue(seen['/custom/'] ~= nil)
		assertEq(seen['/custom/'].source, 'saved')
	end)

	it('rowsToMappings drops cleared rows, normalizes prefixes, and preserves row order', function()
		local rows = {
			{ label = 'A', name = 'A', importPath = '/a' },
			{ label = 'B', name = 'B', importPath = '/b/' },
		}
		local mappings = PathMappingChoices.rowsToMappings(rows, function(row)
			if row.importPath == '/a' then return '/Volumes/a/' end
			return ''
		end)

		assertEq(#mappings, 1)
		assertEq(mappings[1].immich, '/a/')
		assertEq(mappings[1].local_, '/Volumes/a/')
	end)

	it('upsertMapping adds new custom mapping and replaces matching normalized prefix', function()
		local list, err = PathMappingChoices.upsertMapping(
			{ { label = 'Global', immich = '/data/library/', local_ = '/Volumes/nas/' } },
			{ label = 'Alice', immich = '/data/library/alice', local_ = '/Volumes/ssd/alice' }
		)
		assertNil(err)
		assertEq(#list, 2)
		assertEq(list[2].immich, '/data/library/alice/')

		local updated, err2 = PathMappingChoices.upsertMapping(list, {
			label = 'Alice v2', immich = '/data/library/alice///', local_ = '/Volumes/ssd2/alice',
		})
		assertNil(err2)
		assertEq(#updated, 2)
		assertEq(updated[2].label, 'Alice v2')
		assertEq(updated[2].local_, '/Volumes/ssd2/alice')

		local bad, badErr = PathMappingChoices.upsertMapping(list, { immich = '/', local_ = '/x' })
		assertNil(bad)
		assertTrue(badErr ~= nil)
	end)

	it('summarizeMappings reports empty and populated states', function()
		local emptySummary = PathMappingChoices.summarizeMappings({})
		assertTrue(emptySummary:match('No path mappings configured yet') ~= nil)

		local summary = PathMappingChoices.summarizeMappings({
			{ immich = '/data/library/', local_ = '/Volumes/photos/immich/library/' },
			{ immich = '/family/', local_ = '/Volumes/family/' },
		})
		assertTrue(summary:match('2 path mappings configured') ~= nil)
		assertTrue(summary:match('/data/library/') ~= nil)
		assertTrue(summary:match('/family/') ~= nil)
	end)
end)
