local PathMapper = require 'PathMapper'
local Paths = require 'util.Paths'

describe('PathMapper', function()
	it('translates Immich paths to local paths with longest prefix match', function()
		Paths._setOS('linux')
		local m = PathMapper.new{
			{ label = 'internal', immich = '/upload/',             local_ = '/nas/immich/' },
			{ label = 'ext-2024', immich = '/upload/library/2024', local_ = '/nas/ext2024' },
		}
		local p, err = m:immichToLocal('/upload/library/2024/IMG_1.jpg')
		assertNil(err)
		assertEq(p, '/nas/ext2024/IMG_1.jpg')
		p = m:immichToLocal('/upload/other/IMG_2.jpg')
		assertEq(p, '/nas/immich/other/IMG_2.jpg')
	end)

	it('reverse maps local to Immich', function()
		Paths._setOS('linux')
		local m = PathMapper.new{
			{ immich = '/upload/', local_ = '/nas/immich/' },
		}
		local p, err = m:localToImmich('/nas/immich/photos/a.jpg')
		assertNil(err)
		assertEq(p, '/upload/photos/a.jpg')
	end)

	it('returns no-mapping for unknown prefix', function()
		Paths._setOS('linux')
		local m = PathMapper.new{ { immich = '/upload/', local_ = '/nas/immich/' } }
		local p, err = m:immichToLocal('/somewhere/else/x.jpg')
		assertNil(p)
		assertEq(err, 'no-mapping')
	end)

	it('honors case-insensitive hosts', function()
		Paths._setOS('macos')
		local m = PathMapper.new{ { immich = '/Upload/', local_ = '/Volumes/NAS/' } }
		local p = m:immichToLocal('/UPLOAD/Foo.JPG')
		assertEq(p, '/Volumes/NAS/Foo.JPG')
	end)

	it('normalizes windows backslashes', function()
		Paths._setOS('windows')
		local m = PathMapper.new{ { immich = 'C:/immich/', local_ = 'D:/photos/' } }
		local p = m:immichToLocal('C:\\immich\\a\\b.jpg')
		assertEq(p, 'D:/photos/a/b.jpg')
	end)

	it('handles empty input', function()
		local m = PathMapper.new{}
		local p, err = m:immichToLocal('')
		assertNil(p); assertEq(err, 'empty-path')
	end)
end)
