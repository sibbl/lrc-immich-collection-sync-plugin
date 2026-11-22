local Dialogs = require 'Dialogs'

local function makeCollection(name, isSmart)
	return {
		_name = name,
		type = function() return 'LrCollection' end,
		isSmartCollection = function() return isSmart == true end,
		getName = function(self) return self._name end,
	}
end

describe('Dialogs', function()
	it('pickSingleRegularCollection accepts one regular collection', function()
		local c = makeCollection('Trips', false)
		local picked, err = Dialogs.pickSingleRegularCollection({ c })
		assertNil(err)
		assertEq(picked, c)
	end)

	it('pickSingleRegularCollection rejects Smart Collections', function()
		local smart = makeCollection('Five Stars', true)
		local picked, err = Dialogs.pickSingleRegularCollection({ smart })
		assertNil(picked)
		assertTrue(err:match('Smart collections') ~= nil)
	end)

	it('pickSingleRegularCollection rejects multiple selected collections', function()
		local c1 = makeCollection('A', false)
		local c2 = makeCollection('B', false)
		local picked, err = Dialogs.pickSingleRegularCollection({ c1, c2 })
		assertNil(picked)
		assertTrue(err:match('Multiple collections') ~= nil)
	end)

	it('sanitizeFileName guards traversal segments, separators, and control chars', function()
		assertEq(Dialogs.sanitizeFileName('IMG_001.JPG', 'fallback.jpg'), 'IMG_001.JPG')
		assertEq(Dialogs.sanitizeFileName('..', 'asset-1.jpg'), 'asset-1.jpg')
		assertEq(Dialogs.sanitizeFileName('.', 'asset-1.jpg'), 'asset-1.jpg')
		assertEq(Dialogs.sanitizeFileName('a/b:c*d.jpg', 'fallback.jpg'), 'a_b_c_d.jpg')
		assertEq(Dialogs.sanitizeFileName('', 'asset-2.jpg'), 'asset-2.jpg')
	end)

	it('normalizeServerUrl trims whitespace, trailing slashes, and case', function()
		assertEq(Dialogs.normalizeServerUrl('  HTTPS://Immich.Local///  '), 'https://immich.local')
	end)
end)
