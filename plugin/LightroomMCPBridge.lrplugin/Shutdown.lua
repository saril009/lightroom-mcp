-- Runs on Lightroom exit. LrDialogs is not available here.
local Bridge = require 'Bridge'

return {
  LrShutdownFunction = function(doneFunction, progressFunction)
    -- Bridge.stop() only flips a flag (no yielding calls), so plain pcall is safe.
    pcall(Bridge.stop)
    if progressFunction then progressFunction(1, 'MCP bridge stopped') end
    doneFunction()
  end,
}
