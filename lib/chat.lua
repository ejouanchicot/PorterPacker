---  ═══════════════════════════════════════════════════════════════════════════
---   PorterPacker - Low-level Chat Helpers
---  ═══════════════════════════════════════════════════════════════════════════
---   FFXI-chat formatting primitives in the GearSwap Tetsouo style
---   ([PorterPacker] tag, inline color codes via 0x1F). The separator lines
---   follow the character's GearSwap chat options when there are any
---   (GearSwap/data/<Name>/_common/display/UI_CONFIG.lua, UIConfig.chat:
---   separators on / off, separator_char, width, separator_color: what
---   //gs c ui separators / sepchar / chatwidth / sepcolor set), so PorterPacker's
---   lines are as wide as GearSwap's; else 69 '=' in gray, GearSwap's standard.
---
---   Public functions:
---     Chat.separator()                  - full-width rule (the player's)
---     Chat.divider()                    - full-width '-' rule
---     Chat.header(title)                - separator + title + separator
---     Chat.section(name)                - section heading "[Section] NAME"
---     Chat.info(message)                - cyan info line
---     Chat.success(message)             - green success line
---     Chat.error(message)               - red error line
---     Chat.warn(message)                - orange warning line
---     Chat.detail(label, value)         - "  label : value" detail row
---     Chat.cmd_row(cmd, desc)           - help-style aligned row
---     Chat.label_row(label, value)      - dot-leader aligned row
---     Chat.blank()                      - blank spacer line
---     Chat.send(line)                   - raw line on system channel
---     Chat.tag()                        - "[PorterPacker] " prefix string
---     Chat.C                            - color palette (gray/yellow/...)
---
---   @file PorterPacker/lib/chat.lua
---  ═══════════════════════════════════════════════════════════════════════════

local Chat = {}

local CHANNEL  = 121          -- FFXI system message channel
local TAG      = 'PorterPacker'
local DIV_CHAR = '-'
-- GearSwap's standard (shared/utils/messages/chat_separators.lua DEFAULT_WIDTH)
local STANDARD = {on = true, char = '=', width = 69, color = nil}
-- the GearSwap file is read again after this many seconds (//gs c ui chatwidth rewrites it)
local STYLE_TTL = 10

-- Inline FFXI color codes (string.char(0x1F, color_id))
local C = {
    gray        = string.char(0x1F, 160),
    yellow      = string.char(0x1F, 50),
    green       = string.char(0x1F, 158),
    red         = string.char(0x1F, 167),
    cyan        = string.char(0x1F, 121),
    white       = string.char(0x1F, 1),
    orange      = string.char(0x1F, 205),
    pale_yellow = string.char(0x1F, 63),
    light_blue  = string.char(0x1F, 207),
    gold        = string.char(0x1F, 220),
    purple      = string.char(0x1F, 208),
    item        = string.char(0x1F, 211),
}
Chat.C = C

---  ═══════════════════════════════════════════════════════════════════════════
---   PRIMITIVES
---  ═══════════════════════════════════════════════════════════════════════════

--- Raw send: already-formatted string to system channel.
function Chat.send(line)
    windower.add_to_chat(CHANNEL, line)
end

--- Blank spacer line.
function Chat.blank()
    windower.add_to_chat(CHANNEL, ' ')
end

--- Build the "[PorterPacker] " prefix in colored brackets.
function Chat.tag()
    return C.gray .. '[' .. C.cyan .. TAG .. C.gray .. ']' .. C.white .. ' '
end

---  ═══════════════════════════════════════════════════════════════════════════
---   PANEL ELEMENTS
---  ═══════════════════════════════════════════════════════════════════════════

local style_cache = {name = nil, at = nil, style = STANDARD}

--- The character's separator options from its GearSwap UI_CONFIG.lua, else GearSwap's standard. A file that does not
--- load, or a value out of range, keeps the standard for that option.
--- @return table {on, char, width, color}
local function style()
    local me = windower.ffxi.get_player()
    local name = me and me.name
    if not name then return STANDARD end
    if style_cache.name == name and style_cache.at and os.clock() - style_cache.at < STYLE_TTL then return style_cache.style end
    local path = windower.addon_path .. '../GearSwap/data/' .. name .. '/_common/display/UI_CONFIG.lua'
    -- (addon_path ends with a slash: debug.lua's addon_path .. 'debug.log'; the same '../' as GearSwap's atelier_export.lua)
    local ok, cfg = pcall(dofile, path)
    local chat = ok and type(cfg) == 'table' and type(cfg.chat) == 'table' and cfg.chat or {}
    local s = {on = chat.separators ~= false, char = STANDARD.char, width = STANDARD.width, color = nil}
    if type(chat.separator_char) == 'string' and #chat.separator_char > 0 then s.char = chat.separator_char end
    local width = tonumber(chat.width)
    if width and width >= 20 and width <= 150 then s.width = math.floor(width) end
    local color = tonumber(chat.separator_color)
    if color and color >= 1 and color <= 255 then s.color = string.char(0x1F, math.floor(color)) end
    style_cache = {name = name, at = os.clock(), style = s}
    return s
end

--- `char` repeated to `n` characters (a multi-character choice is cut).
local function rule(char, n)
    return string.rep(char, math.ceil(n / #char)):sub(1, n)
end

--- Display a separator line: the player's character, width and color (none when separators are off).
function Chat.separator()
    local s = style()
    if not s.on then return end
    windower.add_to_chat(CHANNEL, (s.color or C.gray) .. rule(s.char, s.width))
end

--- Mid-section divider: '-' at the player's width and color (none when separators are off).
function Chat.divider()
    local s = style()
    if not s.on then return end
    windower.add_to_chat(CHANNEL, (s.color or C.gray) .. rule(DIV_CHAR, s.width))
end

--- Header panel: separator + yellow title + separator.
function Chat.header(title)
    Chat.separator()
    windower.add_to_chat(CHANNEL, C.yellow .. title)
    Chat.separator()
end

--- Section heading: orange ">> SECTION NAME"
function Chat.section(name)
    windower.add_to_chat(CHANNEL, C.orange .. '>> ' .. name)
end

---  ═══════════════════════════════════════════════════════════════════════════
---   STATUS LINES
---  ═══════════════════════════════════════════════════════════════════════════

--- Cyan info line: [PorterPacker] message
function Chat.info(message)
    windower.add_to_chat(CHANNEL, Chat.tag() .. message)
end

--- Green success line.
function Chat.success(message)
    windower.add_to_chat(CHANNEL, Chat.tag() .. C.green .. message)
end

--- Red error line.
function Chat.error(message)
    windower.add_to_chat(CHANNEL, Chat.tag() .. C.red .. 'Error: ' .. C.white .. message)
end

--- Orange warning line.
function Chat.warn(message)
    windower.add_to_chat(CHANNEL, Chat.tag() .. C.orange .. 'Warning: ' .. C.white .. message)
end

---  ═══════════════════════════════════════════════════════════════════════════
---   STRUCTURED ROWS
---  ═══════════════════════════════════════════════════════════════════════════

--- Detail row: "  label : value" with fixed label width (22 chars).
function Chat.detail(label, value)
    windower.add_to_chat(CHANNEL, string.format('  %s%-22s%s : %s%s',
        C.gray, label, C.white, C.green, tostring(value)))
end

--- Help command row: "  cmd ........ desc"
function Chat.cmd_row(cmd, desc, min_width)
    min_width = min_width or 32
    local pad_count = math.max(3, min_width - #cmd)
    local pad = string.rep('.', pad_count)
    windower.add_to_chat(CHANNEL, '   ' .. C.cyan .. cmd .. ' ' .. C.gray .. pad .. ' ' .. C.white .. desc)
end

--- Label/value row aligned with dot-leaders (data-table style).
function Chat.label_row(label, value, min_width)
    min_width = min_width or 32
    local pad_count = math.max(3, min_width - #label)
    local pad = string.rep('.', pad_count)
    windower.add_to_chat(CHANNEL, '   ' .. C.pale_yellow .. label .. ' ' .. C.gray .. pad .. ' ' .. C.white .. tostring(value))
end

return Chat
