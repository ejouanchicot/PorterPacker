---============================================================================
--- PorterPacker / lib/inventory.lua
---============================================================================
--- Every call into windower.ffxi's bag API funnels through this module. Nothing
--- else in the addon moves an item directly.
---
--- Two themes run through the functions below:
---
---   * FFXI rate-limits item movement. Anything that moves items in bulk paces
---     itself and, where a drop would be costly, verifies afterwards and retries.
---   * Bag slot indices are read before a move, not during one, because moving
---     an item renumbers the bag underneath us.
---============================================================================

local Config = require('lib/config')
local Debug  = require('lib/debug')

local M = {}

-- Bag 0 is the inventory itself: it is the destination for retrievals and the
-- source for stores, never a place to shuffle items into.
local INVENTORY = 0

-- Pacing for bulk slip movement. Gathering is lighter than trading, so it can
-- run faster; returns get more spacing plus verification passes because a
-- dropped slip is worse than a slow one.
local GATHER_INTERVAL  = 0.05
local RETURN_INTERVAL  = 0.08
local SETTLE_INTERVAL  = 0.5
local RETURN_PASSES    = 3

-- put_away_items retries when a pass moves nothing, which happens while the
-- server is still digesting a previous burst.
local PUT_AWAY_PASSES  = 4
local PUT_AWAY_BACKOFF = 0.1

-- How long to let item data finish arriving after a zone or login before
-- giving up and proceeding anyway.
local BAG_LOAD_POLLS    = 20
local BAG_LOAD_INTERVAL = 0.25

-- Pacing and settling for pulling gear into inventory ahead of a trade. Both
-- exist because item movement is asynchronous and a trade cannot be built from a
-- bag that is still in motion -- see M.wait_until_settled.
local PULL_INTERVAL   = 0.05
local SETTLE_POLLS    = 24
local SETTLE_POLL     = 0.05

-- ===========================================================================
-- Bag inspection
-- ===========================================================================

--- Free slots left in a bag. Disabled or unknown bags report zero so callers
--- can treat "cannot use" and "full" identically.
--- @param bag_id number
--- @return number
function M.space_available(bag_id)
    local bag = windower.ffxi.get_bag_info(bag_id)
    if not bag or not bag.enabled then
        return 0
    end
    return bag.max - bag.count
end

