---  ═══════════════════════════════════════════════════════════════════════════
---   PorterPacker - Low-level Chat Helpers
---  ═══════════════════════════════════════════════════════════════════════════
---   FFXI-chat formatting primitives following the same style as the
---   GearSwap wardrobe_organizer/lib/chat.lua (separator '=' x 74,
---   [PorterPacker] tag, inline color codes via 0x1F).
---
---   Public functions:
---     Chat.separator()                  - 74-char gray rule
---     Chat.divider()                    - 74-char gray '-' rule
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
local SEP_CHAR = '='
local DIV_CHAR = '-'
local SEP_LEN  = 74

local SEP = string.rep(SEP_CHAR, SEP_LEN)
local DIV = string.rep(DIV_CHAR, SEP_LEN)

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

--- Display a colored separator line (74 '=' chars in gray).
function Chat.separator()
    windower.add_to_chat(CHANNEL, C.gray .. SEP)
end

--- Mid-section divider (74 '-' chars in gray).
function Chat.divider()
    windower.add_to_chat(CHANNEL, C.gray .. DIV)
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
