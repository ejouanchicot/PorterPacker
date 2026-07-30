---============================================================================
--- PorterPacker / lib/packets.lua
---============================================================================
--- Everything that speaks FFXI's wire protocol lives here: locating the Moogle,
--- injecting trades, and driving the porter's menu conversation to completion.
---
--- The porter conversation is a small state machine. State.packet_state tracks
--- where we are in it:
---
---   0  idle, nothing in flight
---   1  a trade was injected, waiting for the Moogle to open its menu
---   2  the menu is open and we are answering it
---   3  we asked to close; waiting for the server to confirm
---============================================================================

local Config      = require('lib/config')
local State       = require('lib/state')
local Debug       = require('lib/debug')
local Inv         = require('lib/inventory')
local Msg         = require('messages')
local SlipsLookup = require('lib/slips_lookup')

local M = {}

-- ===========================================================================
-- Protocol constants
-- ===========================================================================

-- Packet identifiers we care about.
local PACKET_MENU_OPEN   = 0x034  -- incoming: Moogle presents a menu
local PACKET_MENU_UPDATE = 0x05C  -- incoming: menu contents changed
local PACKET_MENU_CLOSE  = 0x052  -- incoming: menu dismissed
local PACKET_TRADE       = 0x036  -- outgoing: hand items to an NPC
local PACKET_MENU_ANSWER = 0x05B  -- outgoing: pick an option / close

-- Byte offsets inside the 0x034 menu packet. These are protocol offsets, so
-- they are zero-based; Lua string indexing needs +1 on every read.
local AT = {
    npc_id      = 0x04,  -- uint32, which NPC opened the menu
    stored_bits = 0x08,  -- 24-byte bitfield: what this slip currently holds
    slip_index  = 0x24,  -- uint32, zero-based position in slips.storages
    npc_index   = 0x28,  -- uint16, the NPC's index in the zone
    zone_menu   = 0x2A,  -- two uint16s: zone id then menu id
}

-- The same bitfield appears at a different offset in the 0x05C update packet.
local UPDATE_STORED_BITS = 0x04
local UPDATE_BIT_POS     = 0x2A  -- uint32, which bit the server just acted on

-- A storage slip advertises its contents as a fixed 192-bit field: one bit per
-- possible item, set when that item is currently parked on the slip.
local SLIP_BITFIELD_BITS = 192

-- Sentinel the client sends as an option index to mean "close this menu".
local MENU_CLOSE_OPTION = 0x40000000

-- A trade packet carries at most eight items.
local TRADE_SLOTS = 8

-- Porter Moogles sit inside a 6 yalm interaction bubble. Windower reports
-- npc.distance already squared, so comparing against the squared radius avoids
-- a square root on every check.
local INTERACT_RANGE_SQUARED = 6 * 6

-- An NPC's spawn_type has flag bits layered on top of the type itself; masking
-- them off leaves 2 for a plain NPC.
local SPAWN_TYPE_MASK = 0xDF
local SPAWN_TYPE_NPC  = 2

-- Storage slip 13 is the only one that will take augmented equipment. Every
-- other slip refuses it.
local AUGMENT_FRIENDLY_SLIP = 13

-- How long to wait for the server to acknowledge a trade before giving up.
--
-- Was 5 seconds, which was not enough. Measured menu latency on a good run
-- reaches 4.36s in the unpack phase (2.4s while packing), so a 5s budget left
-- under a second of headroom -- one server hiccup and a trade that was going to
-- land got abandoned. The evidence that these were never real refusals: the same
-- slip, with the same batch, stores fine on a later run.
--
-- 9s nominal, which is roughly 11s of wall clock: the poll loop runs about 1.25x
-- slower than the sleep interval implies (139 polls measured 4.36s where 3.48s
-- was nominal), so budgets here are optimistic and the real deadline is longer
-- than the number. That is the right direction to be wrong in.
local TRADE_TIMEOUT_SECONDS = 9
local TRADE_POLL_SECONDS    = 0.025
local TRADE_SETTLE_SECONDS  = 0.3

-- ===========================================================================
-- Locating the Moogle
-- ===========================================================================

