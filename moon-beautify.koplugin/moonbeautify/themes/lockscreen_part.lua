--- 锁屏壁纸部件：把月读 features.lockscreen 的配置当成一个可分享的部件。
--- 配置本身不在 ext.beautify 里，应用/备份/还原都走 MoonSettings。
local MoonSettings = require("utils.settings")

local M = {}

local ID = "features.lockscreen"

-- 这些是运行时缓存/派生值：存进包里会让目标机跳过重新合成，apply 时反而要清掉。
local SKIP_CAPTURE = {
    lock_screen_day = true,
    lock_screen_transparent = true,
}

local FALLBACK_KEYS = {
    "lock_screen", "lock_screen_background", "lock_screen_component",
    "lock_screen_position", "lock_screen_wide", "lock_screen_bill_period",
    "lock_screen_poster_style", "lock_screen_poster_sort", "lock_screen_insight_page",
    "lock_screen_custom_message",
    "lock_screen_day", "lock_screen_transparent", "lock_screen_quote_index",
    "lock_screen_custom_image", "lock_screen_folder", "lock_screen_split",
    "lock_screen_typo_style", "lock_screen_typo_font", "lock_screen_typo_font_name",
}

local KEYS, KEY_SET = {}, {}
local function addKey(key)
    if type(key) ~= "string" or key == "" or KEY_SET[key] then return end
    KEY_SET[key] = true
    KEYS[#KEYS + 1] = key
end

local okSpec, spec = pcall(function() return require("features.lockscreen.setting") end)
if okSpec and type(spec) == "table" then
    for key in pairs(spec.defaults or {}) do addKey(key) end
    for _, key in ipairs(spec.keys or {}) do addKey(key) end
else
    for _, key in ipairs(FALLBACK_KEYS) do addKey(key) end
end

local copy = require("moonbeautify.themes.parts").copy

local function conf()
    local ok, c = pcall(MoonSettings.get, ID)
    if ok and type(c) == "table" then return c end
    return nil
end

--- 取当前锁屏配置（缓存/派生值不进包）
function M.capture()
    local c = conf()
    local out = {}
    if not c then return out end
    for _, key in ipairs(KEYS) do
        if not SKIP_CAPTURE[key] and c[key] ~= nil then
            out[key] = copy(c[key])
        end
    end
    return out
end

--- 把一份锁屏配置写回月读并触发重新合成
function M.apply(partConf)
    if type(partConf) ~= "table" then return false end
    local c = conf()
    if not c then return false end
    for _, key in ipairs(KEYS) do
        c[key] = copy(partConf[key])
    end
    MoonSettings.save(ID, c)

    -- setMode 会递增 revision、清掉 KOReader 原生 screensaver 覆盖；refresh 再按新配置合成。
    pcall(function()
        local Settings = require("features.lockscreen.settings")
        if Settings.setMode then
            Settings.setMode(c.lock_screen == "compose" and "compose" or "ko")
        end
    end)
    pcall(function()
        local Lock = require("features.lockscreen")
        if Lock.refresh then Lock.refresh(nil, true, "moonbeautify") end
    end)
    return true
end

--- 当前配置是否与部件一致（只比部件里明确写了的键）
function M.matches(partConf)
    if type(partConf) ~= "table" then return false end
    local c = conf()
    if not c then return false end
    for key, value in pairs(partConf) do
        if KEY_SET[key] and not SKIP_CAPTURE[key] and c[key] ~= value then
            return false
        end
    end
    return true
end

return M
