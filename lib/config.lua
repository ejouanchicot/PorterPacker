---============================================================================
--- PorterPacker / lib/config.lua
---============================================================================
--- Constants shared across all modules. Pure data, no side effects.
---
--- Edit ALL_JOBS_PACKLIST to match the jobs you actually use.
--- Edit SLIP_HOME_BAG if you keep your storage slips somewhere other than
--- satchel.
---============================================================================

local M = {}

-- Default (full) bag lists. Per-character overrides via M.refresh() can
-- reduce these to skip e.g. a craft wardrobe (W7 in the Player1 example).
local DEFAULT_EQUIPPABLE = { 0, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16 }
local DEFAULT_PRIORITY   = { 8, 10, 11, 12, 13, 14, 15, 16 }
local DEFAULT_SLIP_BAGS  = { 0, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16 }

-- Bags PorterPacker scans/uses for items and slips. Refreshed by M.refresh().
M.equippable_bags = DEFAULT_EQUIPPABLE
-- Bags filled by put_away_items, in order. First bag with space wins.
M.bag_priority   = DEFAULT_PRIORITY
-- Bags storage slips can live in (used by find_item with limited scope).
M.slip_bags      = DEFAULT_SLIP_BAGS
-- Bag IDs PorterPacker should NOT touch. Filled by per-char config refresh.
M.ignore_bags    = {}

-- Bag where the user keeps their 33 storage slips. Pre-gathered into inventory
-- at the start of pack/unpack and returned here at the end.
-- 5=satchel | 6=sack | 7=case
M.SLIP_HOME_BAG = 5

-- Valid FFXI job codes (used to filter file listing in get_jobs_packlist)
M.VALID_JOBS = {
    BLM=true, BLU=true, BRD=true, BST=true, COR=true, DNC=true,
    DRG=true, DRK=true, GEO=true, MNK=true, NIN=true, PLD=true,
    PUP=true, RDM=true, RNG=true, RUN=true, SAM=true, SCH=true,
    SMN=true, THF=true, WAR=true, WHM=true,
}

-- Minimum level a job must have for packall/unpackall to consider it.
-- 1 = any leveled job. Set higher (e.g. 99) to restrict to endgame jobs only.
M.MIN_JOB_LEVEL = 1

--- Reload per-character config from data/<charname>/config.lua (if present).
--- Format example:
---   return { ignore_bags = {15}, slip_home_bag = 5 }
--- This refreshes M.equippable_bags / M.bag_priority / M.slip_bags by removing
--- any bag id listed in ignore_bags. Called automatically before each command.
function M.refresh()
    -- Reset to defaults first so a char without a config file gets the full list.
    M.equippable_bags = {}
    for _, b in ipairs(DEFAULT_EQUIPPABLE) do table.insert(M.equippable_bags, b) end
    M.bag_priority = {}
    for _, b in ipairs(DEFAULT_PRIORITY) do table.insert(M.bag_priority, b) end
    M.slip_bags = {}
    for _, b in ipairs(DEFAULT_SLIP_BAGS) do table.insert(M.slip_bags, b) end
    M.ignore_bags = {}
    M.SLIP_HOME_BAG = 5  -- default fallback

    local p = windower.ffxi.get_player()
    if not p or not p.name then return end
    -- Per-character config lives in data/<charname>/config.lua. require()
    -- doesn't resolve into the data/ subfolder by default, so use a direct
    -- file load via windower.addon_path + dofile.
    local cfg_path = windower.addon_path .. '/data/' .. p.name .. '/config.lua'
    if not windower.file_exists(cfg_path) then return end
    local ok, cfg = pcall(dofile, cfg_path)
    if not ok or type(cfg) ~= 'table' then return end

    -- Apply ignore_bags filter
    if type(cfg.ignore_bags) == 'table' then
        local ignored = {}
        for _, b in ipairs(cfg.ignore_bags) do ignored[b] = true end
        M.ignore_bags = ignored
        local function filter(list)
            local out = {}
            for _, b in ipairs(list) do
                if not ignored[b] then table.insert(out, b) end
            end
            return out
        end
        M.equippable_bags = filter(M.equippable_bags)
        M.bag_priority   = filter(M.bag_priority)
        M.slip_bags      = filter(M.slip_bags)
    end

    -- Apply slip_home_bag override
    if type(cfg.slip_home_bag) == 'number' then
        M.SLIP_HOME_BAG = cfg.slip_home_bag
    end
end

