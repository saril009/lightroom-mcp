-- Runs once when the plug-in is first loaded (and at Lightroom startup,
-- because Info.lua sets LrForceInitPlugin). Must return immediately: all
-- blocking work happens inside Bridge's background task.
local Bridge = require 'Bridge'

Bridge.start()
