local CatalogIndex = require 'CatalogIndex'
local Paths = require 'Paths'

local function makePhoto(path, isVirtual)
	return {
		_path = path,
		_isVirtual = isVirtual == true,
		getRawMetadata = function(self, key)
			if key == 'path' then return self._path end
			if key == 'isVirtualCopy' then return self._isVirtual end
		end,
	}
end

describe('CatalogIndex', function()
	it('indexes unique paths and looks them up', function()
		Paths._setOS('linux')
		local fold = function(p) return Paths.foldForCompare(p) end
		local idx = CatalogIndex.new({ makePhoto('/a/b.jpg'), makePhoto('/c.jpg') }, fold)
		assertEq(idx:size(), 2)
		assertTrue(idx:lookup('/a/b.jpg') ~= nil)
	end)

	it('marks duplicate masters', function()
		Paths._setOS('linux')
		local fold = function(p) return Paths.foldForCompare(p) end
		local idx = CatalogIndex.new({ makePhoto('/x.jpg'), makePhoto('/x.jpg') }, fold)
		local photo, dup = idx:lookup('/x.jpg')
		assertTrue(photo ~= nil)
		assertEq(dup, true)
	end)

	it('prefers master photo over virtual copy without marking as duplicate', function()
		Paths._setOS('linux')
		local fold = function(p) return Paths.foldForCompare(p) end
		local vcopy = makePhoto('/x.jpg', true)
		local master = makePhoto('/x.jpg', false)
		local idx = CatalogIndex.new({ vcopy, master }, fold)
		local photo, dup = idx:lookup('/x.jpg')
		assertEq(photo, master)
		assertEq(dup, false)

		local idx2 = CatalogIndex.new({ master, vcopy }, fold)
		local photo2, dup2 = idx2:lookup('/x.jpg')
		assertEq(photo2, master)
		assertEq(dup2, false)
	end)

	it('buildFromCatalog uses batchGetRawMetadata when available', function()
		Paths._setOS('linux')
		local fold = function(p) return Paths.foldForCompare(p) end
		local p1 = { id = 1 }
		local p2 = { id = 2 }
		local batchCalled = false
		local catalog = {
			getAllPhotos = function() return { p1, p2 } end,
			batchGetRawMetadata = function(self, photos, keys)
				batchCalled = true
				return {
					[p1] = { path = '/a.jpg', isVirtualCopy = true },
					[p2] = { path = '/a.jpg', isVirtualCopy = false },
				}
			end,
		}
		local idx, err = CatalogIndex.buildFromCatalog(catalog, fold)
		assertNil(err)
		assertEq(batchCalled, true)
		local photo, dup = idx:lookup('/a.jpg')
		assertEq(photo, p2)
		assertEq(dup, false)
	end)

	it('honors case folding on case-insensitive OS', function()
		Paths._setOS('macos')
		local fold = function(p) return Paths.foldForCompare(p) end
		local idx = CatalogIndex.new({ makePhoto('/Photos/IMG.JPG') }, fold)
		assertTrue(idx:lookup('/photos/img.jpg') ~= nil)
	end)
end)
