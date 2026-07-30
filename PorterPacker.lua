_addon.name = 'PorterPacker'
_addon.author = 'ejouanchicot (refactor); orig. Ivaar, mods Gimlic & Siyual'
_addon.version = '2.0.0'
_addon.commands = {'porterpacker', 'packer', 'po'}

---============================================================================
--- PorterPacker - Main entry point
---============================================================================
--- Modular structure:
---   lib/config.lua    - Constants (bags, zones, packlist)
---   lib/state.lua     - Mutable shared state
---   lib/debug.lua     - Logger
---   lib/inventory.lua - Bag operations (gather/return/put_away/retrieve/find)
---   lib/packets.lua   - Packet handlers + state machine + trade_npc
---   lib/flow.lua      - porter_trade (single) + continuous_porter (bulk)
---   messages.lua      - UI formatting
---   data/             - Per-job item lists
---
--- This file owns:
---   - Windower require/load directives
---   - The addon command handler (`//po ...`)
---   - The bulk packall/unpackall iteration logic
---============================================================================

require('pack')
require('sets')
require('logger')
require('coroutine')
bit = require('bit')
slips = require('slips')
res = require('resources')

local Msg = require('messages')
local Config = require('lib/config')
local State = require('lib/state')
local Debug = require('lib/debug')
local Inv = require('lib/inventory')
local Packets = require('lib/packets')
local Flow = require('lib/flow')
local Naked = require('lib/naked')
local SlipsLookup = require('lib/slips_lookup')

---============================================================================
--- File loader: turns a list of item NAMES into a set of item IDs.
---
--- Lookup priority (FIRST hit wins):
---   1. data/<charname>/Active/<file>.lua    (job player actively plays)
---   2. data/<charname>/Inactive/<file>.lua  (job stored only, not played)
---   3. data/<charname>/<file>.lua           (legacy flat per-char layout)
---   4. data/<file>.lua                       (legacy generic location)
---
--- Active/Inactive split lets //po unpackall target only active jobs by default.
--- Per-character profile lets multiple characters share the addon while each
--- has their own gear list (Player1/Active/COR.lua vs Player2/Active/COR.lua).
---============================================================================

-- Per-command cache: <file_name>|<mode> -> set of item_ids.
-- Cleared at the top of every addon command (right after Config.refresh) so
-- per-character config changes always take effect. Within a single command,
-- the same (file, mode) pair is never re-scanned against res.items.
--
-- A //po swap previously re-scanned res.items ~17 times per swap
-- (1 target unpack + 1 per job pack list + 1 target unpack again),
-- each scan being a full iteration of ~30 000 items with two string.lower
-- allocations per item. The cache eliminates the redundant scans.
--
-- IMPORTANT: load_file returns a *fresh copy* on cache hit, because callers
-- mutate the result (assigned to State.retrieve which gets entries removed
-- during unpack, or filtered in bulk_op via exclude_ids).
local load_file_cache = {}