-- Job lists are derived from physical folders:
--   data/<charname>/Active/<JOB>.lua    -> jobs the player actively plays
--   data/<charname>/Inactive/<JOB>.lua  -> jobs the player keeps stored only
--
-- Legacy: data/<charname>/<JOB>.lua at the char root is still recognised by
-- load_file (rétro-compat), but it does NOT contribute to the packlists below
-- - placement matters now: move files into Active/ or Inactive/ to opt in.

--- Internal: scan a single subfolder for <JOB>.lua files.
--- @param subfolder string  'Active' or 'Inactive'
--- @return table sorted list of upper-case job codes
local function scan_subfolder(subfolder)
    local player = windower.ffxi.get_player()
    local char_name = (player and player.name) or nil
    if not char_name then return {} end

    local dir = windower.addon_path .. '/data/' .. char_name .. '/' .. subfolder .. '/'
    local files = windower.get_dir(dir)
    if not files then return {} end

    local jobs = {}
    for _, file in ipairs(files) do
        local job = file:match('^(%w+)%.lua$')
        if job and M.VALID_JOBS[job:upper()] then
            jobs[job:upper()] = true
        end
    end

    -- Filter by player's actual job levels (skip jobs not leveled)
    local player_jobs = (player and player.jobs) or {}
    local list = {}
    for j, _ in pairs(jobs) do
        local level = player_jobs[j] or 0
        if level >= M.MIN_JOB_LEVEL then
            table.insert(list, j)
        end
    end
    table.sort(list)
    return list
end

-- Active jobs = jobs in data/<charname>/Active/.
function M.get_active_jobs_packlist()
    return scan_subfolder('Active')
end

-- Inactive jobs = jobs in data/<charname>/Inactive/.
function M.get_inactive_jobs_packlist()
    return scan_subfolder('Inactive')
end

-- All known jobs = Active + Inactive (de-duplicated, sorted).
function M.get_jobs_packlist()
    local seen = {}
    local list = {}
    for _, j in ipairs(M.get_active_jobs_packlist()) do
        if not seen[j] then seen[j] = true; table.insert(list, j) end
    end
    for _, j in ipairs(M.get_inactive_jobs_packlist()) do
        if not seen[j] then seen[j] = true; table.insert(list, j) end
    end
    table.sort(list)
    return list
end

-- Backward-compat: keep ALL_JOBS_PACKLIST as a *static* fallback (for direct
-- table access elsewhere). Prefer M.get_jobs_packlist() which is char-aware.
M.ALL_JOBS_PACKLIST = {'BLM', 'BRD', 'BST', 'DNC', 'PLD', 'THF', 'WAR'}

-- Every zone that has a Porter Moogle, mapped to the menu id that Moogle uses.
--
-- The Moogle exposes two menus at consecutive ids: retrieval at the id below,
-- and storage one lower still. packets.lua derives the second from the first,
-- so only the retrieval id is recorded here.
--
-- Zone ids and menu ids are fixed game data; the grouping is only for reading.
M.zones = {
    -- Starting nations
    [231] = 874,    -- Northern San d'Oria .............. K-8
    [235] = 547,    -- Bastok Markets ................... I-9
    [240] = 870,    -- Port Windurst .................... L-6
    [245] = 10106,  -- Lower Jeuno ...................... I-6

    -- Their Wings of the Goddess counterparts
    [80]  = 661,    -- Southern San d'Oria [S] .......... M-5
    [87]  = 603,    -- Bastok Markets [S] ............... H-7
    [94]  = 525,    -- Windurst Waters [S] .............. L-10

    -- Outposts and ferry towns
    [247] = 138,    -- Rabao ............................ G-8
    [248] = 1139,   -- Selbina .......................... I-9
    [249] = 338,    -- Mhaura ........................... I-8
    [250] = 309,    -- Kazham ........................... H-9
    [252] = 246,    -- Norg ............................. G-7

    -- Expansion hubs
    [26]  = 621,    -- Tavnazian Safehold ............... F-8
    [50]  = 959,    -- Aht Urhgan Whitegate ............. I-11
    [53]  = 330,    -- Nashmau .......................... H-6
    [256] = 43,     -- Western Adoulin .................. H-11

    -- Instanced areas, where the Moogle has no map coordinate
    [280] = 802,    -- Mog Garden
    [298] = 13,     -- Walk of Echoes [P1]
    [279] = 13,     -- Walk of Echoes [P2]
}

return M
