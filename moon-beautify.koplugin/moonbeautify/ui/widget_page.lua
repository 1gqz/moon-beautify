--[[--
首页组件自己的设置（编辑态齿轮）：吧唧与相框。
用月读 `ui.themes.widgets.settings` 表格弹窗（与缓存章节、最近阅读等同款），
改完就地刷新；选图 / Spin / 取景仍开叶子弹窗。

@module moonbeautify.ui.widget_page
--]]

local Spin = require("ui.themes.widgets.spin")
local Settings = require("ui.themes.widgets.settings")
local _ = require("moonbeautify.l10n")
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, focusText, pickPath, chooseFocus =
    Common.repaint, Common.focusText, Common.pickPath, Common.chooseFocus

--- 记下配置、落盘、重画；有 page 时刷新表格弹窗
---@param desktop table|nil
---@param key string
---@param value any
---@param page table|nil
local function put(desktop, key, value, page)
    Store.conf()[key] = value
    Store.save()
    repaint(desktop)
    if page then pcall(function() page:updateView() end) end
end

local M = {}

local function applyFocusPrefixed(conf, prefix, v)
    conf[prefix .. "focus"] = { x = v.x, y = v.y, w = v.w, h = v.h }
end

local SIZES = {
    { value = "s", text = _("小") },
    { value = "m", text = _("中") },
    { value = "l", text = _("大") },
}

local function effectsText(conf, key)
    local Effects = require("moonbeautify.render.effects")
    local t = conf[key]
    if type(t) ~= "table" then return _("无") end
    local out = {}
    for _i, id in ipairs({ "glitter", "rain", "stars" }) do
        if t[id] then out[#out + 1] = Effects.LABEL[id] end
    end
    return #out > 0 and table.concat(out, "·") or _("无")
end

local function overlayText(conf, key)
    local p = conf[key]
    if type(p) ~= "string" or p == "" then return _("未设置") end
    return p:match("([^/]+)$") or p
end

local function ringCurrent(conf, prefix)
    local v = conf[prefix .. "ring"]
    if v == true or v == "beads" or v == "lace" then return "double" end
    if type(v) == "string" and v ~= "" then return v end
    return "none"
end

local function slotsText(conf, key)
    local m = conf[key]
    if type(m) ~= "table" then return _("空") end
    local n = 0
    for _k, v in pairs(m) do
        if type(v) == "string" and v ~= "" then n = n + 1 end
    end
    return n > 0 and T(_("%1 格已配图"), n) or _("空")
end

local function fileName(path)
    if type(path) ~= "string" or path == "" then return _("未选择") end
    return path:match("([^/]+)$") or path
end

local SPIN_ON = 24

local function spinning(conf, prefix)
    return (tonumber(conf[prefix .. "spin"]) or 0) > 0
end

local function prefixTitle(prefix)
    local n = tonumber(prefix:match("^badge(%d*)_$") or "")
    if not n or n == 1 then return _("吧唧1") end
    return T(_("吧唧%1"), n)
end

local function frameTitle(prefix)
    if prefix == "frame_" then return _("相框1") end
    local n = prefix:match("^frame(%d*)_") or "2"
    return T(_("相框 %1"), n)
end

--- 取景；返回 false 让表格弹窗先别刷新
---@param desktop table|nil
---@param prefix string
---@param page table|nil
local function openFocus(desktop, prefix, page)
    local conf = Store.conf()
    local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])
    chooseFocus(select(1, require("moonbeautify.widgets.view").pickSrc(conf, prefix)), focus, function(v)
        applyFocusPrefixed(Store.conf(), prefix, v)
        Store.save()
        -- Overlay 已在 chooseFocus 里关掉；Settings 弹窗还在，只刷新它。
        -- 不调 repaint：全屏选区关后重画桌面会把底下叠层又捞上来。
        if page then pcall(function() page:updateView() end) end
    end, desktop)
end

--- 特效子表
---@param desktop table|nil
---@param key string
---@param parent table|nil
local function effectsSettings(desktop, key, parent)
    local Effects = require("moonbeautify.render.effects")
    Settings:new{
        title = _("特效"),
        items = function()
            local cur = Store.conf()[key]
            if type(cur) ~= "table" then cur = {} end
            local items = {}
            for _i, id in ipairs({ "glitter", "rain", "stars" }) do
                items[#items + 1] = {
                    title = Effects.LABEL[id],
                    toggle = true,
                    checked = cur[id] and true or false,
                    callback = function()
                        local now = Store.conf()[key]
                        if type(now) ~= "table" then now = {} end
                        now[id] = (not now[id]) and true or nil
                        put(desktop, key, now, parent)
                    end,
                }
            end
            items[#items + 1] = {
                title = _("全部关掉"),
                chevron = false,
                callback = function()
                    put(desktop, key, {}, parent)
                end,
            }
            return items
        end,
    }:show()
