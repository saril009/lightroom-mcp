-- Library > Plug-in Extras > Toggle MCP Bridge
local Bridge = require 'Bridge'
local LrDialogs = import 'LrDialogs'

if Bridge.isRunning() then
  Bridge.stop()
  LrDialogs.showBezel('MCP bridge stopped')
else
  Bridge.start()
  LrDialogs.showBezel('MCP bridge started')
end
