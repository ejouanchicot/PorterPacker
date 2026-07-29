---============================================================================
--- PorterPacker / lib/state.lua
---============================================================================
--- All mutable state shared across modules.
---
--- Lua's `require` caches modules so every `require('lib/state')` returns the
--- same table. Modules read/write fields on this single instance, providing
--- shared state without globals.
---
--- State machine values (`packet_state`):
---   0 = idle
---   1 = trade-in-flight (waiting for menu open)
---   2 = menu-open (selecting items / processing 0x05C updates)
---   3 = menu-closing (we sent 0x40000000, waiting for 0x052)
---============================================================================

local M = {}

-- ---------------------------------------------------------------------------
-- Packet state machine
-- ---------------------------------------------------------------------------
M.packet_state         = 0      -- 0/1/2/3 (see header)
M.last_update          = nil    -- last 0x05C menu update packet
M.last_trade_confirmed = false  -- true when 0x052 close arrived (vs force-reset)

-- ---------------------------------------------------------------------------
-- Operation flags
-- ---------------------------------------------------------------------------
M.storing_items = false  -- true if current op is a pack
M.continuous    = false  -- true for `all` (continuous_porter), false for single

-- ---------------------------------------------------------------------------
-- Item-ID sets (set by command handler before continuous_porter runs)
-- ---------------------------------------------------------------------------
M.retrieve          = {}  -- items still pending retrieve from porter
M.original_retrieve = {}  -- snapshot of initial retrieve list
M.store             = {}  -- items still pending pack to porter
M.original_store    = {}  -- snapshot of initial store list

-- ---------------------------------------------------------------------------
-- Async progress tracking (used by both flow.lua and bulk.lua summaries)
-- ---------------------------------------------------------------------------
M.async_operation          = nil  -- 'pack' | 'unpack' | nil
M.async_current_slip_num   = nil
M.async_current_slip_items = 0
M.async_total_items        = 0
M.async_total_slips        = 0

-- Trade attempt counters (used by bulk to distinguish "nothing to do" vs
-- "deadlock" - the former is success, the latter aborts).
M.async_trade_attempts  = 0  -- total trade_npc calls
M.async_trade_successes = 0  -- trades that completed with state==0

-- ---------------------------------------------------------------------------
-- Trade rate analysis (debug only)
-- ---------------------------------------------------------------------------
M.last_trade_clock   = 0
M.last_trade_slip_id = 0

-- ---------------------------------------------------------------------------
-- Debug toggle (read by debug.lua, written by command handler)
-- ---------------------------------------------------------------------------
M.debug_enabled = false

-- ---------------------------------------------------------------------------
-- Reset helpers
-- ---------------------------------------------------------------------------

--- Hard reset: clears everything. Used by //po reset and on errors.
function M.reset_all()
    M.packet_state         = 0
    M.last_update          = nil
    M.last_trade_confirmed = false
    M.storing_items        = false
    M.continuous           = false
    M.retrieve          = {}
    M.original_retrieve = {}
    M.store             = {}
    M.original_store    = {}
    M.async_operation          = nil
    M.async_current_slip_num   = nil
    M.async_current_slip_items = 0
    M.async_total_items        = 0
    M.async_total_slips        = 0
    M.async_trade_attempts     = 0
    M.async_trade_successes    = 0
end

--- Soft reset between bulk-mode jobs: clears item lists and per-job counters,
--- but leaves packet state alone (caller is expected to verify state==0 first).
function M.reset_job()
    M.retrieve          = {}
    M.original_retrieve = {}
    M.store             = {}
    M.original_store    = {}
    M.async_operation          = nil
    M.async_current_slip_num   = nil
    M.async_current_slip_items = 0
    M.async_total_items        = 0
    M.async_total_slips        = 0
    M.async_trade_attempts     = 0
    M.async_trade_successes    = 0
end

return M
