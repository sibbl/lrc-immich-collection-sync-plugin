local CatalogIndex = require 'CatalogIndex'
local Paths = require 'util.Paths'

local function makePhoto(path)
	return { getRawMetadata = function(_, key) if key == 'path' then return path end end }
end

describe('CatalogIndex', function()
	it('indexes unique paths and looks them up', function()
		Paths._setOS('linux')
		local fold = function(p) return Paths.foldForCompare(p) end
		local idx = CatalogIndex.new({ makePhoto('/a/b.jpg'), makePhoto('/c.jpg') }, fold)
		assertEq(idx:size(), 2)
		assertTrue(idx:lookup('/a/b.jpg') ~= nil)
	end)

	it('marks duplicates', function()
		Paths._setOS('linux')
		local fold = function(p) return Paths.foldForCompare(p) end
		local idx = CatalogIndex.new({ makePhoto('/x.jpg'), makePhoto('/x.jpg') }, fold)
		local photo, dup = idx:lookup('/x.jpg')
		assertTrue(photo ~= nil)
		assertEq(dup, true)
	end)

	it('honors case folding on case-insensitive OS', function()
		Paths._setOS('macos')
		local fold = function(p) return Paths.foldForCompare(p) end
		local idx = CatalogIndex.new({ makePhoto('/Photos/IMG.JPG') }, fold)
		assertTrue(idx:lookup('/photos/img.jpg') ~= nil)
	end)
end)
