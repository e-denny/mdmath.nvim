local nvim = require'mdmath.nvim'
local config = require'mdmath.config'.opts
local util = require'mdmath.util'

local M = {}

-- Extensions treated as attachments (opened externally when not renderable).
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

-- Extensions we can rasterize and render inline with the Kitty protocol.
local IMAGE_EXTENSIONS = {
    svg = true,
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    webp = true,
    bmp = true,
    tiff = true,
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

local function extension_of(target)
    local ext = target:match('%.([^%.%/]+)$')
    return ext and ext:lower() or nil
end

local function is_attachment(target)
    local ext = extension_of(target)
    return ext ~= nil and ATTACHMENT_EXTENSIONS[ext] == true
end

local function is_image(target)
    local ext = extension_of(target)
    return ext ~= nil and IMAGE_EXTENSIONS[ext] == true
end

M.is_image = is_image

-- Return info about the attachment link under the cursor, or nil.
-- info = { target = string, row = number, col = number, len = number },
-- where row/col are 0-indexed and len is the length of the link text.
function M.image_link_info()
    local line = nvim.get_current_line()
    local row, col = util.get_cursor(0)
    col = col + 1 -- get_cursor returns a 0-indexed column; string ops are 1-indexed

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
                    return { target = target, row = row, col = s - 1, len = e - s + 1 }
                end
            end
            search_start = e + 1
        end
    end

    return nil
end

-- Find all renderable image links in a line.
-- Returns a list of { target = string, col = number, len = number } (col 0-indexed).
function M.find_image_links(line)
    local links = {}
    for _, pattern in ipairs(LINK_PATTERNS) do
        local search_start = 1
        while search_start <= #line do
            local s, e = line:find(pattern, search_start)
            if s == nil then
                break
            end
            local target = parse_target(line:sub(s, e))
            if target ~= nil and is_image(target) then
                links[#links + 1] = { target = target, col = s - 1, len = e - s + 1 }
            end
            search_start = e + 1
        end
    end
    return links
end

function M.image_link_under_cursor()
    local info = M.image_link_info()
    return info and info.target or nil
end

-- Open a path with the external opener (`open_image_cmd`).
local function open_external(path)
    local open_cmd = config.open_image_cmd
    if type(open_cmd) == 'function' then
        open_cmd(path)
    else
        vim.fn.jobstart({ open_cmd, path }, { detach = true })
    end
end

function M.open_image()
    local info = M.image_link_info()
    if info == nil then
        util.err_message('no image/attachment link under the cursor')
        return
    end

    local dir = vim.fn.expand('%:p:h')
    local path = vim.fs.joinpath(dir, info.target)

    if vim.fn.filereadable(path) ~= 1 then
        util.err_message('file not found: ' .. path)
        return
    end

    -- Image links render in place automatically; other attachments open externally.
    if is_image(info.target) then
        vim.notify('mdmath.nvim: image links render in place automatically (toggle with :MdMath toggle_images)', vim.log.levels.INFO)
    else
        open_external(path)
    end
end

return M
