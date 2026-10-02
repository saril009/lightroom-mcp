-- Lightroom MCP Bridge
-- Manifest for the Lightroom Classic plug-in that bridges an MCP server to the
-- Lightroom catalog. See README.md for setup.
return {
  -- Every API used by this plug-in is available as of SDK 6.0 (Lightroom 6 /
  -- CC 2015). Declaring 6.0 keeps the plug-in loadable in older installs; the
  -- server-side tool descriptions list anything that needs a newer build.
  LrSdkVersion = 6.0,
  LrSdkMinimumVersion = 6.0,

  LrToolkitIdentifier = 'dev.lightroommcp.bridge',
  LrPluginName = 'Lightroom MCP Bridge',
  LrPluginInfoProvider = 'PluginInfoProvider.lua',
  LrPluginInfoUrl = 'https://github.com/',

  -- Start the bridge poll loop as soon as Lightroom launches (the loop itself
  -- returns immediately and only blocks inside a background task).
  LrForceInitPlugin = true,
  LrInitPlugin = 'Init.lua',
  LrEnablePlugin = 'Enable.lua',
  LrDisablePlugin = 'Disable.lua',
  LrShutdownApp = 'Shutdown.lua',

  LrLibraryMenuItems = {
    { title = 'Toggle MCP Bridge', file = 'ToggleBridge.lua' },
  },

  VERSION = { major = 0, minor = 1, revision = 0, build = '1' },
}
