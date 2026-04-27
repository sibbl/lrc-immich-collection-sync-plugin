local CatalogImport = require 'CatalogImport'

describe('CatalogImport', function()
	it('uses catalog:addPhotos when Lightroom exposes it', function()
		local calledWith
		local photo = { id = 'P1' }
		local catalog = {
			addPhotos = function(self, paths)
				calledWith = paths
				return { photo }
			end,
		}

		local result = CatalogImport.importPhotos(catalog, { '/a.jpg' })
		assertEq(calledWith[1], '/a.jpg')
		assertEq(result[1], photo)
	end)

	it('falls back to catalog:addPhoto one file at a time', function()
		local calls = {}
		local catalog = {
			addPhoto = function(self, path)
				table.insert(calls, path)
				return { path = path }
			end,
		}

		local result = CatalogImport.importPhotos(catalog, { '/a.jpg', '/b.jpg' })
		assertDeepEq(calls, { '/a.jpg', '/b.jpg' })
		assertEq(#result, 2)
		assertEq(result[1].path, '/a.jpg')
		assertEq(result[2].path, '/b.jpg')
	end)

	it('raises a clear error when no catalog import API exists', function()
		local ok, err = pcall(function()
			CatalogImport.importPhotos({}, { '/a.jpg' })
		end)
		assertEq(ok, false)
		assertTrue(tostring(err):match('neither addPhotos') ~= nil)
	end)
end)