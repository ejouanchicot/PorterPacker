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

--- Start a stopwatch for one span of work.
---
--- Returns a function that logs how long the span took when called. When debug
--- is off it returns a do-nothing closure, so call sites need no guard.
---
--- Spans are logged indented under `timing` so a run can be summarised with
--- `grep timing debug.log`.
---
--- @param label string short name for the span
--- @return function stop  call with an optional note to close the span
function M.stopwatch(label)
    if not State.debug_enabled then
        return function() end
    end

    local started = os.clock()
    return function(note)
        local elapsed_ms = (os.clock() - started) * 1000
        M.log(('  timing %-24s %8.1fms%s'):format(
            label, elapsed_ms, note and (' | ' .. note) or ''))
        return elapsed_ms
    end
end

--- Truncate the log file. Called when debug is enabled to start fresh.
function M.clear()
    local f = io.open(M.log_path, 'w')
    if f then f:close() end
end

return M
