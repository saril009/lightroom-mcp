-- Runs when the plug-in is disabled in the Plug-in Manager. Only flips a flag
-- (no yielding calls), so plain pcall is safe and no dialog is needed.
local Bridge = require 'Bridge'

pcall(Bridge.stop)
