--[[--
设置界面共用的小工具：重画、写配置、选图、单选弹窗、取景、组件清单、提示。

@module moonbeautify.ui.common
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local List = require("ui.themes.widgets.list")
local Overlay = require("desktop.pages.setting.overlay")
local Image = require("utils.image")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")

local M = {}

--- 选完设置重画首页（桌面还在就整屏刷一次）
---@param desktop table|nil
local function repaint(desktop)
    -- 换图/换尺寸后旧的解码结果不会再命中，清掉让缓存不随设置次数无限增长
    require("moonbeautify.render.bg").clear()
    require("moonbeautify.render.deco").clear()
    if not desktop then return end
    pcall(function() desktop:updateView() end)
    -- desktop:updateView 里已顺带重刷设置页；这里标全屏让整条 window stack 一起重画
    pcall(function() UIManager:setDirty("all", "ui") end)
end

--- 取景设置项的显示文字：有选区显示选区描述，否则按「整图」看待。
local function focusText(focus)
    if type(focus) == "table" and tonumber(focus.w) and tonumber(focus.h) then
        local wp = math.floor(focus.w * 100 + 0.5)
        local hp = math.floor(focus.h * 100 + 0.5)
        if wp >= 99 and hp >= 99 then return _("整图") end
        return T(_("选区 宽%1 高%2"), wp, hp)
    end
    return _("整图")
end

--- 弹路径选择器。「上次目录」的读取与记忆由 core.patch 的 patchPicker 统一处理。
---@param desktop table|nil
---@param current string|nil 当前路径（文件或目录）
---@param is_file boolean 选文件 or 选目录
---@param apply fun(path: string)
local function pickPath(desktop, current, is_file, apply)
    local dir = type(current) == "string" and current ~= "" and (is_file and current:match("^(.*)/") or current)
    if not (dir and lfs.attributes(dir, "mode") == "directory") then
        -- 传 home：patchPicker 会把它换成上次用过的目录
        dir = require("apps/filemanager/filemanagerutil").getHomeFolder()
    end
    require("ui.themes.widgets.path_picker"):new{
        path = dir,
        select_file = is_file,
        filter = is_file and function(name) return Image.suffix(name) ~= nil end or nil,
        on_select = function(path)
            apply(path)
            Store.save()
            repaint(desktop)
        end,
    }:show()
end

--- 单选 / 动作弹窗。
--- items 也可以是函数：每次打开/每次选项回调后重新求值，用于让弹窗停在屏幕上并刷新最新值。
---@param title string
---@param items table[]|fun():table[]
---@param current any
---@param on_select fun(value: any)
local function choose(title, items, current, on_select)
    local makeItems = type(items) == "function" and items or nil
    local dlg
    dlg = List:new{
        title = title,
        items = makeItems and makeItems() or items,
        current = current,
        centered = true,
        on_select = function(value)
            if value == nil then return end
            on_select(value)
            -- 带 keep_open 的项会留住本弹窗（选图/缩放等），用最新配置重建选项，避免显示旧值
            if makeItems then
                pcall(function() dlg.items = makeItems(); dlg:refresh() end)
            end
        end,
    }
    dlg:show()
    return dlg
end

--- 弹「取景选区」：全屏拖拽 Picker，回调选区 { x, y, w, h }。
--- 没设图也能用——Picker 有「无预览图，仅设置选区比例」模式，照样能框选。
---@param path string|nil 预览图绝对路径（可空）
---@param focus table|nil 当前选区 { x, y, w, h }
---@param apply fun(v: table)
---@param desktop table|nil 传了就在开窗前关掉设置叠层链，避免 Picker 关闭后被 UIManager 重绘出来
local function chooseFocus(path, focus, apply, desktop)
    -- 全屏 Picker 关闭时 UIManager 会自动重绘它下面露出的窗口。
    -- 若设置叠还压在下面，就会被画出来（表现为"确定后又弹出拓展/设置页"）。
    -- 所以开窗前先关掉整条设置叠链，让 Picker 下面是桌面。
    if desktop and Overlay.closeAll then
        pcall(Overlay.closeAll, desktop)
    end
    require("moonbeautify.ui.focus_picker"):new{
        path = type(path) == "string" and path ~= "" and path or nil,
        current = focus,
        on_select = function(x, y, w, h) apply({ x = x, y = y, w = w, h = h }) end,
    }:show()
end

--- 组件清单：月读首页注册表（内置 + 扩展）
---@return table[] {{ id, label }}
local function componentList()
    local out = {}
    local ok, list = pcall(function() return require("desktop.pages.home.registry").list() end)
    if ok and type(list) == "table" then
        for _idx, comp in ipairs(list) do
            out[#out + 1] = { id = comp.id, label = comp.label or comp.id }
        end
    end
    return out
end

--- 轻提示（月读主题 Toast：点一下即关，默认 2 秒自动消失）
---@param text string
---@param seconds number|nil
local function toast(text, seconds)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = seconds or 2 }:show()
end

--- 让当前主题页重新取数据（sections 是函数，rebuild 会重新调用）
---@param desktop table|nil
local function refreshOverlay(desktop)
    if not desktop then return end
    local ov = desktop.settings_overlay
    if not ov then return end
    pcall(function()
        ov.page = nil      -- 列表变短后旧页码会越界，重置回第一页
        ov:rebuild()
        UIManager:setDirty(ov, "ui")
    end)
end

M.repaint = repaint
M.focusText = focusText
M.pickPath = pickPath
M.choose = choose
M.chooseFocus = chooseFocus
M.componentList = componentList
M.toast = toast
M.refreshOverlay = refreshOverlay

return M
