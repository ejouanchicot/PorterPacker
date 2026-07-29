---  ═══════════════════════════════════════════════════════════════════════════
---   PorterPacker Messages - High-level UI helpers
---  ═══════════════════════════════════════════════════════════════════════════
---   Application-specific messaging built on top of lib/chat.lua. Provides
---   semantic helpers (action, stored, retrieved, slip_hint, summary, busy)
---   and the help screen, all using the unified panel style.
---
---   For low-level primitives (separator, header, info, success, error, warn,
---   detail, cmd_row, label_row) see lib/chat.lua.
---
---   @file    PorterPacker/messages.lua
---   @author  ejouanchicot
---   @version 2.0
---   @date    Refactored: 2026-04-30
---  ═══════════════════════════════════════════════════════════════════════════

local Chat = require('lib/chat')

local Messages = {}

-- Re-export color palette and tag for external callers (some code does Msg.C.x)
Messages.C   = Chat.C
Messages.tag = Chat.tag

---  ═══════════════════════════════════════════════════════════════════════════
---   THIN PASS-THROUGHS (kept for back-compat with existing call sites)
---  ═══════════════════════════════════════════════════════════════════════════

Messages.send      = Chat.send
Messages.blank     = Chat.blank
Messages.separator = Chat.separator
Messages.divider   = Chat.divider
Messages.section   = Chat.section
Messages.info      = Chat.info
Messages.success   = Chat.success
Messages.warning   = Chat.warn
Messages.error     = Chat.error
Messages.notice    = Chat.info
Messages.cmd_row   = Chat.cmd_row
Messages.label_row = Chat.label_row

--- Big banner header (separator + title + separator).
--- @param title string
--- @param subtitle string|nil
function Messages.banner(title, subtitle)
    Chat.blank()
    Chat.separator()
    if subtitle then
        Chat.send(Chat.C.yellow .. title .. Chat.C.gray .. ' - ' .. Chat.C.white .. subtitle)
    else
        Chat.send(Chat.C.yellow .. title)
    end
    Chat.separator()
end

--- Bottom footer.
function Messages.footer()
    Chat.separator()
    Chat.blank()
end

---  ═══════════════════════════════════════════════════════════════════════════
---   ACTION / PROGRESS LINES
---  ═══════════════════════════════════════════════════════════════════════════

--- Job-action header: "[PorterPacker] PACK WAR (continuous)"
--- @param action string PACK|UNPACK|SWAP|EXPORT|AUTO PACK ALL
--- @param target string|nil Job code or descriptor
--- @param continuous boolean|nil
function Messages.action(action, target, continuous)
    local C = Chat.C
    local mode = continuous and (C.gray .. ' (' .. C.green .. 'continuous' .. C.gray .. ')') or ''
    local tgt  = target and (C.gray .. ' [' .. C.pale_yellow .. tostring(target) .. C.gray .. ']') or ''
    Chat.send(Chat.tag() .. C.yellow .. action .. tgt .. mode)
end

--- Trade summary: "Stored 12 items via Slip 27"
function Messages.stored(count, slip_num)
    local C = Chat.C
    local slip_str = slip_num and (C.gray .. ' via ' .. C.cyan .. 'Slip ' .. slip_num) or ''
    Chat.send(Chat.tag() .. C.green .. ('Stored %d items'):format(count) .. slip_str)
end

--- Retrieve summary: "Retrieved 5 items from Slip 27"
function Messages.retrieved(count, slip_num)
    local C = Chat.C
    local slip_str = slip_num and (C.gray .. ' from ' .. C.cyan .. 'Slip ' .. slip_num) or ''
    Chat.send(Chat.tag() .. C.green .. ('Retrieved %d items'):format(count) .. slip_str)
end

--- Progress arrow: "-> Packing Slip 27 (12 items)"
function Messages.progress(verb, slip_num, count)
    local C = Chat.C
    local cnt = count and (C.gray .. ' (' .. C.pale_yellow .. count .. C.gray .. ' items)') or ''
    Chat.send(Chat.tag() .. C.cyan .. '-> ' .. C.white .. verb .. ' ' ..
        C.cyan .. 'Slip ' .. slip_num .. cnt)
end

--- Single-job summary: "Done: 23 items across 4 slips"
function Messages.summary(verb, total_items, slip_count)
    local C = Chat.C
    Chat.send(Chat.tag() .. C.green .. 'Done: ' ..
        C.white .. verb .. ' ' .. C.pale_yellow .. total_items ..
        C.white .. ' items across ' .. C.pale_yellow .. slip_count ..
        C.white .. ' slip' .. (slip_count > 1 and 's' or ''))
end

