--- 界面壁纸部件：把月读 features.wallpaper 的配置当成一个可分享的部件。
--- 配置本身不在 ext.beautify 里，应用/备份/还原都走 MoonSettings。
local MoonSettings = require("utils.settings")

local M = {}

local ID = "features.wallpaper"
local okScope, scopeMod = pcall(function() return require("features.wallpaper.setting") end)
local SCOPES = (okScope and scopeMod and scopeMod.SCOPES) or
    { "home", "library", "store", "insight", "settings", "dialog", "reader" }

local KEYS = {
    "wallpaper_enabled", "wallpaper_desktop", "wallpaper_dialog",
    "wallpaper_topbar", "wallpaper_tabbar", "wallpaper_tabbar_plain",
    "wallpaper_contain", "wallpaper_opacity", "wallpaper_custom_image",
    "wallpaper_source",
}
for _, scope in ipairs(SCOPES) do
    KEYS[#KEYS + 1] = "wallpaper_" .. scope
    KEYS[#KEYS + 1] = "wallpaper_image_" .. scope
    KEYS[#KEYS + 1] = "wallpaper_contain_" .. scope
    KEYS[#KEYS + 1] = "wallpaper_opacity_" .. scope
end

local KEY_SET = {}
for _, key in ipairs(KEYS) do KEY_SET[key] = true end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function conf()
    return MoonSettings.get(ID)
end

--- 取当前壁纸配置（只取壁纸相关键，nil 键不写）
function M.capture()
    local c = conf()
    local out = {}
    for _, key in ipairs(KEYS) do
        if c[key] ~= nil then out[key] = copy(c[key]) end
    end
    return out
end

--- 把一份壁纸配置写回月读并让缓存失效
function M.apply(partConf)
    if type(partConf) ~= "table" then return end
    local c = conf()
    for _, key in ipairs(KEYS) do c[key] = copy(partConf[key]) end
    MoonSettings.save(ID, c)
    pcall(function() require("features.wallpaper").invalidate() end)
end

--- 当前配置是否与部件一致（只比部件里明确写了的键）
function M.matches(partConf)
    if type(partConf) ~= "table" then return false end
    local c = conf()
    for key, value in pairs(partConf) do
        if KEY_SET[key] then
            if c[key] ~= value then return false end
        end
    end
    return true
end

return M
