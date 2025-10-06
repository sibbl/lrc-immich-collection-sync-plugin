--[[
SyncServiceProvider.lua - Provides path-based synchronization with Immich albums

This module provides functionality to:
1. Configure storage path mappings between Immich and local file system
2. Link Lightroom collections to Immich albums without downloading photos
3. Synchronize collections based on file paths
4. Handle missing files with error reporting

--]]

local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrBinding = import 'LrBinding'
local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrLogger = import 'LrLogger'

require "ImmichAPI"
require "util"

-- Initialize logging
local log = LrLogger('ImmichSyncPlugin')
log:enable("logfile")

-- Get plugin preferences
local prefs = import 'LrPrefs'.prefsForPlugin()

local SyncServiceProvider = {}

-- Storage path mapping configuration
local function showStorageConfigurationDialog()
    log:info("Opening Immich sync storage configuration dialog")
    LrFunctionContext.callWithContext("showStorageConfigurationDialog", function(context)
        local f = LrView.osFactory()
        local bind = LrView.bind
        local share = LrView.share
        local propertyTable = LrBinding.makePropertyTable(context)
        
        -- Initialize values from preferences
        propertyTable.url = prefs.url or ""
        propertyTable.apiKey = prefs.apiKey or ""
        propertyTable.uploadLocationPath = prefs.uploadLocationPath or ""
        propertyTable.uploadLocationImmichPath = prefs.uploadLocationImmichPath or "/data/library"
        propertyTable.externalLibraryPaths = prefs.externalLibraryPaths or {}
        propertyTable.libraries = {}
        propertyTable.librariesFound = false
        
        -- Function to test connection and fetch libraries
        local function testConnectionAndFetchLibraries()
            if propertyTable.url == "" or propertyTable.apiKey == "" then
                LrDialogs.message('Please enter URL and API Key first')
                return
            end
            
            LrTasks.startAsyncTask(function()
                local immich = ImmichAPI:new(propertyTable.url, propertyTable.apiKey)
                if immich:checkConnectivity() then
                    log:info("Connection successful, fetching libraries")
                    local libraries = immich:getLibraries()
                    if libraries and type(libraries) == "table" and #libraries > 0 then
                        propertyTable.libraries = libraries
                        propertyTable.librariesFound = true
                        
                        -- Initialize external library path mappings from libraries response
                        local externalMappings = {}
                        for _, library in ipairs(libraries) do
                            if library.importPaths then
                                for _, importPath in ipairs(library.importPaths) do
                                    table.insert(externalMappings, {
                                        libraryName = library.name,
                                        libraryId = library.id,
                                        immichPath = importPath,
                                        localPath = ""  -- User will configure this
                                    })
                                end
                            end
                        end
                        propertyTable.externalLibraryPaths = externalMappings
                        
                        log:info("Found libraries: " .. util.dumpTable(libraries))
                        LrDialogs.message('Connection successful', 'Found ' .. #libraries .. ' external libraries. Configure local paths below.')
                    else
                        propertyTable.librariesFound = false
                        log:info("No libraries found or libraries endpoint returned: " .. tostring(libraries))
                        
                        -- Try to get a sample album to see asset path structure
                        local albums = immich:getAlbumsWODate()
                        if albums and #albums > 0 then
                            local sampleAlbum = albums[1]
                            local albumAssets = immich:getAlbumAssets(sampleAlbum.value)
                            if albumAssets and #albumAssets > 0 then
                                local sampleAsset = immich:getAssetInfo(albumAssets[1].id)
                                if sampleAsset then
                                    log:info("Sample asset structure for path mapping reference: " .. util.dumpTable(sampleAsset))
                                end
                            end
                        end
                        
                        LrDialogs.message('Connection successful', 'Libraries endpoint not available. Check plugin logs for sample asset paths to configure mappings.')
                    end
                else
                    LrDialogs.message('Connection test failed')
                end
            end)
        end
        
        -- Function to create external library UI elements
        local function createExternalLibrariesUI()
            local elements = {}
            
            if propertyTable.librariesFound and propertyTable.externalLibraryPaths then
                table.insert(elements, f:static_text {
                    title = "External Libraries:",
                    font = "<system/bold>",
                })
                
                for i, mapping in ipairs(propertyTable.externalLibraryPaths) do
                    -- Group box for each library
                    table.insert(elements, f:group_box {
                        title = mapping.libraryName or "External Library " .. i,
                        fill_horizontal = 1,
                        
                        f:static_text {
                            title = "Immich Path: " .. (mapping.immichPath or ""),
                            font = "<system/small>",
                        },
                        
                        f:row {
                            f:static_text {
                                title = "Local Path:",
                                alignment = 'right',
                                width = share 'labelWidth'
                            },
                            f:edit_field {
                                value = bind('externalLibraryPaths[' .. i .. '].localPath'),
                                truncation = 'middle',
                                immediate = false,
                                fill_horizontal = 1,
                                width_in_chars = 28,
                            },
                            f:push_button {
                                title = 'Browse...',
                                action = function()
                                    local path = LrDialogs.runOpenPanel {
                                        title = "Select Local Path for " .. (mapping.libraryName or "External Library"),
                                        canChooseFiles = false,
                                        canChooseDirectories = true,
                                        allowsMultipleSelection = false,
                                    }
                                    if path and path[1] then
                                        propertyTable.externalLibraryPaths[i].localPath = path[1]
                                    end
                                end,
                            },
                        },
                    })
                end
            else
                table.insert(elements, f:static_text {
                    title = "External Libraries:",
                    font = "<system/bold>",
                })
                
                table.insert(elements, f:static_text {
                    title = "Test connection first to discover external libraries automatically.",
                    font = "<system/small>",
                })
            end
            
            return elements
        end
        
        local contents = f:column {
            bind_to_object = propertyTable,
            spacing = f:control_spacing(),
            
            f:group_box {
                title = "Immich Connection",
                fill_horizontal = 1,
                
                f:row {
                    f:static_text {
                        title = "URL:",
                        alignment = 'right',
                        width = share 'labelWidth'
                    },
                    f:edit_field {
                        value = bind 'url',
                        truncation = 'middle',
                        immediate = false,
                        fill_horizontal = 1,
                        width_in_chars = 28,
                    },
                },
                
                f:row {
                    f:static_text {
                        title = "API Key:",
                        alignment = 'right',
                        width = share 'labelWidth'
                    },
                    f:edit_field {
                        value = bind 'apiKey',
                        truncation = 'middle',
                        immediate = false,
                        fill_horizontal = 1,
                        width_in_chars = 28,
                    },
                },
                
                f:row {
                    f:push_button {
                        title = 'Test Connection & Fetch Libraries',
                        action = testConnectionAndFetchLibraries,
                        fill_horizontal = 1,
                    },
                },
            },
            
            f:group_box {
                title = "Storage Path Mappings",
                fill_horizontal = 1,
                
                f:static_text {
                    title = "Configure how Immich storage paths map to your local file system:",
                    font = "<system/small>",
                },
                
                f:row {
                    f:static_text {
                        title = "Immich Server Path:",
                        alignment = 'right',
                        width = share 'labelWidth'
                    },
                    f:edit_field {
                        value = bind 'uploadLocationImmichPath',
                        truncation = 'middle',
                        immediate = false,
                        fill_horizontal = 1,
                        width_in_chars = 28,
                        tooltip = "Immich server path for upload location (default: /data/library)",
                    },
                },
                
                f:row {
                    f:static_text {
                        title = "Upload Location:",
                        alignment = 'right',
                        width = share 'labelWidth'
                    },
                    f:edit_field {
                        value = bind 'uploadLocationPath',
                        truncation = 'middle',
                        immediate = false,
                        fill_horizontal = 1,
                        width_in_chars = 28,
                        tooltip = "Local path where Immich upload location files are stored",
                    },
                    f:push_button {
                        title = 'Browse...',
                        action = function()
                            local path = LrDialogs.runOpenPanel {
                                title = "Select Upload Location Root Path",
                                canChooseFiles = false,
                                canChooseDirectories = true,
                                allowsMultipleSelection = false,
                            }
                            if path and path[1] then
                                propertyTable.uploadLocationPath = path[1]
                            end
                        end,
                    },
                },
            },
            
            unpack(createExternalLibrariesUI()),
        }

        local result = LrDialogs.presentModalDialog {
            title = "Immich Sync Configuration",
            contents = contents,
            actionVerb = "Save",
        }

        if result == "ok" then
            -- Validate configuration
            if propertyTable.url == "" or propertyTable.apiKey == "" then
                LrDialogs.message("Invalid Configuration", "URL and API Key are required.", "warning")
                return
            end
            
            if propertyTable.uploadLocationPath == "" then
                LrDialogs.message("Invalid Configuration", "Upload location path is required.", "warning")
                return
            end
            
            -- Save configuration
            prefs.url = propertyTable.url
            prefs.apiKey = propertyTable.apiKey
            prefs.uploadLocationPath = propertyTable.uploadLocationPath
            prefs.uploadLocationImmichPath = propertyTable.uploadLocationImmichPath
            prefs.externalLibraryPaths = propertyTable.externalLibraryPaths
            log:info("Sync configuration saved")
            LrDialogs.message("Configuration Saved", "Sync configuration has been saved successfully.", "info")
        end
    end)
end

-- Collection to album sync dialog
local function showSyncDialog()
    log:info("Opening collection sync dialog")
    
    -- Check if sync is configured
    if not prefs.url or not prefs.apiKey or not prefs.uploadLocationPath then
        LrDialogs.message("Configuration Required", "Please configure Immich sync settings first.", "info")
        showStorageConfigurationDialog()
        return
    end
    
    local catalog = LrApplication.activeCatalog()
    local selectedCollection = catalog:getTargetCollection()
    
    if not selectedCollection then
        LrDialogs.message("No Collection Selected", "Please select a collection to sync.", "info")
        return
    end
    
    LrFunctionContext.callWithContext("showSyncDialog", function(context)
        LrTasks.startAsyncTask(function()
            local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
            
            -- Get albums from Immich
            local albums = immich:getAlbumsWODate()
            if not albums or #albums == 0 then
                LrDialogs.message("Error", "No albums found in Immich.", "critical")
                return
            end
            
            -- Create dialog
            local f = LrView.osFactory()
            local bind = LrView.bind
            local propertyTable = LrBinding.makePropertyTable(context)
            
            propertyTable.selectedAlbum = albums[1] and albums[1].value or nil
            propertyTable.addNew = true
            propertyTable.removeOld = true
            propertyTable.newCount = 0
            propertyTable.removeCount = 0
            propertyTable.analyzing = false
            
            -- Function to analyze sync changes
            local function analyzeSyncChanges()
                if not propertyTable.selectedAlbum then return end
                
                LrTasks.startAsyncTask(function()
                    -- Update UI to show analysis in progress
                    propertyTable.analyzing = true
                    
                    local albumAssets = immich:getAlbumAssets(propertyTable.selectedAlbum)
                    local collectionPhotos = selectedCollection:getPhotos()
                    
                    if not albumAssets then
                        LrDialogs.message("Error", "Failed to get album assets.", "critical")
                        propertyTable.analyzing = false
                        return
                    end
                    
                    log:info("Analyzing sync for " .. #albumAssets .. " album assets and " .. #collectionPhotos .. " collection photos")
                    
                    -- Get detailed asset info including paths
                    local albumPaths = {}
                    local unmappedAssets = {}
                    
                    for _, asset in ipairs(albumAssets) do
                        local localPath, immichPath = getAssetPathInfo(immich, asset.id)
                        if localPath then
                            albumPaths[localPath] = {
                                assetId = asset.id,
                                immichPath = immichPath
                            }
                        else
                            table.insert(unmappedAssets, {
                                id = asset.id,
                                fileName = asset.originalFileName
                            })
                        end
                    end
                    
                    -- Get collection photo paths
                    local collectionPaths = {}
                    for _, photo in ipairs(collectionPhotos) do
                        local path = photo:getRawMetadata("path")
                        if path then
                            collectionPaths[path] = photo
                        end
                    end
                    
                    -- Calculate differences
                    local newPaths = {}
                    local removePaths = {}
                    
                    for albumPath, _ in pairs(albumPaths) do
                        if not collectionPaths[albumPath] then
                            table.insert(newPaths, albumPath)
                        end
                    end
                    
                    for collectionPath, _ in pairs(collectionPaths) do
                        if not albumPaths[collectionPath] then
                            table.insert(removePaths, collectionPath)
                        end
                    end
                    
                    propertyTable.newCount = #newPaths
                    propertyTable.removeCount = #removePaths
                    propertyTable.newPaths = newPaths
                    propertyTable.removePaths = removePaths
                    propertyTable.analyzing = false
                    
                    -- Report unmapped assets if any
                    if #unmappedAssets > 0 then
                        local message = "Warning: " .. #unmappedAssets .. " assets in the album could not be mapped to local paths:\n\n"
                        for _, asset in ipairs(unmappedAssets) do
                            message = message .. "- " .. (asset.fileName or asset.id) .. "\n"
                        end
                        message = message .. "\nPlease check your storage path configuration."
                        LrDialogs.message("Path Mapping Warning", message, "warning")
                    end
                    
                    log:info("Analysis complete: " .. #newPaths .. " new, " .. #removePaths .. " to remove, " .. #unmappedAssets .. " unmapped")
                end)
            end
            
            local contents = f:column {
                bind_to_object = propertyTable,
                spacing = f:control_spacing(),
                
                f:row {
                    f:static_text {
                        title = "Collection:",
                        alignment = 'right',
                        width = LrView.share 'label_width',
                    },
                    f:static_text {
                        title = selectedCollection:getName(),
                        fill_horizontal = 1,
                    },
                },
                
                f:row {
                    f:static_text {
                        title = "Immich Album:",
                        alignment = 'right',
                        width = LrView.share 'label_width',
                    },
                    f:popup_menu {
                        items = albums,
                        value = bind 'selectedAlbum',
                        width = 250,
                        immediate = true,
                        value_to_string = function(value)
                            for _, album in ipairs(albums) do
                                if album.value == value then
                                    return album.title
                                end
                            end
                            return ""
                        end,
                    },
                    f:push_button {
                        title = bind {
                            key = 'analyzing',
                            transform = function(value)
                                return value and 'Analyzing...' or 'Analyze'
                            end,
                        },
                        enabled = bind {
                            key = 'analyzing',
                            transform = function(value) return not value end,
                        },
                        action = analyzeSyncChanges,
                    },
                },
                
                f:separator { fill_horizontal = 1 },
                
                f:row {
                    f:checkbox {
                        title = bind {
                            key = 'newCount',
                            transform = function(value)
                                return "Add new photos (" .. (value or 0) .. ")"
                            end,
                        },
                        value = bind 'addNew',
                        enabled = bind {
                            key = 'newCount',
                            transform = function(value) return (value or 0) > 0 end,
                        },
                    },
                },
                
                f:row {
                    f:checkbox {
                        title = bind {
                            key = 'removeCount',
                            transform = function(value)
                                return "Remove missing photos (" .. (value or 0) .. ")"
                            end,
                        },
                        value = bind 'removeOld',
                        enabled = bind {
                            key = 'removeCount',
                            transform = function(value) return (value or 0) > 0 end,
                        },
                    },
                },
            }

            local result = LrDialogs.presentModalDialog {
                title = "Sync Collection with Immich Album",
                contents = contents,
                actionVerb = "Sync",
            }

            if result == "ok" and propertyTable.selectedAlbum then
                log:info("Starting sync for collection: " .. selectedCollection:getName())
                performSync(selectedCollection, propertyTable)
            end
        end)
    end)
end

-- Convert Immich asset path to local file system path
local function convertImmichPathToLocal(immichPath)
    -- This function maps Immich storage paths to local paths
    -- based on the configured library mappings
    
    if not immichPath then return nil end
    
    log:trace("Converting Immich path to local: " .. immichPath)
    
    -- For upload location (internal library)
    if prefs.uploadLocationPath and prefs.uploadLocationPath ~= "" then
        local uploadLocationPattern = "^" .. (prefs.uploadLocationImmichPath or "/data/library")
        if string.match(immichPath, uploadLocationPattern) then
            local relativePath = string.gsub(immichPath, uploadLocationPattern, "")
            -- Handle leading slash in relative path
            if string.sub(relativePath, 1, 1) == "/" then
                relativePath = string.sub(relativePath, 2)
            end
            local localPath = LrPathUtils.child(prefs.uploadLocationPath, relativePath)
            log:trace("Mapped to upload location: " .. localPath)
            return localPath
        end
    end
    
    -- For external libraries
    if prefs.externalLibraryPaths then
        for _, mapping in ipairs(prefs.externalLibraryPaths) do
            if mapping.immichPath and mapping.localPath then
                -- Try exact prefix match
                if string.find(immichPath, mapping.immichPath, 1, true) == 1 then
                    local relativePath = string.sub(immichPath, #mapping.immichPath + 1)
                    -- Handle leading slash in relative path
                    if string.sub(relativePath, 1, 1) == "/" then
                        relativePath = string.sub(relativePath, 2)
                    end
                    local localPath = LrPathUtils.child(mapping.localPath, relativePath)
                    log:trace("Mapped to external library: " .. localPath)
                    return localPath
                end
            end
        end
    end
    
    -- If no mapping found, try as absolute path (for testing)
    if LrFileUtils.exists(immichPath) then
        log:trace("Using path as-is: " .. immichPath)
        return immichPath
    end
    
    log:warn("No mapping found for Immich path: " .. immichPath)
    return nil
end

-- Enhanced asset info retrieval with better path handling
local function getAssetPathInfo(immich, assetId)
    local assetInfo = immich:getAssetInfo(assetId)
    if not assetInfo then
        log:warn("Could not get asset info for ID: " .. assetId)
        return nil
    end
    
    -- Try different possible path fields from Immich asset response
    local possiblePaths = {
        assetInfo.originalPath,
        assetInfo.originalFileName,
        assetInfo.path,
        assetInfo.filePath,
        assetInfo.libraryPath,
    }
    
    for _, path in ipairs(possiblePaths) do
        if path then
            local localPath = convertImmichPathToLocal(path)
            if localPath then
                return localPath, path
            end
        end
    end
    
    -- If no path found in standard fields, log the asset structure for debugging
    log:trace("Asset info structure for " .. assetId .. ": " .. util.dumpTable(assetInfo))
    return nil, nil
end

-- Perform the actual sync operation
local function performSync(collection, syncParams)
    local catalog = LrApplication.activeCatalog()
    local missingFiles = {}
    
    catalog:withWriteAccessDo("Sync Collection", function()
        -- Add new photos if requested
        if syncParams.addNew and syncParams.newPaths then
            local photosToAdd = {}
            for _, path in ipairs(syncParams.newPaths) do
                if LrFileUtils.exists(path) then
                    table.insert(photosToAdd, path)
                else
                    table.insert(missingFiles, path)
                end
            end
            
            if #photosToAdd > 0 then
                local addedPhotos = catalog:addPhotos(photosToAdd)
                for _, photo in ipairs(addedPhotos) do
                    collection:addPhotos({photo})
                end
                log:info("Added " .. #addedPhotos .. " photos to collection")
            end
        end
        
        -- Remove old photos if requested
        if syncParams.removeOld and syncParams.removePaths then
            local collectionPhotos = collection:getPhotos()
            local photosToRemove = {}
            
            for _, photo in ipairs(collectionPhotos) do
                local photoPath = photo:getRawMetadata("path")
                for _, removePath in ipairs(syncParams.removePaths) do
                    if photoPath == removePath then
                        table.insert(photosToRemove, photo)
                        break
                    end
                end
            end
            
            if #photosToRemove > 0 then
                collection:removePhotos(photosToRemove)
                log:info("Removed " .. #photosToRemove .. " photos from collection")
            end
        end
    end)
    
    -- Report missing files if any
    if #missingFiles > 0 then
        local message = "The following files could not be found locally:\n\n" .. table.concat(missingFiles, "\n")
        LrDialogs.message("Missing Files", message, "warning")
    else
        LrDialogs.message("Sync Complete", "Collection synchronized successfully.", "info")
    end
end

-- Exported functions
SyncServiceProvider.showStorageConfigurationDialog = showStorageConfigurationDialog
SyncServiceProvider.showSyncDialog = showSyncDialog

return SyncServiceProvider