local nvim = require'mdmath.nvim'
local util = require'mdmath.util'
local ts = vim.treesitter
local uv = vim.uv
local Equation = require'mdmath.Equation'
local config = require'mdmath.config'.opts

local augroup = nvim.create_augroup('MdMathManager', {clear = true})

local M = {}
local buffers = {}

local Buffer = util.class 'Buffer'

-- FIX: Temporary workaround before NeoVim 0.12
local function get_parser(bufnr, lang)
    local parser = ts.get_parser(bufnr, lang)
    if not parser then
        error('Parser not found for ' .. lang, 2)
    end

    return parser
end

function Buffer:_init(bufnr)
    self.bufnr = bufnr
    self.equations = {}
    self.parser = get_parser(bufnr, 'markdown')
    self.active = true
    self.timer = uv.new_timer()
    assert(self.timer, 'failed to create a timer')

    -- Original 'wrap' value per window, restored when mdmath is disabled.
    self.saved_wrap = {}

    -- Conceal extmarks require conceallevel >= 2 to hide source text.
    -- Rendered equations are also laid out one image row per buffer line, so a
    -- buffer line wider than the window must not wrap: the wrapped screen rows
    -- have no image row and would split the equation with a blank gap.
    -- Set both on all windows currently showing this buffer, and on future ones.
    local function set_window_opts(winid)
        if vim.api.nvim_win_get_buf(winid) == bufnr then
            if vim.wo[winid].conceallevel < 2 then
                vim.wo[winid].conceallevel = 2
            end
            if self.saved_wrap[winid] == nil then
                self.saved_wrap[winid] = vim.wo[winid].wrap
            end
            vim.wo[winid].wrap = false
        end
    end
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        set_window_opts(winid)
    end

    -- While typing, give the user their original wrapping back so long source
    -- lines remain editable. Images are hidden on insert anyway when
    -- `hide_on_insert` is set, so there is no equation layout to keep aligned.
    local function restore_wrap()
        for winid, wrap in pairs(self.saved_wrap) do
            if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
                vim.wo[winid].wrap = wrap
            end
        end
    end

    local function disable_wrap()
        for winid in pairs(self.saved_wrap) do
            if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
                vim.wo[winid].wrap = false
            end
        end
    end

    nvim.create_autocmd({'BufWinEnter'}, {
        buffer = bufnr,
        group = augroup,
        callback = function(ev)
            set_window_opts(vim.api.nvim_get_current_win())
        end,
    })

    self:attach()

    nvim.create_autocmd({'InsertEnter'}, {
        buffer = bufnr,
        group = augroup,
        callback = function()
            if config.hide_on_insert then
                restore_wrap()
            end
        end
    })
    nvim.create_autocmd({'InsertLeave'}, {
        buffer = bufnr,
        group = augroup,
        callback = function()
            disable_wrap()
            self:parse_view()
        end
    })
    nvim.create_autocmd({'WinScrolled'}, {
        buffer = bufnr,
        group = augroup,
        callback = function()
            self:reset_timer()
        end
    })

    -- FIX: Is this the best way to handle this?
    nvim.create_autocmd({'VimLeave'}, {
        group = augroup,
        callback = function()
            self:free()
        end
    })

    if config.open_image_key then
        vim.keymap.set('n', config.open_image_key, '<cmd>MdMath open_image<CR>', {
            buffer = bufnr,
            desc = 'Open image/attachment under cursor',
        })
    end

    self:parse_view()
end

function Buffer:clear(reset)
    for _, eq in ipairs(self.equations) do
        eq:invalidate()
    end
    self.equations = {}

    if reset then
        self:reset_timer()
    end
end

function Buffer:free()
    if not self.active then
        return
    end
    self.active = false
    buffers[self.bufnr] = nil

    self.timer:stop()
    self.timer:close()

    self:clear(false)

    for winid, wrap in pairs(self.saved_wrap) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == self.bufnr then
            vim.wo[winid].wrap = wrap
        end
    end
    self.saved_wrap = {}

    nvim.clear_autocmds {
        group = augroup,
        buffer = self.bufnr
    }
end

function Buffer:reset_timer()
    self.timer:start(config.update_interval, 0, vim.schedule_wrap(function()
        return self:parse_view()
    end))
end

function Buffer:attach()
    nvim.buf_attach(self.bufnr, false, {
        on_lines = function()
            if not self.active then
                return true
            end
            self:reset_timer()
        end,
        on_detach = function()
            self:free()
        end
    })
end

function Buffer:parse_view()
    local start_row, end_row = util.get_current_view()
    self:parse(start_row, end_row)
end

function Buffer:parse(start_row, end_row)
    assert(type(start_row) == 'number', 'start_row must be a number')
    assert(type(end_row) == 'number', 'end_row must be a number')

    local bufnr = self.bufnr
    local parser = self.parser
    parser:parse({start_row, end_row})

    -- FIX: Almost sure we can move this block to initialization
    local inline_lang = 'markdown_inline'
    local inlines = parser:children()[inline_lang]
    if not inlines then
        return nil
    end
    local query = vim.treesitter.query.parse(inline_lang, '(latex_block) @block')

    local old_equations = self.equations
    local equations = {}

    local function process_equation(sr, sc, er, ec, text)
        -- FIXME: Iterating over all equations is not efficient, we can use a hash table
        local equation = nil
        for key, eq in ipairs(old_equations) do
            if eq ~= 0 and eq.valid and eq.pos[1] == sr and eq.pos[2] == sc and eq.text == text then
                equation = eq
                old_equations[key] = 0
                break
            end
        end

        equation = equation or Equation.new(bufnr, sr, sc, text)
        if equation then
            table.insert(equations, equation)
        end
    end

    local function get_queries(tree)
        local root = tree:root()

        for _, node in query:iter_captures(root, 0, start_row, end_row) do
            local sr, sc, er, ec = node:range()
            local value = ts.get_node_text(node, 0)

            process_equation(sr, sc, er, ec, value)
        end
    end
    inlines:for_each_tree(get_queries)

    for _, eq in ipairs(old_equations) do
        if eq ~= 0 and eq.valid then
            if (not eq.pos[1] or (start_row <= eq.pos[1] and eq.pos[1] < end_row)) then
                eq:invalidate()
            else
                -- add equations out of the range
                table.insert(equations, eq)
            end
        end
    end

    self.equations = equations
end

local function create_buffer(bufnr)
    if not nvim.buf_is_valid(bufnr) then
        return nil
    end

    local buf = Buffer.new(bufnr)
    buffers[bufnr] = buf
    return buf
end

function M.enable(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    if buffers[bufnr] then
        return
    end

    if not create_buffer(bufnr) then
        error('Invalid buffer: ' .. bufnr)
    end
end

function M.disable(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    local buffer = buffers[bufnr]
    if buffer then
        buffer:free()
    end
end

function M.disable_all()
    for bufnr, buffer in pairs(buffers) do
        buffer:free()
    end
end

function M.clear(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    local buffer = buffers[bufnr]
    if buffer then
        buffer:clear(true)
    end
end

return M
