local uv = vim.loop
local util = require'mdmath.util'
local diacritics = require'mdmath.Image.diacritics'

local stdout = uv.new_tty(1, false)
if not stdout then
    error('failed to open stdout')
end

-- Kitty's unicode placeholders encode the row/column with a fixed list of
-- diacritics, so an image can never have more rows/columns than that list.
local MAX_CELLS = #diacritics

-- FIXME: This is a temporary solution to avoid conflicts with other plugins that
-- also uses Kitty's image protocol. We should find a better way to handle this.
local _id = 333
local function next_id()
    local id = _id
    _id = _id + 1
    return id
end

local function tmux_escape(sequence)
    return "\x1bPtmux;" .. sequence:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

local function write_sequence(message)
    local tmux = os.getenv("TMUX")
    if tmux and tmux ~= "" then
        stdout:write(tmux_escape(message))
    else
        stdout:write(message)
    end
end

local function kitty_send(params, payload)
    if not params.q then
        params.q = 2
    end

    local tbl = {}

    for k, v in pairs(params) do
        tbl[#tbl + 1] = tostring(k) .. "=" .. tostring(v)
    end

    params = table.concat(tbl, ",")

    local message
    if payload ~= nil then
        message = string.format("\x1b_G%s;%s\x1b\\", params, vim.base64.encode(payload))
    else
        message = string.format("\x1b_G%s\x1b\\", params)
    end

    write_sequence(message)
end

-- Kitty requires the image payload to be transmitted in chunks of at most
-- `CHUNK_SIZE` base64 characters; a single oversized chunk is dropped, which
-- leaves the unicode placeholders rendering as literal text.
local CHUNK_SIZE = 4096

local function kitty_transmit(id, payload)
    local b64 = vim.base64.encode(payload)
    local nchunks = math.ceil(#b64 / CHUNK_SIZE)

    for i = 1, nchunks do
        local chunk = b64:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
        local more = i < nchunks and 1 or 0

        local params
        if i == 1 then
            params = string.format('i=%d,f=100,t=f,m=%d', id, more)
        else
            params = string.format('i=%d,m=%d', id, more)
        end

        write_sequence(string.format('\x1b_G%s;%s\x1b\\', params, chunk))
    end
end

local Image = util.class 'Image'

function Image:__tostring()
    return string.format('<Image id=%d>', self.id)
end

function Image:_init(rows, cols, payload)
    local id = next_id()
    if self.id then
        self:close()
    end

    self.id = id
    self.rows = math.min(rows, MAX_CELLS)
    self.cols = math.min(cols, MAX_CELLS)

    kitty_transmit(id, payload)
    kitty_send({i = id, U = 1, a = 'p', r = self.rows, c = self.cols})
end

function Image.unicode_at(row, col)
    return '\u{10EEEE}' .. diacritics[row] .. diacritics[col]
end

function Image:text()
    local text = {}
    for row = 1, self.rows do
        local T = {}
        for col = 1, self.cols do
            T[#T + 1] = Image.unicode_at(row, col)
        end
        text[#text + 1] = table.concat(T)
    end
    return text
end

function Image:color()
    return self.id -- Color is represented by the id
end

function Image:close()
    if not self.id then
        return
    end

    kitty_send({i = self.id, a = 'd', d = 'I'})
    self.id = nil
end

return Image
