local PathMappingChoices = require 'PathMappingChoices'

describe('PathMappingChoices', function()
	it('buildRows includes built-ins, libraries, and saved-only mappings without duplicates', function()
		local model = PathMappingChoices.buildRows({
			{ name = 'Family', importPaths = { '/family/' } },
		}, {
			{ label = 'Uploaded override', immich = '/data/library/', local_ = '/Volumes/photos/immich/library/' },
			{ label = 'Custom', immich = '/custom/', local_ = '/Volumes/custom/' },
		})

		assertEq(model.libraryCount, 1)
		assertEq(model.librariesWithoutImportPaths, 0)
		assertEq(model.rows[1].importPath, '/data/library/')
		assertEq(model.rows[1].local_, '/Volumes/photos/immich/library/')

		local seen = {}
		for _, row in ipairs(model.rows) do
			seen[row.importPath] = row
		end
		assertTrue(seen['/family/'] ~= nil)
		assertTrue(seen['/custom/'] ~= nil)
		assertEq(seen['/custom/'].source, 'saved')
	end)

	it('rowsToMappings drops cleared rows and preserves row order', function()
		local rows = {
			{ label = 'A', name = 'A', importPath = '/a/' },
			{ label = 'B', name = 'B', importPath = '/b/' },
		}
		local mappings = PathMappingChoices.rowsToMappings(rows, function(row)
			if row.importPath == '/a/' then return '/Volumes/a/' end
			return ''
		end)

		assertEq(#mappings, 1)
		assertEq(mappings[1].immich, '/a/')
		assertEq(mappings[1].local_, '/Volumes/a/')
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