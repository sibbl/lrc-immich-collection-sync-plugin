local SyncEngine = require 'SyncEngine'
local PathMapper = require 'PathMapper'
local CatalogIndex = require 'CatalogIndex'
local Paths = require 'Paths'

local function fold(p) return Paths.foldForCompare(p) end

local function makePhoto(path)
	return {
		_path = path,
		getRawMetadata = function(self, key) if key == 'path' then return self._path end end,
	}
end

local function makeEnv(albumAssets, collectionPhotos, allCatalogPhotos)
	Paths._setOS('linux')
	local mapper = PathMapper.new{
		{ immich = '/upload/', local_ = '/nas/' },
	}
	local idx = CatalogIndex.new(allCatalogPhotos, fold)
	return {
		pathMapper = mapper,
		catalogIndex = idx,
		albumAssets = albumAssets,
		collectionPhotos = collectionPhotos,
	}
end

describe('SyncEngine.computeDiff', function()
	it('immich->lr adds missing and removes extras', function()
		local p1 = makePhoto('/nas/a.jpg')
		local p2 = makePhoto('/nas/b.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' } }, -- album has A (p1)
			{ p2 },                                          -- collection has p2
			{ p1, p2 }                                       -- both exist in catalog
		)
		env.direction = 'immich_to_lr'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toAddLocal, 1)
		assertEq(d.toAddLocal[1]._path, '/nas/a.jpg')
		assertEq(#d.toRemoveLocal, 1)
		assertEq(d.toRemoveLocal[1]._path, '/nas/b.jpg')
	end)

	it('immich->lr imports mapped files that are not in the catalog yet', function()
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' } },
			{},
			{}
		)
		env.direction = 'immich_to_lr'
		env.fileExists = function(path) return path == '/nas/a.jpg' end
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toAddLocal, 0)
		assertEq(#d.toImportLocal, 1)
		assertEq(d.toImportLocal[1].assetId, 'A')
		assertEq(d.toImportLocal[1].localPath, '/nas/a.jpg')
		assertEq(d.summary.addCount, 1)
		assertEq(#d.warnings.missingLocal, 0)
	end)

	it('immich->lr warns when a mapped file is not accessible locally', function()
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' } },
			{},
			{}
		)
		env.direction = 'immich_to_lr'
		env.fileExists = function() return false end
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toImportLocal, 0)
		assertEq(#d.warnings.missingLocal, 1)
		assertEq(d.warnings.missingLocal[1].localPath, '/nas/a.jpg')
	end)

	it('lr->immich removes album assets that are not in the collection', function()
		local p1 = makePhoto('/nas/a.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' },
			  { id = 'B', originalPath = '/upload/b.jpg' } },
			{ p1 },                -- collection only has a
			{ p1 }                 -- b is not in the catalog either, still we want A kept
		)
		env.direction = 'lr_to_immich'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toRemoveRemote, 0)   -- B is unresolved (no LrPhoto), so a warning, not a delete
		assertEq(#d.toAddRemote, 0)
		assertEq(#d.warnings.missingLocal, 1)
	end)

	it('lr->immich removes album asset present in catalog but not collection', function()
		local p1 = makePhoto('/nas/a.jpg')
		local p2 = makePhoto('/nas/b.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' },
			  { id = 'B', originalPath = '/upload/b.jpg' } },
			{ p1 },                -- collection has only A
			{ p1, p2 }             -- catalog has both
		)
		env.direction = 'lr_to_immich'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toRemoveRemote, 1)
		assertEq(d.toRemoveRemote[1], 'B')
	end)

	it('idempotent: empty diff when already in sync', function()
		local p1 = makePhoto('/nas/a.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' } },
			{ p1 }, { p1 })
		env.direction = 'immich_to_lr'
		local d = SyncEngine.computeDiff(env)
		assertEq(d.summary.addCount, 0)
		assertEq(d.summary.removeCount, 0)
	end)

	it('reports unmappable Immich path as warning', function()
		local env = makeEnv(
			{ { id = 'X', originalPath = '/elsewhere/a.jpg' } }, {}, {})
		env.direction = 'immich_to_lr'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.warnings.unmappableImmich, 1)
		assertEq(d.warnings.unmappableImmich[1].assetId, 'X')
	end)

	it('reports LR photo outside mapping as warning in lr->immich', function()
		local weird = makePhoto('/tmp/weird.jpg')
		local env = makeEnv({}, { weird }, { weird })
		env.direction = 'lr_to_immich'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.warnings.unmappableLocal, 1)
	end)
end)

