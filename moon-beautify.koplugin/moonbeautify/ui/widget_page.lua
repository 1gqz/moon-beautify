--[[--
首页组件自己的设置（编辑态齿轮）：吧唧与相框。
交互对齐月读「存储空间」：Overlay 叠层 + sections + Row.widget / Row.choice / toggle。
叶子动作（选图、Spin、取景）仍用现有弹窗。

@module moonbeautify.ui.widget_page
--]]

local Spin = require("ui.themes.widgets.spin")
local Row = require("ui.themes.widgets.row")
local Overlay = require("desktop.pages.setting.overlay")
local _ = require("moonbeautify.l10n")
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, focusText, pickPath, chooseFocus, refreshOverlay =
    Common.repaint, Common.focusText, Common.pickPath, Common.chooseFocus, Common.refreshOverlay

--- 记下配置、落盘、刷新叠层与首页
---@param desktop table|nil
---@param key string
---@param value any
local function put(desktop, key, value)
    Store.conf()[key] = value
    Store.save()
    refreshOverlay(desktop)
    repaint(desktop)
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

local function ringText(conf, prefix)
    local v = conf[prefix .. "ring"]
    if v == true then return _("双线") end
    if type(v) == "string" and v ~= "" then
        return require("moonbeautify.widgets.badge").RING_LABEL[v] or _("未设置")
    end
    return _("无")
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

--- 转动只有开 / 关，开就是最快（约 24 秒一圈）
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

