--[[
  PathMappingChoices — pure helpers for the Plugin Manager path-mapping UI.

  Builds a stable, deduplicated list of mapping rows from:
    - built-in Immich upload-library roots (both storage-template-on and off),
    - external library importPaths returned by Immich,
    - already-saved mappings that are not currently reported by Immich.
]]

local Paths = require 'Paths'

local M = {}

M.INTERNAL_LIBRARY_ROOTS = {
	{
		name = 'Immich data folder (Docker /data)',
		importPath = '/data/',
		description = 'Maps your Immich /data mount — covers all uploaded assets automatically (both /data/library/ and /data/upload/).',
	},
	{
		name = 'Immich data folder (legacy Docker)',
		importPath = '/usr/src/app/upload/',
		description = 'Maps the legacy Immich upload mount — covers both /usr/src/app/upload/library/ and /usr/src/app/upload/upload/.',
	},
}

local function nonEmpty(value)
	return value ~= nil and tostring(value):match('%S') ~= nil
end

local function trim(value)
	if value == nil then return '' end
	return (tostring(value):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Normalize an Immich prefix to canonical form (forward slashes, single
-- trailing slash). Returns nil if empty or root '/'.
function M.normalizeImmichPath(path)
	local trimmed = trim(path)
	if trimmed == '' then return nil end
	local prefix = Paths.asPrefix(trimmed)
	if not prefix or prefix == '/' then return nil end
	return prefix
end

function M.buildRows(libraries, currentMappings, internalRoots)
	internalRoots = internalRoots or M.INTERNAL_LIBRARY_ROOTS
	local rows = {}
	local seen = {}
	local currentByImmich = {}
	local libraryCount = 0
	local librariesWithoutImportPaths = 0

	for _, mapping in ipairs(currentMappings or {}) do
		local norm = M.normalizeImmichPath(mapping.immich)
		if norm then
			currentByImmich[norm] = mapping
		end
	end

	local function addRow(row)
		local norm = M.normalizeImmichPath(row.importPath)
		if not norm or seen[norm] then return end
		seen[norm] = true
		row.importPath = norm
		table.insert(rows, row)
	end

	for _, root in ipairs(internalRoots) do
		local norm = M.normalizeImmichPath(root.importPath)
		local current = norm and currentByImmich[norm] or nil
		addRow {
			name = root.name,
			label = (current and current.label) or root.name,
			importPath = root.importPath,
			local_ = (current and current.local_) or '',
			description = root.description,
			source = 'internal',
		}
	end

	for _, lib in ipairs(libraries or {}) do
		libraryCount = libraryCount + 1
		local paths = lib.importPaths or {}
		if #paths == 0 then
			librariesWithoutImportPaths = librariesWithoutImportPaths + 1
		else
			for _, path in ipairs(paths) do
				local norm = M.normalizeImmichPath(path)
				local current = norm and currentByImmich[norm] or nil
				addRow {
					name = lib.name or 'Immich library',
					label = (current and current.label) or (lib.name or ''),
					importPath = path,
					local_ = (current and current.local_) or '',
					source = 'library',
				}
			end
		end
	end

	for _, mapping in ipairs(currentMappings or {}) do
		local norm = M.normalizeImmichPath(mapping.immich)
		if norm and not seen[norm] then
			addRow {
				name = nonEmpty(mapping.label) and mapping.label or 'Saved mapping',
				label = mapping.label or '',
				importPath = norm,
				local_ = mapping.local_ or '',
				description = 'Previously saved mapping that is not currently reported by Immich.',
				source = 'saved',
			}
		end
	end

	return {
		rows = rows,
		libraryCount = libraryCount,
		librariesWithoutImportPaths = librariesWithoutImportPaths,
	}
end

function M.rowsToMappings(rows, getLocalPath)
	local mappings = {}
	local seen = {}
	for _, row in ipairs(rows or {}) do
		local localPath = trim(getLocalPath(row))
		local normImmich = M.normalizeImmichPath(row.importPath)
		if normImmich and nonEmpty(localPath) and not seen[normImmich] then
			seen[normImmich] = true
			table.insert(mappings, {
				label = row.label or row.name or '',
				immich = normImmich,
				local_ = localPath,
			})
		end
	end
	return mappings
end

-- Upsert a custom mapping into an existing mapping list (normalizing the
-- Immich prefix and replacing any existing entry with the same prefix).
-- Returns (newList, nil) or (nil, reason).
function M.upsertMapping(existingMappings, entry)
	if type(entry) ~= 'table' then return nil, 'Mapping entry required.' end
	local normImmich = M.normalizeImmichPath(entry.immich)
	if not normImmich then
		return nil, 'Please enter a valid Immich path prefix (for example /data/library/user/).'
	end
	local localPath = trim(entry.local_)
	if not nonEmpty(localPath) or Paths.asPrefix(localPath) == '/' then
		return nil, 'Please choose a valid local folder.'
	end

	local out = {}
	local replaced = false
	local label = trim(entry.label)
	if label == '' then label = 'Custom mapping' end

	for _, m in ipairs(existingMappings or {}) do
		local mNorm = M.normalizeImmichPath(m.immich)
		if mNorm == normImmich then
			table.insert(out, { label = label, immich = normImmich, local_ = localPath })
			replaced = true
		elseif mNorm then
			table.insert(out, { label = m.label or '', immich = mNorm, local_ = m.local_ or '' })
		end
	end
	if not replaced then
		table.insert(out, { label = label, immich = normImmich, local_ = localPath })
	end
	return out, nil
end

function M.summarizeMappings(mappings)
	mappings = mappings or {}
	if #mappings == 0 then
		return 'No path mappings configured yet. Click "Choose path mappings…" to assign Lightroom folders.'
	end

	local lines = {
		('%d path mapping%s configured.'):format(#mappings, #mappings == 1 and '' or 's'),
	}
	local previewCount = math.min(#mappings, 5)
	for i = 1, previewCount do
		local mapping = mappings[i]
		table.insert(lines, ('• %s → %s'):format(mapping.immich or '?', mapping.local_ or '?'))
	end
	if #mappings > previewCount then
		table.insert(lines, ('• … and %d more'):format(#mappings - previewCount))
	end
	return table.concat(lines, '\n')
end

return M
