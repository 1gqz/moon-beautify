--[[--
组件背景、组件顶层图（花边）与输入法键盘背景。

@module moonbeautify.ui.decor_page
--]]

local List = require("ui.themes.widgets.list")
local Spin = require("ui.themes.widgets.spin")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, focusText, pickPath, choose, chooseFocus, componentList = Common.repaint, Common.focusText, Common.pickPath, Common.choose, Common.chooseFocus, Common.componentList

--- 组件背景/花边可设置的组件：排除本扩展的吧唧、相框（它们有自己的设置入口）。
---@return table[] {{ id, label }}
local function decoratableComponents()
    local out = {}
    for _i, comp in ipairs(componentList()) do
        local id = comp.id
        local bare = type(id) == "string" and (id:match("ext%.beautify%.(.+)$") or id) or ""
        local is_badge = bare:match("^badge%d*$") ~= nil
        local is_frame = bare:match("^frame%d*$") ~= nil
        if not (is_badge or is_frame) then out[#out + 1] = comp end
    end
    return out
end

local M = {}

--- 单个组件的背景：选图 / 不透明度 / 移除
---@param desktop table|nil
---@param comp table { id, label }
local function widgetBgDialog(desktop, comp)
    local function nameOf(path)
        if type(path) ~= "string" or path == "" then return nil end
        return path:match("([^/]+)$") or path
    end
    local function makeItems()
        local c = Store.conf()
        local all = type(c.widget_bg) == "table" and c.widget_bg or {}
        local item = all[comp.id]
        local src = type(item) == "table" and item.src or nil
        local veil = type(item) == "table" and tonumber(item.veil) or 0
        local padMap = type(c.widget_pad) == "table" and c.widget_pad or {}
        local pad = tonumber(padMap[comp.id]) or 0
        local focus = type(item) == "table" and require("moonbeautify.widgets.view").focusOf(item.focus) or nil
        local name = nameOf(src)
        return {
            { value = "pick", text = name and T(_("更换背景图：%1"), name) or _("选一张背景图…"), keep_open = true },
            { value = "anchor", text = T(_("取景选区：%1"), focusText(focus)), enabled = true, keep_open = true },
            { value = "veil", text = T(_("内容提亮：%1%"), veil), keep_open = true },
            { value = "pad", text = T(_("内容内边距：%1"), pad > 0 and (pad .. " px") or _("关")), keep_open = true },
            { value = "reset", text = _("移除背景"), enabled = item ~= nil, keep_open = true },
        }
    end
    local dlg
    local function refreshDlg()
        if dlg then pcall(function() dlg.items = makeItems(); dlg:refresh() end) end
    end
    local function save(mutate)
        local c = Store.conf()
        c.widget_bg = type(c.widget_bg) == "table" and c.widget_bg or {}
        mutate(c.widget_bg)
        if next(c.widget_bg) == nil then c.widget_bg = nil end
        Store.save()
        repaint(desktop)
        refreshDlg()
    end
    dlg = choose(comp.label, makeItems, nil, function(value)
        local c = Store.conf()
        local all = type(c.widget_bg) == "table" and c.widget_bg or {}
        local item = all[comp.id]
        if value == "pick" then
            pickPath(desktop, type(item) == "table" and item.src or nil, true, function(path)
                save(function(bg)
                    bg[comp.id] = bg[comp.id] or {}
                    bg[comp.id].src = path
                end)
            end)
        elseif value == "anchor" then
            local focus = type(item) == "table" and require("moonbeautify.widgets.view").focusOf(item.focus) or nil
            chooseFocus(type(item) == "table" and item.src or nil,
                focus, function(v)
                    -- 只落盘不 repaint：避免全屏选区关闭后重建叠层导致拓展/设置页重现
                    local cc = Store.conf()
                    cc.widget_bg = type(cc.widget_bg) == "table" and cc.widget_bg or {}
                    cc.widget_bg[comp.id] = cc.widget_bg[comp.id] or {}
                    cc.widget_bg[comp.id].focus = { x = v.x, y = v.y, w = v.w, h = v.h }
                    Store.save()
                    refreshDlg()
                end, desktop)
        elseif value == "veil" then
            local veil = type(item) == "table" and tonumber(item.veil) or 0
            Spin:new{
                title = _("内容提亮"),
                fields = { {
                    value = veil, min = 0, max = 90, step = 10,
                    format = function(v) return v .. "%" end,
                } },
                callback = function(v)
                    save(function(bg)
                        bg[comp.id] = bg[comp.id] or {}
                        bg[comp.id].veil = math.floor(v)
                    end)
                end,
            }:show()
        elseif value == "pad" then
            local padMap = type(c.widget_pad) == "table" and c.widget_pad or {}
            local pad = tonumber(padMap[comp.id]) or 0
            Spin:new{
                title = _("内容内边距"),
                fields = { {
                    value = pad, min = 0, max = 24, step = 2,
                    format = function(v) return (v <= 0) and _("关") or (v .. " px") end,
                } },
                callback = function(v)
                    local cc = Store.conf()
                    cc.widget_pad = type(cc.widget_pad) == "table" and cc.widget_pad or {}
                    local n = math.floor(v)
                    cc.widget_pad[comp.id] = n > 0 and n or nil
                    if next(cc.widget_pad) == nil then cc.widget_pad = nil end
                    Store.save()
                    repaint(desktop)
                    refreshDlg()
                end,
            }:show()
        elseif value == "reset" then
            save(function(bg) bg[comp.id] = nil end)
        end
    end)
end

--- 组件背景总入口
---@param desktop table|nil
local function widgetBgPage(desktop)
    local conf = Store.conf()
    local all = type(conf.widget_bg) == "table" and conf.widget_bg or {}
    local items = {}
    for _idx, comp in ipairs(decoratableComponents()) do
        items[#items + 1] = {
            value = comp.id,
            text = comp.label,
            mandatory = type(all[comp.id]) == "table" and _("已设") or nil,
            keep_open = true,
        }
    end
    choose(_("组件背景"), items, nil, function(id)
        for _i, comp in ipairs(decoratableComponents()) do
            if comp.id == id then return widgetBgDialog(desktop, comp) end
        end
    end)
end

--- 输入法键盘背景：选图 / 取景选区 / 提亮 / 移除
---@param desktop table|nil
local function imeBgDialog(desktop)
    local function nameOf(path)
        if type(path) ~= "string" or path == "" then return nil end
        return path:match("([^/]+)$") or path
    end
    local function makeItems()
        local c = Store.conf()
        local item = type(c.ime_bg) == "table" and c.ime_bg or {}
        local focus = type(item.focus) == "table" and require("moonbeautify.widgets.view").focusOf(item.focus) or nil
        local name = nameOf(item.src)
        return {
            { value = "pick", text = name and T(_("更换背景图：%1"), name) or _("选一张背景图…"), keep_open = true },
            { value = "anchor", text = T(_("取景选区：%1"), focusText(focus)), enabled = true, keep_open = true },
            { value = "veil", text = T(_("内容提亮：%1%"), tonumber(item.veil) or 0), keep_open = true },
            { value = "alpha", text = T(_("按键透明度：%1%"), tonumber(item.key_alpha) or 0), keep_open = true },
            { value = "reset", text = _("移除背景"), enabled = name ~= nil, keep_open = true },
        }
    end
    local dlg
    local function refreshDlg()
        if dlg then pcall(function() dlg.items = makeItems(); dlg:refresh() end) end
    end
    local function save(mutate)
        local c = Store.conf()
        c.ime_bg = type(c.ime_bg) == "table" and c.ime_bg or {}
        mutate(c.ime_bg)
        if next(c.ime_bg) == nil then c.ime_bg = nil end
        Store.save()
        repaint(desktop)
        refreshDlg()
    end
    dlg = choose(_("输入法键盘背景"), makeItems, nil, function(value)
        local c = Store.conf()
        local item = type(c.ime_bg) == "table" and c.ime_bg or {}
        if value == "pick" then
            pickPath(desktop, item.src, true, function(path)
                save(function(bg) bg.src = path end)
            end)
        elseif value == "anchor" then
            local focus = type(item.focus) == "table" and require("moonbeautify.widgets.view").focusOf(item.focus) or nil
            chooseFocus(item.src, focus, function(v)
                -- 只落盘不 repaint：避免全屏选区关闭后重建叠层导致设置页重现
                local cc = Store.conf()
                cc.ime_bg = type(cc.ime_bg) == "table" and cc.ime_bg or {}
                cc.ime_bg.focus = { x = v.x, y = v.y, w = v.w, h = v.h }
                Store.save()
                refreshDlg()
            end, desktop)
        elseif value == "veil" then
            Spin:new{
                title = _("内容提亮"),
                fields = { {
                    value = tonumber(item.veil) or 0, min = 0, max = 90, step = 10,
                    format = function(v) return v .. "%" end,
                } },
                callback = function(v)
                    save(function(bg) bg.veil = math.floor(v) end)
                end,
            }:show()
        elseif value == "alpha" then
            Spin:new{
                title = _("按键透明度"),
                fields = { {
                    value = tonumber(item.key_alpha) or 0, min = 0, max = 100, step = 10,
                    format = function(v) return v .. "%" end,
                } },
                callback = function(v)
                    save(function(bg) bg.key_alpha = math.floor(v) end)
                end,
            }:show()
        elseif value == "reset" then
            save(function(bg)
                for k in pairs(bg) do bg[k] = nil end
            end)
        end
    end)
end

--- 组件顶层图总入口：逐个组件设置（与组件背景一样用取景选区）
---@param desktop table|nil
local function widgetLacePage(desktop)
    local Deco = require("moonbeautify.render.deco")
    local focusOf = require("moonbeautify.widgets.view").focusOf
    local conf = Store.conf()
    local map = type(conf.widget_lace) == "table" and conf.widget_lace or {}
    -- 取值兼容旧格式：字符串=纯路径；表={ src, focus }
    local function split(v)
        if type(v) == "string" then return v ~= "" and v or nil, nil end
        if type(v) == "table" then
            local p = v.src
            return (type(p) == "string" and p ~= "") and p or nil, focusOf(v.focus)
        end
        return nil, nil
    end
    local items = {}
    local labels = {}
    for _idx, comp in ipairs(decoratableComponents()) do
        labels[comp.id] = comp.label
        local _src = split(map[comp.id])
        items[#items + 1] = {
            value = comp.id,
            text = comp.label,
            mandatory = _src and _("已设置") or nil,
            keep_open = true,
        }
    end
    List:new{
        title = _("组件花边"),
        subtitle = _("和组件背景一样用取景选区（透明 PNG 可镂空，普通图片整张盖住）"),
        items = items,
        centered = true,
        on_select = function(value)
            local function nameOf(path)
                if type(path) ~= "string" or path == "" then return nil end
                return path:match("([^/]+)$") or path
            end
            local function makeItems()
                local c = Store.conf()
                local m = type(c.widget_lace) == "table" and c.widget_lace or {}
                local current, focus = split(m[value])
                local name = nameOf(current)
                return {
                    { value = "pick", text = name and T(_("更换顶层图：%1"), name) or _("选一张顶层图…"), keep_open = true },
                    { value = "anchor", text = T(_("取景选区：%1"), focusText(focus)), enabled = true, keep_open = true },
                    { value = "reset", text = _("移除顶层图"), enabled = current ~= nil, keep_open = true },
                }
            end
            local dlg
            local function refreshDlg()
                if dlg then pcall(function() dlg.items = makeItems(); dlg:refresh() end) end
            end
            dlg = choose(labels[value] or value, makeItems, nil, function(v)
                local c = Store.conf()
                local m = type(c.widget_lace) == "table" and c.widget_lace or {}
                local current, focus = split(m[value])
                -- 保留已有字段；没选图也能先设选区，选图时一起写回
                local function write(src, fit_focus, quiet)
                    local cc = Store.conf()
                    cc.widget_lace = type(cc.widget_lace) == "table" and cc.widget_lace or {}
                    cc.widget_lace[value] = { src = src, focus = fit_focus }
                    require("moonbeautify.render.deco").clear()
                    Store.save()
                    -- 全屏选区关闭后不重建叠层，否则会把底下的拓展/设置页重画出来
                    if not quiet then repaint(desktop) end
                    refreshDlg()
                end
                if v == "pick" then
                    pickPath(desktop, current, true, function(path) write(path, focus) end)
                elseif v == "anchor" then
                    chooseFocus(current, focus, function(v2)
                        write(current, { x = v2.x, y = v2.y, w = v2.w, h = v2.h }, true)
                    end, desktop)
                elseif v == "reset" then
                    local cc = Store.conf()
                    cc.widget_lace = type(cc.widget_lace) == "table" and cc.widget_lace or {}
                    cc.widget_lace[value] = nil
                    if next(cc.widget_lace) == nil then cc.widget_lace = nil end
                    require("moonbeautify.render.deco").clear()
                    Store.save()
                    repaint(desktop)
                    refreshDlg()
                end
            end)
        end,
    }:show()
end

M.bgPage = widgetBgPage
M.imeDialog = imeBgDialog
M.lacePage = widgetLacePage

return M