--- Slip suggestion shown when items are detected but slip not in inv.
function Messages.slip_hint(slip_num, count)
    local C = Chat.C
    Chat.send(Chat.tag() .. C.orange .. 'Hint: ' .. C.white ..
        'Consider getting ' .. C.cyan .. 'Storage Slip ' .. slip_num ..
        C.gray .. ' (' .. C.pale_yellow .. count .. C.gray .. ' storable items not in list)')
end

--- File loaded notification.
function Messages.file_loaded(filename)
    local C = Chat.C
    Chat.send(Chat.tag() .. C.gray .. 'Loaded ' .. C.cyan .. filename)
end

--- All-done message.
function Messages.completed()
    local C = Chat.C
    Chat.send(Chat.tag() .. C.green .. 'All movements completed' ..
        C.gray .. ' (' .. C.pale_yellow .. 'idle' .. C.gray .. ')')
end

--- Busy guard message.
function Messages.busy(state_num, status_num)
    local C = Chat.C
    Chat.send(Chat.tag() .. C.orange .. 'Busy:' .. C.white ..
        ' state=' .. C.pale_yellow .. state_num ..
        C.white .. ' status=' .. C.pale_yellow .. status_num ..
        C.gray .. ' - try again in a moment')
end

---  ═══════════════════════════════════════════════════════════════════════════
---   BULK-OP PANELS  (NEW in v2 - one panel per processed job)
---  ═══════════════════════════════════════════════════════════════════════════

--- Bulk start banner: full panel before iterating jobs.
--- @param mode string 'PACK' | 'UNPACK' | 'AUTO PACK ALL'
--- @param target_job string|nil  Job we're heading toward (for unpack contexts)
--- @param job_count number       Number of jobs that will be processed
--- @param skip_job string|nil    Job that will be skipped (for auto-packall)
function Messages.bulk_start(mode, target_job, job_count, skip_job)
    local title = ('PorterPacker - %s Started'):format(mode)
    Chat.header(title)
    if target_job then Chat.detail('Target', target_job) end
    Chat.detail('Jobs to process', job_count)
    if skip_job then Chat.detail('Skipping', skip_job .. ' (target of unpack)') end
    Chat.separator()
end

--- Per-job header inside a bulk run.
--- @param idx number    Current job index (1-based)
--- @param total number  Total job count
--- @param job string    Job code (e.g. 'THF')
--- @param status string Short status: 'ready', 'skip', etc.
--- @param item_count number|nil  Items found in bags (or nil)
function Messages.bulk_job_header(idx, total, job, status, item_count)
    local C = Chat.C
    -- One-line header; lighter than full panel to avoid spam for 7 jobs
    local progress = ('%d / %d'):format(idx, total)
    local items_str = item_count and (C.gray .. '  items=' .. C.pale_yellow .. item_count) or ''
    -- Status color: 'skip*' in gray, 'done' in green, anything else (pack/unpack) in yellow
    local status_color = C.yellow
    if status:sub(1, 4) == 'skip' then
        status_color = C.gray
    elseif status == 'done' then
        status_color = C.green
    end
    Chat.send(Chat.tag() ..
        C.cyan .. 'Job ' .. C.pale_yellow .. progress .. C.gray .. '  ' ..
        C.white .. job .. items_str .. C.gray .. '  ' ..
        status_color .. '[' .. status .. ']')
end

--- Bulk end summary panel.
--- @param mode string 'PACK' | 'UNPACK' | 'AUTO PACK ALL'
--- @param processed number   Jobs that actually traded
--- @param skipped number     Jobs skipped (already packed/unpacked)
--- @param aborted number     Jobs aborted (network deadlock)
--- @param total_items number Sum of items moved
--- @param total_slips number Sum of slips used
function Messages.bulk_end(mode, processed, skipped, aborted, total_items, total_slips)
    Chat.separator()
    Chat.send(Chat.C.yellow .. ('PorterPacker - %s Complete'):format(mode))
    Chat.separator()
    Chat.detail('Jobs processed',     processed)
    if skipped > 0 then Chat.detail('Jobs skipped',     skipped .. ' (nothing to do)') end
    if aborted > 0 then Chat.detail('Jobs aborted',     aborted .. ' (network)') end
    Chat.detail('Total items',        total_items)
    Chat.detail('Total slips',        total_slips)
    Chat.separator()
end

---  ═══════════════════════════════════════════════════════════════════════════
---   HELP SCREEN
---  ═══════════════════════════════════════════════════════════════════════════

