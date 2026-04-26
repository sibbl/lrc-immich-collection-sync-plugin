--[[
  Compatibility shim for older Lightroom registrations that still point
  `LrPluginInfoProvider` at `PluginInfo.lua`.

  The v4 plugin uses `PluginInfoProvider.lua` as the canonical module, but
  keeping this alias avoids hard failures when Lightroom has not fully
  refreshed its cached script references yet.
]]

return require 'PluginInfoProvider'