--- 图片来源相关行（固定图 / 文件夹），主页与子页共用
---@param desktop table|nil
---@param prefix string
---@return (fun(iw: number): table)[]
local function srcRows(desktop, prefix)
    local conf = Store.conf()
    local pick = Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file")
    local rows = {
        function(iw)
            return Row.choice({
                width = iw, icon = "photo_library", title = _("图片来源"),
                items = {
                    { value = "file", text = _("固定一张图") },
                    { value = "folder", text = _("文件夹里挑一张") },
                },
                current = pick,
                on_select = function(how) put(desktop, prefix .. "pick", how) end,
            })
        end,
    }
    if pick == "folder" then
        rows[#rows + 1] = function(iw)
            return Row.widget({
                width = iw, icon = "folder", title = _("文件夹"),
                status = fileName(conf[prefix .. "dir"]), status_on = true, chevron = true,
                callback = function()
                    pickPath(desktop, conf[prefix .. "dir"], false, function(path)
                        put(desktop, prefix .. "dir", path)
                    end)
                end,
            })
        end
        rows[#rows + 1] = function(iw)
            return Row.choice({
                width = iw, icon = "shuffle", title = _("换图节奏"),
                items = {
                    { value = "daily", text = _("每天一张") },
                    { value = "shuffle", text = _("每次刷新随机") },
                },
                current = Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily"),
                on_select = function(m) put(desktop, prefix .. "mode", m) end,
            })
        end
    else
        rows[#rows + 1] = function(iw)
            return Row.widget({
                width = iw, icon = "image", title = _("图片"),
                status = fileName(conf[prefix .. "src"]), status_on = true, chevron = true,
                callback = function()
                    pickPath(desktop, conf[prefix .. "src"], true, function(path)
                        put(desktop, prefix .. "src", path)
                    end)
                end,
            })
        end
    end
    return rows
end

--- 特效子页：每个特效一行开关
---@param desktop table|nil
---@param key string
local function effectsPage(desktop, key)
    local Effects = require("moonbeautify.render.effects")
    Overlay.push(desktop, {
        title = _("特效"),
        sections = function()
            local cur = Store.conf()[key]
            if type(cur) ~= "table" then cur = {} end
            local rows = {}
            for _i, id in ipairs({ "glitter", "rain", "stars" }) do
                local on = cur[id] and true or false
                rows[#rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "toggle", icon = "auto_awesome",
                        title = Effects.LABEL[id],
                        status = on and _("开") or _("关"), status_on = on,
                        callback = function()
                            local now = Store.conf()[key]
                            if type(now) ~= "table" then now = {} end
                            now[id] = (not now[id]) and true or nil
                            put(desktop, key, now)
                        end,
                    })
                end
            end
            rows[#rows + 1] = function(iw)
                return Row.widget({
                    width = iw, kind = "action", chevron = false, icon = "block",
                    title = _("全部关掉"),
                    enabled = next(cur) ~= nil,
                    callback = function() put(desktop, key, {}) end,
                })
            end
            return { { title = _("特效"), rows = rows } }
        end,
    })
end

--- 贴图子页：8 格
---@param desktop table|nil
---@param key string
local function slotsPage(desktop, key)
    Overlay.push(desktop, {
        title = _("贴图"),
        sections = function()
            local map = Store.conf()[key]
            if type(map) ~= "table" then map = {} end
            local rows = {}
            for i = 1, 8 do
                local edge = (i == 1 or i == 4 or i == 5 or i == 8)
                local name = type(map[i]) == "string" and (map[i]:match("([^/]+)$") or map[i]) or _("空")
                rows[#rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, icon = "grid_view",
                        title = T(_("第 %1 格"), i),
                        subtitle = edge and _("仅单独一行时显示") or nil,
                        status = name, status_on = true, chevron = true,
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
                                            put(desktop, key, now)
                                        end)
                                    else
                                        local now = Store.conf()[key]
                                        if type(now) == "table" then
                                            now[i] = nil
                                            put(desktop, key, now)
                                        end
                                    end
                                end,
                            }:show()
                        end,
                    })
                end
            end
            rows[#rows + 1] = function(iw)
                return Row.note(iw, _("上 4 下 4 共 8 格，并排时只显示中间 4 格"))
            end
            return { { title = _("贴图"), rows = rows } }
        end,
    })
end

--- 叠加素材：当前状态 + 选图 / 清除
---@param desktop table|nil
---@param key string
local function overlayPage(desktop, key)
    Overlay.push(desktop, {
        title = _("叠加素材"),
        sections = function()
            local cur = Store.conf()[key]
            local name = overlayText(Store.conf(), key)
            local has = type(cur) == "string" and cur ~= ""
            return { { title = _("叠加素材"), rows = {
                function(iw)
                    return Row.widget({
                        width = iw, icon = "layers", title = _("素材图"),
                        subtitle = _("带透明通道的 PNG，压在照片上"),
                        status = name, status_on = true, chevron = true,
                        callback = function()
                            pickPath(desktop, cur, true, function(path) put(desktop, key, path) end)
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw, kind = "action", chevron = false, icon = "delete",
                        title = _("清除"), enabled = has,
                        callback = function() put(desktop, key, nil) end,
                    })
                end,
            } } }
        end,
    })
end

--- 取景：开全屏选区（会关掉叠层链，避免确定后又弹出设置页）
---@param desktop table|nil
---@param prefix string
local function openFocus(desktop, prefix)
    local conf = Store.conf()
    local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])
    chooseFocus(select(1, require("moonbeautify.widgets.view").pickSrc(conf, prefix)), focus, function(v)
        applyFocusPrefixed(Store.conf(), prefix, v)
        Store.save()
    end, desktop)
end

