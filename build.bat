@echo off
REM Build the distributable Lightroom Classic plugin bundle on Windows.
setlocal
cd /d "%~dp0"

set OUT=dist\lrc-immich-collection-sync-plugin.lrplugin
set LEGACY_OUT=dist\immich-sync.lrplugin
if exist "%LEGACY_OUT%" rmdir /s /q "%LEGACY_OUT%"
if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%"

xcopy /E /I /Q src\* "%OUT%\" >nul
if not exist "%OUT%\Info.lua" (
    echo ERROR: %OUT%\Info.lua missing.
    exit /b 1
)

echo Build complete: %OUT%
echo.
echo To install in Lightroom Classic:
echo   File ^> Plug-in Manager... ^> Add ^> select %OUT%
