local nvim = require'mdmath.nvim'
local config = require'mdmath.config'.opts
local util = require'mdmath.util'

local M = {}

-- Extensions that are opened as attachments. Anything else (including `.md`
-- notes and extension-less wiki titles) is left to obsidian.nvim / `gf`.
local ATTACHMENT_EXTENSIONS = {
    svg = true,
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    webp = true,
    bmp = true,
    tiff = true,
    pdf = true,
    mp4 = true,
    mov = true,
    webm = true,
    mp3 = true,
    wav = true,
    zip = true,
    csv = true,
}

-- Link forms recognized:
--   1. Obsidian embed:      ![[figures/img.svg|description]]
--   2. Obsidian wikilink:   [[figures/img.svg|description]]
--   3. Standard image:      ![description](figures/img.svg)
local LINK_PATTERNS = {
    '%!?%[%[[^%]]+%]%]',       -- ![[...]] and [[...]]
    '%!%[[^%]]+%]%([^%)]+%)',  -- ![alt](target)
}

-- Parse the target (path) out of a matched link string.
local function parse_target(raw)
    local target
    if raw:sub(1, 3) == '![[' then
        target = raw:sub(4, -3):match('^%s*([^|]+)')
    elseif raw:sub(1, 2) == '[[' then
        target = raw:sub(3, -3):match('^%s*([^|]+)')
    else
        target = raw:match('^%![^%]]*%]%(%s*([^%s%)]+)')
    end
    if target ~= nil then
        target = target:gsub('%s+$', '')
    end
    return target
end

local function is_attachment(target)
    local ext = target:match('%.([^%.%/]+)$')
    return ext ~= nil and ATTACHMENT_EXTENSIONS[ext:lower()] == true
end

-- Return the attachment target under the cursor, or nil.
function M.image_link_under_cursor()
    local line = nvim.get_current_line()
    local _, col = util.get_cursor(0)
    col = col + 1 -- get_cursor returns a 0-indexed column

    for _, pattern in ipairs(LINK_PATTERNS) do
        local search_start = 1
        while search_start <= #line do
            local s, e = line:find(pattern, search_start)
            if s == nil then
                break
            end
            if s <= col and col <= e then
                local target = parse_target(line:sub(s, e))
                if target ~= nil and is_attachment(target) then
                    return target
                end
            end
            search_start = e + 1
        end
    end

    return nil
end

function M.open_image()
    local target = M.image_link_under_cursor()
    if target == nil then
        util.err_message('no image/attachment link under the cursor')
        return
    end

    local dir = vim.fn.expand('%:p:h')
    local path = vim.fs.joinpath(dir, target)

    if vim.fn.filereadable(path) ~= 1 then
        util.err_message('file not found: ' .. path)
        return
    end

    local open_cmd = config.open_image_cmd
    if type(open_cmd) == 'function' then
        open_cmd(path)
    else
        vim.fn.jobstart({ open_cmd, path }, { detach = true })
    end
end

return M