end

--- 贴图子表
---@param desktop table|nil
---@param key string
---@param parent table|nil
local function slotsSettings(desktop, key, parent)
    Settings:new{
        title = _("贴图"),
        items = function(page)
            local map = Store.conf()[key]
            if type(map) ~= "table" then map = {} end
            local items = {}
            for i = 1, 8 do
                local edge = (i == 1 or i == 4 or i == 5 or i == 8)
                local name = type(map[i]) == "string" and (map[i]:match("([^/]+)$") or map[i]) or _("空")
                items[#items + 1] = {
                    title = T(_("第 %1 格"), i) .. (edge and _("（仅单独一行时显示）") or ""),
                    status = name,
                    chevron = true,
                    callback = function()
                        local List = require("ui.themes.widgets.list")
                        List:new{
                            title = T(_("第 %1 格"), i),
                            items = {
                                { value = "pick", text = _("选一张图…") },
                                { value = "clear", text = _("清空这一格") },
                            },
                            centered = true,
                            on_select = function(v)
                                if v == nil then return end
                                if v == "pick" then
                                    local cur = Store.conf()[key]
                                    pickPath(desktop, type(cur) == "table" and cur[i] or nil, true, function(path)
                                        local now = Store.conf()[key]
                                        if type(now) ~= "table" then now = {} end
                                        now[i] = path
                                        put(desktop, key, now, page)
                                        if parent then pcall(function() parent:updateView() end) end
                                    end)
                                else
                                    local now = Store.conf()[key]
                                    if type(now) == "table" then
                                        now[i] = nil
                                        put(desktop, key, now, page)
                                        if parent then pcall(function() parent:updateView() end) end
                                    end
                                end
                            end,
                        }:show()
                        return false
                    end,
                }
            end
            items[#items + 1] = {
                note = _("贴图（上 4 下 4 共 8 格，并排时只显示中间 4 格）"),
            }
            return items
        end,
    }:show()
end

--- 叠加素材子表
---@param desktop table|nil
---@param key string
---@param parent table|nil
local function overlaySettings(desktop, key, parent)
    Settings:new{
        title = _("叠加素材"),
        items = function(page)
            local cur = Store.conf()[key]
            local has = type(cur) == "string" and cur ~= ""
            return {
                {
                    title = _("选一张透明 PNG…"),
                    status = overlayText(Store.conf(), key),
                    chevron = true,
                    callback = function()
                        pickPath(desktop, cur, true, function(path)
                            put(desktop, key, path, page)
                            if parent then pcall(function() parent:updateView() end) end
                        end)
                        return false
                    end,
                },
                {
                    title = _("清除"),
                    chevron = false,
                    callback = function()
                        if not has then return false end
                        put(desktop, key, nil, page)
                        if parent then pcall(function() parent:updateView() end) end
                    end,
                },
            }
        end,
    }:show()
end

--- 图片来源相关行
---@param desktop table|nil
---@param prefix string
---@param page table
---@return table[]
local function srcItems(desktop, prefix, page)
    local conf = Store.conf()
    local pick = Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file")
    local items = {
        {
            title = _("图片来源"),
            items = {
                { value = "file", text = _("固定一张图") },
                { value = "folder", text = _("文件夹里挑一张") },
            },
            current = pick,
            on_select = function(how) put(desktop, prefix .. "pick", how, page) end,
        },
    }
    if pick == "folder" then
        items[#items + 1] = {
            title = _("文件夹"),
            status = fileName(conf[prefix .. "dir"]),
            chevron = true,
            callback = function()
                pickPath(desktop, conf[prefix .. "dir"], false, function(path)
                    put(desktop, prefix .. "dir", path, page)
                end)
                return false
            end,
        }
        items[#items + 1] = {
            title = _("换图节奏"),
            items = {
                { value = "daily", text = _("每天一张") },
                { value = "shuffle", text = _("每次刷新随机") },
            },
            current = Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily"),
            on_select = function(m) put(desktop, prefix .. "mode", m, page) end,
        }
    else
        items[#items + 1] = {
            title = _("图片"),
            status = fileName(conf[prefix .. "src"]),
            chevron = true,
            callback = function()
                pickPath(desktop, conf[prefix .. "src"], true, function(path)
                    put(desktop, prefix .. "src", path, page)
                end)
                return false
            end,
        }
    end
    return items