--- Wait until inventory stops changing, so slot numbers read afterwards are the
--- ones the server will agree with.
---
--- This exists because item movement is asynchronous. get_item and put_item put a
--- packet on the wire; the client's own inventory table only catches up when the
--- server confirms, and nothing tells us when that is. A trade built from a bag
--- read too early carries slot numbers for items that have not landed yet -- and
--- the server's answer to a trade with bad slots is to ignore it entirely. That
--- surfaces as a timeout with the state machine stuck at 1, which is
--- indistinguishable from the porter simply being slow, and it is why the same
--- batch that "times out" during a pack stores fine on a later run: by then the
--- gear was already in inventory and there was nothing to wait for.
---
--- Replaces a flat 0.15s pause, which was a guess that happened to be far too
--- short for a burst of eight moves.
---
--- @param max_seconds number? cap on the wait; defaults to the poll budget
--- @return boolean true when inventory went quiet, false if it was still moving
function M.wait_until_settled(max_seconds)
    local polls = max_seconds and math.floor(max_seconds / SETTLE_POLL) or SETTLE_POLLS

    local function fingerprint()
        local contents = windower.ffxi.get_items(INVENTORY)
        if not contents then
            return nil
        end

        -- Slot index, id and count together: a move changes at least one of them,
        -- and reading them all is cheaper than reasoning about which changed.
        local parts = {}
        for index, item in ipairs(contents) do
            parts[#parts + 1] = ('%d:%d:%d'):format(index, item.id, item.count)
        end
        return table.concat(parts, ',')
    end

    local previous = fingerprint()

    for poll = 1, polls do
        coroutine.sleep(SETTLE_POLL)

        local current = fingerprint()
        if current and current == previous then
            -- Two identical reads in a row: the bag is quiet.
            if poll > 1 then
                Debug.log(('inventory settled after %.2fs'):format(poll * SETTLE_POLL))
            end
            return true
        end
        previous = current
    end

    Debug.log(('!! inventory still moving after %.2fs - trading anyway'):format(polls * SETTLE_POLL))
    return false
end

--- Whether the client has finished populating the bags we are about to use.
---
--- Item data arrives in pieces after a zone or a fresh login: a bag can report
--- holding twenty items while only a handful of slots have come through. Acting
--- on that half-built view produces a run that walks every slip, never manages
--- to assemble a complete slip-plus-cargo batch, and ends having traded nothing.
---
--- The client's own count for a bag is the reference. Comparing it against the
--- slots actually visible says whether the rest is still on its way.
---
--- @param bags table array of bag ids to check
--- @return boolean ready
--- @return string|nil what disagreed, for the log
function M.bags_ready(bags)
    for _, bag_id in ipairs(bags) do
        local info = windower.ffxi.get_bag_info(bag_id)

        if info and info.enabled then
            local contents = windower.ffxi.get_items(bag_id)
            if not contents then
                return false, ('bag %d has no item data yet'):format(bag_id)
            end

            local visible = 0
            for _, item in ipairs(contents) do
                if item.id ~= 0 then
                    visible = visible + 1
                end
            end

            if visible ~= info.count then
                return false, ('bag %d shows %d of %d item(s)'):format(bag_id, visible, info.count)
            end
        end
    end

    return true, nil
end

--- Give the bags a moment to finish arriving.
---
--- Returns whether they settled. A false result is not a reason to refuse the
--- command: this check reads a count the client maintains, and if that count
--- ever means something other than assumed, a wrong answer here should cost a
--- few seconds and a log line rather than block the addon outright. Callers
--- warn and carry on.
---
--- @param bags table array of bag ids
--- @return boolean settled
function M.wait_for_bags(bags)
    local ready, reason = M.bags_ready(bags)
    if ready then
        return true
    end

    Debug.log(('waiting for item data: %s'):format(reason))

    for _ = 1, BAG_LOAD_POLLS do
        coroutine.sleep(BAG_LOAD_INTERVAL)
        ready, reason = M.bags_ready(bags)
        if ready then
            Debug.log('item data complete')
            return true
        end
    end

    Debug.log(('!! item data still incomplete after %.1fs: %s'):format(
        BAG_LOAD_POLLS * BAG_LOAD_INTERVAL, reason))
    return false
end

--- Narrow a bag list down to the ones actually available to write into,
--- dropping the inventory itself. Saves re-querying bag info in inner loops.
local function usable_bags(bags)
    local usable = {}
    for _, bag_id in pairs(bags) do
        if bag_id ~= INVENTORY then
            local bag = windower.ffxi.get_bag_info(bag_id)
            if bag and bag.enabled then
                usable[#usable + 1] = bag_id
            end
        end
    end
    return usable
end

--- First settled item across the given bags matching an id and stack size.
--- @param bags table array of bag ids to search
--- @param item_id number
--- @param minimum_count number smallest acceptable stack
--- @return table|nil item record
function M.find_item(bags, item_id, minimum_count)
    for _, bag_id in pairs(bags) do
        -- A disabled bag reads back nil -- a mog wardrobe becomes one the moment
        -- you leave the mog house. This runs once per outstanding item on every
        -- accounting pass, so an unguarded walk here threw from the middle of a
        -- flow and killed the coroutine with every operation flag still set.
        for _, item in ipairs(windower.ffxi.get_items(bag_id) or {}) do
            if item.id == item_id and item.status == 0 and item.count >= minimum_count then
                return item
            end
        end
    end
    return nil
end

-- ===========================================================================
-- Storage slip shuffling
-- ===========================================================================

--- Collect a snapshot of where the slips sit in a bag, so the indices stay
--- valid while we move them.
--- @param skip table|nil slip ids to leave alone
--- @param only table|nil when given, restrict to these slip ids
local function slip_positions(bag_id, skip, only)
    local found = {}
    local contents = windower.ffxi.get_items(bag_id)
    if not contents then
        return found
    end

    for index, item in ipairs(contents) do
        local is_slip = item.id ~= 0 and item.status == 0 and slips.items[item.id]
        local take = is_slip
            and not (skip and skip[item.id])
            and (only == nil or only[item.id])

        if take then
            found[#found + 1] = { index = index, count = item.count }
        end
    end
    return found
end

--- Pull storage slips out of the configured home bag and into inventory,
--- skipping any already there.
---
--- Pass `only` to fetch just the slips an operation will actually use. A swap
--- usually touches a handful, and hauling all 33 in costs both inventory space
--- and several seconds of paced packets. Omit it to take everything.
---
--- Under-fetching is safe: the trade flow looks for a slip across every bag it
--- knows about and pulls it in on demand, so a slip left behind here only costs
--- a little time, never correctness.
---
--- Reports what it could not do rather than failing silently: when inventory
--- runs out mid-way the caller gets the exact shortfall so it can tell the user
--- how many slots to clear.
---
--- @param only table|nil set of slip ids to fetch; nil means every slip
--- @return number moved   slips successfully pulled
--- @return number needed  free slots still required (0 when all were gathered)
--- @return number pending slips that needed gathering at the start
function M.gather_slips_from_home(only)
    if not windower.ffxi.get_items(Config.SLIP_HOME_BAG) then
        return 0, 0, 0
    end

    -- Slips already in hand do not need pulling again.
    local in_hand = {}
    for _, item in ipairs(windower.ffxi.get_items(INVENTORY) or {}) do
        if item.id ~= 0 and item.status == 0 and slips.items[item.id] then
            in_hand[item.id] = true
        end
    end

    local queue   = slip_positions(Config.SLIP_HOME_BAG, in_hand, only)
    local pending = #queue
    local needed  = math.max(0, pending - M.space_available(INVENTORY))
    local moved   = 0

    for _, slip in ipairs(queue) do
        if M.space_available(INVENTORY) <= 0 then
            Debug.log(('!! gather inventory full at %d/%d (need %d more free slots)'):format(
                moved, pending, needed))
            break
        end
        windower.ffxi.get_item(Config.SLIP_HOME_BAG, slip.index, slip.count)
        moved = moved + 1
        coroutine.sleep(GATHER_INTERVAL)
    end

    if moved > 0 then
        coroutine.sleep(SETTLE_INTERVAL)  -- let the server confirm before we move on
    end

    return moved, needed, pending
end

--- Send every storage slip in inventory back to its home bag.
---
--- Runs up to RETURN_PASSES times: each pass sends what it finds, waits, then
--- re-reads inventory. Anything the server dropped shows up again and gets
--- another attempt, which is cheaper than pacing the first pass slowly enough
--- to never drop anything.
---
--- @return number slips moved across all passes
function M.return_slips_to_home()
    local total = 0

    for pass = 1, RETURN_PASSES do
        local queue = slip_positions(INVENTORY)
        if #queue == 0 then
            break
        end

        Debug.log(('return_slips pass %d: %d slip(s) in inv'):format(pass, #queue))

        local sent = 0
        for _, slip in ipairs(queue) do
            if M.space_available(Config.SLIP_HOME_BAG) <= 0 then
                Debug.log(('!! return satchel full at %d/%d'):format(sent, #queue))
                return total + sent
            end
            windower.ffxi.put_item(Config.SLIP_HOME_BAG, slip.index, slip.count)
            sent = sent + 1
            coroutine.sleep(RETURN_INTERVAL)
        end

        total = total + sent
        coroutine.sleep(SETTLE_INTERVAL)  -- settle before the verification re-read
    end

    return total
end

-- ===========================================================================
-- Moving gear between inventory and storage bags
-- ===========================================================================

--- Push matching inventory items out into the given bags, filling them in the
--- order supplied so the caller controls priority.
---
--- A pass that moves nothing means the server is still busy, so it backs off
--- and tries again; a pass that moves something is enough and returns.
---
--- @param items table set of item_id -> truthy
--- @param bags table array of destination bag ids, most preferred first
--- @return number total stack count moved
function M.put_away_items(items, bags)
    -- Nothing to file away is the common case on a pack-only run, where the
    -- retrieve list is empty by definition. Without this the retry loop below ran
    -- its full four passes finding nothing to move, and since this is called after
    -- every single trade it cost about 430ms per trade -- five seconds across a
    -- one-job pack, spent entirely on scanning for items that were never queued.
    if not items or next(items) == nil then
        return 0
    end

    local destinations = usable_bags(bags)
    if #destinations == 0 then
        return 0
    end

    local remaining_space = {}
    local any_space = false
    for _, bag_id in ipairs(destinations) do
        remaining_space[bag_id] = M.space_available(bag_id)
        any_space = any_space or remaining_space[bag_id] > 0
    end
    if not any_space then
        return 0
    end

    local moved = 0

    for _ = 1, PUT_AWAY_PASSES do
        local moved_this_pass = 0

        for index, item in ipairs(windower.ffxi.get_items(INVENTORY) or {}) do
            if item.status == 0 and items[item.id] then
                for _, bag_id in ipairs(destinations) do
                    if remaining_space[bag_id] > 0 then
                        remaining_space[bag_id] = remaining_space[bag_id] - 1
                        windower.ffxi.put_item(bag_id, index, item.count)
                        moved = moved + item.count
                        moved_this_pass = moved_this_pass + 1
                        break
                    end
                end
            end
        end

        if moved_this_pass > 0 then
            break
        end
        coroutine.sleep(PUT_AWAY_BACKOFF)
    end

    return moved
end

--- Pull the listed items into inventory from the given bags.
---
--- Walks the wanted list in order, so when inventory fills up the items the
--- caller cared about most are the ones that made it in.
---
--- @param items table array of item records; only .id is read
--- @param bags table array of source bag ids
--- @return number total stack count moved
function M.retrieve_items(items, bags)
    if #items == 0 then
        return 0
    end

    local sources = usable_bags(bags)
    if #sources == 0 then
        return 0
    end

    local free  = M.space_available(INVENTORY)
    local moved = 0

    for _, wanted in ipairs(items) do
        for _, bag_id in ipairs(sources) do
            for index, item in ipairs(windower.ffxi.get_items(bag_id) or {}) do
                if item.id == wanted.id and item.status == 0 then
                    if free == 0 then
                        return moved
                    end
                    free  = free - 1
                    moved = moved + item.count
                    windower.ffxi.get_item(bag_id, index, item.count)
                    -- Paced like every other bulk move in this file. This used to
                    -- fire the whole burst inside one frame, which is what the
                    -- caller then had to guess a settle time for.
                    coroutine.sleep(PULL_INTERVAL)
                end
            end
        end
    end

    return moved
end

return M
