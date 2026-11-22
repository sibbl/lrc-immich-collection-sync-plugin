local Paths = require 'Paths'

describe('Paths', function()
	it('loads when Lightroom hides package/io globals', function()
		local oldPackage = package
		local oldIo = io
		local oldImport = import
		package = nil
		io = nil
		import = nil
		local ok, loaded = pcall(dofile, 'src/Paths.lua')
		package = oldPackage
		io = oldIo
		import = oldImport
		assertEq(ok, true)
		assertEq(type(loaded.normalizeSeparators), 'function')
	end)

	it('normalizes backslashes', function()
		assertEq(Paths.normalizeSeparators('a\\b\\c'), 'a/b/c')
	end)

	it('strips trailing slashes', function()
		assertEq(Paths.stripTrailingSlash('/a/'), '/a')
		assertEq(Paths.stripTrailingSlash('/a///'), '/a')
		assertEq(Paths.stripTrailingSlash('/'), '/')
	end)

	it('asPrefix ends with exactly one slash and handles nil/empty/multi-slash', function()
		assertEq(Paths.asPrefix('/a/b'), '/a/b/')
		assertEq(Paths.asPrefix('/a/b/'), '/a/b/')
		assertEq(Paths.asPrefix('/a/b///'), '/a/b/')
		assertEq(Paths.asPrefix('C:\\x'), 'C:/x/')
		assertNil(Paths.asPrefix(nil))
		assertNil(Paths.asPrefix(''))
	end)

	it('normalizeKey combines separator normalization and case folding', function()
		Paths._setOS('windows')
		assertEq(Paths.normalizeKey('D:\\Photos\\IMG.JPG'), 'd:/photos/img.jpg')
		Paths._setOS('linux')
		assertEq(Paths.normalizeKey('/Photos/IMG.JPG'), '/Photos/IMG.JPG')
	end)

	it('startsWith respects case sensitivity on linux', function()
		Paths._setOS('linux')
		assertEq(Paths.startsWith('/Foo/bar', '/foo/'), false)
		assertEq(Paths.startsWith('/foo/bar', '/foo/'), true)
	end)

	it('startsWith is case-insensitive on mac', function()
		Paths._setOS('macos')
		assertEq(Paths.startsWith('/Foo/bar', '/foo/'), true)
	end)
end)
