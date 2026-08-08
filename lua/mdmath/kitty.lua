local M = {}

-- Returns the kitty config file path, respecting KITTY_CONFIG_DIRECTORY and XDG_CONFIG_HOME.
local function config_path()
    local kitty_dir = os.getenv('KITTY_CONFIG_DIRECTORY')
    if kitty_dir and kitty_dir ~= '' then
        return kitty_dir .. '/kitty.conf'
    end

    local xdg = os.getenv('XDG_CONFIG_HOME')
    if xdg and xdg ~= '' then
        return xdg .. '/kitty/kitty.conf'
    end

    return os.getenv('HOME') .. '/.config/kitty/kitty.conf'
end

-- Returns the font_family string from kitty.conf, or nil if not found/readable.
-- Handles both `font_family` and `font family` directive spellings.
function M.font_family()
    local path = config_path()
    local f = io.open(path, 'r')
    if not f then return nil end

    local family = nil
    for line in f:lines() do
        -- strip comments
        line = line:match('^(.-)%s*#.*$') or line
        -- match 'font_family value' or 'font family value'
        local v = line:match('^%s*font[_ ]family%s+(.+)%s*$')
        if v and v ~= '' then
            family = v
            -- don't break: last occurrence wins (like kitty itself)
        end
    end
    f:close()
    return family
end

return M
