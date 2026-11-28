--[[--
底栏图标：一页列出底栏格子，交互照月读「阅读页底栏」的组件列表——
左侧是当前图标，点整行换图；右侧清除（恢复默认图标）、上移、下移。

@module moonbeautify.ui.tab_page
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Button = require("ui.themes.widgets.button")
local Row = require("ui.themes.widgets.row")
local Theme = require("ui.themes")
local _ = require("moonbeautify.l10n")
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, pickPath = Common.repaint, Common.pickPath

local M = {}

--- 底栏格子清单（月读原始顺序）：优先用桌面当前的 Tab，取不到（阅读中）就退回内置格子。
---@param desktop table|nil
---@return table[] {{ id, text, icon }}
local function tabList(desktop)
    local out = {}
    for _idx, tab in ipairs(desktop and type(desktop._tabs) == "table" and desktop._tabs or {}) do
        out[#out + 1] = { id = tab.id, text = tab.text or tab.id, icon = tab.icon }
    end
    if #out > 0 then return out end
    return {
        { id = "home", text = _("首页"), icon = "home" },
        { id = "library", text = _("图书馆"), icon = "local_library" },
        { id = "store", text = _("书城"), icon = "storefront" },
        { id = "insight", text = _("统计"), icon = "bar_chart" },
        { id = "settings", text = _("设置"), icon = "settings" },
    }
end

--- 按 tab_order 排好的格子：配置里有的按配置排，没配的按月读原顺序跟在后面（与 core.patch 一致）
---@param tabs table[]
---@return table[]
local function ordered(tabs)
    local order = Store.conf().tab_order
    local rank = {}
    for i, id in ipairs(type(order) == "table" and order or {}) do
        if rank[id] == nil then rank[id] = i end
    end
    local out = {}
    for i, tab in ipairs(tabs) do out[i] = { tab = tab, i = i } end
    table.sort(out, function(a, b)
        local ra, rb = rank[a.tab.id] or math.huge, rank[b.tab.id] or math.huge
        if ra ~= rb then return ra < rb end
        return a.i < b.i
    end)
    for i, item in ipairs(out) do out[i] = item.tab end
    return out
end

local function changed(desktop)
    Store.save()
    repaint(desktop)
end

---@param id string
---@param path string|nil nil = 恢复默认图标
local function setIcon(desktop, id, path)
    local conf = Store.conf()
    local map = type(conf.tab_icons) == "table" and conf.tab_icons or {}
    map[id] = path
    conf.tab_icons = next(map) ~= nil and map or nil
    changed(desktop)
end

--- 交换相邻两格并整体写回 tab_order。眼下不在底栏的格子（如关掉的书城）保留原相对顺序排在后面
---@param tabs table[] 当前显示顺序
local function move(desktop, tabs, index, delta)
    local ids, shown = {}, {}
    for i, tab in ipairs(tabs) do ids[i], shown[tab.id] = tab.id, true end
    ids[index], ids[index + delta] = ids[index + delta], ids[index]
    local old = Store.conf().tab_order
    for _idx, id in ipairs(type(old) == "table" and old or {}) do
        if not shown[id] then ids[#ids + 1] = id end
    end
    Store.conf().tab_order = ids
    changed(desktop)
end

--- 月读「页面顺序」同款 36px ghost 按钮，不可用时禁用
local function smallButton(icon, enabled, callback)
    local size = Theme.px(36)
    return Button:new{
        icon = icon, variant = "ghost", width = size, height = size,
        enabled = enabled, callback = callback,
    }
end

local function tabRow(desktop, tabs, index)
    local tab = tabs[index]
    return function(iw)
        local map = Store.conf().tab_icons
        local custom = type(map) == "table" and map[tab.id] or nil
        local gap = Theme.px(4)
        return Row.widget({
            width = iw,
            chevron = false,
            icon = custom or tab.icon or "tab",
            title = tab.text,
            subtitle = custom and _("自定义图片") or _("默认图标"),
            status = HorizontalGroup:new{
                align = "center",
                smallButton("close", custom ~= nil, function() setIcon(desktop, tab.id, nil) end),
                HorizontalSpan:new{ width = gap },
                smallButton("arrow_upward", index > 1, function() move(desktop, tabs, index, -1) end),
                HorizontalSpan:new{ width = gap },
                smallButton("arrow_downward", index < #tabs, function() move(desktop, tabs, index, 1) end),
            },
            -- 右侧按钮先接住自己的点击，点行的其余部分才是换图
            callback = function()
                pickPath(desktop, custom, true, function(path) setIcon(desktop, tab.id, path) end)
            end,
        })
    end
end

local function resetRow(desktop, icon, title, enabled, key)
    return function(iw)
        return Row.widget({
            width = iw, kind = "action", chevron = false, icon = icon, title = title,
            enabled = enabled,
            callback = function()
                Store.conf()[key] = nil
                changed(desktop)
            end,
        })
    end
end

--- 底栏图标设置页（设置叠层）
---@param desktop table|nil
---@return table
function M.page(desktop)
    return {
        title = _("底栏图标"),
        sections = function()
            local tabs = ordered(tabList(desktop))
            local rows = {}
            for i = 1, #tabs do rows[i] = tabRow(desktop, tabs, i) end
            rows[#rows + 1] = function(iw)
                return Row.note(iw, _("点一行换图，建议用方形单色小图标（PNG），会缩到图标大小"))
            end
            local conf = Store.conf()
            local anyIcon = type(conf.tab_icons) == "table" and next(conf.tab_icons) ~= nil
            local anyOrder = type(conf.tab_order) == "table" and #conf.tab_order > 0
            return {
                { title = _("底栏图标"), rows = rows },
                { title = _("恢复"), rows = {
                    resetRow(desktop, "restart_alt", _("全部恢复默认图标"), anyIcon, "tab_icons"),
                    resetRow(desktop, "swap_vert", _("恢复默认顺序"), anyOrder, "tab_order"),
                } },
            }
        end,
    }
end

return M
