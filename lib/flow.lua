---============================================================================
--- PorterPacker / lib/flow.lua
---============================================================================
--- Orchestration: deciding which slip to hand over next, and in what order.
---
--- Two strategies live here, and they exist because the porter behaves very
--- differently depending on how hard you push it.
---
---   step_through_slips()  One slip at a time, driven by the packet layer. The
---                         0x052 close handler calls back in here for the next
---                         one, so control returns to the game between trades.
---                         Used for ordinary single-job commands.
---
---   run_bulk_transfer()   A single long sequential run for `//po all` and
---                         friends. It blocks on each trade, watches for the
---                         server going quiet, and keeps inventory drained as
---                         it goes. Doing this many trades through the async
---                         path would outrun the server.
---
--- Both read State.store / State.retrieve / State.storing_items and clear them
--- as work completes.
---============================================================================

local Config      = require('lib/config')
local State       = require('lib/state')
local Debug       = require('lib/debug')
local Inv         = require('lib/inventory')
local Packets     = require('lib/packets')
local Msg         = require('messages')
local SlipsLookup = require('lib/slips_lookup')

local M = {}

local PORTER = 'Porter Moogle'

-- How many times to offer a slip its batch before treating the silence as real.
-- The porter intermittently ignores a trade, and the same batch goes through on
-- the next attempt, so one silence is not evidence of anything.
local TRADE_ATTEMPTS = 3
local RETRY_BACKOFF  = 1.0

-- A slip that stays silent across all its attempts, twice running, means the
-- client's packet queue has jammed; pushing further just produces more of the
-- same.
local DEADLOCK_STRIKES = 2

-- Upper bounds so a slip that never resolves cannot spin forever.
local MAX_PACK_PASSES   = 80
local MAX_UNPACK_PASSES = 15

-- Inventory headroom below which we flush before continuing. A single slip can
-- return many items at once, and the porter closes its menu the moment bag 0
-- fills up.
local FLUSH_THRESHOLD = 8

-- Brief pauses that let the server catch up between distinct operations.
local PAUSE_AFTER_GATHER = 0.15
local PAUSE_AFTER_SLIP   = 0.025
local PAUSE_AFTER_PULL   = 0.1

-- Where a slip may live, in the order we check when putting one back.
local SLIP_ORIGINS = {
    { key = 'satchel', bag = 5 },
    { key = 'sack',    bag = 6 },
    { key = 'case',    bag = 7 },
}

-- ===========================================================================
-- Shared helpers
-- ===========================================================================

--- Abandon whatever was queued. Used when the Moogle goes out of reach.
local function clear_pending()
    State.retrieve      = {}
    State.store         = {}
    State.storing_items = false
end

--- Re-locate the Moogle, clearing pending work if it has gone.
--- @return table|nil
local function require_porter()
    local npc = Packets.find_npc(PORTER)
    if not npc then
        clear_pending()
    end
    return npc
end

--- A slip group is ready to trade when it holds the slip itself plus at least
--- one item to put on it.
local function is_tradeable(group, slip_id)
    return #group > 1 and group[1].id == slip_id
end

--- Note where each slip was sitting before we started, so it can go back there.
local function snapshot_slip_origins()
    local origins = {}
    for _, origin in ipairs(SLIP_ORIGINS) do
        origins[origin.key] = Packets.find_porter_items({ origin.bag })
    end
    return origins
end

--- Put a slip back in the bag it came from.
---
--- `verify_in_hand` covers the unpack path, where the last candidate bag is
--- only correct if the slip really is in hand; without that check a slip that
--- never made it back to inventory would be filed in the wrong place.
--- @return number how many slips were actually moved
local function return_slip_to_origin(slip_id, origins, verify_in_hand)
    for position, origin in ipairs(SLIP_ORIGINS) do
        local group = origins[origin.key][slip_id]

        if group and group[1].id == slip_id then
            local is_last = position == #SLIP_ORIGINS
            if verify_in_hand and is_last
                and not Inv.find_item({ slips.default_storages[1] }, slip_id, 1) then
                return 0
            end

            return Inv.put_away_items({ [slip_id] = true }, { origin.bag })
        end
    end
    return 0
end

--- Anything from the original request that is still parked on a slip goes back
--- onto the retrieve list. Trades that timed out leave gaps, and this is what
--- lets the next pass pick them up.
--- @param only_missing boolean also require the item to be absent from our bags
local function requeue_outstanding(only_missing)
    for _, contents in pairs(slips.get_player_items()) do
        if contents.n ~= 0 then
            for _, item_id in ipairs(contents) do
                local outstanding = State.original_retrieve[item_id]
                    and (not only_missing or (
                        not State.retrieve[item_id]
                        and not Inv.find_item(Config.slip_bags, item_id, 1)))

                if outstanding then
                    State.retrieve[item_id] = true
                end
            end
        end
    end
