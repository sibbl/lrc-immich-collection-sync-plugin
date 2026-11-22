--[[
  MetadataEngine — pure diff computation + injectable apply step for two-way
  metadata sync between Lightroom photos and Immich assets.

  Supported fields (all independently toggleable):
    - rating    : 1..5 stars (LR `rating` <-> Immich `exifInfo.rating` / PUT `rating`)
    - favorite  : LR pick flag (`pickStatus == 1`) <-> Immich `isFavorite`
    - caption   : LR `caption` <-> Immich `exifInfo.description` / PUT `description`
    - gps       : LR `gps` (`{latitude, longitude}`) <-> Immich `exifInfo.latitude/longitude`
    - keywords  : additive:
                    * LR -> Immich: LR keywords -> Immich tags (PUT /tags + /tags/assets)
                    * Immich -> LR: Immich tags -> LR keywords + Immich people -> "People/<name>"

  Conflict policy:
    - Explicit direction per run ('immich_to_lr' | 'lr_to_immich').
    - `overwrite = false` (default): only fill empty target fields; never
      clobber existing non-empty values.
    - Empty source values NEVER clear a non-empty target field.
]]

local Errors = require 'Errors'

local M = {}

local function trim(s)
	if s == nil then return '' end
	return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function isNonEmpty(s)
	return type(s) == 'string' and trim(s) ~= ''
end

local function approxEqual(a, b)
	if type(a) ~= 'number' or type(b) ~= 'number' then return false end
	return math.abs(a - b) < 1e-6
end

local function collectLrKeywords(photo)
	local names = {}
	local seen = {}
	local kwObjs = photo:getRawMetadata('keywords')
	if type(kwObjs) == 'table' then
		for _, kw in ipairs(kwObjs) do
			if type(kw) == 'table' and type(kw.getName) == 'function' then
				local include = true
				if type(kw.getAttributes) == 'function' then
					local attrs = kw:getAttributes()
					if type(attrs) == 'table' and attrs.includeOnExport == false then
						include = false
					end
				end
				if include then
					local name = trim(kw:getName())
					if name ~= '' and not seen[name:lower()] then
						seen[name:lower()] = true
						table.insert(names, name)
					end
				end
			elseif type(kw) == 'string' then
				local name = trim(kw)
				if name ~= '' and not seen[name:lower()] then
					seen[name:lower()] = true
					table.insert(names, name)
				end
			end
		end
	end
	table.sort(names)
	return names, seen
end

local function collectImmichTags(asset)
	local names = {}
	local seen = {}
	for _, tag in ipairs(asset.tags or {}) do
		local raw = type(tag) == 'table' and (tag.value or tag.name) or tag
		local name = trim(raw)
		if name ~= '' and not seen[name:lower()] then
			seen[name:lower()] = true
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names, seen
end

local function collectImmichPeople(asset)
	local names = {}
	local seen = {}
	for _, person in ipairs(asset.people or {}) do
		if type(person) == 'table' and isNonEmpty(person.name) then
			local name = trim(person.name)
			if not seen[name:lower()] then
				seen[name:lower()] = true
				table.insert(names, name)
			end
		end
	end
	table.sort(names)
	return names
end

