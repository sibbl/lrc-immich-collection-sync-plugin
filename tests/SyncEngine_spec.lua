local SyncEngine = require 'SyncEngine'
local PathMapper = require 'PathMapper'
local CatalogIndex = require 'CatalogIndex'
local Paths = require 'Paths'

local function fold(p) return Paths.normalizeKey(p) end

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

local function makeEnv(albumAssets, collectionPhotos, allCatalogPhotos, osName, mappings)
	Paths._setOS(osName or 'linux')
	local mapper = PathMapper.new(mappings or {
		{ immich = '/upload/', local_ = '/nas/' },
	})
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
			{ { id = 'A', originalPath = '/upload/a.jpg' } },
			{ p2 },
			{ p1, p2 }
		)
		env.direction = 'immich_to_lr'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toAddLocal, 1)
		assertEq(d.toAddLocal[1]._path, '/nas/a.jpg')
		assertEq(#d.toRemoveLocal, 1)
		assertEq(d.toRemoveLocal[1]._path, '/nas/b.jpg')
	end)

	it('matches Windows backslash Lightroom paths against PathMapper forward slashes', function()
		local p1 = makePhoto('D:\\photos\\2024\\IMG_1.JPG')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/data/library/2024/img_1.jpg' } },
			{ p1 },
			{ p1 },
			'windows',
			{ { immich = '/data/library/', local_ = 'D:\\photos\\' } }
		)
		env.direction = 'lr_to_immich'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toRemoveRemote, 0)
		assertEq(#d.toAddRemote, 0)
		assertEq(d.summary.warningCount, 0)

		env.direction = 'immich_to_lr'
		local d2 = SyncEngine.computeDiff(env)
		assertEq(#d2.toAddLocal, 0)
		assertEq(#d2.toRemoveLocal, 0)
		assertEq(d2.summary.warningCount, 0)
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

	it('immich->lr matches previously downloaded unmapped assets without re-downloading', function()
		local dlPhoto = makePhoto('/downloads/IMG_99.jpg')
		local env = makeEnv(
			{ { id = 'UNMAP-1', originalPath = '/other/IMG_99.jpg' } },
			{ dlPhoto },
			{ dlPhoto }
		)
		env.direction = 'immich_to_lr'
		env.downloadedPaths = { ['UNMAP-1'] = '/downloads/IMG_99.jpg' }
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.warnings.unmappableImmich, 0)
		assertEq(#d.warnings.unmappableLocal, 0)
		assertEq(d.summary.addCount, 0)
		assertEq(d.summary.removeCount, 0)
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

	it('lr->immich resolves collection photos via resolveRemoteAsset and populates toAddRemote', function()
		local p1 = makePhoto('/nas/a.jpg')
		local p2 = makePhoto('/nas/b.jpg')
		local p3 = makePhoto('/nas/c.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' } },
			{ p1, p2, p3 },
			{ p1, p2, p3 }
		)
		env.direction = 'lr_to_immich'
		env.resolveRemoteAsset = function(immichPath)
			if immichPath == '/upload/b.jpg' then
				return { id = 'B', originalPath = '/upload/b.jpg' }, nil
			end
			return nil, nil
		end
		local d = SyncEngine.computeDiff(env)
		assertDeepEq(d.toAddRemote, { 'B' })
		assertEq(#d.toRemoveRemote, 0)
		assertEq(#d.warnings.missingRemote, 1)
		assertEq(d.warnings.missingRemote[1].immichPath, '/upload/c.jpg')
		assertEq(d.summary.addCount, 1)
	end)

	it('lr->immich keeps unresolved album asset as missingLocal warning rather than deleting', function()
		local p1 = makePhoto('/nas/a.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' },
			  { id = 'B', originalPath = '/upload/b.jpg' } },
			{ p1 },
			{ p1 }
		)
		env.direction = 'lr_to_immich'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toRemoveRemote, 0)
		assertEq(#d.toAddRemote, 0)
		assertEq(#d.warnings.missingLocal, 1)
	end)

	it('lr->immich removes album asset present in catalog but not collection', function()
		local p1 = makePhoto('/nas/a.jpg')
		local p2 = makePhoto('/nas/b.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' },
			  { id = 'B', originalPath = '/upload/b.jpg' } },
			{ p1 },
			{ p1, p2 }
		)
		env.direction = 'lr_to_immich'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.toRemoveRemote, 1)
		assertEq(d.toRemoveRemote[1], 'B')
	end)

	it('surfaces duplicateLocal warning when multiple catalog masters share a path', function()
		local p1 = makePhoto('/nas/a.jpg')
		local p1dup = makePhoto('/nas/a.jpg')
		local env = makeEnv(
			{ { id = 'A', originalPath = '/upload/a.jpg' } },
			{},
			{ p1, p1dup }
		)
		env.direction = 'immich_to_lr'
		local d = SyncEngine.computeDiff(env)
		assertEq(#d.warnings.duplicateLocal, 1)
		assertEq(d.warnings.duplicateLocal[1].localPath, '/nas/a.jpg')
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
			addAssetsToAlbum = function(self, id, ids) added = { id, ids }; return { added = #ids, failed = {} }, nil end,
			removeAssetsFromAlbum = function(self, id, ids) removed = { id, ids }; return { removed = #ids, failed = {} }, nil end,
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
			withWriteAccess = function(_, fn) wwaCalled = true; fn(); return 'executed' end,
		})
		assertEq(result.addedRemote, 1)
		assertEq(result.removedRemote, 1)
		assertEq(result.addedLocal, 1)
		assertEq(result.removedLocal, 1)
		assertEq(added[1], 'ALB'); assertEq(added[2][1], 'X')
		assertEq(removed[1], 'ALB'); assertEq(removed[2][1], 'Y')
		assertEq(collectionCalls.add[1], 'p1')
		assertEq(collectionCalls.rem[1], 'p2')
		assertEq(wwaCalled, true)
	end)

	it('records API errors and per-item failures without raising', function()
		local apiMock = {
			addAssetsToAlbum = function() return nil, { code='http_500', message='boom' } end,
			removeAssetsFromAlbum = function() return { removed = 1, failed = { { id = 'Y2', error = 'not_found' } } }, nil end,
		}
		local result = SyncEngine.applyDiff({
			toAddRemote = { 'X' }, toRemoveRemote = { 'Y1', 'Y2' },
			toAddLocal = {}, toRemoveLocal = {},
		}, {
			immichApi = apiMock, albumId = 'A',
			collection = {}, withWriteAccess = function(_, fn) fn() end,
		})
		assertEq(result.removedRemote, 1)
		assertEq(#result.errors, 2)
		assertEq(result.errors[1].op, 'remote_remove')
		assertEq(result.errors[2].op, 'remote_add')
	end)

	it('records an error when catalog write access is aborted', function()
		local result = SyncEngine.applyDiff({
			toAddRemote = {}, toRemoveRemote = {},
			toAddLocal = { 'p1' }, toRemoveLocal = {},
		}, {
			immichApi = {}, albumId = 'A',
			collection = { addPhotos = function() end },
			withWriteAccess = function() return 'aborted' end,
		})
		assertEq(result.addedLocal, 0)
		assertEq(#result.errors, 1)
		assertEq(result.errors[1].op, 'local_write')
		assertEq(result.errors[1].err.code, 'write_access_aborted')
	end)

	it('imports files into the LR catalog before adding them to the collection and records partial failures', function()
		local importedPhoto = makePhoto('/nas/a.jpg')
		local importedPaths
		local usedYieldSafePcall = false
		local insideWriteAccess = false
		local collectionCalls = { add = {} }
		local collectionMock = {
			addPhotos = function(self, ps) collectionCalls.add = ps end,
			removePhotos = function() end,
		}
		local result = SyncEngine.applyDiff({
			toAddRemote = {}, toRemoveRemote = {},
			toAddLocal = {},
			toImportLocal = {
				{ assetId = 'A', localPath = '/nas/a.jpg' },
				{ assetId = 'B', localPath = '/nas/bad.mov' },
			},
			toRemoveLocal = {},
		}, {
			immichApi = {}, albumId = 'ALB', collection = collectionMock,
			fileExists = function() return true end,
			importPhotos = function(paths)
				assertEq(insideWriteAccess, true)
				importedPaths = paths
				return { importedPhoto }, { { path = '/nas/bad.mov', err = 'unsupported' } }
			end,
			yieldSafePcall = function(fn, ...)
				usedYieldSafePcall = true
				return pcall(fn, ...)
			end,
			withWriteAccess = function(_, fn)
				insideWriteAccess = true
				fn()
				insideWriteAccess = false
				return 'executed'
			end,
		})
		assertEq(importedPaths[1], '/nas/a.jpg')
		assertEq(usedYieldSafePcall, true)
		assertEq(result.importedLocal, 1)
		assertEq(result.addedLocal, 1)
		assertEq(collectionCalls.add[1], importedPhoto)
		assertEq(#result.errors, 1)
		assertEq(result.errors[1].op, 'local_import')
	end)

	it('downloads unmapped assets, tracks them via onAssetDownloaded, imports, then adds to collection', function()
		local importedPhoto = makePhoto('/downloads/a.jpg')
		local downloadedAssetId, trackedId, trackedPath
		local savedEntry, savedBytes
		local importedPaths
		local progressCalls = 0
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
			onAssetDownloaded = function(id, path) trackedId = id; trackedPath = path end,
			fileExists = function(path) return path == '/downloads/a.jpg' end,
			importPhotos = function(paths) importedPaths = paths; return { importedPhoto } end,
			withWriteAccess = function(_, fn) fn(); return 'executed' end,
			progress = {
				setCaption = function() end,
				setPortionComplete = function() progressCalls = progressCalls + 1 end,
				isCanceled = function() return false end,
			},
		})
		assertEq(downloadedAssetId, 'A')
		assertEq(trackedId, 'A')
		assertEq(trackedPath, '/downloads/a.jpg')
		assertEq(savedEntry.fileName, 'a.jpg')
		assertEq(savedBytes, 'BYTES')
		assertEq(importedPaths[1], '/downloads/a.jpg')
		assertEq(result.downloadedLocal, 1)
		assertEq(result.importedLocal, 1)
		assertEq(result.addedLocal, 1)
		assertEq(collectionCalls.add[1], importedPhoto)
		assertTrue(progressCalls >= 2)
	end)
end)
