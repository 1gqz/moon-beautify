--[[--
并排组合：两个组件挤同一行。

@module moonbeautify.ui.rows_page
--]]

local List = require("ui.themes.widgets.list")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, choose, componentList, toast = Common.repaint, Common.choose, Common.componentList, Common.toast

local M = {}

--- 依次点两个组件，存成一组并排（一个组件只能进一组）
---@param desktop table|nil
---@param first string|nil 已选的第一个组件 id
local function pickPair(desktop, first)
    local list = componentList()
    local labels = {}
    for _i, comp in ipairs(list) do labels[comp.id] = comp.label end
    local index = require("moonbeautify.widgets.rows").groupIndex(Store.conf().rows)
    if not first then
        local items = {}
        for _i, comp in ipairs(list) do
            local g = index[comp.id]
            local mate
            if g then
                for _j, id in ipairs(g.ids) do
                    if id ~= comp.id and labels[id] then mate = labels[id] break end
                end
            end
            items[#items + 1] = {
                value = comp.id,
                text = comp.label,
                mandatory = mate and T(_("已和「%1」并排"), mate) or nil,
                enabled = not g,
            }
        end
        return choose(_("第一个组件"), items, nil, function(id)
            if id then pickPair(desktop, id) end
        end)
    end
    -- 第二个：只挑还没进任何组的
    local items = {}
    for _i, comp in ipairs(list) do
        if comp.id ~= first and not index[comp.id] then
            items[#items + 1] = { value = comp.id, text = comp.label }
        end
    end
    if #items == 0 then
        toast(_("其余组件都已有组合，没有可并排的了"))
        return
    end
    choose(T(_("和「%1」并排"), labels[first] or first), items, nil, function(id)
        local c = Store.conf()
        c.rows = type(c.rows) == "table" and c.rows or {}
        c.rows[#c.rows + 1] = { first, id }
        Store.save()
        repaint(desktop)
    end)
end

--- 并排组合管理页
---@param desktop table|nil
local function rowsPage(desktop)
    local conf = Store.conf()
    -- 自愈：旧版本可能存过成员重叠的组合（渲染层只认先出现的那组），打开本页时清掉
    local cleaned, changed = require("moonbeautify.widgets.rows").cleanGroups(conf.rows)
    if changed then
        conf.rows = #cleaned > 0 and cleaned or nil
        Store.save()
        repaint(desktop)
        toast(_("清理了与其他组合重叠的无效组合"))
    end
    local groups = cleaned
    local labels = {}
    for _i, comp in ipairs(componentList()) do labels[comp.id] = comp.label end

    local items = {}
    for i, group in ipairs(groups) do
        local names = {}
        for _j, id in ipairs(group) do names[#names + 1] = labels[id] or id end
        items[#items + 1] = { value = i, text = table.concat(names, " ＋ "), mandatory = _("并排") }
    end
    items[#items + 1] = { value = "new", text = _("新建并排组合…") }

    List:new{
        title = _("并排组合"),
        subtitle = _("同一页的两个组件合成一行，宽度均分"),
        items = items,
        centered = true,
        on_select = function(value)
            if value == "new" then return pickPair(desktop, nil) end
            if type(value) ~= "number" then return end
            local text = items[value] and items[value].text or _("并排")
            choose(text, { { value = "remove", text = _("解散这一组") } }, nil, function()
                local c = Store.conf()
                if type(c.rows) == "table" then
                    table.remove(c.rows, value)
                    if #c.rows == 0 then c.rows = nil end
                end
                Store.save()
                repaint(desktop)
            end)
        end,
    }:show()
end

M.page = rowsPage

return M
