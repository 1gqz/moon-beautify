--[[--
组件背景、组件顶层图（花边）与输入法（键盘背景 + 按键）。
组件清单用 List（自带分页）；单组件详情与输入法用 Settings 表格弹窗。

@module moonbeautify.ui.decor_page
--]]

local List = require("ui.themes.widgets.list")
local Spin = require("ui.themes.widgets.spin")
local Settings = require("ui.themes.widgets.settings")
local _ = require("moonbeautify.l10n")
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, focusText, pickPath, chooseFocus, componentList =
    Common.repaint, Common.focusText, Common.pickPath, Common.chooseFocus, Common.componentList

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

local function nameOf(path)
    if type(path) ~= "string" or path == "" then return nil end
    return path:match("([^/]+)$") or path
end

local function fileStatus(path)
    return nameOf(path) or _("未选择")
end

--- ime_bg 空表或只剩无效字段时写成 nil；0 透明度不占位
local function normalizeIme(bg)
    if type(bg) ~= "table" then return nil end
    local Regions = require("moonbeautify.core.ime_regions")
    Regions.migrate(bg)
    if tonumber(bg.key_alpha) and tonumber(bg.key_alpha) <= 0 then bg.key_alpha = nil end
    if tonumber(bg.veil) and tonumber(bg.veil) <= 0 then bg.veil = nil end
    local has_bg = type(bg.src) == "string" and bg.src ~= ""
    if not has_bg then bg.src, bg.focus, bg.veil = nil, nil, nil end
    if type(bg.regions) == "table" then
        for id, r in pairs(bg.regions) do
            if type(r) ~= "table" or type(r.src) ~= "string" or r.src == "" then
                bg.regions[id] = nil
            end
        end
        if next(bg.regions) == nil then bg.regions = nil end
    end
    if not Regions.anySkin(bg) then bg.key_src, bg.key_focus = nil, nil end
    if not (has_bg or Regions.anySkin(bg) or (tonumber(bg.key_alpha) or 0) > 0) then
        return nil
    end
    return bg
end

---@param desktop table|nil
---@param mutate fun(bg: table)
---@param page table|nil
---@param quiet boolean|nil
local function saveIme(desktop, mutate, page, quiet)
    local c = Store.conf()
    c.ime_bg = type(c.ime_bg) == "table" and c.ime_bg or {}
    mutate(c.ime_bg)
    c.ime_bg = normalizeIme(c.ime_bg)
    Store.save()
    if not quiet then repaint(desktop) end
    if page then pcall(function() page:updateView() end) end
end

local M = {}

--- 单个组件的背景
---@param desktop table|nil
---@param comp table { id, label }
---@param parent table|nil
local function widgetBgDialog(desktop, comp, parent)
    Settings:new{
        title = comp.label,
        items = function(page)
            local c = Store.conf()
            local all = type(c.widget_bg) == "table" and c.widget_bg or {}
            local item = all[comp.id]
            local src = type(item) == "table" and item.src or nil
            local veil = type(item) == "table" and tonumber(item.veil) or 0
            local padMap = type(c.widget_pad) == "table" and c.widget_pad or {}
            local pad = tonumber(padMap[comp.id]) or 0
            local focus = type(item) == "table" and require("moonbeautify.widgets.view").focusOf(item.focus) or nil
            local function save(mutate)
                local cc = Store.conf()
                cc.widget_bg = type(cc.widget_bg) == "table" and cc.widget_bg or {}
                mutate(cc.widget_bg)
                if next(cc.widget_bg) == nil then cc.widget_bg = nil end
                Store.save()
                repaint(desktop)
                pcall(function() page:updateView() end)
                if parent then pcall(function() parent:updateView() end) end
            end
            return {
                {
                    title = _("背景图"),
                    status = fileStatus(src),
                    chevron = true,
                    callback = function()
                        pickPath(desktop, src, true, function(path)
                            save(function(bg)
                                bg[comp.id] = bg[comp.id] or {}
                                bg[comp.id].src = path
                            end)
                        end)
                        return false
                    end,
                },
                {
                    title = _("取景选区"),
                    status = focusText(focus),
                    chevron = true,
                    callback = function()
                        chooseFocus(src, focus, function(v)
                            local cc = Store.conf()
                            cc.widget_bg = type(cc.widget_bg) == "table" and cc.widget_bg or {}
                            cc.widget_bg[comp.id] = cc.widget_bg[comp.id] or {}
                            cc.widget_bg[comp.id].focus = { x = v.x, y = v.y, w = v.w, h = v.h }
                            Store.save()
                            pcall(function() page:updateView() end)
                        end, desktop)
                        return false
                    end,
                },
                {
                    title = _("内容提亮"),
                    status = veil .. "%",
                    chevron = true,
                    callback = function()
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
                        return false
                    end,
                },
                {
                    title = _("内容内边距"),
                    status = pad > 0 and (pad .. " px") or _("关"),
                    chevron = true,
                    callback = function()
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
                                pcall(function() page:updateView() end)
                            end,
                        }:show()
                        return false
                    end,
                },
                {
                    title = _("移除背景"),
                    chevron = false,
                    callback = function()
                        if item == nil then return false end
                        save(function(bg) bg[comp.id] = nil end)
                    end,
                },
            }
        end,
    }:show()
