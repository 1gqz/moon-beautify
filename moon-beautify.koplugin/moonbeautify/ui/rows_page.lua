--[[--
并排组合：两个组件挤同一行。
管理页用 Settings；挑组件用 List（自带分页）。

@module moonbeautify.ui.rows_page
--]]

local List = require("ui.themes.widgets.list")
local Settings = require("ui.themes.widgets.settings")
local _ = require("moonbeautify.l10n")
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, componentList, toast = Common.repaint, Common.componentList, Common.toast

local M = {}

--- 依次点两个组件，存成一组并排（一个组件只能进一组）
---@param desktop table|nil
---@param first string|nil 已选的第一个组件 id
---@param parent table|nil
local function pickPair(desktop, first, parent)
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
                chevron = not g,
                keep_open = true,
                callback = function()
                    if g then return end
                    pickPair(desktop, comp.id, parent)
                end,
            }
        end
        List:new{ title = _("第一个组件"), items = items }:show()
        return
    end
    local items = {}
    for _i, comp in ipairs(list) do
        if comp.id ~= first and not index[comp.id] then
            items[#items + 1] = {
                value = comp.id,
                text = comp.label,
                chevron = true,
                callback = function()
                    local c = Store.conf()
                    c.rows = type(c.rows) == "table" and c.rows or {}
                    c.rows[#c.rows + 1] = { first, comp.id }
                    Store.save()
                    repaint(desktop)
                    if parent then pcall(function() parent:updateView() end) end
                end,
            }
        end
    end
    if #items == 0 then
        toast(_("其余组件都已有组合，没有可并排的了"))
        return
    end
    List:new{
        title = T(_("和「%1」并排"), labels[first] or first),
        items = items,
    }:show()
end

--- 并排组合管理页
---@param desktop table|nil
local function rowsPage(desktop)
    local conf = Store.conf()
    local cleaned, changed = require("moonbeautify.widgets.rows").cleanGroups(conf.rows)
    if changed then
        conf.rows = #cleaned > 0 and cleaned or nil
        Store.save()
        repaint(desktop)
        toast(_("清理了与其他组合重叠的无效组合"))
    end

    Settings:new{
        title = _("并排组合"),
        items = function(page)
            local groups = require("moonbeautify.widgets.rows").cleanGroups(Store.conf().rows)
            local labels = {}
            for _i, comp in ipairs(componentList()) do labels[comp.id] = comp.label end
            local items = {
                { note = _("同一页的两个组件合成一行，宽度均分") },
            }
            for i, group in ipairs(groups) do
                local names = {}
                for _j, id in ipairs(group) do names[#names + 1] = labels[id] or id end
                local text = table.concat(names, " ＋ ")
                items[#items + 1] = {
                    title = text,
                    status = _("并排"),
                    chevron = true,
                    callback = function()
                        Settings:new{
                            title = text,
                            items = function(sub)
                                return {
                                    {
                                        title = _("解散这一组"),
                                        chevron = false,
                                        callback = function()
                                            local c = Store.conf()
                                            if type(c.rows) == "table" then
                                                table.remove(c.rows, i)
                                                if #c.rows == 0 then c.rows = nil end
                                            end
                                            Store.save()
                                            repaint(desktop)
                                            pcall(function() sub:close() end)
                                            pcall(function() page:updateView() end)
                                        end,
                                    },
                                }
                            end,
                        }:show()
                        return false
                    end,
                }
            end
            items[#items + 1] = {
                title = _("新建并排组合…"),
                chevron = true,
                callback = function()
                    pickPair(desktop, nil, page)
                    return false
                end,
            }
            return items
        end,
    }:show()
end

M.page = rowsPage

return M