end

--- Drain inventory back into the wardrobes when it is running short.
local function flush_inventory_if_tight()
    if Inv.space_available(0) < FLUSH_THRESHOLD then
        Inv.put_away_items(State.original_retrieve, Config.bag_priority)
        return true
    end
    return false
end

-- ===========================================================================
-- One slip at a time
-- ===========================================================================

--- Emit the summary line for the slip that just finished, then reset the
--- per-slip counters.
local function report_finished_slip()
    if not State.async_current_slip_num then
        return
    end

    if State.async_operation == 'pack' then
        Msg.stored(State.async_current_slip_items, State.async_current_slip_num)
    elseif State.async_operation == 'unpack' then
        Msg.retrieved(State.async_current_slip_items, State.async_current_slip_num)
    end

    State.async_total_items = State.async_total_items + State.async_current_slip_items
    State.async_total_slips = State.async_total_slips + 1
    State.async_current_slip_num   = nil
    State.async_current_slip_items = 0
end

--- Begin tracking a slip we are about to trade.
local function begin_slip(operation, slip_num, item_count)
    State.async_operation          = operation
    State.async_current_slip_num   = slip_num
    State.async_current_slip_items = item_count
end

--- Wrap up: print totals, put the slips away, reset counters.
local function finish_stepping()
    if State.async_total_slips > 0 then
        local verb = State.async_operation == 'pack' and 'Packed' or 'Retrieved'
        Msg.summary(verb, State.async_total_items, State.async_total_slips)

        local returned = Inv.return_slips_to_home()
        if returned > 0 then
            Msg.info(('Returned %d storage slip(s) to satchel'):format(returned))
        end
        Msg.completed()
    end

    State.async_operation          = nil
    State.async_current_slip_num   = nil
    State.async_current_slip_items = 0
    State.async_total_items        = 0
    State.async_total_slips        = 0
    State.retrieve                 = {}
end

--- Find the next slip worth trading and hand it over, then return. The packet
--- layer calls back in here once the porter closes that slip's menu, so each
--- invocation advances the operation by exactly one slip.
function M.step_through_slips()
    report_finished_slip()

    local npc = require_porter()
    if not npc then
        return
    end

    -- Packing: any complete slip-plus-items group sitting in inventory.
    if State.storing_items then
        for slip_id, group in pairs(Packets.find_porter_items({ 0 })) do
            if is_tradeable(group, slip_id) then
                local slip_num   = slips.get_slip_number_by_id(slip_id)
                local item_count = #group - 1  -- the slip itself is not cargo

                begin_slip('pack', slip_num, item_count)
                Msg.progress('Packing', slip_num, item_count)
                return Packets.trade_npc(npc, group)
            end
        end

        State.store         = {}
        State.storing_items = false
    end

    -- Unpacking: the next slip holding something we asked for.
    if table.length(State.retrieve) ~= 0 and Inv.space_available(0) ~= 0 then
        for slip_id, contents in pairs(slips.get_player_items()) do
            if contents.n ~= 0 then
                for _, item_id in ipairs(contents) do
                    local wanted = State.retrieve[item_id]
                        and not Inv.find_item(slips.default_storages, item_id, 1)

                    if wanted then
                        local slip_item = Inv.find_item({ slips.default_storages[1] }, slip_id, 1)
                        if slip_item then
                            local slip_num = slips.get_slip_number_by_id(slip_id)

                            begin_slip('unpack', slip_num, 0)
                            Msg.progress('Retrieving from', slip_num, nil)
                            return Packets.trade_npc(npc, { slip_item })
                        end
                    end
                end
            end
        end
    end

    finish_stepping()
end

-- Hand ourselves to the packet layer so it can chain slips without importing
-- this module (which would close an import cycle).
Packets.on_slip_finished = M.step_through_slips

-- ===========================================================================
-- Bulk transfer
-- ===========================================================================

--- Spell out what a trade contained. Built only when one fails, since that is
--- the only time the contents matter.
---
--- A timeout leaves the state machine at 1, meaning the porter never opened a
--- menu -- it declined the whole trade rather than taking part of it. When that
--- happens repeatedly for one slip while every other slip goes through first
--- time, the likely reason is a single item in the batch the porter will not
--- accept there, so the batch needs naming.
local function describe_group(group)
    local parts = {}
    for index, item in ipairs(group) do
        local record = res.items[item.id]
        parts[index] = ('%s(%d)'):format(record and record.name or '?', item.id)
    end
    return table.concat(parts, ', ')