-- Compute a metadata diff for already-matched `{ photo = LrPhoto, asset = ImmichAsset }` pairs.
function M.computeDiff(opts)
	assert(opts.direction == 'immich_to_lr' or opts.direction == 'lr_to_immich',
		'direction must be immich_to_lr or lr_to_immich')

	local fields = opts.fields or {}
	local overwrite = opts.overwrite == true
	local pairsList = opts.pairs or {}

	local toUpdateLocal = {}
	local toUpdateRemote = {}
	local fieldCounts = { rating = 0, favorite = 0, caption = 0, gps = 0, keywords = 0 }
	local unchangedCount = 0

	for _, pair in ipairs(pairsList) do
		local photo = pair.photo
		local asset = pair.asset
		if photo and asset and asset.id then
			local exif = type(asset.exifInfo) == 'table' and asset.exifInfo or {}

			local lrRating = photo:getRawMetadata('rating')
			local lrPick = photo:getRawMetadata('pickStatus') or 0
			local lrCaption = (type(photo.getFormattedMetadata) == 'function' and photo:getFormattedMetadata('caption'))
				or photo:getRawMetadata('caption')
				or ''
			local lrGps = photo:getRawMetadata('gps')
			local lrKeywords, lrKeywordSet = collectLrKeywords(photo)

			local imRating = (type(exif.rating) == 'number' and exif.rating >= 1) and exif.rating or nil
			local imFavorite = asset.isFavorite == true
			local imCaption = isNonEmpty(exif.description) and trim(exif.description) or ''
			local imLat = type(exif.latitude) == 'number' and exif.latitude or nil
			local imLon = type(exif.longitude) == 'number' and exif.longitude or nil
			local imTags, imTagSet = collectImmichTags(asset)
			local imPeople = collectImmichPeople(asset)

			if opts.direction == 'immich_to_lr' then
				local patch = {}
				local keywordsToAdd = {}
				local peopleToAdd = {}
				local changed = false

				if fields.rating and imRating then
					local lrHasRating = type(lrRating) == 'number' and lrRating >= 1
					if (overwrite or not lrHasRating) and lrRating ~= imRating then
						patch.rating = imRating
						fieldCounts.rating = fieldCounts.rating + 1
						changed = true
					end
				end

				if fields.favorite and imFavorite then
					if (overwrite or lrPick == 0) and lrPick ~= 1 then
						patch.pickStatus = 1
						fieldCounts.favorite = fieldCounts.favorite + 1
						changed = true
					end
				end

				if fields.caption and imCaption ~= '' then
					local lrTrim = trim(lrCaption)
					if (overwrite or lrTrim == '') and lrTrim ~= imCaption then
						patch.caption = imCaption
						fieldCounts.caption = fieldCounts.caption + 1
						changed = true
					end
				end

				if fields.gps and imLat and imLon then
					local lrHasGps = type(lrGps) == 'table'
						and type(lrGps.latitude) == 'number'
						and type(lrGps.longitude) == 'number'
					local sameGps = lrHasGps
						and approxEqual(lrGps.latitude, imLat)
						and approxEqual(lrGps.longitude, imLon)
					if (overwrite or not lrHasGps) and not sameGps then
						patch.gps = { latitude = imLat, longitude = imLon }
						fieldCounts.gps = fieldCounts.gps + 1
						changed = true
					end
				end

				if fields.keywords then
					for _, tag in ipairs(imTags) do
						if not lrKeywordSet[tag:lower()] then
							table.insert(keywordsToAdd, tag)
						end
					end
					for _, person in ipairs(imPeople) do
						if not lrKeywordSet[person:lower()] then
							table.insert(peopleToAdd, person)
						end
					end
					if #keywordsToAdd > 0 or #peopleToAdd > 0 then
						fieldCounts.keywords = fieldCounts.keywords + 1
						changed = true
					end
				end

				if changed then
					table.insert(toUpdateLocal, {
						photo = photo,
						assetId = asset.id,
						patch = patch,
						keywords = keywordsToAdd,
						people = peopleToAdd,
					})
				else
					unchangedCount = unchangedCount + 1
				end
			else -- lr_to_immich
				local patch = {}
				local tagsToAdd = {}
				local changed = false

				if fields.rating and type(lrRating) == 'number' and lrRating >= 1 then
					if (overwrite or imRating == nil) and imRating ~= lrRating then
						patch.rating = lrRating
						fieldCounts.rating = fieldCounts.rating + 1
						changed = true
					end
				end

				if fields.favorite and lrPick == 1 then
					if not imFavorite then
						patch.isFavorite = true
						fieldCounts.favorite = fieldCounts.favorite + 1
						changed = true
					end
				end

				if fields.caption then
					local lrTrim = trim(lrCaption)
					if lrTrim ~= '' and (overwrite or imCaption == '') and imCaption ~= lrTrim then
						patch.description = lrTrim
						fieldCounts.caption = fieldCounts.caption + 1
						changed = true
					end
				end

				if fields.gps and type(lrGps) == 'table'
					and type(lrGps.latitude) == 'number'
					and type(lrGps.longitude) == 'number' then
					local imHasGps = imLat ~= nil and imLon ~= nil
					local sameGps = imHasGps
						and approxEqual(imLat, lrGps.latitude)
						and approxEqual(imLon, lrGps.longitude)
					if (overwrite or not imHasGps) and not sameGps then
						patch.latitude = lrGps.latitude
						patch.longitude = lrGps.longitude
						fieldCounts.gps = fieldCounts.gps + 1
						changed = true
					end
				end

				if fields.keywords then
					for _, kw in ipairs(lrKeywords) do
						if not imTagSet[kw:lower()] then
							table.insert(tagsToAdd, kw)
						end
					end
					if #tagsToAdd > 0 then
						fieldCounts.keywords = fieldCounts.keywords + 1
						changed = true
					end
				end

				if changed then
					table.insert(toUpdateRemote, {
						assetId = asset.id,
						photo = photo,
						patch = patch,
						tags = tagsToAdd,
					})
				else
					unchangedCount = unchangedCount + 1
				end
			end
		end
	end

	return {
		direction = opts.direction,
		toUpdateLocal = toUpdateLocal,
		toUpdateRemote = toUpdateRemote,
		summary = {
			matchedPairs = #pairsList,
			updateCount = #toUpdateLocal + #toUpdateRemote,
			unchangedCount = unchangedCount,
			fieldCounts = fieldCounts,
		},
	}