end

--- 吧唧设置
---@param desktop table|nil
---@param prefix string
local function badgeSettings(desktop, prefix)
    Settings:new{
        title = prefixTitle(prefix),
        items = function(page)
            local conf = Store.conf()
            local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])
            local shape = Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle")
            local spin_on = spinning(conf, prefix)
            local items = srcItems(desktop, prefix, page)
            items[#items + 1] = {
                title = _("取景选区"),
                status = focusText(focus),
                chevron = true,
                callback = function()
                    openFocus(desktop, prefix, page)
                    return false
                end,
            }
            items[#items + 1] = {
                title = _("形状"),
                items = {
                    { value = "circle", text = _("圆形") },
                    { value = "round", text = _("圆角") },
                    { value = "square", text = _("直角") },
                },
                current = shape,
                on_select = function(v) put(desktop, prefix .. "shape", v, page) end,
            }
            items[#items + 1] = {
                title = _("尺寸"),
                items = SIZES,
                current = Store.enum(conf, prefix .. "size", { s = true, m = true, l = true }, "m"),
                on_select = function(v) put(desktop, prefix .. "size", v, page) end,
            }
            items[#items + 1] = {
                title = _("光环"),
                items = {
                    { value = "none", text = _("无") },
                    { value = "double", text = _("双线（两条细环）") },
                },
                current = ringCurrent(conf, prefix),
                on_select = function(v)
                    put(desktop, prefix .. "ring", v == "none" and nil or v, page)
                end,
            }
            items[#items + 1] = {
                title = _("转动"),
                toggle = true,
                checked = spin_on,
                callback = function()
                    put(desktop, prefix .. "spin", spin_on and 0 or SPIN_ON, page)
                end,
            }
            items[#items + 1] = {
                title = _("特效"),
                status = effectsText(conf, prefix .. "effects"),
                chevron = true,
                callback = function()
                    effectsSettings(desktop, prefix .. "effects", page)
                    return false
                end,
            }
            items[#items + 1] = {
                title = _("叠加素材"),
                status = overlayText(conf, prefix .. "overlay"),
                chevron = true,
                callback = function()
                    overlaySettings(desktop, prefix .. "overlay", page)
                    return false
                end,
            }
            items[#items + 1] = {
                title = _("贴图"),
                status = slotsText(conf, prefix .. "slots"),
                chevron = true,
                callback = function()
                    slotsSettings(desktop, prefix .. "slots", page)
                    return false
                end,
            }
            return items
        end,
    }:show()
end

--- 相框设置
---@param desktop table|nil
---@param prefix string
local function frameSettings(desktop, prefix)
    Settings:new{
        title = frameTitle(prefix),
        items = function(page)
            local conf = Store.conf()
            local view = Store.enum(conf, prefix .. "view", { single = true, stack = true }, "stack")
            local count = math.max(1, math.min(9, tonumber(conf[prefix .. "count"]) or 5))
            local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])
            local items = {
                {
                    title = _("呈现方式"),
                    items = {
                        { value = "single", text = _("单图铺满（一张，填满裁边）") },
                        { value = "stack", text = _("多图堆叠（方块窗，左右滑动翻页）") },
                    },
                    current = view,
                    on_select = function(v) put(desktop, prefix .. "view", v, page) end,
                },
            }
            if view == "stack" then
                items[#items + 1] = {
                    title = _("张数"),
                    status = tostring(count),
                    chevron = true,
                    callback = function()
                        Spin:new{
                            title = _("相框张数"),
                            fields = { { value = count, min = 1, max = 9 } },
                            callback = function(v)
                                put(desktop, prefix .. "count", math.floor(v), page)
                            end,
                        }:show()
                        return false
                    end,
                }
            end
            for _i, row in ipairs(srcItems(desktop, prefix, page)) do
                items[#items + 1] = row
            end
            if view == "single" then
                items[#items + 1] = {
                    title = _("取景选区"),
                    status = focusText(focus),
                    chevron = true,
                    callback = function()
                        openFocus(desktop, prefix, page)
                        return false
                    end,
                }
            else
                items[#items + 1] = {
                    note = _("取景选区：（多图堆叠完整显示，不裁切）"),
                }
            end
            return items
        end,
    }:show()
end

--- 设置入口（widget.settings(desktop, id)）
---@param prefix string
---@param desktop table|nil
function M.show(prefix, desktop)
    badgeSettings(desktop, prefix)
end

--- 相框设置入口
---@param prefix string
---@param desktop table|nil
function M.showFrame(prefix, desktop)
    frameSettings(desktop, prefix)
end

return M