end

--- Find the current, tradeable batch for a slip, with slot numbers as they are
--- right now. Returns nil when the slip has nothing left to hand over.
local function current_batch_for(slip_id)
    for candidate_id, candidate in pairs(Packets.find_porter_items({ 0 })) do
        if candidate_id == slip_id and is_tradeable(candidate, slip_id) then
            return candidate
        end
    end
    return nil
end

--- Trade one group and wait for the server. Returns whether it went through.
local function trade_and_wait(npc, group, slip_num, item_count)
    Msg.progress('Packing', slip_num, item_count)
    Packets.trade_npc(npc, group)
    Packets.wait_for_trades()

    if State.packet_state == 0 then
        return true
    end

    Debug.log(('!! slip %d REFUSED the batch: %s'):format(slip_num, describe_group(group)))

    State.packet_state = 0  -- clear the stuck state so the next trade can run
    return false
end

--- Hand a slip's batch over, trying again if the porter stays silent.
---
--- A timeout leaves the state machine at 1, meaning no menu was ever opened and
--- the batch was not taken. In practice this is intermittent: the same slip,
--- with the same batch, goes through moments later. Abandoning the slip after
--- one silence loses gear for no reason, and two such silences in a row used to
--- stop the whole pack.
---
--- Each retry rescans the inventory instead of resending the original batch.
--- Slot numbers are captured when a batch is built, so if the trade did land
--- while we were not looking, those slots now hold something else and resending
--- them would trade the wrong items. The rescan either produces a batch with
--- current slots, or reports the slip has nothing left -- which means the silent
--- trade went through after all.
---
--- @return boolean traded
--- @return number|nil items handed over; nil means the Moogle went out of range
local function trade_slip_with_retries(npc, group, slip_id, slip_num)
    local batch = group

    for attempt = 1, TRADE_ATTEMPTS do
        if attempt > 1 then
            coroutine.sleep(RETRY_BACKOFF)

            batch = current_batch_for(slip_id)
            if not batch then
                Debug.log(('slip %d has nothing left to hand over - the silent trade landed')
                    :format(slip_num))
                return true, 0
            end

            npc = require_porter()
            if not npc then
                return false, nil
            end

            Debug.log(('slip %d: attempt %d of %d'):format(slip_num, attempt, TRADE_ATTEMPTS))
        end

        local item_count = #batch - 1
        if trade_and_wait(npc, batch, slip_num, item_count) then
            return true, item_count
        end
    end

    return false, 0
end

