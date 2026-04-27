--[[
  PathMappingChoices — pure helpers for the Plugin Manager path-mapping UI.

  Builds a stable, deduplicated list of mapping rows from:
    - built-in Immich upload-library roots,
    - external library importPaths returned by Immich,
    - already-saved mappings that are not currently reported by Immich.
]]

local M = {}

M.INTERNAL_LIBRARY_ROOTS = {
	{
		name = 'Uploaded assets (all users, Docker /data)',
		importPath = '/data/library/',
		description = 'Maps Immich default uploaded/user libraries for current Docker installs.',
	},
	{
		name = 'Uploaded assets (all users, legacy Docker)',
		importPath = '/usr/src/app/upload/library/',
		description = 'Maps Immich default uploaded/user libraries for older installs.',
	},
}

local function nonEmpty(value)
	return value ~= nil and tostring(value):match('%S') ~= nil
end

function M.buildRows(libraries, currentMappings, internalRoots)
	internalRoots = internalRoots or M.INTERNAL_LIBRARY_ROOTS
	local rows = {}
	local seen = {}
	local currentByImmich = {}
	local libraryCount = 0
	local librariesWithoutImportPaths = 0

	for _, mapping in ipairs(currentMappings or {}) do
		if mapping.immich and mapping.immich ~= '' then
			currentByImmich[mapping.immich] = mapping
		end
	end

	local function addRow(row)
		if not row.importPath or row.importPath == '' or seen[row.importPath] then return end
		seen[row.importPath] = true
		table.insert(rows, row)
	end

	for _, root in ipairs(internalRoots) do
		local current = currentByImmich[root.importPath]
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
				local current = currentByImmich[path]
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
		if nonEmpty(mapping.immich) and not seen[mapping.immich] then
			addRow {
				name = nonEmpty(mapping.label) and mapping.label or 'Saved mapping',
				label = mapping.label or '',
				importPath = mapping.immich,
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
	for _, row in ipairs(rows or {}) do
		local localPath = getLocalPath(row)
		if row.importPath and nonEmpty(localPath) then
			table.insert(mappings, {
				label = row.label or row.name or '',
				immich = row.importPath,
				local_ = localPath,
			})
		end
	end
	return mappings
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