end

--- 组件背景总入口（List 自带分页，组件一多 Settings 会顶出屏）
---@param desktop table|nil
local function widgetBgPage(desktop)
    local dlg
    local function items()
        local conf = Store.conf()
        local all = type(conf.widget_bg) == "table" and conf.widget_bg or {}
        local out = {}
        for _idx, comp in ipairs(decoratableComponents()) do
            out[#out + 1] = {
                value = comp.id,
                text = comp.label,
                mandatory = type(all[comp.id]) == "table" and _("已设") or _("未设置"),
                chevron = true,
                keep_open = true,
                callback = function()
                    widgetBgDialog(desktop, comp, {
                        updateView = function()
                            if dlg then dlg:setItems(items()) end
                        end,
                    })
                end,
            }
        end
        return out
    end
    dlg = List:new{ title = _("组件背景"), items = items() }
    dlg:show()
end

--- 输入法：直接进布局预览（不再套一层 Settings 弹窗）
---@param desktop table|nil
local function imeSettings(desktop)
    require("moonbeautify.ui.ime_layout").show(desktop)
end

--- 花边：取值兼容旧格式（字符串=纯路径；表={ src, focus }）
local function splitLace(v)
    local focusOf = require("moonbeautify.widgets.view").focusOf
    if type(v) == "string" then return v ~= "" and v or nil, nil end
    if type(v) == "table" then
        local p = v.src
        return (type(p) == "string" and p ~= "") and p or nil, focusOf(v.focus)
    end
    return nil, nil
end

--- 单个组件花边
---@param desktop table|nil
---@param comp table
---@param parent table|nil
local function laceDialog(desktop, comp, parent)
    Settings:new{
        title = comp.label,
        items = function(page)
            local c = Store.conf()
            local m = type(c.widget_lace) == "table" and c.widget_lace or {}
            local current, focus = splitLace(m[comp.id])
            local function write(src, fit_focus, quiet)
                local cc = Store.conf()
                cc.widget_lace = type(cc.widget_lace) == "table" and cc.widget_lace or {}
                cc.widget_lace[comp.id] = { src = src, focus = fit_focus }
                require("moonbeautify.render.deco").clear()
                Store.save()
                if not quiet then repaint(desktop) end
                pcall(function() page:updateView() end)
                if parent then pcall(function() parent:updateView() end) end
            end
            return {
                {
                    title = _("顶层图"),
                    status = fileStatus(current),
                    chevron = true,
                    callback = function()
                        pickPath(desktop, current, true, function(path) write(path, focus) end)
                        return false
                    end,
                },
                {
                    title = _("取景选区"),
                    status = focusText(focus),
                    chevron = true,
                    callback = function()
                        chooseFocus(current, focus, function(v2)
                            write(current, { x = v2.x, y = v2.y, w = v2.w, h = v2.h }, true)
                        end, desktop)
                        return false
                    end,
                },
                {
                    title = _("移除顶层图"),
                    chevron = false,
                    callback = function()
                        if not current then return false end
                        local cc = Store.conf()
                        cc.widget_lace = type(cc.widget_lace) == "table" and cc.widget_lace or {}
                        cc.widget_lace[comp.id] = nil
                        if next(cc.widget_lace) == nil then cc.widget_lace = nil end
                        require("moonbeautify.render.deco").clear()
                        Store.save()
                        repaint(desktop)
                        pcall(function() page:updateView() end)
                        if parent then pcall(function() parent:updateView() end) end
                    end,
                },
            }
        end,
    }:show()
end

--- 组件花边总入口（List 自带分页）
---@param desktop table|nil
local function widgetLacePage(desktop)
    local dlg
    local function items()
        local conf = Store.conf()
        local map = type(conf.widget_lace) == "table" and conf.widget_lace or {}
        local out = {}
        for _idx, comp in ipairs(decoratableComponents()) do
            local src = splitLace(map[comp.id])
            out[#out + 1] = {
                value = comp.id,
                text = comp.label,
                mandatory = src and _("已设置") or _("未设置"),
                chevron = true,
                keep_open = true,
                callback = function()
                    laceDialog(desktop, comp, {
                        updateView = function()
                            if dlg then dlg:setItems(items()) end
                        end,
                    })
                end,
            }
        end
        return out
    end
    dlg = List:new{
        title = _("组件花边"),
        subtitle = _("和组件背景一样用取景选区（透明 PNG 可镂空，普通图片整张盖住）"),
        items = items(),
    }
    dlg:show()
end

M.bgPage = widgetBgPage
M.imeSettings = imeSettings
M.imeBgDialog = imeSettings
M.imeKeysDialog = imeSettings
M.lacePage = widgetLacePage

return M