describe('SyncEngine.applyDiff', function()
	it('calls immich and LR collection with right inputs', function()
		local added, removed
		local apiMock = {
			addAssetsToAlbum = function(self, id, ids) added = { id, ids }; return {}, nil end,
			removeAssetsFromAlbum = function(self, id, ids) removed = { id, ids }; return {}, nil end,
		}
		local collectionCalls = { add = {}, rem = {} }
		local collectionMock = {
			addPhotos = function(self, ps) collectionCalls.add = ps end,
			removePhotos = function(self, ps) collectionCalls.rem = ps end,
		}
		local wwaCalled = false
		local result = SyncEngine.applyDiff({
			toAddRemote = { 'X' }, toRemoveRemote = { 'Y' },
			toAddLocal = { 'p1' }, toRemoveLocal = { 'p2' },
			warnings = {}, summary = {},
		}, {
			immichApi = apiMock,
			albumId = 'ALB',
			collection = collectionMock,
			withWriteAccess = function(_, fn) wwaCalled = true; fn() end,
		})
		assertEq(result.addedRemote, 1)
		assertEq(result.removedRemote, 1)
		assertEq(result.addedLocal, 1)
		assertEq(result.removedLocal, 1)
		assertEq(added[1], 'ALB'); assertEq(added[2][1], 'X')
		assertEq(removed[1], 'ALB'); assertEq(removed[2][1], 'Y')
		assertEq(wwaCalled, true)
	end)

	it('records API errors without raising', function()
		local apiMock = {
			addAssetsToAlbum = function() return nil, { code='http_500', message='boom' } end,
			removeAssetsFromAlbum = function() return {}, nil end,
		}
		local result = SyncEngine.applyDiff({
			toAddRemote = { 'X' }, toRemoveRemote = {},
			toAddLocal = {}, toRemoveLocal = {},
		}, {
			immichApi = apiMock, albumId = 'A',
			collection = {}, withWriteAccess = function(_, fn) fn() end,
		})
		assertEq(#result.errors, 1)
		assertEq(result.errors[1].op, 'remote_add')
	end)

	it('imports files into the LR catalog before adding them to the collection', function()
		local importedPhoto = makePhoto('/nas/a.jpg')
		local importedPaths
		local collectionCalls = { add = {} }
		local collectionMock = {
			addPhotos = function(self, ps) collectionCalls.add = ps end,
			removePhotos = function() end,
		}
		local result = SyncEngine.applyDiff({
			toAddRemote = {}, toRemoveRemote = {},
			toAddLocal = {}, toImportLocal = { { assetId = 'A', localPath = '/nas/a.jpg' } },
			toRemoveLocal = {},
		}, {
			immichApi = {}, albumId = 'ALB', collection = collectionMock,
			fileExists = function(path) return path == '/nas/a.jpg' end,
			importPhotos = function(paths) importedPaths = paths; return { importedPhoto } end,
			withWriteAccess = function(_, fn) fn() end,
		})
		assertEq(importedPaths[1], '/nas/a.jpg')
		assertEq(result.importedLocal, 1)
		assertEq(result.addedLocal, 1)
		assertEq(collectionCalls.add[1], importedPhoto)
	end)

	it('downloads unmapped assets, saves them, imports them, then adds to the collection', function()
		local importedPhoto = makePhoto('/downloads/a.jpg')
		local downloadedAssetId
		local savedEntry, savedBytes
		local importedPaths
		local collectionCalls = { add = {} }
		local collectionMock = {
			addPhotos = function(self, ps) collectionCalls.add = ps end,
			removePhotos = function() end,
		}
		local result = SyncEngine.applyDiff({
			toAddRemote = {}, toRemoveRemote = {},
			toAddLocal = {}, toImportLocal = {},
			toDownloadLocal = { { assetId = 'A', fileName = 'a.jpg', originalPath = '/data/library/u/a.jpg' } },
			toRemoveLocal = {},
		}, {
			immichApi = {}, albumId = 'ALB', collection = collectionMock,
			downloadAsset = function(assetId) downloadedAssetId = assetId; return 'BYTES', nil end,
			saveDownloadedAsset = function(entry, bytes)
				savedEntry = entry; savedBytes = bytes; return '/downloads/a.jpg', nil
			end,
			fileExists = function(path) return path == '/downloads/a.jpg' end,
			importPhotos = function(paths) importedPaths = paths; return { importedPhoto } end,
			withWriteAccess = function(_, fn) fn() end,
		})
		assertEq(downloadedAssetId, 'A')
		assertEq(savedEntry.fileName, 'a.jpg')
		assertEq(savedBytes, 'BYTES')
		assertEq(importedPaths[1], '/downloads/a.jpg')
		assertEq(result.downloadedLocal, 1)
		assertEq(result.importedLocal, 1)
		assertEq(result.addedLocal, 1)
		assertEq(collectionCalls.add[1], importedPhoto)
	end)
end)
