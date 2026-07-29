---============================================================================
--- PorterPacker / lib/slips_lookup.lua
---============================================================================
--- O(1) lookup tables built from the slips library's hardcoded storage data.
---
--- Why this exists: the upstream slips.get_slip_id_by_item_id iterates all
--- 33 storage slips and does a linear :contains(id) on each slip's item list
--- (~50-190 items per slip) -- around 3 960 comparisons per call.
--- find_porter_items invokes it per item per bag, so a single scan of all
--- equippable bags burns roughly 12 bags x 80 items x 4 000 ops = ~3.8M ops
--- just to figure out which item belongs to which slip. During trades this
--- happens dozens of times back-to-back, which is what tanked the FPS.
---
--- This module pays the cost once at addon load: iterate the static slip
--- definitions and build a flat item_id -> slip_id map.
---============================================================================

local M = {}

local item_to_slip = {}
do
    for _, slip_id in ipairs(slips.storages) do
        local items_list = slips.items[slip_id]
        if items_list then
            for _, item_id in ipairs(items_list) do
                -- First-write wins: items normally belong to exactly one
                -- storage. Any rare collision (same id in two slip defs)
                -- is handled correctly downstream by the porter dialog
                -- itself, not by this lookup.
                if not item_to_slip[item_id] then
                    item_to_slip[item_id] = slip_id
                end
            end
        end
    end
end

--- O(1) replacement for slips.get_slip_id_by_item_id.
--- @param item_id number FFXI item id
--- @return number|nil storage slip id the item belongs to, or nil if none
function M.get_slip_id(item_id)
    return item_to_slip[item_id]
end

return M
