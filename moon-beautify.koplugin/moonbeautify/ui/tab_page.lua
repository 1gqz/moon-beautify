--[[--
底栏图标：换图与调整顺序。

@module moonbeautify.ui.tab_page
--]]

local List = require("ui.themes.widgets.list")
local _ = require("moonbeautify.l10n")
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, pickPath, choose, toast = Common.repaint, Common.pickPath, Common.choose, Common.toast

local M = {}

--- 底栏格子清单：优先用桌面当前的 Tab，取不到就退回已知 id。
---@param desktop table|nil
---@return table[] {{ id, text }}
local function tabList(desktop)
    local out = {}
    local tabs = desktop and desktop._tabs
    if type(tabs) == "table" then
        for _idx, tab in ipairs(tabs) do
            out[#out + 1] = { id = tab.id, text = tab.text or tab.id }
        end
    end
    if #out == 0 then
        out = {
            { id = "home", text = _("首页") }, { id = "library", text = _("图书馆") },
            { id = "store", text = _("书城") }, { id = "insight", text = _("统计") },
            { id = "settings", text = _("设置") },
        }
    end
    return out
end

--- 单个底栏格子的图标：选图 / 恢复默认
---@param desktop table|nil
---@param tab table { id, text }
local function tabIconDialog(desktop, tab)
    local map = Store.conf().tab_icons
    local current = type(map) == "table" and map[tab.id] or nil
    choose(tab.text or tab.id, {
        { value = "pick", text = _("选一张图…") },
        { value = "reset", text = _("恢复默认图标"), enabled = current ~= nil },
    }, nil, function(value)
        if value == "pick" then
            pickPath(desktop, current, true, function(path)
                local conf = Store.conf()
                conf.tab_icons = type(conf.tab_icons) == "table" and conf.tab_icons or {}
                conf.tab_icons[tab.id] = path
                Store.save()
                repaint(desktop)
            end)
        elseif value == "reset" then
            local conf = Store.conf()
            if type(conf.tab_icons) == "table" then
                conf.tab_icons[tab.id] = nil
                if next(conf.tab_icons) == nil then conf.tab_icons = nil end
                Store.save()
                repaint(desktop)
            end
        end
    end)
end

--- 底栏图标总入口
---@param desktop table|nil
local function tabIconsPage(desktop)
    local conf = Store.conf()
    local map = type(conf.tab_icons) == "table" and conf.tab_icons or {}
    local items = {}
    for _idx, tab in ipairs(tabList(desktop)) do
        items[#items + 1] = {
            value = tab.id,
            text = tab.text,
            mandatory = map[tab.id] and _("自定义") or nil,
        }
    end
    local custom = next(map) ~= nil
    items[#items + 1] = {
        value = "reset",
        text = _("恢复默认图标"),
        mandatory = custom and _("恢复全部") or nil,
        enabled = custom,
        separator = true,
    }
    List:new{
        title = _("底栏图标"),
        subtitle = _("建议用方形单色小图标（PNG），会缩到图标大小"),
        items = items,
        current = nil,
        centered = true,
        on_select = function(id)
            if id == "reset" then
                local c = Store.conf()
                c.tab_icons = nil
                Store.save()
                repaint(desktop)
                return
            end
            for _i, tab in ipairs(tabList(desktop)) do
                if tab.id == id then return tabIconDialog(desktop, tab) end
            end
        end,
    }:show()
end

local tabOrderPage -- 前置声明：moveTab 移动完要重开本页

--- 当前顺序数组：用户配置里还存在的格子按配置排，没配的按默认顺序补在后面
---@param desktop table|nil
---@return string[] id 数组
local function currentTabOrder(desktop)
    local conf = Store.conf()
    local order = type(conf.tab_order) == "table" and conf.tab_order or {}
    local seen, out = {}, {}
    for _idx, id in ipairs(order) do
        if type(id) == "string" and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    for _idx, tab in ipairs(tabList(desktop)) do
        if not seen[tab.id] then
            seen[tab.id] = true
            out[#out + 1] = tab.id
        end
    end
    return out
end

--- id -> 显示名
---@param desktop table|nil
---@param id string
---@return string
local function tabName(desktop, id)
    for _idx, tab in ipairs(tabList(desktop)) do
        if tab.id == id then return tab.text end
    end
    return id
end

--- 单个格子的移动：上移 / 下移
---@param desktop table|nil
---@param order string[] 当前顺序（会被修改并保存）
---@param index integer 要移动的格子
---@param delta integer -1 上移 / 1 下移
local function moveTab(desktop, order, index, delta)
    local to = index + delta
    if to < 1 or to > #order then
        toast(delta < 0 and _("已经在最前面了") or _("已经在最后面了"))
        return
    end
    order[index], order[to] = order[to], order[index]
    Store.conf().tab_order = order
    Store.save()
    repaint(desktop)
    tabOrderPage(desktop)   -- 重开本页让列表反映新顺序
end

--- 底栏图标顺序编辑页
---@param desktop table|nil
function tabOrderPage(desktop)
    if not desktop then
        toast(_("回到桌面后再设置"))
        return
    end
    local order = currentTabOrder(desktop)
    local conf = Store.conf()
    local custom = type(conf.tab_order) == "table" and #conf.tab_order > 0 or false
    local items = {}
    for i, id in ipairs(order) do
        items[#items + 1] = {
            value = tostring(i),
            text = tabName(desktop, id),
            mandatory = tostring(i),
        }
    end
    items[#items + 1] = {
        value = "reset",
        text = _("恢复默认顺序"),
        mandatory = custom and _("按月读原来的排列") or nil,
        enabled = custom,
        separator = true,
    }
    List:new{
        title = _("图标顺序"),
        subtitle = _("点一个图标，选上移或下移"),
        items = items,
        current = nil,
        centered = true,
        on_select = function(value)
            if value == "reset" then
                Store.conf().tab_order = nil
                Store.save()
                repaint(desktop)
                toast(_("已恢复默认顺序"))
                return
            end
            local index = tonumber(value)
            if not index then return end
            local id = order[index]
            choose(tabName(desktop, id), {
                { value = "up", text = _("上移一位"), enabled = index > 1 },
                { value = "down", text = _("下移一位"), enabled = index < #order },
            }, nil, function(v)
                if v == "up" then
                    moveTab(desktop, order, index, -1)
                elseif v == "down" then
                    moveTab(desktop, order, index, 1)
                end
            end)
        end,
    }:show()
end

M.iconsPage = tabIconsPage
M.orderPage = tabOrderPage

return M
