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
        propertyTable.internalLibraryPath = prefs.internalLibraryPath or ""
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
                        LrDialogs.message('Connection successful', 'Found ' .. #libraries .. ' libraries. You can now configure path mappings below.')
                    else
                        propertyTable.librariesFound = false
                        LrDialogs.message('Connection successful', 'No libraries found via API. You can manually configure path mappings below.')
                    end
                else
                    LrDialogs.message('Connection test failed')
                end
            end)
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
                        title = "Internal Library:",
                        alignment = 'right',
                        width = share 'labelWidth'
                    },
                    f:edit_field {
                        value = bind 'internalLibraryPath',
                        truncation = 'middle',
                        immediate = false,
                        fill_horizontal = 1,
                        width_in_chars = 28,
                        tooltip = "Local path where Immich internal library files are stored",
                    },
                    f:push_button {
                        title = 'Browse...',
                        action = function()
                            local path = LrDialogs.runOpenPanel {
                                title = "Select Internal Library Root Path",
                                canChooseFiles = false,
                                canChooseDirectories = true,
                                allowsMultipleSelection = false,
                            }
                            if path and path[1] then
                                propertyTable.internalLibraryPath = path[1]
                            end
                        end,
                    },
                },
                
                f:static_text {
                    title = "External Libraries:",
                    font = "<system/bold>",
                },
                
                f:static_text {
                    title = "Add mappings for external libraries. Format: /immich/path -> /local/path",
                    font = "<system/small>",
                },
                
                f:row {
                    f:static_text {
                        title = "Example:",
                        alignment = 'right',
                        width = share 'labelWidth'
                    },
                    f:static_text {
                        title = "/external-library/photos -> /Users/username/Photos",
                        font = "<system/small>",
                    },
                },
            },
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
            
            if propertyTable.internalLibraryPath == "" then
                LrDialogs.message("Invalid Configuration", "Internal library path is required.", "warning")
                return
            end
            
            -- Save configuration
            prefs.url = propertyTable.url
            prefs.apiKey = propertyTable.apiKey
            prefs.internalLibraryPath = propertyTable.internalLibraryPath
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
    if not prefs.url or not prefs.apiKey or not prefs.internalLibraryPath then
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
            
            -- Function to analyze sync changes
            local function analyzeSyncChanges()
                if not propertyTable.selectedAlbum then return end
                
                LrTasks.startAsyncTask(function()
                    local albumAssets = immich:getAlbumAssets(propertyTable.selectedAlbum)
                    local collectionPhotos = selectedCollection:getPhotos()
                    
                    if not albumAssets then
                        LrDialogs.message("Error", "Failed to get album assets.", "critical")
                        return
                    end
                    
                    -- Get detailed asset info including paths
                    local albumPaths = {}
                    for _, asset in ipairs(albumAssets) do
                        local assetInfo = immich:getAssetWithPath(asset.id)
                        if assetInfo and assetInfo.originalPath then
                            -- Convert Immich path to local path
                            local localPath = convertImmichPathToLocal(assetInfo.originalPath)
                            if localPath then
                                albumPaths[localPath] = asset.id
                            end
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
                        title = 'Analyze',
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
    
    -- For internal library
    if prefs.internalLibraryPath and prefs.internalLibraryPath ~= "" then
        -- Assume internal library paths start with /usr/src/app/upload or similar
        -- Map these to the configured internal library path
        local internalPattern = "^/usr/src/app/upload/"
        if string.match(immichPath, internalPattern) then
            local relativePath = string.gsub(immichPath, internalPattern, "")
            return LrPathUtils.child(prefs.internalLibraryPath, relativePath)
        end
    end
    
    -- For external libraries
    if prefs.externalLibraryPaths then
        for _, mapping in ipairs(prefs.externalLibraryPaths) do
            if mapping.immichPath and mapping.localPath then
                if string.find(immichPath, mapping.immichPath, 1, true) == 1 then
                    local relativePath = string.sub(immichPath, #mapping.immichPath + 1)
                    return LrPathUtils.child(mapping.localPath, relativePath)
                end
            end
        end
    end
    
    return nil
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