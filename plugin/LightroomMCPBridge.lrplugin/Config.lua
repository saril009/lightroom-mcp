-- Shared configuration: bridge port, poll interval, shared-secret token path.
--
-- The port is auto-discovered: whichever MCP server manages to bind first
-- publishes it to <system temp>/lightroom-classic-mcp/port, and the plug-in
-- reads that file. The Plug-in Manager port setting is only a fallback for
-- running without a server (or when the temp folders differ).
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrPrefs = import 'LrPrefs'

local Config = {}

Config.DEFAULT_PORT = 8790
Config.DEFAULT_POLL_SECONDS = 0.5
Config.SUBDIR = 'lightroom-classic-mcp'
Config.TOKEN_FILENAME = 'token'
Config.PORT_FILENAME = 'port'

local cachedPort = nil
local cachedAt = -math.huge

local function prefs()
  return LrPrefs.prefsForPlugin(_PLUGIN)
end

function Config.port()
  -- Refresh the auto-discovered port at most every 5 seconds (a couple of tiny
  -- file reads per poll is nothing, but there is no reason to hammer disk).
  local now = os.time()
  if cachedPort == nil or now - cachedAt >= 5 then
    cachedAt = now
    local ok, content = pcall(LrFileUtils.readFile, Config.tempDir() .. '/' .. Config.PORT_FILENAME)
    local published = ok and type(content) == 'string' and tonumber(content) or nil
    if published and published >= 1 and published <= 65535 then
      cachedPort = math.floor(published)
    else
      cachedPort = false -- none published; fall back to prefs
    end
  end
  if cachedPort then return cachedPort end

  local n = tonumber(prefs().port)
  if n and n >= 1 and n <= 65535 then return math.floor(n) end
  return Config.DEFAULT_PORT
end

-- Where the current port value came from: 'auto', 'manual' or 'default'.
function Config.portSource()
  if cachedPort then return 'auto' end
  if tonumber(prefs().port) then return 'manual' end
  return 'default'
end

function Config.setPort(n)
  prefs().port = math.floor(tonumber(n) or Config.DEFAULT_PORT)
  cachedPort = nil
  cachedAt = -math.huge
end

function Config.pollSeconds()
  local n = tonumber(prefs().pollSeconds)
  if n and n >= 0.1 and n <= 30 then return n end
  return Config.DEFAULT_POLL_SECONDS
end

function Config.baseUrl()
  -- Loopback only: the bridge is never reachable from other machines.
  return 'http://127.0.0.1:' .. Config.port()
end

function Config.tempDir()
  return LrPathUtils.getStandardFilePath('temp') .. '/' .. Config.SUBDIR
end

function Config.tokenPath()
  return Config.tempDir() .. '/' .. Config.TOKEN_FILENAME
end

return Config