--- 吧唧设置叠层
---@param desktop table|nil
---@param prefix string
local function badgePage(desktop, prefix)
    return {
        title = prefixTitle(prefix),
        sections = function()
            local conf = Store.conf()
            local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])
            local shape = Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle")
            local ring = (function()
                local v = conf[prefix .. "ring"]
                if v == true or v == "beads" or v == "lace" then return "double" end
                if type(v) == "string" and v ~= "" then return v end
                return "none"
            end)()
            local spin_on = spinning(conf, prefix)

            local image_rows = srcRows(desktop, prefix)
            image_rows[#image_rows + 1] = function(iw)
                return Row.widget({
                    width = iw, icon = "crop", title = _("取景选区"),
                    status = focusText(focus), status_on = true, chevron = true,
                    callback = function() openFocus(desktop, prefix) end,
                })
            end

            return {
                { title = _("图片"), rows = image_rows },
                { title = _("外观"), rows = {
                    function(iw)
                        return Row.choice({
                            width = iw, icon = "circle", title = _("形状"),
                            items = {
                                { value = "circle", text = _("圆形") },
                                { value = "round", text = _("圆角") },
                                { value = "square", text = _("直角") },
                            },
                            current = shape,
                            on_select = function(v) put(desktop, prefix .. "shape", v) end,
                        })
                    end,
                    function(iw)
                        return Row.choice({
                            width = iw, icon = "photo_size_select_large", title = _("尺寸"),
                            items = SIZES,
                            current = Store.enum(conf, prefix .. "size", { s = true, m = true, l = true }, "m"),
                            on_select = function(v) put(desktop, prefix .. "size", v) end,
                        })
                    end,
                    function(iw)
                        return Row.choice({
                            width = iw, icon = "radio_button_unchecked",
                            title = _("光环"),
                            subtitle = _("画在吧唧本体外面的一圈"),
                            items = {
                                { value = "none", text = _("无") },
                                { value = "double", text = _("双线（两条细环）") },
                            },
                            current = ring,
                            on_select = function(v)
                                put(desktop, prefix .. "ring", v == "none" and nil or v)
                            end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, chevron = false, kind = "toggle", icon = "rotate_right",
                            title = _("转动"),
                            status = spin_on and _("开") or _("关"), status_on = spin_on,
                            callback = function()
                                put(desktop, prefix .. "spin", spin_on and 0 or SPIN_ON)
                            end,
                        })
                    end,
                } },
                { title = _("装饰"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "auto_awesome", title = _("特效"),
                            status = effectsText(conf, prefix .. "effects"), status_on = true, chevron = true,
                            callback = function() effectsPage(desktop, prefix .. "effects") end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "layers", title = _("叠加素材"),
                            status = overlayText(conf, prefix .. "overlay"), status_on = true, chevron = true,
                            callback = function() overlayPage(desktop, prefix .. "overlay") end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "grid_view", title = _("贴图"),
                            subtitle = _("上 4 下 4 共 8 格，并排时只显示中间 4 格"),
                            status = slotsText(conf, prefix .. "slots"), status_on = true, chevron = true,
                            callback = function() slotsPage(desktop, prefix .. "slots") end,
                        })
                    end,
                } },
            }
        end,
    }
end

--- 相框设置叠层
---@param desktop table|nil
---@param prefix string
local function framePage(desktop, prefix)
    return {
        title = frameTitle(prefix),
        sections = function()
            local conf = Store.conf()
            local view = Store.enum(conf, prefix .. "view", { single = true, stack = true }, "stack")
            local count = math.max(1, math.min(9, tonumber(conf[prefix .. "count"]) or 5))
            local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])

            local look_rows = {
                function(iw)
                    return Row.choice({
                        width = iw, icon = "view_agenda", title = _("呈现方式"),
                        items = {
                            { value = "single", text = _("单图铺满（一张，填满裁边）") },
                            { value = "stack", text = _("多图堆叠（方块窗，左右滑动翻页）") },
                        },
                        current = view,
                        on_select = function(v) put(desktop, prefix .. "view", v) end,
                    })
                end,
            }
            if view == "stack" then
                look_rows[#look_rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, icon = "filter_none", title = _("张数"),
                        status = tostring(count), status_on = true, chevron = true,
                        callback = function()
                            Spin:new{
                                title = _("相框张数"),
                                fields = { { value = count, min = 1, max = 9 } },
                                callback = function(v) put(desktop, prefix .. "count", math.floor(v)) end,
                            }:show()
                        end,
                    })
                end
            end

            local image_rows = srcRows(desktop, prefix)
            if view == "single" then
                image_rows[#image_rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, icon = "crop", title = _("取景选区"),
                        status = focusText(focus), status_on = true, chevron = true,
                        callback = function() openFocus(desktop, prefix) end,
                    })
                end
            else
                image_rows[#image_rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, chevron = false, icon = "crop", title = _("取景选区"),
                        subtitle = _("多图堆叠完整显示，不裁切"),
                        enabled = false,
                    })
                end
            end

            return {
                { title = _("呈现"), rows = look_rows },
                { title = _("图片"), rows = image_rows },
            }
        end,
    }
end

--- 设置入口（widget.settings(desktop, id)）
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param desktop table|nil
function M.show(prefix, desktop)
    Overlay.open(desktop, badgePage(desktop, prefix))
end

--- 相框设置入口
---@param prefix string
---@param desktop table|nil
function M.showFrame(prefix, desktop)
    Overlay.open(desktop, framePage(desktop, prefix))
end

return M
