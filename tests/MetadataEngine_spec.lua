local MetadataEngine = require 'MetadataEngine'

local function makePhoto(opts)
	opts = opts or {}
	local state = {
		rating = opts.rating or 0,
		pickStatus = opts.pickStatus or 0,
		caption = opts.caption or '',
		gps = opts.gps,
		keywords = opts.keywords or {},
		addedKeywords = {},
		writes = {},
	}
	return {
		_state = state,
		getRawMetadata = function(_, key)
			if key == 'rating' then return state.rating end
			if key == 'pickStatus' then return state.pickStatus end
			if key == 'caption' then return state.caption end
			if key == 'gps' then return state.gps end
			if key == 'keywords' then return state.keywords end
		end,
		getFormattedMetadata = function(_, key)
			if key == 'caption' then return state.caption end
		end,
		setRawMetadata = function(_, key, val)
			state[key] = val
			state.writes[key] = val
		end,
		addKeyword = function(_, kw)
			table.insert(state.addedKeywords, kw)
		end,
	}
end

describe('MetadataEngine.computeDiff', function()
	it('immich_to_lr fills empty LR fields by default and respects overwrite=false', function()
		local p = makePhoto({ rating = 3, caption = 'Existing caption', pickStatus = 0 })
		local asset = {
			id = 'A1',
			isFavorite = true,
			exifInfo = { rating = 5, description = 'Immich desc', latitude = 48.1, longitude = 11.5 },
			tags = { { value = 'travel' } },
			people = { { name = 'Alice' } },
		}

		local d = MetadataEngine.computeDiff{
			direction = 'immich_to_lr',
			pairs = { { photo = p, asset = asset } },
			fields = { rating = true, favorite = true, caption = true, gps = true, keywords = true },
			overwrite = false,
		}
		assertEq(#d.toUpdateLocal, 1)
		local item = d.toUpdateLocal[1]
		assertNil(item.patch.rating)       -- existing rating=3 preserved
		assertNil(item.patch.caption)      -- existing caption preserved
		assertEq(item.patch.pickStatus, 1) -- empty pickStatus filled
		assertEq(item.patch.gps.latitude, 48.1)
		assertDeepEq(item.keywords, { 'travel' })
		assertDeepEq(item.people, { 'Alice' })

		-- With overwrite=true, rating and caption are also updated.
		local d2 = MetadataEngine.computeDiff{
			direction = 'immich_to_lr',
			pairs = { { photo = p, asset = asset } },
			fields = { rating = true, favorite = true, caption = true, gps = false, keywords = false },
			overwrite = true,
		}
		assertEq(d2.toUpdateLocal[1].patch.rating, 5)
		assertEq(d2.toUpdateLocal[1].patch.caption, 'Immich desc')
	end)

	it('lr_to_immich pushes non-empty LR fields and exportable keywords', function()
		local kw1 = { getName = function() return 'Mountains' end, getAttributes = function() return { includeOnExport = true } end }
		local kwHidden = { getName = function() return 'Internal' end, getAttributes = function() return { includeOnExport = false } end }
		local p = makePhoto({
			rating = 4,
			pickStatus = 1,
			caption = 'Alps',
			gps = { latitude = 47.0, longitude = 10.0 },
			keywords = { kw1, kwHidden },
		})
		local asset = {
			id = 'A2',
			isFavorite = false,
			exifInfo = { rating = 0, description = '' },
			tags = {},
		}

		local d = MetadataEngine.computeDiff{
			direction = 'lr_to_immich',
			pairs = { { photo = p, asset = asset } },
			fields = { rating = true, favorite = true, caption = true, gps = true, keywords = true },
			overwrite = false,
		}
		assertEq(#d.toUpdateRemote, 1)
		local item = d.toUpdateRemote[1]
		assertEq(item.assetId, 'A2')
		assertEq(item.patch.rating, 4)
		assertEq(item.patch.isFavorite, true)
		assertEq(item.patch.description, 'Alps')
		assertEq(item.patch.latitude, 47.0)
		assertDeepEq(item.tags, { 'Mountains' }) -- 'Internal' excluded
	end)

	it('produces zero updates when already in sync', function()
		local p = makePhoto({ rating = 5, pickStatus = 1, caption = 'Same', keywords = { 'sunset' } })
		local asset = {
			id = 'A3',
			isFavorite = true,
			exifInfo = { rating = 5, description = 'Same' },
			tags = { { value = 'Sunset' } },
		}
		local d = MetadataEngine.computeDiff{
			direction = 'immich_to_lr',
			pairs = { { photo = p, asset = asset } },
			fields = { rating = true, favorite = true, caption = true, keywords = true },
			overwrite = true,
		}
		assertEq(d.summary.updateCount, 0)
		assertEq(d.summary.unchangedCount, 1)
	end)
end)

describe('MetadataEngine.applyDiff', function()
	it('applies local metadata and creates People hierarchy keywords', function()
		local p = makePhoto({})
		local created = {}
		local catalogMock = {
			createKeyword = function(_, name, _, _, parent)
				local kw = { name = name, parent = parent and parent.name or nil }
				table.insert(created, kw)
				return kw
			end,
		}
		local res = MetadataEngine.applyDiff({
			toUpdateLocal = {
				{
					photo = p,
					assetId = 'A1',
					patch = { rating = 4, pickStatus = 1, caption = 'Nice' },
					keywords = { 'trip' },
					people = { 'Alice' },
				},
			},
			toUpdateRemote = {},
		}, {
			catalog = catalogMock,
			withWriteAccess = function(_, fn) fn(); return 'executed' end,
		})
		assertEq(res.updatedLocal, 1)
		assertEq(#res.errors, 0)
		assertEq(p._state.writes.rating, 4)
		assertEq(p._state.writes.caption, 'Nice')
		assertEq(#p._state.addedKeywords, 2)
		assertEq(p._state.addedKeywords[1].name, 'trip')
		assertEq(p._state.addedKeywords[2].name, 'Alice')
		assertEq(p._state.addedKeywords[2].parent, 'People')
	end)

	it('applies remote metadata and upserts/assigns tags', function()
		local updatedId, updatedPatch, upsertedTags, assignedTagIds, assignedAssetId
		local apiMock = {
			updateAsset = function(_, id, patch) updatedId = id; updatedPatch = patch; return {}, nil end,
			upsertTags = function(_, tags) upsertedTags = tags; return { { id = 'T1', value = 'Alps' } }, nil end,
			assignTagsToAsset = function(_, tids, aid) assignedTagIds = tids; assignedAssetId = aid; return {}, nil end,
		}
		local res = MetadataEngine.applyDiff({
			toUpdateLocal = {},
			toUpdateRemote = {
				{ assetId = 'A9', patch = { rating = 5, isFavorite = true }, tags = { 'Alps' } },
			},
		}, { immichApi = apiMock })
		assertEq(res.updatedRemote, 1)
		assertEq(#res.errors, 0)
		assertEq(updatedId, 'A9')
		assertEq(updatedPatch.rating, 5)
		assertDeepEq(upsertedTags, { 'Alps' })
		assertDeepEq(assignedTagIds, { 'T1' })
		assertEq(assignedAssetId, 'A9')
	end)

	it('records an error when catalog write access is aborted', function()
		local res = MetadataEngine.applyDiff({
			toUpdateLocal = { { photo = makePhoto({}), assetId = 'A1', patch = { rating = 5 } } },
			toUpdateRemote = {},
		}, {
			withWriteAccess = function() return 'aborted' end,
		})
		assertEq(res.updatedLocal, 0)
		assertEq(#res.errors, 1)
		assertEq(res.errors[1].err.code, 'write_access_aborted')
	end)
end)
