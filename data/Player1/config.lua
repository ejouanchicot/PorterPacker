---  ═══════════════════════════════════════════════════════════════════════════
---   PorterPacker - Player1 per-character config
---  ═══════════════════════════════════════════════════════════════════════════
---   Loaded by Config.refresh() at the start of every //po command.
---
---   Available fields:
---     ignore_bags    = { <bag_id>, ... }  bags PorterPacker should not touch
---     slip_home_bag  = <bag_id>            where storage slips are kept
---
---   FFXI bag IDs:
---     0 = inventory   5 = satchel    6 = sack    7 = case
---     8 = wardrobe1  10 = wardrobe2 11 = wardrobe3 12 = wardrobe4
---    13 = wardrobe5  14 = wardrobe6 15 = wardrobe7 16 = wardrobe8
---  ═══════════════════════════════════════════════════════════════════════════

return {
    -- Ignore Wardrobe 7 (used for craft gear, do not touch).
    ignore_bags = { 15 },
}