function Messages.show_help()
    local C = Chat.C
    Messages.banner('PORTERPACKER HELP', 'Quick Reference')
    Chat.blank()

    Chat.section('PRIMARY')
    Chat.cmd_row('//po <JOB>',           'SWAP: pack others + unpack <JOB>')
    Chat.cmd_row('//po swap [JOB]',      'Same as above (default JOB = current)')
    Chat.cmd_row('//po u [JOB]',         'UNPACK only (no auto-pack of others)')
    Chat.cmd_row('//po p [JOB]',         'PACK only (no unpack)')
    Chat.cmd_row('//po all',             'PACK ALL jobs (Active + Inactive)')
    Chat.cmd_row('//po fetch',           'UNPACK ALL Active jobs')
    Chat.cmd_row('//po fetch inactive',  'UNPACK ALL Inactive jobs')
    Chat.cmd_row('//po s [scope]',       'STATUS: see what is stored vs out')
    Chat.blank()

    Chat.section('STATUS SCOPES')
    Chat.cmd_row('//po s',               '(default) Active jobs only')
    Chat.cmd_row('//po s inactive',      'Inactive jobs only')
    Chat.cmd_row('//po s all',           'Every job')
    Chat.cmd_row('//po s PLD',           'A single job')
    Chat.blank()

    Chat.section('UTILITIES')
    Chat.cmd_row('help | ?',             'Show this help')
    Chat.cmd_row('reset | unstuck',      'Force-reset state when blocked')
    Chat.cmd_row('slips | rs',           'Return slips left in inventory to satchel')
    Chat.cmd_row('export | exp [name]',  'Export inventory to data/<name>.lua')
    Chat.cmd_row('debug on | off',       'Toggle packet debug logging')
    Chat.blank()

    Chat.section('LONG ALIASES')
    Chat.cmd_row('unpack=u  pack=p  packall=all  unpackall=fetch  status=s', '')
    Chat.blank()

    Chat.section('FOLDER LAYOUT')
    Chat.send('   ' .. C.gray .. 'data/<charname>/Active/<JOB>.lua    ' ..
                  C.cyan .. '<- jobs you actively play')
    Chat.send('   ' .. C.gray .. 'data/<charname>/Inactive/<JOB>.lua  ' ..
                  C.cyan .. '<- jobs stored only')

    Messages.footer()
end

---  ═══════════════════════════════════════════════════════════════════════════
---   STATUS DISPLAY
---  ═══════════════════════════════════════════════════════════════════════════

--- Pretty-print the storage status table.
--- @param header string  e.g. 'Active', 'Inactive', 'All jobs', 'PLD'
--- @param rows   table   array of {job, in_bag, total, status, current}
--- @param current_job string
function Messages.show_status(header, rows, current_job)
    local C = Chat.C
    Messages.banner('PORTER STORAGE', header)

    if #rows == 0 then
        Chat.send('   ' .. C.gray .. 'No matching jobs found.')
        Messages.footer()
        return
    end

    Chat.section(string.format('%s jobs (%d)', header, #rows))
    for _, r in ipairs(rows) do
        local status_color
        if r.status == 'stored' then
            status_color = C.green
        elseif r.status == 'out' then
            status_color = C.yellow
        else  -- MIXED
            status_color = C.orange
        end
        local current_tag = r.current and (C.cyan .. ' *current*') or ''
        local line = string.format(
            '   %s%-4s%s | wardrobes: %s%2d%s / %2d | %s%-7s%s%s',
            C.cyan,    r.job,    C.gray,
            C.white,   r.in_bag, C.gray,   r.total,
            status_color, r.status, C.gray, current_tag
        )
        Chat.send(line)
    end

    -- Bag-level info: wardrobe space + slips currently in inv vs satchel
    -- (slips module is loaded as a global by PorterPacker.lua)
    local wardrobes = {8, 10, 11, 12, 13, 14, 15, 16}
    local w_free, w_total = 0, 0
    for _, b in ipairs(wardrobes) do
        local info = windower.ffxi.get_bag_info(b)
        if info and info.enabled then
            w_free  = w_free  + (info.max - info.count)
            w_total = w_total + info.max
        end
    end

    local function count_slips_in(bag_id)
        local items = windower.ffxi.get_items(bag_id)
        if not items then return 0 end
        local n = 0
        for _, it in ipairs(items) do
            if it.id and it.id > 0 and slips.items[it.id] then n = n + 1 end
        end
        return n
    end

    Chat.separator()
    Chat.send(string.format(
        '   %sWardrobes free: %s%d%s / %d   %sSlips: %sinv %d%s  satchel %d',
        C.gray, C.white, w_free, C.gray, w_total,
        C.gray, C.white, count_slips_in(0), C.gray, count_slips_in(5)))
    Messages.footer()
end

return Messages
