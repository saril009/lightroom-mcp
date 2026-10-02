-- File > Plug-in Manager: status panel for the Lightroom MCP Bridge.
--
-- Lightroom expects this script to return a TABLE of function definitions,
-- not a function: it reads the result as `provider.sectionsForTopOfDialog`.
-- Returning a function instead makes the Plug-in Manager fail with
-- "attempt to index a function value".
local Bridge = require 'Bridge'
local Config = require 'Config'

local function bridgeStatus()
  local state = Bridge.state

  if not Bridge.isRunning() then
    return 'Stopped. The bridge polls for work in the background; start it below '
      .. '(it normally starts automatically when Lightroom launches).'
  end

  local lines = {}
  lines[#lines + 1] = 'Running - polling http://127.0.0.1:' .. Config.port()
    .. '/poll every ' .. Config.pollSeconds() .. 's'
    .. ' (port source: ' .. Config.portSource() .. ')'

  if Bridge.isConnected() then
    lines[#lines + 1] = 'MCP server: connected - ' .. state.polls .. ' polls, '
      .. state.jobsCompleted .. ' job(s) completed.'
  else
    lines[#lines + 1] = 'MCP server: not connected yet. Start an agent session that uses the '
      .. '"lightroom" MCP server, then the plug-in will see it within a second.'
  end

  if state.currentJob then
    lines[#lines + 1] = 'Working on: ' .. tostring(state.currentJob)
  end
  if state.lastError then
    lines[#lines + 1] = 'Note: ' .. tostring(state.lastError)
  end
  return table.concat(lines, '\n')
end

-- f is the view factory Lightroom passes in; do not build our own.
local function sectionsForTopOfDialog(f, propertyTable)
  propertyTable.bridgeStatus = bridgeStatus()
  propertyTable.bridgeRunning = Bridge.isRunning()

  local function refresh()
    propertyTable.bridgeStatus = bridgeStatus()
    propertyTable.bridgeRunning = Bridge.isRunning()
  end

  return {
    {
      title = 'Lightroom MCP Bridge',

      f:column {
        bind_to_object = propertyTable,
        spacing = f:control_spacing(),

        f:static_text {
          key = 'bridgeStatus',
          title = propertyTable.bridgeStatus,
          width = 430,
          height_in_lines = 6,
        },

        f:row {
          spacing = f:label_spacing(),

          f:push_button {
            title = 'Start bridge',
            enabled = not propertyTable.bridgeRunning,
            action = function()
              Bridge.start()
              refresh()
            end,
          },

          f:push_button {
            title = 'Stop bridge',
            enabled = propertyTable.bridgeRunning,
            action = function()
              Bridge.stop()
              refresh()
            end,
          },

          f:push_button {
            title = 'Refresh status',
            action = refresh,
          },
        },

        f:separator { fill_horizontal = 1 },

        f:static_text {
          title = 'The bridge only talks to 127.0.0.1. It expects an MCP server named '
            .. '"lightroom" (package: lightroom-classic-mcp) running on the port shown above; '
            .. 'the port is published automatically by that server, so no configuration is '
            .. 'usually needed. Library > Plug-in Extras > Toggle MCP Bridge does the same as '
            .. 'the buttons above.',
          width = 430,
          height_in_lines = 6,
        },
      },
    },
  }
end

return {
  sectionsForTopOfDialog = sectionsForTopOfDialog,
}