end

-- Apply a computed metadata diff.
--
-- deps:
--   immichApi        ImmichAPI instance (required for lr_to_immich)
--   catalog          LrCatalog (required for immich_to_lr keywords)
--   withWriteAccess  function(name, fn) -> status (required for immich_to_lr)
--   yieldSafePcall   optional function(fn, ...)
--   progress         optional { setCaption, setPortionComplete, isCanceled }
function M.applyDiff(diff, deps)
	deps = deps or {}
	local yieldSafePcall = deps.yieldSafePcall or pcall
	local progress = deps.progress

	local result = {
		updatedLocal = 0,
		updatedRemote = 0,
		canceled = false,
		errors = {},
	}

	if #(diff.toUpdateLocal or {}) > 0 then
		assert(deps.withWriteAccess, 'withWriteAccess required')
		if progress and progress.setCaption then
			progress.setCaption(('Updating %d Lightroom photo(s)…'):format(#diff.toUpdateLocal))
		end

		local peopleParent = nil
		local keywordCache = {}
		local peopleCache = {}

		local writeStatus = deps.withWriteAccess('Immich metadata sync', function()
			local total = #diff.toUpdateLocal
			for i, item in ipairs(diff.toUpdateLocal) do
				if progress and progress.isCanceled and progress.isCanceled() then
					result.canceled = true
					return
				end
				if progress and progress.setPortionComplete then
					progress.setPortionComplete(i - 1, total)
				end

				local ok, err = yieldSafePcall(function()
					local photo = item.photo
					for k, v in pairs(item.patch or {}) do
						photo:setRawMetadata(k, v)
					end
					if deps.catalog then
						for _, kwName in ipairs(item.keywords or {}) do
							local kw = keywordCache[kwName]
							if not kw then
								kw = deps.catalog:createKeyword(kwName, {}, true, nil, true)
								keywordCache[kwName] = kw
							end
							if kw then photo:addKeyword(kw) end
						end
						if #(item.people or {}) > 0 then
							if peopleParent == nil then
								peopleParent = deps.catalog:createKeyword('People', {}, false, nil, true)
							end
							if peopleParent then
								for _, personName in ipairs(item.people) do
									local pkw = peopleCache[personName]
									if not pkw then
										pkw = deps.catalog:createKeyword(personName, {}, true, peopleParent, true)
										peopleCache[personName] = pkw
									end
									if pkw then photo:addKeyword(pkw) end
								end
							end
						end
					end
				end)
				if ok then
					result.updatedLocal = result.updatedLocal + 1
				else
					table.insert(result.errors, {
						op = 'metadata_local',
						err = Errors.make('metadata_local_failed', tostring(err), item.assetId),
					})
				end

				if progress and progress.setPortionComplete then
					progress.setPortionComplete(i, total)
				end
			end
		end)

		if writeStatus == 'aborted' or writeStatus == false then
			table.insert(result.errors, {
				op = 'metadata_local',
				err = Errors.make('write_access_aborted',
					'Lightroom could not acquire catalog write access (catalog busy). Please retry.'),
			})
		end
	end

	if #(diff.toUpdateRemote or {}) > 0 then
		assert(deps.immichApi, 'immichApi required')
		local total = #diff.toUpdateRemote
		for i, item in ipairs(diff.toUpdateRemote) do
			if progress and progress.isCanceled and progress.isCanceled() then
				result.canceled = true
				break
			end
			if progress and progress.setCaption then
				progress.setCaption(('Updating Immich metadata (%d/%d)…'):format(i, total))
			end
			if progress and progress.setPortionComplete then
				progress.setPortionComplete(i - 1, total)
			end

			local itemOk = true
			if next(item.patch or {}) ~= nil then
				local _, err = deps.immichApi:updateAsset(item.assetId, item.patch)
				if err then
					itemOk = false
					table.insert(result.errors, { op = 'metadata_remote', err = err })
				end
			end

			if #(item.tags or {}) > 0 then
				local tags, tagErr = deps.immichApi:upsertTags(item.tags)
				if tagErr then
					itemOk = false
					table.insert(result.errors, { op = 'metadata_remote_tags', err = tagErr })
				else
					local tagIds = {}
					for _, t in ipairs(tags or {}) do
						if t.id then table.insert(tagIds, t.id) end
					end
					if #tagIds > 0 then
						local _, assignErr = deps.immichApi:assignTagsToAsset(tagIds, item.assetId)
						if assignErr then
							itemOk = false
							table.insert(result.errors, { op = 'metadata_remote_tags', err = assignErr })
						end
					end
				end
			end

			if itemOk then
				result.updatedRemote = result.updatedRemote + 1
			end

			if progress and progress.setPortionComplete then
				progress.setPortionComplete(i, total)
			end
		end
	end

	return result
end

return M