-- Reverse lookup: lower-cased item name -> list of ids. Built once at addon
-- load by scanning res.items (~30 000 entries). Without this, every load_file
-- call iterated all of res.items and called string.lower twice per item to
-- match a job's ~50-200 entries -- a 100-600x ratio of wasted work.
--
-- IMPORTANT: one name can map to multiple ids. Reforged armor (Maxixi/Horos/
-- Macuele/Meg./Charis/etc.) ships with two ids per piece -- one for races=298
-- (Hume/Elvaan/Tarutaru/Galka males) and one for races=212 (females + Mithra)
-- -- and slip storage stores BOTH ids. If we kept only one id per name, the
-- unpack set would miss the gender variant the player actually owns and those
-- items would never come out of the slip. So map name -> array of ids and
-- resolve every match in load_file.
--
-- Both .name and .name_log are indexed because data files use the display
-- name ("Naegling") while res.items sometimes only matches via name_log.
local items_by_lower_name = {}
local function add_name_id(name, id)
    if not name or name == '' then return end
    local key = name:lower()
    local list = items_by_lower_name[key]
    if not list then
        items_by_lower_name[key] = {id}
        return
    end
    for _, existing in ipairs(list) do
        if existing == id then return end
    end
    list[#list + 1] = id
end
do
    local count = 0
    for id, item in pairs(res.items) do
        add_name_id(item.name_log, id)
        add_name_id(item.name, id)
        count = count + 1
    end
    -- Tiny sanity check so a corrupt resources table is loud, not silent.
    if count == 0 then
        windower.add_to_chat(167,
            '[PorterPacker] WARNING: res.items returned 0 entries - name lookup table is empty.')
    end
end

--- Load a job data file and return a set of FFXI item ids matching the names.
---
--- The data file's `return` value can be:
---   1. A flat array of item-name strings (legacy format) — used for both
---      pack and unpack indiscriminately.
---   2. A split table `{ pack = {...}, unpack = {...} }` — pack uses the wider
---      list (e.g. items the player owns even for jobs not played), unpack
---      uses the narrower list (only items in the active char's set files).
---
--- @param file_name string  Job code or custom name (e.g. 'COR', 'Player1_THF')
--- @param mode      string? 'pack' or 'unpack' (only used for split files);
---                          defaults to 'pack' if absent.
--- @return table set of item_ids matching the resolved list, or nil on error
local function load_file(file_name, mode)
    mode = mode or 'pack'

    -- Cache hit: return a fresh copy (callers mutate the result)
    local cache_key = file_name .. '|' .. mode
    local cached = load_file_cache[cache_key]
    if cached then
        local copy = {}
        for id in pairs(cached) do copy[id] = true end
        return copy
    end

    local player = windower.ffxi.get_player()
    local char_name = (player and player.name) or nil

    -- Build lookup paths in priority order:
    -- char/Active -> char/Inactive -> char root (legacy) -> data root (legacy)
    local paths = {}
    if char_name then
        table.insert(
            paths,
            {
                path = windower.addon_path .. '/data/' .. char_name .. '/Active/' .. file_name .. '.lua',
                label = char_name .. '/Active/' .. file_name .. '.lua'
            }
        )
        table.insert(
            paths,
            {
                path = windower.addon_path .. '/data/' .. char_name .. '/Inactive/' .. file_name .. '.lua',
                label = char_name .. '/Inactive/' .. file_name .. '.lua'
            }
        )
        table.insert(
            paths,
            {
                path = windower.addon_path .. '/data/' .. char_name .. '/' .. file_name .. '.lua',
                label = char_name .. '/' .. file_name .. '.lua'
            }
        )
    end
    table.insert(
        paths,
        {
            path = windower.addon_path .. '/data/' .. file_name .. '.lua',
            label = file_name .. '.lua'
        }
    )

    for _, p in ipairs(paths) do
        if windower.file_exists(p.path) then
            local item_table = dofile(p.path)
            -- Detect split format: presence of .pack or .unpack keys.
            local is_split =
                type(item_table) == 'table' and (type(item_table.pack) == 'table' or type(item_table.unpack) == 'table')
            local names_list
            if is_split then
                names_list = item_table[mode] or item_table.pack or item_table.unpack
            else
                names_list = item_table -- legacy flat list
            end

            -- Resolve names -> ids via the precomputed reverse lookup table
            -- (built once at addon load). One hash lookup per data-file entry
            -- instead of one full pass over res.items per call. Each name may
            -- map to multiple ids (gender variants for reforged armor) -- add
            -- them all so the unpack set covers whichever id the slip stored.
            local item_ids = {}
            for _, name in pairs(names_list) do
                if type(name) == 'string' then
                    local ids = items_by_lower_name[name:lower()]
                    if ids then
                        for _, id in ipairs(ids) do
                            item_ids[id] = true
                        end
                    end
                end
            end
            if table.length(item_ids) ~= 0 then
                local label = p.label
                if is_split then
                    label = label .. ' [' .. mode .. ']'
                end
                Msg.file_loaded(label)
                -- Cache the canonical set, then hand the caller its own copy
                -- so subsequent mutations (State.retrieve removals, exclude
                -- filtering) don't corrupt the cached entry.
                load_file_cache[cache_key] = item_ids
                local copy = {}
                for id in pairs(item_ids) do copy[id] = true end
                return copy
            end
            Msg.error(('Unable to load items from %s'):format(p.label))
            return nil
        end
    end

    -- Build a friendly error message listing the paths tried
    local tried = {}
    for _, p in ipairs(paths) do
        table.insert(tried, p.label)
    end
    Msg.error('No matching data file found. Tried: ' .. table.concat(tried, ', '))
    return nil
end

---============================================================================
--- Bulk packall / unpackall logic
---============================================================================

---============================================================================
--- Count items in equippable_bags whose id is in `item_ids` (set).
--- Used by bulk_op to skip jobs that have nothing to pack.
---============================================================================
local function count_items_in_bags(item_ids)
    local count = 0
    for _, bag_id in ipairs(Config.equippable_bags) do
        local bag = windower.ffxi.get_items(bag_id)
        if bag then
            for _, it in ipairs(bag) do
                if it.id and it.id > 0 and it.status == 0 and item_ids[it.id] then
                    count = count + 1
                end
            end
        end
    end
    return count
end

---============================================================================
--- Working out which storage slips an operation actually needs
---============================================================================
--- Fetching all 33 slips costs 33 inventory slots and roughly seven seconds of
--- paced packets, whether or not the operation touches them. A typical swap
--- involves a handful. These helpers work out the real set beforehand.
---
--- Getting the set slightly wrong is not dangerous: the trade flow searches
--- every bag for a slip it needs and pulls it in on demand, so a slip missed
--- here costs a moment, not correctness.

--- Slips that at least one item currently in the bags would be stored on.
--- Reads the bags rather than the job's item list, because only what you are
--- actually carrying can be packed.
local function slips_with_packable_items()
    local found = {}
    for slip_id, group in pairs(Packets.find_porter_items(Config.equippable_bags)) do
        for _, item in ipairs(group) do
            -- The slip itself sits in its own group; ignore it and look for cargo.
            if item.id ~= slip_id then
                found[slip_id] = true
                break
            end
        end
    end
    return found
end

--- Slips currently holding at least one item on the retrieve list.
local function slips_holding_wanted_items()
    local found = {}
    for slip_id, contents in pairs(slips.get_player_items()) do
        if contents.n ~= 0 then
            for _, item_id in ipairs(contents) do
                if State.retrieve[item_id] then
                    found[slip_id] = true
                    break
                end
            end
        end
    end
    return found
end

--- Everything the pending operation will touch, derived from State.
--- @return table set of slip ids
--- @return number how many
local function slips_needed_now()
    local needed = {}

    if State.storing_items then
        for slip_id in pairs(slips_with_packable_items()) do
            needed[slip_id] = true
        end
    end

    if next(State.retrieve) then
        for slip_id in pairs(slips_holding_wanted_items()) do
            needed[slip_id] = true
        end
    end

    local count = 0
    for _ in pairs(needed) do
        count = count + 1
    end
    return needed, count
end

--- Make sure the client has finished sending item data before we act on it.
---
--- Warns and proceeds when it has not: the readiness test reads a count the
--- client maintains, and if that ever means something other than assumed, the
--- cost should be a few wasted seconds rather than a command that refuses to
--- run.
local function await_item_data()
    if Inv.wait_for_bags(Config.equippable_bags) then
        return
    end

    Msg.warning('Item data still loading - results may be incomplete. Retry in a moment if so.')
end

--- Bring in the slips an operation needs, and say precisely what is missing
--- when inventory cannot hold them.
--- @param wanted table|nil set of slip ids, or nil to fetch every slip
--- @param context string label for the debug log
--- @return boolean ok      false when the caller should abort
--- @return number  gathered
local function gather_needed_slips(wanted, context)
    local gathered, needed, pending = Inv.gather_slips_from_home(wanted)

    if needed and needed > 0 then
        local left_behind = pending - gathered
        Msg.error(('Not enough inventory space: %d of %d needed slip(s) could not be gathered.')
            :format(left_behind, pending))
        Msg.error(('Free %d more inventory slot(s), then run the command again.'):format(needed))
        Debug.log(('ABORT [%s]: missing %d slots, %d of %d slips ungathered'):format(
            context, needed, left_behind, pending))
        return false, gathered
    end

    if gathered > 0 then
        Msg.info(('Gathered %d storage slip(s) from satchel'):format(gathered))
    end
    return true, gathered
end

---============================================================================
--- Bulk operation: iterate the active char's job list, packing or unpacking.
---============================================================================
--- @param is_pack    boolean  true = pack everything, false = unpack everything
--- @param player     table    windower.ffxi.get_player()
--- @param skip_job  string?  optional job code to exclude from the iteration
---                           (e.g. 'PLD' to pack everything except PLD)
--- @param mode      string?  'active'   = only jobs in data/<char>/Active/
---                           'inactive' = only jobs in data/<char>/Inactive/
---                           nil        = every job (Active + Inactive)
--- @param defer_slip_return boolean? if true, slips stay in inv at the end
---        (caller is responsible for the final return). Used by swap mode so
---        the unpack phase can reuse the slips already in inv.
--- @param exclude_ids table? set of item_ids to remove from each job's pack
---        list before packing. Used by swap mode to keep items in inv that
---        the upcoming unpack phase will need anyway (otherwise we'd pack
---        Naegling under WAR.lua then immediately re-unpack it under THF
---        because Naegling appears in nearly every job's pack list).
-- Pause between two jobs that traded, on top of waiting for the state machine
-- to go idle. Covers packets the client has queued but not yet put on the wire.
local INTER_JOB_SETTLE = 2.0

local function bulk_op(is_pack, player, skip_job, mode, defer_slip_return, exclude_ids, token)
    local skip_upper = skip_job and skip_job:upper() or nil
    local action_label = is_pack and 'PACK ALL' or 'UNPACK ALL'
    if mode == 'active' then
        action_label = action_label .. ' (ACTIVE)'
    end
    if mode == 'inactive' then
        action_label = action_label .. ' (INACTIVE)'
    end

    -- Discover jobs from data/<charname>/{Active,Inactive}/ (filtered by
    -- player.jobs[JOB] >= Config.MIN_JOB_LEVEL).
    local jobs_list
    if mode == 'active' then
        jobs_list = Config.get_active_jobs_packlist()
    elseif mode == 'inactive' then
        jobs_list = Config.get_inactive_jobs_packlist()
    else
        jobs_list = Config.get_jobs_packlist()
    end
    if #jobs_list == 0 then
        local cname = (player and player.name) or '?'
        if mode == 'active' then
            Msg.error(('No Active jobs found - put files in data/%s/Active/<JOB>.lua.'):format(cname))
            return
        end
        if mode == 'inactive' then
            Msg.error(('No Inactive jobs found - put files in data/%s/Inactive/<JOB>.lua.'):format(cname))
            return
        end
        Msg.error(
            ('No data files found in data/%s/Active/ or /Inactive/ - create some first (or use //po export to bootstrap).'):format(
                cname
            )
        )
        return
    end

    local target_count = #jobs_list
    if skip_upper then
        target_count = target_count - 1
    end

    await_item_data()

    Msg.bulk_start(action_label, nil, target_count, skip_upper)
    Debug.log(
        ('===== BULK %s START - %s%s ====='):format(
            action_label,
            table.concat(jobs_list, ','),
            skip_upper and (' [SKIP ' .. skip_upper .. ']') or ''
        )
    )

    -- Pre-gather slips once. Packing can see what is in the bags and so knows
    -- exactly which slips it will use; unpacking has not loaded the per-job
    -- item lists yet, so it still has to take everything.
    local wanted = is_pack and slips_with_packable_items() or nil
    local ok, gathered = gather_needed_slips(wanted, 'bulk')
    if not ok then
        return
    end
    if gathered > 0 then
        Debug.log(('gathered %d slips - 2s settle'):format(gathered))
        coroutine.sleep(2.0)
    end

    -- Counters
    -- Whether the job before this one put anything on the wire, which decides
    -- if the next one has to wait for it to settle.
    local previous_job_traded = false
    local total_done = 0 -- jobs that actually performed trades
    local total_skipped = 0 -- jobs skipped (no items / no file)
    local total_aborted = 0 -- jobs aborted (network deadlock)
    local total_items = 0
    local total_slips = 0
    local stalled_jobs = 0

    for job_idx, job in ipairs(jobs_list) do
        -- A reset, a zone change or a logout during a long run hands ownership
        -- on; stopping at the job boundary is what lets //po reset end a bulk
        -- sweep instead of leaving it to grind through every remaining job.
        if State.superseded(token) then
            Debug.log('===== BULK ABANDONED: no longer owns the addon =====')
            return
        end

        -- Caller-requested skip (target of an unpack)
        if skip_upper and job:upper() == skip_upper then
            Debug.log(('SKIP job %s (excluded by caller: target of unpack)'):format(job))
        else
            Debug.log(('---------- JOB %d/%d: %s ----------'):format(job_idx, #jobs_list, job))
            -- For split-format files, pack uses the wide list, unpack the narrow one.
            local item_ids = load_file(job, is_pack and 'pack' or 'unpack')

            if not item_ids then
                -- No data file -> skip
                total_skipped = total_skipped + 1
                previous_job_traded = false
                Debug.log(('SKIP %s: no data file'):format(job))
            else
                -- Swap-mode optimization: exclude items that the upcoming
                -- unpack phase will need. Removing them from THIS job's pack
                -- set means they stay in inv instead of doing a pack+unpack
                -- round-trip through the Porter (saves trades for shared gear
                -- like Naegling/Sibyl Scarf that appear in every job's pack).
                if is_pack and exclude_ids then
                    local removed = 0
                    for id in pairs(exclude_ids) do
                        if item_ids[id] then
                            item_ids[id] = nil
                            removed = removed + 1
                        end
                    end
                    if removed > 0 then
                        Debug.log(('  %s pack list: excluded %d item(s) destined for unpack'):format(job, removed))
                    end
                end

                -- Skip-if-empty optimization: for PACK ops, scan bags and count
                -- how many items the job has currently. If 0, skip (already packed).
                local in_bag_count = is_pack and count_items_in_bags(item_ids) or nil
                if is_pack and in_bag_count == 0 then
                    total_skipped = total_skipped + 1
                    previous_job_traded = false
                    Debug.log(('SKIP %s: 0 items in bags (already packed)'):format(job))
                else
                    -- Let anything the previous job put on the wire settle.
                    --
                    -- The poll below is the real check; the flat pause after it
                    -- is insurance against packets the client has queued but not
                    -- sent. A job that never traded queued nothing, so it skips
                    -- the pause entirely -- on a mostly-packed character that is
                    -- the majority of the loop.
                    if job_idx > 1 then
                        local poll = 0
                        while State.packet_state ~= 0 and poll < 200 do
                            coroutine.sleep(0.025)
                            poll = poll + 1
                        end

                        if previous_job_traded then
                            Debug.log(('inter-job poll: %d cycles, state=%d, then %.1fs settle'):format(
                                poll, State.packet_state, INTER_JOB_SETTLE))
                            coroutine.sleep(INTER_JOB_SETTLE)
                        else
                            Debug.log(('inter-job poll: %d cycles, state=%d, previous job idle - no settle'):format(
                                poll, State.packet_state))
                        end
                    end

                    if State.packet_state ~= 0 then
                        Msg.warning(
                            ('State stuck (state=%d) before job %s - forcing reset'):format(State.packet_state, job)
                        )
                        Debug.log(('FORCE RESET state from %d to 0 before %s'):format(State.packet_state, job))
                        -- Close the menu rather than only forgetting it. A state
                        -- left non-zero here means a conversation the server still
                        -- considers open, and it takes no trades until it ends --
                        -- so every job after this one used to time out too.
                        Packets.abort_menu()
                        coroutine.sleep(1.0)
                    end

                    -- Re-gather any missing slips. Idempotent: skips slips already in inv.
                    if job_idx > 1 then
                        -- State.store still holds the previous job's list here,
                        -- and it is not replaced until reset_job() below. Clear
                        -- it for the scan so every packable item is considered,
                        -- not just the ones the last job happened to want.
                        local previous_store = State.store
                        State.store = {}
                        local re_wanted = is_pack and slips_with_packable_items() or nil
                        State.store = previous_store

                        local re_gathered, re_needed = Inv.gather_slips_from_home(re_wanted)
                        if re_needed and re_needed > 0 then
                            Msg.warning(
                                ('Could not gather all slips before %s: need %d more inv slot(s)'):format(
                                    job,
                                    re_needed
                                )
                            )
                            Debug.log(('!! re-gather inv full: missing %d slots before %s'):format(re_needed, job))
                        end
                        if re_gathered > 0 then
                            Debug.log(('  re-gathered %d additional slip(s) before %s'):format(re_gathered, job))
                            coroutine.sleep(1.0)
                        end
                    end

                    -- Reset per-job state and configure for this job
                    State.reset_job()
                    if is_pack then
                        State.store = item_ids
                        State.storing_items = true
                    else
                        State.retrieve = item_ids
                        State.storing_items = false
                    end

                    Msg.bulk_job_header(job_idx, #jobs_list, job, is_pack and 'pack' or 'unpack', in_bag_count)

                    Debug.log(
                        ('--> calling continuous_porter for %s (in_bags=%s, inv_free=%d)'):format(
                            job,
                            tostring(in_bag_count),
                            Inv.space_available(0)
                        )
                    )
                    Flow.continuous_porter(token)

                    -- Capture per-job totals (continuous_porter sets these at line 371-372
                    -- of flow.lua) and add to the bulk-wide accumulator.
                    local job_items = State.async_total_items or 0
                    local job_slips = State.async_total_slips or 0
                    total_items = total_items + job_items
                    total_slips = total_slips + job_slips

                    local job_attempts = State.async_trade_attempts
                    local job_successes = State.async_trade_successes
                    -- Only a job that actually traded leaves packets in flight.
                    previous_job_traded = job_attempts > 0
                    Debug.log(
                        ('<-- %s done (items=%d, slips=%d, attempts=%d, successes=%d, inv_free=%d, state=%d)'):format(
                            job,
                            job_items,
                            job_slips,
                            job_attempts,
                            job_successes,
                            Inv.space_available(0),
                            State.packet_state
                        )
                    )

                    total_done = total_done + 1

                    -- Stall detection
                    if job_attempts > 0 and job_successes == 0 then
                        stalled_jobs = stalled_jobs + 1
                        Msg.warning(('Job %s: %d trade(s) failed, server not responding'):format(job, job_attempts))
                        Debug.log(
                            ('STALL #%d on job %s (%d attempts, 0 successes)'):format(stalled_jobs, job, job_attempts)
                        )
                        if stalled_jobs >= 2 then
                            Msg.error('Network deadlock detected (2 jobs failed in a row).')
                            Msg.error('FFXI client packet stuck - zone to recover, then retry.')
                            Debug.log('===== BULK ABORTED: deadlock detected =====')
                            total_aborted = #jobs_list - job_idx
                            break
                        end
                    else
                        stalled_jobs = 0
                    end
                end
            end
        end
    end

    -- Post-return slips once at the very end (skipped when caller is in swap
    -- mode and will do its own final return after the unpack phase).
    if defer_slip_return then
        Debug.log('Slip return deferred to caller (swap mode)')
    else
        Debug.log('--- Post-return slips to satchel ---')
        local returned = Inv.return_slips_to_home()
        Debug.log(('return_slips_to_home: %d slips, inv_free=%d'):format(returned, Inv.space_available(0)))
        if returned > 0 then
            Msg.info(('Returned %d storage slip(s) to satchel'):format(returned))
        end
    end

    Debug.log(
        ('===== BULK COMPLETE: %d done, %d skipped, %d aborted ====='):format(total_done, total_skipped, total_aborted)
    )

    Msg.bulk_end(action_label, total_done, total_skipped, total_aborted, total_items, total_slips)
end

---============================================================================
--- Export command (//po export [file] [all])
---============================================================================

local function export_op(commands, player, all_arg)
    local str = 'return {\n'
    local bags = {0}
    if all_arg then
        bags = {0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
    end
    for _, bag_id in pairs(bags) do
        -- get_items returns nil for disabled bags (mog wardrobe outside moghouse)
        local bag_items = windower.ffxi.get_items(bag_id)
        if bag_items then
            for _, item in ipairs(bag_items) do
                if SlipsLookup.get_slip_id(item.id) and res.items[item.id] then
                    str = str .. ('\t"%s",\n'):format(res.items[item.id].name)
                end
            end
        end
    end
    str = str .. '}\n'
    local file_path = windower.addon_path .. '/data/'
    if not windower.dir_exists(file_path) then
        windower.create_dir(file_path)
    end
    local out_name
    if all_arg then
        out_name = ('export_%s_%s'):format(player.name, player.main_job)
    else
        out_name = commands[2] or ('export_%s_%s'):format(player.name, player.main_job)
    end
    local full_path = file_path .. out_name .. '.lua'
    local export, err = io.open(full_path, 'w')
    if not export then
        Msg.error(('Could not write %s: %s'):format(out_name .. '.lua', tostring(err)))
        return
    end
    export:write(str)
    export:close()
    Msg.success(('Exported storable inventory to ' .. Msg.C.cyan .. '%s.lua'):format(out_name))
end

---============================================================================
--- Addon command handler
---============================================================================
---
--- Command set (5 primaries + utilities):
---     //po                       -> swap to current job (pack others + unpack)
---     //po <JOB>                 -> swap to <JOB>
---     //po u [JOB]               -> unpack only (alias: unpack)
---     //po p [JOB]               -> pack only (alias: pack)
---     //po all                   -> pack ALL jobs (alias: packall)
---     //po fetch                 -> unpack all Active (alias: unpackall)
---     //po fetch inactive        -> unpack all Inactive
---     //po s [JOB|all|inactive]  -> show storage status (alias: status)
---     //po help / debug / reset / slips / export   -> utilities
---============================================================================

--- Run a single-job pack-or-unpack flow.
--- @param mode      string   'unpack' | 'pack' | 'swap'  (swap = auto-pack-others + unpack)
--- @param target    string   job code (e.g. 'PLD'); defaults handled by caller
--- @param player    table    windower player object
local function single_job_op(mode, target, player, token)
    local target_upper = target:upper()
    local is_pack = (mode == 'pack')
    local is_unpack = (mode == 'unpack')
    local is_swap = (mode == 'swap')

    -- Swap = pack everything else first, then unpack the target.
    if is_swap then
        Msg.action('AUTO PACK ALL', 'before unpacking ' .. target_upper .. ' (skip ' .. target_upper .. ')', true)
        Debug.log(('===== AUTO PACK ALL before unpack %s (skip %s) ====='):format(target_upper, target_upper))
        -- Pre-load the target's UNPACK list and pass it as an exclusion set
        -- to the pack phase. Items destined for unpack (e.g. Naegling shared
        -- across every job's pack list) stay in inv through the pack phase
        -- instead of being stored and immediately re-fetched. Saves trades
        -- proportional to overlap between target.unpack and other jobs' pack.
        local target_unpack_ids = load_file(target_upper, 'unpack')
        if target_unpack_ids then
            local n = 0
            for _ in pairs(target_unpack_ids) do n = n + 1 end
            Debug.log(('PACK exclusion set: %d items from %s.unpack will stay in inv'):format(n, target_upper))
        end
        -- mode=nil = full job list. defer_slip_return=true so slips stay in
        -- inv for the upcoming unpack phase (saves a return + re-gather cycle).
        bulk_op(true, player, target_upper, nil, true, target_unpack_ids, token)

        if State.superseded(token) then
            Debug.log('SWAP abandoned after the pack phase: no longer owns the addon')
            return
        end

        Debug.log('AUTO PACK ALL complete - 2s settle before unpack')
        coroutine.sleep(2.0)
        State.reset_job()
    end

    -- Load the target job's item list with mode-appropriate filter:
    -- - pack/swap-source: wide list (everything storable, even unused items)
    -- - unpack/swap-target: narrow list (items actually used in the active sets)
    local item_ids = load_file(target_upper, is_pack and 'pack' or 'unpack')
    if not item_ids then
        return
    end

    -- Clear whatever the last command left behind before configuring this one.
    --
    -- Only the swap path used to reset here, so a plain pack or unpack started
    -- with the previous command's lists still in State. That matters because
    -- find_porter_items treats State.original_retrieve as an exclusion set: a
    -- pack run straight after a swap onto the same job would hide exactly the
    -- gear that swap had just fetched -- which is the gear the pack is there to
    -- put away. The pre-scan therefore reported nothing to store, while the
    -- trade loop, running after run_bulk_transfer had cleared the field, found
    -- slips to trade after all. The two disagreed because they were reading
    -- different state, not different bags.
    State.reset_job()

    if is_pack then
        State.store = item_ids
        State.storing_items = true
    else
        State.retrieve = item_ids
        State.storing_items = false
    end

    local action_label = is_pack and 'PACK' or (is_swap and 'SWAP' or 'UNPACK')
    Msg.action(action_label, target_upper, true)

    await_item_data()

    -- State.store / State.retrieve are set by now, so we know exactly which
    -- slips this job needs and can leave the rest in the satchel.
    local wanted, wanted_count = slips_needed_now()

    -- An empty set is the one answer we should not trust. It claims the
    -- operation touches no slip at all, yet the trade loop that follows does
    -- its own scan and has been seen to find slips to trade anyway -- and a
    -- trade whose slip was never brought in is a trade the porter ignores,
    -- which shows up as a timeout with the state machine stuck at 1.
    --
    -- Rather than reason about which scan is right, fall back to fetching
    -- everything, which is what this did before the set was computed at all.
    if wanted_count == 0 then
        Debug.log(('%s: needed-slip set came back empty - fetching all slips'):format(target_upper))
        wanted = nil
    else
        Debug.log(('%s: %d slip(s) needed (of %d)'):format(
            target_upper, wanted_count, #slips.storages))
    end

    if not gather_needed_slips(wanted, target_upper) then
        return
    end

    Flow.continuous_porter(token)

    if State.superseded(token) then
        return  -- another operation owns the bags now; do not move its slips
    end

    local returned = Inv.return_slips_to_home()
    if returned > 0 then
        Msg.info(('Returned %d storage slip(s) to satchel'):format(returned))
    end
    Msg.completed()
end

--- Print storage status: per-job count of items currently in bags vs total.
--- @param scope  string  'active' | 'inactive' | 'all' | <JOB code>
local function status_op(scope, player)
    local current_job = (player and player.main_job) or '?'
    local jobs_list, header_label

    scope = (scope or 'active'):lower()
    if scope == 'inactive' then
        jobs_list = Config.get_inactive_jobs_packlist()
        header_label = 'Inactive'
    elseif scope == 'all' then
        jobs_list = Config.get_jobs_packlist()
        header_label = 'All jobs'
    elseif Config.VALID_JOBS[scope:upper()] then
        jobs_list = {scope:upper()}
        header_label = scope:upper()
    else
        jobs_list = Config.get_active_jobs_packlist()
        header_label = 'Active'
    end

    local rows = {}
    for _, job in ipairs(jobs_list) do
        local item_ids = load_file(job)
        if item_ids then
            local n_total = 0
            for _ in pairs(item_ids) do
                n_total = n_total + 1
            end
            local n_in_bag = count_items_in_bags(item_ids)
            local status
            if n_in_bag == 0 then
                status = 'stored'
            elseif n_in_bag >= n_total then
                status = 'out'
            else
                status = 'MIXED'
            end
            table.insert(
                rows,
                {
                    job = job,
                    in_bag = n_in_bag,
                    total = n_total,
                    status = status,
                    current = (job == current_job:upper())
                }
            )
        end
    end

    Msg.show_status(header_label, rows, current_job)
end

--- Run one action command with the addon claimed for its whole duration.
---
--- The lock is the point of this function. `packet_state` was never one: it sits
--- at 0 for seconds at a time inside a run -- waiting on item data, settling
--- between jobs, backing off between retries, throughout every burst of item
--- movement -- and a command typed in one of those windows used to pass the guard
--- and start a second flow over the same shared state. Both traded, each consumed
--- the other's menu answers, neither finished, and //po reset could not stop
--- either one, because it clears fields and a coroutine is not a field.
---
--- Deliberately not wrapped in pcall: every action below sleeps, and yielding
--- across a pcall boundary is not portable on this runtime. If an action does
--- throw, the lock stays held and //po reset releases it -- reset_all clears
--- operation_active as well as bumping the generation.
--- @param strip_gear boolean? undress before the action and hand the slots back
---        after. Every pack/unpack path wants this: find_porter_items only sees
---        items with status 0, which equipped gear does not have, so a job's own
---        set -- the gear most likely to be worn when you ask for it to be packed
---        -- was invisible to every scan.
local function run_exclusive(action, strip_gear)
    local token = State.begin_operation()
    if not token then
        Msg.already_running()
        return
    end

    if strip_gear then
        Naked.strip()
    end

    action(token)

    if strip_gear then
        Naked.release()
    end

    State.end_operation(token)
end

-- Zoning or logging out mid-operation used to leave every flag exactly as it
-- was: a packet state that refused all later commands, lists describing a job
-- that no longer applies, and a run still grinding through jobs in a zone with
-- no Moogle in it. Handing ownership on stops the run and clears the slate.
windower.register_event('zone change', function()
    if State.operation_active or State.packet_state ~= 0 then
        Msg.warning('Zoned mid-operation - PorterPacker stopped and reset.')
        Debug.log('zone change during an operation - reset')
        -- The slots were locked for the run that just got cut short. Leaving a
        -- player unable to change gear is the worst way for this addon to fail.
        Naked.release()
    end
    State.reset_all()
end)

windower.register_event('logout', function()
    State.reset_all()
end)

windower.register_event(
    'addon command',
    function(...)
        local commands = {...}
        local player = windower.ffxi.get_player()
        if not player then
            return
        end
        -- Re-read per-character config so ignore_bags / slip_home_bag etc. are
        -- always current (cheap: just reads one optional file at <char>/config.lua).
        Config.refresh()
        -- Drop the load_file cache so per-char config changes (and edits to
        -- data files between commands) always take effect. Within a single
        -- command, the cache survives across the multiple load_file calls a
        -- swap performs (target unpack + per-job pack lists + target unpack
        -- again), eliminating the expensive res.items re-scans.
        load_file_cache = {}
        local cmd = commands[1] and commands[1]:lower() or nil
        local arg = commands[2] and commands[2]:lower() or nil

        -- ---- help ---------------------------------------------------------------
        if cmd == 'help' or cmd == '?' then
            Msg.show_help()
            return
        end

        -- ---- bare //po = SWAP to current job (most common action) ---------------
        if not cmd then
            if State.packet_state ~= 0 or player.status ~= 0 then
                Msg.busy(State.packet_state, player.status)
                return
            end
            run_exclusive(function(token)
                single_job_op('swap', player.main_job, player, token)
            end, true)
            return
        end

        -- ---- debug toggle -------------------------------------------------------
        if cmd == 'debug' then
            if arg == 'on' or arg == '1' or arg == 'enable' then
                Debug.clear()
                State.debug_enabled = true
                Debug.log('===== Debug session started =====')
                Msg.success('Debug logging ENABLED -> ' .. Msg.C.cyan .. Debug.log_path)
            elseif arg == 'off' or arg == '0' or arg == 'disable' then
                State.debug_enabled = false
                Msg.notice('Debug logging DISABLED')
            else
                Msg.notice('Usage: //po debug on | off')
                Msg.notice('Log file: ' .. Debug.log_path)
            end
            return
        end

        -- ---- status (read-only, never busy-blocked) ----------------------------
        if cmd == 'status' or cmd == 's' or cmd == 'info' then
            status_op(arg, player)
            return
        end

        -- ---- reset / unstuck ---------------------------------------------------
        if cmd == 'reset' or cmd == 'unstuck' then
            -- Close any menu we may have abandoned before clearing our own view
            -- of it. A conversation the server still believes is open is what
            -- makes the porter refuse every later trade, and clearing fields does
            -- not end one -- which is why this command used to leave the addon
            -- just as stuck as it found it.
            --
            -- Only when there is something to close, though: with nothing in
            -- flight the newest cached menu belongs to the player, and dismissing
            -- that is not this command's business.
            if State.packet_state ~= 0 or State.operation_active then
                Packets.abort_menu()
            end

            -- Unconditional, and the reason this command is the recovery path: an
            -- operation that died without reaching its own release left the gear
            -- slots locked. `gs enable all` is harmless when nothing is locked.
            Naked.release()

            State.reset_all()
            Msg.success('State machine reset - slots released, any run in progress will stop')
            return
        end

        -- ---- export ------------------------------------------------------------
        if cmd == 'export' or cmd == 'exp' then
            local all_set = S {'all', 'a', 'continuous'}
            local all_arg = all_set:contains(commands[2]) or all_set:contains(commands[3])
            export_op(commands, player, all_arg)
            return
        end

        -- ---- slips: manually return any leftover slips to satchel --------------
        if cmd == 'slips' or cmd == 'returnslips' or cmd == 'rs' then
            -- Under the lock like every other command that moves items. It used to
            -- sit above the guard, so it could be run mid-operation and file the
            -- slips away while a pack loop was still trading them.
            run_exclusive(function()
                local returned = Inv.return_slips_to_home()
                if returned > 0 then
                    Msg.success(('Returned %d storage slip(s) to satchel'):format(returned))
                else
                    Msg.notice('No storage slips in inventory to return.')
                end
            end)
            return
        end

        -- ---- busy guard for the action commands below --------------------------
        if State.packet_state ~= 0 or player.status ~= 0 then
            Msg.busy(State.packet_state, player.status)
            return
        end

        -- ---- bulk: pack ALL ----------------------------------------------------
        if cmd == 'all' or cmd == 'packall' then
            run_exclusive(function(token)
                bulk_op(true, player, nil, nil, nil, nil, token) -- mode=nil => Active + Inactive
            end, true)
            return
        end

        -- ---- bulk: unpack Active (default) or Inactive -------------------------
        if cmd == 'fetch' or cmd == 'unpackall' then
            local scope = (arg == 'inactive' or arg == 'i') and 'inactive' or 'active'
            run_exclusive(function(token)
                bulk_op(false, player, nil, scope, nil, nil, token)
            end, true)
            return
        end

        -- ---- single-job: unpack only -------------------------------------------
        if cmd == 'unpack' or cmd == 'u' then
            local target = (arg and arg:upper()) or player.main_job
            run_exclusive(function(token)
                single_job_op('unpack', target, player, token)
            end, true)
            return
        end

        -- ---- single-job: pack only ---------------------------------------------
        if cmd == 'pack' or cmd == 'p' then
            local target = (arg and arg:upper()) or player.main_job
            run_exclusive(function(token)
                single_job_op('pack', target, player, token)
            end, true)
            return
        end

        -- ---- single-job: SWAP (pack others + unpack) ---------------------------
        -- Triggered by: //po swap [JOB]   OR   //po <JOB>   (bare job code)
        if cmd == 'swap' then
            local target = (arg and arg:upper()) or player.main_job
            run_exclusive(function(token)
                single_job_op('swap', target, player, token)
            end, true)
            return
        end
        if Config.VALID_JOBS[cmd:upper()] then
            local target = cmd:upper()
            run_exclusive(function(token)
                single_job_op('swap', target, player, token)
            end, true)
            return
        end

        -- ---- unknown -----------------------------------------------------------
        Msg.error(('Unknown command: "%s". Type //po help for the list.'):format(cmd))
    end
)
