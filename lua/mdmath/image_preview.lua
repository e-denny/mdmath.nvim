local vim = vim
local nvim = require'mdmath.nvim'
local uv = vim.loop
local util = require'mdmath.util'
local config = require'mdmath.config'.opts
local Image = require'mdmath.Image'
local marks = require'mdmath.marks'
local terminfo = require'mdmath.terminfo'
local tracker = require'mdmath.tracker'
local diacritics = require'mdmath.Image.diacritics'

local M = {}

-- Global toggle for automatic image previews.
M.enabled = true

-- Rasterized PNG files we created (for cleanup on exit).
local temp_files = {}

-- Cache: absolute source path -> absolute PNG path (avoids re-rasterizing).
local raster_cache = {}

local PNG_SIG = '\137PNG\r\n\26\n'

-- Resolve an image target relative to a buffer's directory.
local function resolve_path(bufnr, target)
    if vim.startswith(target, '/') then
        return target
    end
    local filepath = nvim.buf_get_name(bufnr)
    local dir = vim.fn.fnamemodify(filepath, ':h')
    return vim.fs.joinpath(dir, target)
end

-- Read width/height from a PNG file's IHDR chunk.
local function png_file_dimensions(path)
    local fd = uv.fs_open(path, 'r', 0)
    if not fd then
        return nil, nil
    end
    local data = uv.fs_read(fd, 24, 0)
    uv.fs_close(fd)
    if data == nil or #data < 24 or data:sub(1, 8) ~= PNG_SIG then
        return nil, nil
    end
    local w, h = 0, 0
    for i = 0, 3 do
        w = w * 256 + data:byte(17 + i)
        h = h * 256 + data:byte(21 + i)
    end
    return w, h
end

-- Rasterize an image to a PNG file. `callback` receives the PNG path or nil.
local function rasterize_async(path, callback)
    local cached = raster_cache[path]
    if cached then
        callback(cached)
        return
    end

    local ext = path:match('%.([^%.%/]+)$')
    ext = ext and ext:lower()

    if ext == 'png' then
        raster_cache[path] = path
        callback(path)
        return
    end

    local base = vim.fn.tempname()
    os.remove(base) -- only want the unique name, not the empty placeholder file
    local tmp = base .. '.png'

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

    vim.fn.jobstart(argv, {
        on_exit = function(_, code)
            if code == 0 then
                raster_cache[path] = tmp
                temp_files[tmp] = true
                callback(tmp)
            else
                os.remove(tmp)
                callback(nil)
            end
        end,
    })
end

-- Convert pixel dimensions to cell dimensions.
--
-- With `image_width` set, the image is rescaled to that many cells wide
-- (upscaling small rasters, so they may look soft), preserving aspect ratio.
-- Otherwise the native pixel size is used (1 image pixel per terminal pixel).
-- Either way the result is shrunk to fit the window and the diacritics
-- placeholder limit.
local function cell_dims(pixel_w, pixel_h)
    local cell_w, cell_h = terminfo.cell_size()

    local cols, rows
    if config.image_width then
        local scale = (config.image_width * cell_w) / pixel_w
        cols = config.image_width
        rows = (pixel_h * scale) / cell_h
    else
        cols = math.ceil(pixel_w / cell_w)
        rows = math.ceil(pixel_h / cell_h)
    end

    local win_cols = nvim.win_get_width(0)
    local win_rows = nvim.win_get_height(0)
    local max = #diacritics

    local max_cols = math.max(1, math.min(win_cols - 2, max))
    local max_rows = math.max(1, math.min(win_rows - 2, max))

    local scale = math.min(1, max_cols / cols, max_rows / rows)

    cols = math.max(1, math.floor(cols * scale))
    rows = math.max(1, math.floor(rows * scale))
    return cols, rows
end

-- Render a rasterized PNG inline at `row`, overlaying the source line and
-- adding the remaining rows (plus a blank spacer line) as virtual lines.
local function render(bufnr, row, source_width, png_file)
    local pixel_w, pixel_h = png_file_dimensions(png_file)
    if pixel_w == nil then
        return nil
    end

    local cols, rows = cell_dims(pixel_w, pixel_h)

    local image = Image.new(rows, cols, png_file)
    local texts = image:text()

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
    lines[#lines + 1] = { '', -1 } -- a little vertical breathing room

    local mark_id = marks.add(bufnr, row, 0, {
        lines = lines,
        color = image:color(),
    })

    return image, mark_id
end

local ImageLink = util.class 'ImageLink'

function ImageLink:_init(bufnr, row, target, len)
    self.bufnr = bufnr
    self.row = row
    self.target = target
    self.len = len
    self.valid = true
    self.created = false
    self.image = nil
    self.mark_id = nil

    local source_width = util.linewidth(bufnr, row)

    -- Invalidate when the line is edited.
    self.pos = tracker.add(bufnr, row, 0, row, source_width)
    if self.pos then
        self.pos.on_finish = function()
            self:invalidate()
        end
    end

    local path = resolve_path(bufnr, target)
    if vim.fn.filereadable(path) ~= 1 then
        return false
    end

    rasterize_async(path, function(png_file)
        if not self.valid or png_file == nil then
            return
        end
        vim.schedule(function()
            if not self.valid then
                return
            end
            local image, mark_id = render(self.bufnr, self.row, source_width, png_file)
            if image then
                self.image = image
                self.mark_id = mark_id
                self.created = true
            end
        end)
    end)
end

function ImageLink:invalidate()
    if not self.valid then
        return
    end
    self.valid = false
    if self.created then
        if self.image then
            self.image:close()
        end
        if self.mark_id then
            marks.remove(self.bufnr, self.mark_id)
        end
        self.created = false
    end
    if self.pos then
        self.pos:cancel()
    end
end

M.ImageLink = ImageLink

-- Clean up rasterized temp files on exit.
do
    local group = nvim.create_augroup('MdMathImagePreview', { clear = true })
    nvim.create_autocmd('VimLeave', {
        group = group,
        callback = function()
            for path in pairs(temp_files) do
                os.remove(path)
            end
            temp_files = {}
        end,
    })
end

return M
