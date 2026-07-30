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
-- Set when a store menu is patched: the client, not us, sends the 0x5B that
-- closes it, and that close would otherwise look like the player interfering.
M.expecting_client_close = false

-- ---------------------------------------------------------------------------
-- Operation flags
-- ---------------------------------------------------------------------------
M.storing_items = false  -- true if current op is a pack

-- There used to be a `continuous` flag here. Nothing gated on its true value:
-- its only reader let the 0x052 handler chain the next trade itself whenever it
-- was *false*, and since every entry point set it true, the sole way to reach
-- that chain was to clear the flag mid-run -- which //po reset did. Removed with
-- the chain rather than left as a field whose purpose has to be guessed.

-- ---------------------------------------------------------------------------
-- Operation ownership
-- ---------------------------------------------------------------------------
-- Windower runs every `addon command` on its own coroutine, so `packet_state`
-- alone never was a lock: it sits at 0 for seconds at a time inside a run (item
-- data waits, inter-job settles, retry backoffs, every item-movement burst). A
-- second command typed in one of those windows used to start a whole second
-- flow over this same table -- both trading, each consuming the other's menu
-- answers, neither ever finishing, and no reset able to stop either.
--
-- `operation_active` is the lock that refuses the second command. `generation`
-- is bumped by every reset so a flow that is still running can see it no longer
-- owns the addon and return on its own, which is what //po reset needs in order
-- to replace //lua unload+load.
M.operation_active = false
M.generation       = 0

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
-- Per-trade diagnostics
-- ---------------------------------------------------------------------------
-- A trade that does not complete looks identical whether the porter refused the
-- batch or simply never answered, and the two call for opposite responses: a
-- refusal means stop offering it, silence means try again. These two fields are
-- what tell them apart in the log -- whether a menu ever opened, and anything the
-- server said while we were waiting.
M.trade_menu_seen = false
M.trade_messages  = {}

-- ---------------------------------------------------------------------------
-- Debug toggle (read by debug.lua, written by command handler)
-- ---------------------------------------------------------------------------
M.debug_enabled = false

-- ---------------------------------------------------------------------------
-- Reset helpers
-- ---------------------------------------------------------------------------

--- Claim the addon for one operation. Returns the owning token, or nil when an
--- operation is already running.
function M.begin_operation()
    if M.operation_active then
        return nil
    end
    M.operation_active = true
    return M.generation
end

--- Release the lock, but only if this operation still owns it. A reset that
--- happened mid-run has already handed ownership on, and releasing then would
--- unlock the operation that took over.
function M.end_operation(token)
    if token == M.generation then
        M.operation_active = false
    end
end

--- True once `token` no longer owns the addon: a reset, a zone change or a
--- logout happened, and whatever is still running should stop where it is.
---
--- A missing token counts as still owning it. The alternative fails the wrong
--- way: a caller that forgot to pass one through would report every checkpoint as
--- superseded, and the flow would return at its first one having done nothing at
--- all, silently.
function M.superseded(token)
    return token ~= nil and token ~= M.generation
end

--- Drop the packet machine back to idle and forget the conversation we just
--- abandoned.
---
--- `last_update` matters as much as `packet_state` here. It is compared
--- byte-for-byte to reject the repeats the server sends, so a stale one makes
--- the next attempt's identical update look like a duplicate: it is swallowed,
--- no answer goes out, and the menu hangs at state 2 until the timeout -- which
--- clears the state and leaves the same stale update behind again.
function M.force_idle()
    M.packet_state           = 0
    M.last_update            = nil
    M.last_trade_confirmed   = false
    M.expecting_client_close = false
end

--- Hard reset: clears everything. Used by //po reset and on errors.
---
--- Bumping the generation is what makes this able to stop work in flight: any
--- flow still running sees itself superseded at its next checkpoint and returns.
function M.reset_all()
    M.force_idle()
    M.generation       = M.generation + 1
    M.operation_active = false
    M.storing_items        = false
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
--- but leaves the state machine itself alone (caller is expected to verify
--- state==0 first).
---
--- The two conversation leftovers below are cleared even so: they describe the
--- previous job's menu, and carrying either into the next job is what makes the
--- first update of that job be discarded as a duplicate, or the next player
--- cancel be mistaken for a close we were waiting for.
function M.reset_job()
    M.last_update            = nil
    M.expecting_client_close = false
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
