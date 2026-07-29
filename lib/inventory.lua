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
        for _, item in ipairs(windower.ffxi.get_items(bag_id)) do
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
    for _, item in ipairs(windower.ffxi.get_items(INVENTORY)) do
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

        for index, item in ipairs(windower.ffxi.get_items(INVENTORY)) do
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
            for index, item in ipairs(windower.ffxi.get_items(bag_id)) do
                if item.id == wanted.id and item.status == 0 then
                    if free == 0 then
                        return moved
                    end
                    free  = free - 1
                    moved = moved + item.count
                    windower.ffxi.get_item(bag_id, index, item.count)
                end
            end
        end
    end

    return moved
end

return M
