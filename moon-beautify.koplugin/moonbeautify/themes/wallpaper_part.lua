--- 界面壁纸部件：把月读 features.wallpaper 的配置当成一个可分享的部件。
--- 配置本身不在 ext.beautify 里，应用/备份/还原都走 MoonSettings。
local lfs = require("libs/libkoreader-lfs")
local MoonSettings = require("utils.settings")
local Image = require("utils.image")
local Pick = require("moonbeautify.core.pick")

local M = {}

local ID = "features.wallpaper"

-- 月读不可用时（单测）的兜底；正常从 features.wallpaper.setting 的 defaults + keys 取，
-- 月读加了新壁纸键这里自动跟上
local FALLBACK_KEYS = {
    "wallpaper_enabled", "wallpaper_desktop", "wallpaper_dialog",
    "wallpaper_topbar", "wallpaper_tabbar", "wallpaper_tabbar_plain",
    "wallpaper_tabbar_translucent", "wallpaper_contain", "wallpaper_opacity",
    "wallpaper_custom_image",
}
for _, scope in ipairs({ "home", "library", "store", "insight", "settings", "dialog", "reader" }) do
    for _, prefix in ipairs({ "wallpaper_", "wallpaper_image_", "wallpaper_contain_", "wallpaper_opacity_" }) do
        FALLBACK_KEYS[#FALLBACK_KEYS + 1] = prefix .. scope
    end
end

local KEYS, KEY_SET = {}, {}
local function addKey(key)
    if type(key) ~= "string" or key == "" or KEY_SET[key] then return end
    KEY_SET[key] = true
    KEYS[#KEYS + 1] = key
end

local okSpec, spec = pcall(function() return require("features.wallpaper.setting") end)
if okSpec and type(spec) == "table" then
    for key in pairs(spec.defaults or {}) do addKey(key) end
    for _, key in ipairs(spec.keys or {}) do addKey(key) end
else
    for _, key in ipairs(FALLBACK_KEYS) do addKey(key) end
end
-- 旧版月读的壁纸来源键，老主题包里还带着，照旧收发
addKey("wallpaper_source")

local copy = require("moonbeautify.themes.parts").copy

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

--- 值得存进主题：开关开着、且明确选了图片或有图的文件夹。
--- “开 + 未选择”只会在主题里留下一个空壁纸部件。
function M.shareable(partConf)
    if partConf.wallpaper_enabled == false then return false end
    for key, value in pairs(partConf) do
        local is_image_key = key == "wallpaper_custom_image" or key:match("^wallpaper_image_") ~= nil
        if is_image_key and type(value) == "string" and value ~= "" then
            local mode = lfs.attributes(value, "mode")
            if mode == "file" and Image.suffix(value) then return true end
            if mode == "directory" and #Pick.listImages(value) > 0 then return true end
        end
    end
    return false
end

return M