--- Resolve a nearby NPC by name and confirm we can actually interact with it.
--- Prints the reason and returns nil when we cannot.
--- @param name string NPC display name
--- @return table|nil mob record
function M.find_npc(name)
    local npc = windower.ffxi.get_mob_by_name(name)

    local reachable = npc
        and npc.valid_target
        and npc.is_npc
        and npc.distance < INTERACT_RANGE_SQUARED
        and bit.band(npc.spawn_type, SPAWN_TYPE_MASK) == SPAWN_TYPE_NPC

    if reachable then
        return npc
    end

    Msg.error(('%s is not in range'):format(name))
    return nil
end

-- ===========================================================================
-- Trading
-- ===========================================================================

--- Lay out a trade payload: a header naming the target, then the per-slot item
--- counts, then the per-slot inventory positions, then a short trailer.
--- Slots beyond the item list are zero-filled.
local function build_trade_payload(npc, items)
    local counts, positions = {}, {}

    for slot = 1, TRADE_SLOTS do
        local item = items[slot]
        counts[slot]    = ('I'):pack(item and item.count or 0)
        positions[slot] = ('C'):pack(item and item.slot or 0)
    end

    return table.concat {
        ('I2'):pack(0, npc.id),
        table.concat(counts),
        ('I2'):pack(0, 0),
        table.concat(positions),
        ('C2HI'):pack(0, 0, npc.index, math.min(#items, TRADE_SLOTS)),
    }
end

--- Record timing around a trade so debug.log can show pacing problems: trades
--- fired too close together, or the same slip being handed over twice.
local function log_trade_pacing(items)
    local now = os.clock()
    local since_last = State.last_trade_clock > 0 and (now - State.last_trade_clock) or 0
    local slip_id = items[1] and items[1].id or 0

    local notes = ''
    if since_last > 0 and since_last < 0.5 then
        notes = notes .. ' [FAST<0.5s]'
    end
    if slip_id == State.last_trade_slip_id then
        notes = notes .. ' [REPEAT]'
    end

    Debug.log(('trade #%d items, slip_id=%d, gap=%.2fs%s'):format(
        #items, slip_id, since_last, notes))

    State.last_trade_clock   = now
    State.last_trade_slip_id = slip_id
end

--- Hand up to eight items to an NPC and arm the state machine.
--- @param npc table mob record from M.find_npc
--- @param items table array of item records {id, slot, count}
function M.trade_npc(npc, items)
    if State.debug_enabled then
        log_trade_pacing(items)
    end

    State.async_trade_attempts = State.async_trade_attempts + 1

    -- Fresh diagnostics per trade, so a failure reports what happened during
    -- *this* attempt and not a previous one.
    State.trade_menu_seen = false
    State.trade_messages  = {}

    windower.packets.inject_outgoing(PACKET_TRADE, build_trade_payload(npc, items))
    State.packet_state = 1
end

--- Say what the server did while a failed trade was in flight, so the log can
--- distinguish a refusal from silence.
--- @return string
function M.describe_trade_outcome()
    local parts = {}

    parts[#parts + 1] = State.trade_menu_seen
        and 'porter DID open a menu'
        or 'porter opened NO menu'

    if #State.trade_messages == 0 then
        parts[#parts + 1] = 'server said nothing (silence, not a refusal)'
    else
        parts[#parts + 1] = ('server said: %q'):format(table.concat(State.trade_messages, ' | '))
    end

    return table.concat(parts, '; ')
end

--- Park the current coroutine until the state machine falls back to idle.
--- Gives up after TRADE_TIMEOUT_SECONDS and leaves a note in the log; callers
--- inspect State.packet_state afterwards to tell success from timeout.
function M.wait_for_trades()
    local entered_at    = State.packet_state
    local started_clock = os.clock()
    local max_polls     = math.floor(TRADE_TIMEOUT_SECONDS / TRADE_POLL_SECONDS)
    local polls         = 0

    State.last_trade_confirmed = false

    while State.packet_state ~= 0 and polls < max_polls do
        coroutine.sleep(TRADE_POLL_SECONDS)
        polls = polls + 1
    end

    if State.packet_state ~= 0 then
        Debug.log(('!! TIMEOUT %.2fs state=%d (started at %d) - %s'):format(
            os.clock() - started_clock, State.packet_state, entered_at,
            M.describe_trade_outcome()))
        return
    end

    -- This is the one span we cannot shorten: it is the porter answering.
    -- Everything else around a trade is our own code and is fair game.
    Debug.log(('  timing %-24s %8.1fms | %d polls'):format(
        'server:menu-dialog', (os.clock() - started_clock) * 1000, polls))

    State.async_trade_successes = State.async_trade_successes + 1

    local stop = Debug.stopwatch('settle:post-trade')
    coroutine.sleep(TRADE_SETTLE_SECONDS)  -- let trailing packets land
    stop()
end

-- ===========================================================================
-- Deciding what can be stored
-- ===========================================================================

--- An augment is only finished once bit 6 of extdata byte 2 and the high bit of
--- byte 12 are both raised. Reads defensively: extdata can be shorter than the
--- offsets we probe.
local function augment_is_complete(extdata)
    local stage    = extdata:byte(2)
    local finalise = extdata:byte(12)
    return stage ~= nil and finalise ~= nil
        and stage % 0x80 >= 0x40
        and finalise >= 0x80
end

--- Whether the porter will accept this item onto the given slip.
--- extdata byte 1 == 2 marks the item as carrying an augment record. Slip 13
--- takes those provided the augment is complete; the rest only take unaugmented
--- pieces (or, again, a completed augment).
local function porter_accepts(item, slip_id)
    local extdata = item.extdata

    if slip_id == slips.storages[AUGMENT_FRIENDLY_SLIP] then
        return augment_is_complete(extdata)
    end

    return extdata:byte(1) ~= 2 or augment_is_complete(extdata)
end

--- Snapshot every item currently sitting on a slip, as an item_id set. One pass
--- over the slip data answers every "is this already stored?" question below,
--- instead of re-querying per item.
local function build_stored_set()
    local stored = {}
    for _, contents in pairs(slips.get_player_items()) do
        for _, item_id in ipairs(contents) do
            stored[item_id] = true
        end
    end
    return stored
end

--- Group the contents of the given bags by the slip they belong to.
---
--- Each returned group is an array of item records. When the slip itself is
--- present in one of the bags it is placed first, which is what callers test to
--- decide whether a group is ready to trade.
---
--- Items are skipped when they are already stored, when a store filter is
--- active and excludes them, when they are queued to be pulled back out, or
--- when the porter would refuse them outright.
---
--- @param bags table array of bag ids
--- @return table slip_id -> array of item records
function M.find_porter_items(bags)
    local groups   = {}
    local filter   = table.length(State.store) > 0 and State.store
    local stored   = build_stored_set()

    local function add_to_group(slip_id, item, as_slip)
        local group = groups[slip_id]
        if not group then
            group = {}
            groups[slip_id] = group
        end
        if as_slip then
            table.insert(group, 1, item)
        else
            group[#group + 1] = item
        end
    end

    for _, bag_id in ipairs(bags) do
        -- get_items returns nil for a disabled bag -- a mog wardrobe becomes one
        -- the moment you step out of the mog house. Walking it unguarded threw
        -- from inside whichever coroutine was scanning, and the flow died with
        -- every operation flag still set.
        for _, item in ipairs(windower.ffxi.get_items(bag_id) or {}) do
            if item.id ~= 0 and item.status == 0 then
                local slip_id = SlipsLookup.get_slip_id(item.id)

                local packable = slip_id
                    and not stored[item.id]
                    and (not filter or filter[item.id])
                    and not State.retrieve[item.id]
                    and not State.original_retrieve[item.id]
                    and porter_accepts(item, slip_id)

                if packable then
                    add_to_group(slip_id, item, false)
                elseif slips.items[item.id] then
                    -- The item is itself a storage slip.
                    add_to_group(item.id, item, true)
                end
            end
        end
    end

    return groups
end

-- ===========================================================================
-- Answering the porter's menu
-- ===========================================================================

--- Reply to an open menu: either pick an option or send MENU_CLOSE_OPTION.
local function answer_menu(npc_id, npc_index, zone_id, menu_id, option_index, confirm)
    windower.packets.inject_outgoing(PACKET_MENU_ANSWER,
        ('I3H4'):pack(0, npc_id, option_index, npc_index, confirm, zone_id, menu_id))
    return true
end

--- Walk the set bits of a slip's contents bitfield.
---
--- The menu numbers its options over *present* items only, so the option index
--- advances one per set bit while the bit position keeps counting through the
--- gaps. Yields (option_index, item_id, bit_position).
local function each_stored_item(bitfield, contents)
    local bit_position = -1
    local option_index = 0

    -- Normally 192 bits. Bounded by what actually arrived because the bitfield is
    -- sliced out of a packet: a shorter one than expected would otherwise be read
    -- past its end, and that throws inside the packet handler -- no reply sent,
    -- menu stuck open.
    local last_bit = math.min(SLIP_BITFIELD_BITS, #bitfield * 8) - 1

    return function()
        while bit_position < last_bit do
            bit_position = bit_position + 1

            local byte_at = math.floor(bit_position / 8) + 1
            local bit_at  = bit_position % 8 + 1

            if bitfield:unpack('b', byte_at, bit_at) == 1 then
                local this_option = option_index
                option_index = option_index + 1
                return this_option, contents[bit_position + 1], bit_position
            end
        end
    end
end

--- The store menu opens gated shut. Rewriting the five bytes after the header
--- opens it. Modern FFXI routes storage through the retrieve menu instead, so
--- this path is effectively legacy and rarely runs.
local function handle_store_menu(data)
    local GATE_AT     = 0x0C
    local HEADER_LAST = 0x07

    if data:byte(GATE_AT + 1) ~= 0 then
        return false
    end

    -- Storing never sends its own menu answer: we hand the patched packet back
    -- and the client closes the dialog itself. Record that so the outgoing
    -- handler recognises that close as ours rather than reporting it as the
    -- player interfering.
    State.expecting_client_close = true

    return data:sub(1, HEADER_LAST + 1)
        .. string.char(1, 0, 0, 0, 1)
        .. data:sub(GATE_AT + 2)
end

--- Drive the retrieve menu: look through what the slip is holding, click the
--- first entry we still want, and close once nothing is left to take.
---
--- Called once when the menu opens and again for every update the server sends.
--- An update carries the bit the server just resolved, which is how we know an
--- item actually arrived and can strike it off the retrieve list.
local function handle_retrieve_menu(data, update, zone_id, menu_id)
    local npc_id     = data:unpack('I', AT.npc_id + 1)
    local npc_index  = data:unpack('H', AT.npc_index + 1)
    local slip_index = data:unpack('I', AT.slip_index + 1) + 1

    local function close()
        State.packet_state = 3
        return answer_menu(npc_id, npc_index, zone_id, menu_id, MENU_CLOSE_OPTION, 0)
    end

    -- Guard against a slip index we have no definition for; without this the
    -- contents lookup below would index a nil table.
    local slip_id  = slips.storages[slip_index]
    local contents = slip_id and slips.items[slip_id]
    if not contents then
        Debug.log(('!! retrieve menu ABORT: unknown slip index %d'):format(slip_index))
        return close()
    end

    if Inv.space_available(0) == 0 then
        return close()
    end

    local bitfield = update
        and update:sub(UPDATE_STORED_BITS + 1, UPDATE_STORED_BITS + 24)
        or data:sub(AT.stored_bits + 1, AT.stored_bits + 24)

    local resolved_bit = update
        and #update >= UPDATE_BIT_POS + 4
        and update:unpack('I', UPDATE_BIT_POS + 1)

    for option_index, item_id, bit_position in each_stored_item(bitfield, contents) do
        if item_id and State.retrieve[item_id] and Inv.space_available(0) ~= 0 then
            if bit_position == resolved_bit then
                -- The server just handed this one over.
                State.retrieve[item_id] = nil
                State.async_current_slip_items = State.async_current_slip_items + 1
            else
                return answer_menu(npc_id, npc_index, zone_id, menu_id, option_index, 1)
            end
        end
    end

    return close()
end

-- Which handler serves which menu, per zone. The porter exposes its retrieve
-- menu at the id recorded in Config.zones and its store menu one below that.
local menu_handlers = {}
for zone_id, retrieve_menu_id in pairs(Config.zones) do
    menu_handlers[zone_id] = {
        [retrieve_menu_id - 1] = handle_store_menu,
        [retrieve_menu_id]     = handle_retrieve_menu,
    }
end

--- Route a menu packet to whichever handler owns it. Returns false when the
--- menu is not one of ours, leaving it untouched.
local function dispatch_menu(data, update)
    -- The update path feeds us a cached packet, and the cache is empty until the
    -- client has seen one menu open -- which is exactly the case right after a
    -- reload. Unpacking nil threw from inside the packet handler, so no answer
    -- was sent and the menu sat at state 2 with nothing left to move it.
    if not data or #data < AT.zone_menu + 4 then
        return false
    end

    local zone_id, menu_id = data:unpack('H2', AT.zone_menu + 1)

    local handler = menu_handlers[zone_id] and menu_handlers[zone_id][menu_id]
    if not handler then
        return false
    end

    -- The server repeats updates; acting on the same one twice would double
    -- count retrieved items.
    if update and update == State.last_update then
        return true
    end

    -- Committed before the handler runs, because a handler that closes the menu
    -- moves the state on to 3 itself and must not be overwritten afterwards.
    local previous_state  = State.packet_state
    local previous_update = State.last_update

    State.packet_state    = 2
    State.last_update     = update
    State.trade_menu_seen = true

    local result = handler(data, update, zone_id, menu_id)

    if result == false then
        -- The handler wants nothing to do with this menu: the store gate was
        -- already open, so there is no packet of ours to patch. Leaving state at
        -- 2 for a conversation we never joined was its own failure -- the next
        -- release read as a player cancel, and every later menu open was ignored
        -- because that path requires state 1.
        State.packet_state = previous_state
        State.last_update  = previous_update
    end

    return result
end

--- Give up on the menu currently open, closing it on the way out.
---
--- A trade that times out used to be handled by dropping our own state back to
--- idle and saying nothing. But a timeout does not mean nothing happened: more
--- often the porter did open its menu, just later than we were willing to wait.
--- Staying silent left the client inside that event, and the server answers no
--- further trades while an event is open -- so the first timeout turned every
--- trade after it into a timeout too. That is the loop where the addon keeps
--- cycling slips, the moogle never answers again, and nothing short of a reload
--- appears to help.
---
--- Sending the close the conversation is still waiting for is what lets the next
--- trade be heard.
function M.abort_menu()
    local opened = windower.packets.last_incoming(PACKET_MENU_OPEN)

    if opened and #opened >= AT.zone_menu + 4 then
        local zone_id, menu_id = opened:unpack('H2', AT.zone_menu + 1)

        -- Only close a menu that is one of ours. Anything else belongs to
        -- whatever the player was doing and is not ours to dismiss.
        if menu_handlers[zone_id] and menu_handlers[zone_id][menu_id] then
            answer_menu(
                opened:unpack('I', AT.npc_id + 1),
                opened:unpack('H', AT.npc_index + 1),
                zone_id, menu_id, MENU_CLOSE_OPTION, 0)
            Debug.log(('abandoned menu %d: sent close so the event ends'):format(menu_id))
        end
    end

    State.force_idle()
end

--- The player cancelled out of the menu. Acknowledge the close and drop every
--- pending list so nothing half-finished carries into the next command.
local function handle_cancel(data, release)
    if data and #data >= AT.zone_menu + 4 then
        local zone_id, menu_id = data:unpack('H2', AT.zone_menu + 1)

        if menu_id == release:unpack('H', 0x05 + 1) then
            answer_menu(
                data:unpack('I', AT.npc_id + 1),
                data:unpack('H', AT.npc_index + 1),
                zone_id, menu_id, MENU_CLOSE_OPTION, 0)
        else
            -- The menu the server released is not the one we had cached, so
            -- there is no reply we can safely send. We stand down regardless:
            -- returning here left the machine pinned at state 2, and from that
            -- point no menu open was ever processed again, because that path
            -- requires state 1. Only a reload cleared it.
            Debug.log('release names a menu we did not open - standing down')
        end
    end

    State.force_idle()
    State.retrieve      = {}
    State.store         = {}
    State.storing_items = false
end

--- The menu closed. Either it is the close we asked for, in which case the slip
--- is done and the next one can start, or the player cancelled mid-conversation.
local function handle_menu_close(data)
    if State.packet_state == 3 then
        State.packet_state         = 0
        State.last_update          = nil
        State.last_trade_confirmed = true
        return
    end

    -- Byte 4 distinguishes a real cancel (2) from an intermediate sub-menu
    -- close (1). Ignoring the latter keeps us in state 2 so the retrieve menu
    -- can carry on processing updates.
    local CANCELLED = 2
    if State.packet_state == 2 and data:byte(0x04 + 1) == CANCELLED then
        handle_cancel(windower.packets.last_incoming(PACKET_MENU_OPEN), data)
    end
end

-- ===========================================================================
-- Event wiring
-- ===========================================================================

windower.register_event('incoming chunk', function(id, data)
    if id == PACKET_MENU_OPEN and State.packet_state == 1 then
        return dispatch_menu(data)
    end

    if id == PACKET_MENU_UPDATE and State.packet_state == 2 then
        dispatch_menu(windower.packets.last_incoming(PACKET_MENU_OPEN), data)
        return
    end

    if id == PACKET_MENU_CLOSE and State.packet_state ~= 0 then
        handle_menu_close(data)
    end
end)

windower.register_event('outgoing chunk', function(id, data, modified, injected)
    if id ~= PACKET_MENU_ANSWER or State.packet_state == 0 or injected then
        return
    end

    -- A menu answer we did not inject nearly always means the client dismissed a
    -- porter store dialog on its own, which is how packing normally finishes.
    -- Exactly one variant is real interference, and separating them is the whole
    -- point of this block: the old label blamed the player for all of them, at one
    -- per trade, which sent a real investigation looking for a cause on the
    -- player's side that was never there.
    --
    -- Order matters. A patched menu leaves the state at 2 as well, so the flag has
    -- to be tested before the state.
    if State.expecting_client_close then
        State.expecting_client_close = false
        Debug.log('store menu closed by client (we patched it open)')

    elseif State.packet_state == 2 then
        -- We had a menu open and were answering its updates, and something else
        -- replied to it. This one really is someone else's click.
        Debug.log('!! 0x5B arrived while we were driving the menu (state=2) - player touched the UI')

    else
        -- The store menu arrived with its gate byte already non-zero, so there was
        -- nothing of ours to patch and handle_store_menu declined it, leaving the
        -- state at 1. The client shows and closes its own dialog, and that close
        -- lands here. Routine on this client: one per trade on the modern store
        -- path, and the trade completes normally afterwards.
        Debug.log(('store menu closed by client (gate already open, state=%d)'):format(
            State.packet_state))
    end

    State.packet_state = 3
end)

-- How many lines of server dialogue to keep per trade. Enough to see a refusal,
-- short enough that a chatty zone cannot grow this without bound.
local TRADE_TRANSCRIPT_LIMIT = 6

windower.register_event('incoming text', function(original, modified, mode)
    -- Porter dialogue pauses on a "press Enter" marker. Stripping it while an
    -- operation is in flight lets the conversation advance on its own.
    local PROMPT_MODES = { [150] = true, [151] = true }

    -- Record whatever the server says while a trade is in flight. This is the
    -- only way to tell a refusal ("you cannot store that") from the server
    -- simply not answering in time, and the two want opposite handling.
    if State.packet_state ~= 0 and #State.trade_messages < TRADE_TRANSCRIPT_LIMIT then
        local plain = original:gsub('[%c\128-\255]', ''):gsub('^%s+', ''):gsub('%s+$', '')
        if plain ~= '' then
            State.trade_messages[#State.trade_messages + 1] = ('[%d] %s'):format(mode, plain)
        end
    end

    local operating = State.packet_state ~= 0
        or State.storing_items
        or (State.retrieve and next(State.retrieve) ~= nil)

    if operating and PROMPT_MODES[mode] then
        return (modified:gsub(string.char(0x7F, 0x31), ''))
    end

    return modified
end)

return M
