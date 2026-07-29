---============================================================================
--- PorterPacker / lib/debug.lua
---============================================================================
--- Debug logger: writes to <addon>/debug.log when State.debug_enabled is true.
--- No-op (zero overhead) when debug is off.
---
--- Convention: lines starting with `!!` are anomalies/errors. Use them when
--- something unexpected happens so they're easy to spot via `grep '!!'`.
---============================================================================

local State = require('lib/state')

local M = {}

M.log_path = windower.addon_path .. 'debug.log'

--- Append a single line with timestamp.
--- @param line string Log content
function M.log(line)
    if not State.debug_enabled then return end
    local f = io.open(M.log_path, 'a')
    if f then
        f:write(os.date('[%H:%M:%S] ') .. line .. '\n')
        f:close()
    end
end

--- Truncate the log file. Called when debug is enabled to start fresh.
function M.clear()
    local f = io.open(M.log_path, 'w')
    if f then f:close() end
end

return M
