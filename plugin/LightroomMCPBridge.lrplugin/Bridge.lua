-- The bridge: a background task that polls the MCP server for work.
--
-- Transport (all on 127.0.0.1, no inbound ports opened by Lightroom):
--   GET  /poll     -> { "job": null } | { "job": { id, tool, args } }
--   POST /result   <- { id, ok, data } | { id, ok, error }
--
-- Every call to a catalog/photo API yields, so protected calls must use
-- LrTasks.pcall (plain pcall cannot yield across the C boundary in Lua 5.1).
local LrTasks = import 'LrTasks'
local LrHttp = import 'LrHttp'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrMD5 = import 'LrMD5'

local Json = require 'Json'
local Config = require 'Config'
local Handlers = require 'Handlers'

local logger = LrLogger('LightroomMCPBridge')
logger:enable('logfile')

local Bridge = {}

local state = {
  running = false,
  polls = 0,
  jobsCompleted = 0,
  serverReachable = false,
  lastError = nil,
  startedAt = nil,
  lastContactAt = nil,
  currentJob = nil,
  token = nil,
}
Bridge.state = state

-- ---------------------------------------------------------------------------
-- shared secret
-- ---------------------------------------------------------------------------
-- The token is written to the system temp folder so the MCP server (same user,
-- same machine) can read it back. If the server cannot find it, it simply runs
-- without authentication rather than failing - the transport is loopback-only.
local function writeToken()
  local seed = table.concat({
    tostring(os.time()),
    tostring(os.clock()),
    tostring(math.random()),
    _PLUGIN and _PLUGIN.path or '',
  }, '|')
  local token = LrMD5.digest(seed)

  LrTasks.pcall(function()
    LrFileUtils.createAllDirectories(Config.tempDir())
    LrFileUtils.writeFile(Config.tokenPath(), token)
  end)
  state.token = token
end

-- ---------------------------------------------------------------------------
-- HTTP helpers
-- ---------------------------------------------------------------------------
local function pollHeaders()
  return {
    { field = 'X-Lightroom-MCP-Token', value = state.token or '' },
    { field = 'Accept', value = 'application/json' },
  }
end

local function postResult(payload)
  local body = Json.encode(payload)
  local headers = {
    { field = 'Content-Type', value = 'application/json' },
    { field = 'X-Lightroom-MCP-Token', value = state.token or '' },
  }
  -- LrHttp.post(url, body, headers, method, timeout)
  local ok, res = LrTasks.pcall(function()
    return LrHttp.post(Config.baseUrl() .. '/result', body, headers, 'POST', 15)
  end)
  if not ok or res == nil then
    state.lastError = 'Could not deliver result to the MCP server'
    logger:warn('postResult failed: ' .. tostring(res))
  end
end

-- ---------------------------------------------------------------------------
-- job execution
-- ---------------------------------------------------------------------------
local function runJob(job)
  local tool = job.tool
  local args = type(job.args) == 'table' and job.args or {}
  state.currentJob = tool
  logger:info('running ' .. tostring(tool))

  local payload
  if type(tool) ~= 'string' or Handlers[tool] == nil then
    payload = { id = job.id, ok = false, error = 'Unknown tool: ' .. tostring(tool) }
  else
    local ok, data, err = LrTasks.pcall(Handlers[tool], args)
    if not ok then
      payload = { id = job.id, ok = false, error = tostring(data) }
    elseif data == nil then
      payload = { id = job.id, ok = false, error = tostring(err or 'handler returned no data') }
    else
      payload = { id = job.id, ok = true, data = data }
      state.jobsCompleted = state.jobsCompleted + 1
    end
  end

  state.currentJob = nil
  postResult(payload)
end

local function handlePollResponse(body)
  local ok, msg = LrTasks.pcall(Json.decode, body)
  if not ok or type(msg) ~= 'table' then
    state.lastError = 'Malformed response from MCP server'
    return
  end
  if msg.error and msg.error ~= Json.null then
    state.lastError = tostring(msg.error)
    return
  end
  local job = msg.job
  -- NB: Json.null is a table sentinel, so compare it explicitly rather than
  -- relying on type(job) == 'table'.
  if job == nil or job == Json.null then return end
  if type(job) == 'table' and job.id ~= nil then
    runJob(job)
  end
end

function Bridge.pollOnce()
  local ok, body = LrTasks.pcall(function()
    return LrHttp.get(Config.baseUrl() .. '/poll', pollHeaders(), 4)
  end)

  if not ok or body == nil or body == '' then
    if state.serverReachable then
      logger:info('MCP server went away on port ' .. Config.port())
    end
    state.serverReachable = false
    state.lastError = 'MCP server not reachable on port ' .. Config.port()
      .. ' (is an agent session running?)'
    return
  end

  state.serverReachable = true
  state.lastContactAt = os.time()
  state.lastError = nil
  state.polls = state.polls + 1
  handlePollResponse(body)
end

function Bridge.loop()
  while state.running do
    local ok, err = LrTasks.pcall(Bridge.pollOnce)
    if not ok then
      state.lastError = tostring(err)
      logger:error('poll error: ' .. tostring(err))
      -- Polling must never die: a bad job only fails that one request.
      LrTasks.sleep(1)
    end
    if state.running then
      LrTasks.sleep(Config.pollSeconds())
    end
  end
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------
function Bridge.start()
  if state.running then
    return false
  end
  state.running = true
  state.startedAt = os.time()
  state.lastError = nil
  state.serverReachable = false
  writeToken()

  LrTasks.startAsyncTask(function()
    Bridge.loop()
  end, 'Lightroom MCP bridge')

  logger:info('bridge started, polling ' .. Config.baseUrl()
    .. ' every ' .. Config.pollSeconds() .. 's')
  return true
end

function Bridge.stop()
  if not state.running then
    return false
  end
  state.running = false
  state.currentJob = nil
  logger:info('bridge stopped')
  return true
end

function Bridge.isRunning()
  return state.running
end

-- True when a server answered within the last few seconds.
function Bridge.isConnected()
  if not state.running or not state.serverReachable then
    return false
  end
  return os.time() - (state.lastContactAt or 0) <= 10
end

return Bridge
