local vim = vim
local nvim = require'mdmath.nvim'
local uv = vim.loop
local util = require'mdmath.util'
local Image = require'mdmath.Image'
local marks = require'mdmath.marks'
local terminfo = require'mdmath.terminfo'
local tracker = require'mdmath.tracker'
local diacritics = require'mdmath.Image.diacritics'

local M = {}

local current = nil

local PNG_SIG = '\137PNG\r\n\26\n'

local function read_file(path)
    local fd = uv.fs_open(path, 'r', 0)
    if not fd then
        return nil
    end
    local stat = uv.fs_fstat(fd)
    if not stat then
        uv.fs_close(fd)
        return nil
    end
    local data = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    return data
end

-- Read width/height from a PNG IHDR chunk.
local function png_dimensions(data)
    if #data < 24 or data:sub(1, 8) ~= PNG_SIG then
        return nil, nil
    end
    local w, h = 0, 0
    for i = 0, 3 do
        w = w * 256 + data:byte(16 + i)
        h = h * 256 + data:byte(20 + i)
    end
    return w, h
end

-- Rasterize an image file to PNG bytes (SVG via rsvg-convert, other non-PNG
-- formats via ImageMagick). Returns png bytes or nil, err.
local function rasterize(path)
    local ext = path:match('%.([^%.%/]+)$')
    ext = ext and ext:lower()

    local png_path = path
    local tmp
    if ext ~= 'png' then
        tmp = vim.fn.tempname() .. '.png'

        local cmd
        local args
        if ext == 'svg' then
            cmd = 'rsvg-convert'
            args = { '-o', tmp, path }
        elseif vim.fn.executable('magick') == 1 then
            cmd = 'magick'
            args = { path, tmp }
        else
            cmd = 'convert'
            args = { path, tmp }
        end

        local argv = { cmd }
        for _, a in ipairs(args) do
            argv[#argv + 1] = a
        end

        local output = vim.fn.system(argv)
        if vim.v.shell_error ~= 0 then
            os.remove(tmp)
            return nil, ('failed to convert image with %s: %s'):format(cmd, vim.trim(output))
        end
        png_path = tmp
    end

    local data = read_file(png_path)
    if tmp then
        os.remove(tmp)
    end
    if data == nil then
        return nil, 'failed to read image: ' .. png_path
    end
    return data
end

-- Convert pixel dimensions to cell dimensions, scaled to fit the current
-- window and the diacritics placeholder limit while preserving aspect ratio.
local function cell_dims(pixel_w, pixel_h)
    local cell_w, cell_h = terminfo.cell_size()

    local cols = math.ceil(pixel_w / cell_w)
    local rows = math.ceil(pixel_h / cell_h)

    local win_cols = nvim.win_get_width(0)
    local win_rows = nvim.win_get_height(0)
    local max = #diacritics

    local scale = math.min(1, (win_cols - 2) / cols, (win_rows - 2) / rows, max / cols, max / rows)

    cols = math.max(1, math.floor(cols * scale))
    rows = math.max(1, math.floor(rows * scale))
    return cols, rows
end

local function clear()
    if current == nil then
        return
    end
    if current.image then
        current.image:close()
    end
    if current.mark_id then
        marks.remove(current.bufnr, current.mark_id)
    end
    if current.pos then
        current.pos:cancel()
    end
    current = nil
end

function M.clear()
    clear()
end

-- Render `path` inline at the link described by `info`.
-- Returns true on success, false otherwise (after notifying).
function M.show(path, info)
    local data, err = rasterize(path)
    if data == nil then
        util.err_message(err)
        return false
    end

    local pixel_w, pixel_h = png_dimensions(data)
    if pixel_w == nil then
        util.err_message('failed to decode image: ' .. path)
        return false
    end

    local cols, rows = cell_dims(pixel_w, pixel_h)

    clear()

    local bufnr = nvim.get_current_buf()
    local image = Image.new(rows, cols, data)
    local texts = image:text()

    -- The first image row overlays the link's source line (assumed to be the
    -- whole line); remaining rows are virtual lines below it.
    local source_width = util.linewidth(bufnr, info.row)
    local lines = {}
    for i = 1, rows do
        local text = texts[i]
        if i == 1 then
            local padding = source_width - cols
            text = padding > 0 and text .. (' '):rep(padding) or text
            lines[i] = { text, source_width }
        else
            lines[i] = { text, -1 }
        end
    end

    local mark_id = marks.add(bufnr, info.row, 0, {
        lines = lines,
        color = image:color(),
    })

    local pos = tracker.add(bufnr, info.row, 0, info.row, source_width)
    if pos then
        pos.on_finish = clear
    end

    current = { image = image, mark_id = mark_id, bufnr = bufnr, pos = pos }
    return true
end

-- Auto-clear the preview when its buffer is wiped.
do
    local group = nvim.create_augroup('MdMathImagePreview', { clear = true })
    nvim.create_autocmd('BufWipeout', {
        group = group,
        callback = function(ev)
            if current and current.bufnr == ev.buf then
                clear()
            end
        end,
    })
end

return M
