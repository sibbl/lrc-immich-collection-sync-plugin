# Immich Photo Sync Feature

This document describes the new photo synchronization feature that allows you to sync Lightroom collections with Immich albums without downloading or uploading photos.

## Overview

The sync feature works by:
1. Connecting to your Immich server to get album information
2. Mapping Immich storage paths to your local file system paths
3. Comparing album contents with collection contents
4. Adding/removing photos from collections based on file paths (no downloads/uploads)

## Configuration

### Step 1: Configure Storage Paths

1. In Lightroom, go to **File > Plug-in Manager** or use the menu **Library > Plug-in Extras > Immich sync configuration**
2. Enter your Immich server URL and API key
3. Click **Test Connection & Fetch Libraries** to verify connectivity
4. Configure the **Internal Library Path**: This is where your Immich internal library files are stored on your local system
5. For external libraries, you'll need to manually configure path mappings based on the Immich paths shown in logs

### Step 2: Understanding Path Mapping

Immich stores photos in different locations:
- **Internal Library**: Usually under `/usr/src/app/upload/` in the container
- **External Libraries**: Custom paths you've configured in Immich

You need to map these Immich paths to your local file system paths:
- If Immich shows `/usr/src/app/upload/photos/2024/photo.jpg`
- And your local path is `/home/user/immich-library/photos/2024/photo.jpg`
- Then set Internal Library Path to `/home/user/immich-library`

## Usage

### Syncing a Collection

1. Select a collection in Lightroom
2. Go to **Library > Plug-in Extras > Sync with Immich Album**
3. Choose the Immich album to sync with
4. Click **Analyze** to see what changes would be made:
   - **Add new photos**: Photos in the Immich album but not in the collection
   - **Remove missing photos**: Photos in the collection but not in the album
5. Choose which operations to perform (you can uncheck either option)
6. Click **Sync** to apply changes

### What Happens During Sync

- **Adding photos**: Files are added to the collection by path reference (no download)
- **Removing photos**: Photos are removed from the collection (files remain on disk)
- **Missing files**: If a mapped file path doesn't exist locally, it's reported as an error

## Troubleshooting

### "No mapping found for Immich path"
- Check your storage path configuration
- Look at plugin logs to see the actual paths Immich is reporting
- Ensure path mappings are correctly configured

### "Files could not be found locally"
- Verify that your local files are in the expected locations
- Check that Immich paths are correctly mapped to local paths
- Ensure file permissions allow Lightroom to access the files

### Connection Issues
- Verify Immich URL and API key
- Check network connectivity
- Ensure Immich API is accessible

## Technical Notes

- This feature does NOT download or upload any photos
- Collections are updated using file path references only
- The sync is one-way: from Immich album to Lightroom collection
- Original files must be accessible to Lightroom via the configured paths
- External library mappings may require manual configuration based on your Immich setup

## Limitations

- Requires local access to the same files that Immich manages
- Path mapping configuration may need to be adjusted for different storage setups
- Does not sync metadata changes (only photo presence in albums/collections)
- Only works with collections, not folders or other Lightroom organizational structures