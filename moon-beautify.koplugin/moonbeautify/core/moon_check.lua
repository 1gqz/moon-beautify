--[[--
月读依赖门禁：没装月读，或月读低于 0.8.0，本插件整体不工作。
main.lua 负责弹一次提示，moon_source.lua 负责不装补丁、不登记任何能力。

月读版本号在 book.koplugin/bookversion.lua（打包注入；源码运行返回 0.0.0-dev，视为满足）。
本插件 main.lua 加载时月读目录未必在 package.path 里，require 不到就按同级目录直接读文件。
--]]

local _ = require("moonbeautify.l10n")

local MIN = "0.8.0"
local DEV = "0.0.0-dev"
local PLUGINS_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+/moonbeautify/core/[^/]+$")

local M = {}

--- 已安装的月读版本号；没装返回 nil。
---@return string|nil
function M.moonVersion()
    local ok, v = pcall(require, "bookversion")
    if ok and type(v) == "string" then return v end
    local chunk = PLUGINS_DIR and loadfile(PLUGINS_DIR .. "/book.koplugin/bookversion.lua")
    if not chunk then return nil end
    ok, v = pcall(chunk)
    return ok and type(v) == "string" and v or nil
end

---@param v string
---@return boolean
local function atLeastMin(v)
    if v == DEV then return true end
    local a = { v:match("^v?(%d+)%.(%d+)%.(%d+)") }
    if #a == 0 then return false end
    local b = { MIN:match("^(%d+)%.(%d+)%.(%d+)$") }
    for i = 1, 3 do
        local x, y = tonumber(a[i]), tonumber(b[i])
        if x ~= y then return x > y end
    end
    return true
end

--- 给定月读版本号是否可用；不可用返回给用户看的原因。
---@param v string|nil 月读版本号，nil 表示没装
---@return string|nil
function M.check(v)
    if not v then return _("月华美化需要先安装月读（book.koplugin）。") end
    if not atLeastMin(v) then
        return _("月华美化需要月读 %s 或更高版本，当前是 %s，请先升级月读。", MIN, v)
    end
end

---@return string|nil
function M.problem()
    return M.check(M.moonVersion())
end

return M
