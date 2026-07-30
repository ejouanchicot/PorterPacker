---============================================================================
--- PorterPacker / lib/naked.lua
---============================================================================
--- Strip the character before an operation, and hand the slots back after.
---
--- Why this is not optional: find_porter_items only ever considers items with
--- `status == 0`, and equipped gear does not have it. A job's own set is exactly
--- the gear most likely to be worn when you ask for it to be packed, so without
--- this the pieces that matter were invisible to every scan -- the addon
--- reported nothing to store while the gear was on your back.
---
--- The recipe is deliberately the same one the GearSwap wardrobe organiser uses
--- for `//gs c wo`, because it is the one proven against this client:
---
---   1. `gs c naked` FIRST, while the slots are still unlocked. Order matters --
---      naked works through equip(), and equip() respects `gs disable`, so
---      locking first makes the strip a no-op.
---   2. Settle, then verify against windower.ffxi.get_items().equipment rather
---      than trusting the command to have landed.
---   3. Escalate through fallbacks while anything is still worn.
---   4. Only then `gs disable all`, to pin the empty state so GearSwap's
---      idle/engaged hooks cannot dress you again mid-run.
---
--- Everything here degrades to a warning rather than an error: a character
--- without a naked set, or GearSwap unloaded, should cost you an incomplete pack
--- and a message saying so -- not a refused command.
---============================================================================

local Debug = require('lib/debug')
local Msg   = require('messages')

local M = {}

--- Slot names as the equipment API reports them.
local SLOTS = {
    'main', 'sub', 'range', 'ammo', 'head', 'neck', 'left_ear', 'right_ear',
    'body', 'hands', 'left_ring', 'right_ring', 'back', 'waist', 'legs', 'feet',
}

-- Time for a gear swap to reach the server and come back. Same value the
-- wardrobe organiser settled on.
local SETTLE = 1.2

-- A lock has to register before the trades start moving items around.
local LOCK_SETTLE = 0.3

--- Which slots still hold something.
--- @return table array of slot names
function M.still_equipped()
    local items = windower.ffxi.get_items()
    if not items or not items.equipment then
        return {}
    end

    local worn = {}
    for _, slot in ipairs(SLOTS) do
        local index = items.equipment[slot]
        if index and index ~= 0 then
            worn[#worn + 1] = slot
        end
    end
    return worn
end

--- Undress, verify, then lock the slots.
---
--- Runs synchronously: every caller is already inside a command coroutine, so
--- this can sleep and return an answer instead of threading callbacks the way
--- the GearSwap side has to.
---
--- @return boolean true when every slot came back empty
function M.strip()
    local attempts = {
        function() windower.send_command('gs c naked') end,
        function() windower.send_command('gs c naked') end,      -- the first one gets dropped often enough to be worth repeating
        function() windower.send_command('gs equip naked') end,   -- bypass the job file's naked set
        function()                                                -- native client command, one slot at a time
            for _, slot in ipairs(M.still_equipped()) do
                windower.send_command(('input /equip %s empty'):format(slot))
            end
        end,
    }

    if #M.still_equipped() == 0 then
        Debug.log('naked: already stripped, nothing to do')
        M.lock()
        return true
    end

    for attempt, strip in ipairs(attempts) do
        strip()
        coroutine.sleep(SETTLE)

        local worn = M.still_equipped()
        if #worn == 0 then
            Debug.log(('naked: stripped on attempt %d of %d'):format(attempt, #attempts))
            M.lock()
            return true
        end

        Debug.log(('naked: attempt %d left %d slot(s) worn: %s'):format(
            attempt, #worn, table.concat(worn, ',')))
    end

    local worn = M.still_equipped()
    Msg.warning(('Could not unequip %d slot(s): %s - that gear will not be packed.')
        :format(#worn, table.concat(worn, ',')))
    Debug.log(('naked: GAVE UP with %s still worn'):format(table.concat(worn, ',')))

    -- Locked even so. Half-dressed and pinned beats half-dressed with GearSwap
    -- free to re-equip the rest while we trade.
    M.lock()
    return false
end

--- Pin the current equipment state so idle/engaged hooks cannot change it.
function M.lock()
    Debug.log('naked: locking slots (gs disable all)')
    windower.send_command('gs disable all')
    coroutine.sleep(LOCK_SETTLE)
end

--- Hand the slots back. Sent more than once on purpose: leaving a player locked
--- out of their own gear is the worst way for this addon to fail, and the
--- commands are idempotent.
function M.release()
    Debug.log('naked: releasing slots (gs enable all)')
    windower.send_command('gs enable all')
    coroutine.schedule(function() windower.send_command('gs enable all') end, 0.5)
    coroutine.schedule(function() windower.send_command('gs enable all') end, 1.5)
end

return M