--- Pack everything the store filter matched.
---
--- Works slip by slip: bring the slip and its items into inventory, trade every
--- complete group that forms there, then file the slip back where it came from.
--- Repeats while progress is being made.
---
--- @return number items packed
--- @return number slips packed
local function run_pack_phase(npc, origins)
    local packed_items, packed_slips = 0, 0
    local strikes = 0
    local pass = 1
    local progressed = true

    while progressed and pass <= MAX_PACK_PASSES do
        progressed = false

        -- Re-read the bags at the start of every pass rather than working from
        -- the snapshot the first pass used.
        --
        -- More passes than one are genuinely needed: a trade carries at most
        -- eight items, so a slip with more cargo than that has to be visited
        -- again. But once a slip is emptied it should drop out of the loop, and
        -- with a stale snapshot it did not -- later passes kept pulling cargo
        -- that was no longer there, sleeping after it and filing away a slip
        -- that was already home. The rescan costs about five milliseconds and
        -- gives the loop an accurate view of what is left.
        local groups = Packets.find_porter_items(Config.equippable_bags)

        for slip_id, group in pairs(groups) do
            if is_tradeable(group, slip_id) then
                -- Bring the slip and its cargo into inventory to trade from.
                --
                -- The pause here is unconditional on purpose. It was briefly
                -- made to depend on whether items moved, on the reasoning that
                -- nothing moved means nothing to wait for. Timeouts followed:
                -- trades left the client with the porter never opening its
                -- menu (state stuck at 1), after the loop had run three
                -- pull/file cycles inside a single second. Whether or not that
                -- was the cause, this pause is the only spacing between a burst
                -- of item-movement packets and the trade that follows them, and
                -- it is not worth the seconds it saves.
                if Inv.space_available(0) ~= 0 then
                    local stop = Debug.stopwatch('pack:pull-slip-cargo')
                    local pulled = Inv.retrieve_items(group, Config.equippable_bags)
                    stop(('%d of %d item(s)'):format(pulled, #group))
                    coroutine.sleep(PAUSE_AFTER_GATHER)
                end

                local stop_scan = Debug.stopwatch('pack:rescan-inventory')
                local ready = Packets.find_porter_items({ 0 })
                stop_scan()

                for ready_slip_id, ready_group in pairs(ready) do
                    if is_tradeable(ready_group, ready_slip_id) then
                        npc = require_porter()
                        if not npc then
                            return packed_items, packed_slips, true
                        end

                        local slip_num   = slips.get_slip_number_by_id(ready_slip_id)
                        local traded, item_count = trade_slip_with_retries(
                            npc, ready_group, ready_slip_id, slip_num)

                        -- A lost Moogle is reported as an abort, not a failure.
                        if item_count == nil then
                            return packed_items, packed_slips, true
                        end

                        if traded then
                            strikes = 0
                            progressed = true

                            -- Keep inventory clear for the trades that follow.
                            local stop_flush = Debug.stopwatch('pack:flush-inventory')
                            Inv.put_away_items(State.original_retrieve, Config.bag_priority)
                            stop_flush()

                            if item_count > 0 then
                                Msg.stored(item_count, slip_num)
                                packed_items = packed_items + item_count
                                packed_slips = packed_slips + 1
                            end
                        else
                            strikes = strikes + 1
                            Debug.log(('PACK trade TIMEOUT slip=%d (consec=%d)'):format(
                                slip_num, strikes))
                            Msg.warning(('Slip %d trade timed out (network deadlock?) - skipping')
                                :format(slip_num))

                            if strikes >= DEADLOCK_STRIKES then
                                Debug.log('PACK aborted: 2 consecutive timeouts')
                                progressed = false
                                break
                            end
                        end
                    end
                end

                if strikes >= DEADLOCK_STRIKES then
                    break
                end

                local stop_return = Debug.stopwatch('pack:file-slip-home')
                return_slip_to_origin(slip_id, origins, false)
                stop_return()
                coroutine.sleep(PAUSE_AFTER_SLIP)

            elseif #group > 2 and pass == 1 then
                -- Items are here but their slip is not; tell the user which one.
                Msg.slip_hint(slips.get_slip_number_by_id(slip_id), #group)
            end
        end

        requeue_outstanding(false)
        pass = pass + 1
    end

    return packed_items, packed_slips, false
end

--- Pull one slip's worth of wanted items into inventory.
---
--- Returns how many items came back and whether the trade stalled, which the
--- caller uses to tell "this slip is done" from "the server stopped answering".
local function unpack_one_slip(npc, slip_id)
    local stop_find = Debug.stopwatch('unpack:locate-slip')
    local slip_item = Inv.find_item(Config.slip_bags, slip_id, 1)
    stop_find()
    if not slip_item then
        return nil
    end

    -- The slip has to be in hand before it can be traded.
    local stop_pull = Debug.stopwatch('unpack:pull-slip')
    Inv.retrieve_items({ slip_item }, Config.equippable_bags)
    stop_pull()
    coroutine.sleep(PAUSE_AFTER_PULL)

    slip_item = Inv.find_item({ slips.default_storages[1] }, slip_id, 1)
    if not slip_item then
        return nil
    end

    local slip_num = slips.get_slip_number_by_id(slip_id)
    Msg.progress('Retrieving from', slip_num, nil)
    Packets.trade_npc(npc, { slip_item })
    Packets.wait_for_trades()

    local stalled = State.packet_state ~= 0
    if stalled then
        State.packet_state = 0
    end

    -- A slip can return several items in one go, so count what actually landed
    -- rather than assuming one item per trade.
    --
    -- Instrumented because this is a find_item per outstanding item, and each
    -- of those walks every slip bag: the cost scales with the retrieve list,
    -- not with what this slip returned.
    local stop_count = Debug.stopwatch('unpack:account-arrivals')
    local outstanding = table.length(State.retrieve)
    local recovered = 0
    for item_id in pairs(State.retrieve) do
        if Inv.find_item(Config.slip_bags, item_id, 1) then
            State.retrieve[item_id] = nil
            recovered = recovered + 1
        end
    end
    stop_count(('%d scanned, %d found'):format(outstanding, recovered))

    Msg.retrieved(recovered, slip_num)
    return recovered, stalled
end

--- Retrieve everything on the retrieve list.
---
--- Only visits slips known to hold something wanted, and stops early once a
--- pass stops shrinking the list.
---
--- @return number items retrieved
--- @return number slips visited
local function run_unpack_phase(npc, origins)
    if table.length(State.retrieve) == 0 or Inv.space_available(0) == 0 then
        return 0, 0
    end

    -- Only these slips can possibly hold something we want.
    local candidate_slips = {}
    for item_id in pairs(State.original_retrieve) do
        local slip_id = SlipsLookup.get_slip_id(item_id)
        if slip_id then
            candidate_slips[slip_id] = true
        end
    end

    local retrieved_items, visited_slips = 0, 0
    local previous_outstanding = -1
    local pass = 1

    while table.length(State.retrieve) > 0 and pass < MAX_UNPACK_PASSES do
        -- Make room before walking the slips: a pass that starts with a full
        -- inventory retrieves nothing and would trip the no-progress exit.
        local stop_flush = Debug.stopwatch('unpack:flush-before-pass')
        Inv.put_away_items(State.original_retrieve, Config.bag_priority)
        stop_flush(('pass %d'):format(pass))

        local outstanding = table.length(State.retrieve)
        if outstanding == previous_outstanding then
            break  -- a full pass changed nothing; nothing left we can reach
        end
        previous_outstanding = outstanding

        -- Timeouts from an earlier pass must not abort this one before it
        -- has attempted a single trade.
        local strikes = 0
        local player_slips = slips.get_player_items()

        for slip_id in pairs(candidate_slips) do
            if strikes >= DEADLOCK_STRIKES then
                break
            end

            local contents = player_slips[slip_id] or { n = 0 }
            local used = false

            if contents.n ~= 0 then
                for _, item_id in ipairs(contents) do
                    local wanted = State.retrieve[item_id]
                        and not Inv.find_item(Config.slip_bags, item_id, 1)

                    if wanted then
                        npc = require_porter()
                        if not npc then
                            return retrieved_items, visited_slips, true
                        end

                        local recovered, stalled = unpack_one_slip(npc, slip_id)
                        if recovered then
                            retrieved_items = retrieved_items + recovered
                            visited_slips   = visited_slips + 1
                            used = true

                            if stalled and recovered == 0 then
                                strikes = strikes + 1
                                Debug.log(('UNPACK slip=%d FAILED (timeout, 0 items) - fails=%d')
                                    :format(slips.get_slip_number_by_id(slip_id), strikes))
                                break  -- stop hammering a slip that is not answering
                            end

                            strikes = 0
                            flush_inventory_if_tight()
                        end
                    end
                end
            end

            if used then
                return_slip_to_origin(slip_id, origins, true)
                coroutine.sleep(PAUSE_AFTER_SLIP)
            end
        end

        requeue_outstanding(true)

        if flush_inventory_if_tight() then
            coroutine.sleep(PAUSE_AFTER_SLIP)
        end

        pass = pass + 1
    end

    return retrieved_items, visited_slips, false
end

--- Run a full pack and/or unpack in one sequential sweep.
function M.run_bulk_transfer()
    local npc = require_porter()
    if not npc then
        return
    end

    local origins = snapshot_slip_origins()

    -- Keep the original request around: the retrieve list gets consumed as
    -- items arrive, but recovery and inventory flushing both need the full set.
    State.original_retrieve = {}
    for item_id, wanted in pairs(State.retrieve) do
        State.original_retrieve[item_id] = wanted
    end

    local packed_items, packed_slips = 0, 0
    if State.storing_items then
        local aborted
        packed_items, packed_slips, aborted =
            run_pack_phase(npc, origins)
        if aborted then
            return
        end
    end

    State.store         = {}
    State.storing_items = false

    local retrieved_items, retrieved_slips, aborted = run_unpack_phase(npc, origins)
    if aborted then
        return
    end

    Inv.put_away_items(State.original_retrieve, Config.bag_priority)
    State.retrieve = {}

    if packed_slips > 0 then
        Msg.summary('Packed', packed_items, packed_slips)
    end
    if retrieved_slips > 0 then
        Msg.summary('Retrieved', retrieved_items, retrieved_slips)
    end

    -- Bulk mode reads these to decide whether a job made any progress at all.
    State.async_total_items = packed_items + retrieved_items
    State.async_total_slips = packed_slips + retrieved_slips
end

-- Names used before the flow rewrite; kept so callers elsewhere keep working.
M.porter_trade      = M.step_through_slips
M.continuous_porter = M.run_bulk_transfer

return M
