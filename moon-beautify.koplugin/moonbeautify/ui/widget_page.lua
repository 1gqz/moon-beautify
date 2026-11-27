--[[--
首页组件自己的设置（编辑态齿轮）：吧唧与相框。

@module moonbeautify.ui.widget_page
--]]

local UIManager = require("ui/uimanager")
local Spin = require("ui.themes.widgets.spin")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Common = require("moonbeautify.ui.common")
local repaint, focusText, pickPath, choose, chooseFocus = Common.repaint, Common.focusText, Common.pickPath, Common.choose, Common.chooseFocus

--- 记下配置、落盘、重画
---@param desktop table|nil
---@param key string
---@param value any
local function put(desktop, key, value)
    Store.conf()[key] = value
    Store.save()
    repaint(desktop)
end

local M = {}

--- 把选区结果写进「前缀式」配置。
local function applyFocusPrefixed(conf, prefix, v)
    conf[prefix .. "focus"] = { x = v.x, y = v.y, w = v.w, h = v.h }
end

local SIZES = {
    { value = "s", text = _("小") },
    { value = "m", text = _("中") },
    { value = "l", text = _("大") },
}

local SIZE_TEXT = { s = _("小"), m = _("中"), l = _("大") }

---@param conf table
---@param key string
---@return string
local function sizeText(conf, key)
    return SIZE_TEXT[Store.enum(conf, key, { s = true, m = true, l = true }, "m")]
end

--- 特效：细闪 / 雨滴 / 星星（可多选，打开面板会重新弹出来，方便连点）
---@param desktop table|nil
---@param key string 配置键，如 "badge_effects"
local function effectsPage(desktop, key)
    local Effects = require("moonbeautify.render.effects")
    local cur = Store.conf()[key]
    if type(cur) ~= "table" then cur = {} end
    local items = {}
    for _i, id in ipairs({ "glitter", "rain", "stars" }) do
        items[#items + 1] = { value = id, text = (cur[id] and "✓ " or "　") .. Effects.LABEL[id] }
    end
    items[#items + 1] = { value = "none", text = _("全部关掉") }
    choose(_("特效"), items, nil, function(v)
        local now = Store.conf()[key]
        if type(now) ~= "table" then now = {} end
        if v == "none" then
            now = {}
        else
            now[v] = (not now[v]) and true or nil
        end
        put(desktop, key, now)
        UIManager:scheduleIn(0.15, function() effectsPage(desktop, key) end)
    end)
end

--- 贴图：把组件均分成 8 份（并排时 4 份），逐格配图
---@param desktop table|nil
---@param key string
---@param i number
local function slotPage(desktop, key, i)
    local map = Store.conf()[key]
    if type(map) ~= "table" then map = {} end
    choose(T(_("第 %1 格"), i), {
        { value = "pick", text = _("选一张图…") },
        { value = "clear", text = _("清空这一格") },
    }, nil, function(v)
        if v == "pick" then
            pickPath(desktop, map[i], true, function(path)
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
    end)
end

---@param desktop table|nil
---@param key string
local function slotsPage(desktop, key)
    local map = Store.conf()[key]
    if type(map) ~= "table" then map = {} end
    local items = {}
    for i = 1, 8 do
        local name = type(map[i]) == "string" and (map[i]:match("([^/]+)$") or map[i]) or _("空")
        -- 格子摆成田字：上排 1–4，下排 5–8。并排（组合）时只显示中间两列，
        -- 四角的 1、4、5、8 不显示，单独一行时才出现
        local edge = (i == 1 or i == 4 or i == 5 or i == 8)
        items[#items + 1] = {
            value = i,
            text = T(_("第 %1 格：%2"), i, name) .. (edge and _("（仅单独一行时显示）") or ""),
        }
    end
    choose(_("贴图（上 4 下 4 共 8 格，并排时只显示中间 4 格）"), items, nil, function(i)
        slotPage(desktop, key, i)
    end)
end

--- 叠加素材：一张带透明通道的 PNG，压在照片上（方形素材会被裁成圆/矩形）
---@param desktop table|nil
---@param key string
local function overlayPage(desktop, key)
    choose(_("叠加素材"), {
        { value = "pick", text = _("选一张透明 PNG…") },
        { value = "clear", text = _("清除") },
    }, nil, function(v)
        if v == "pick" then
            pickPath(desktop, Store.conf()[key], true, function(path) put(desktop, key, path) end)
        else
            put(desktop, key, nil)
        end
    end)
end

--- 图源：固定一张 / 文件夹里挑一张
---@param desktop table|nil
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param title string
local function srcPage(desktop, prefix, title)
    local conf = Store.conf()
    local pick = Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file")
    local items = {
        { value = "how", text = T(_("图片来源：%1"), pick == "folder" and _("文件夹") or _("固定一张")) },
    }
    if pick == "folder" then
        local dir = conf[prefix .. "dir"]
        items[#items + 1] = { value = "dir", text = T(_("文件夹：%1"),
            (type(dir) == "string" and dir ~= "") and (dir:match("([^/]+)$") or dir) or _("未选择")) }
        items[#items + 1] = { value = "mode", text = T(_("换图节奏：%1"),
            Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily") == "shuffle"
                and _("每次刷新随机") or _("每天一张")) }
    else
        local src = conf[prefix .. "src"]
        items[#items + 1] = { value = "file", text = T(_("图片：%1"),
            (type(src) == "string" and src ~= "") and (src:match("([^/]+)$") or src) or _("未选择")) }
    end
    choose(title, items, nil, function(v)
        if v == "how" then
            choose(_("图片来源"), {
                { value = "file", text = _("固定一张图") },
                { value = "folder", text = _("文件夹里挑一张") },
            }, pick, function(how) put(desktop, prefix .. "pick", how) end)
        elseif v == "dir" then
            pickPath(desktop, conf[prefix .. "dir"], false, function(path) put(desktop, prefix .. "dir", path) end)
        elseif v == "file" then
            pickPath(desktop, conf[prefix .. "src"], true, function(path) put(desktop, prefix .. "src", path) end)
        elseif v == "mode" then
            choose(_("换图节奏"), {
                { value = "daily", text = _("每天一张") },
                { value = "shuffle", text = _("每次刷新随机") },
            }, Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily"),
                function(m) put(desktop, prefix .. "mode", m) end)
        end
    end)
end

--- 特效文字：启用中的特效名字
---@param conf table
---@param key string
---@return string
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

--- 叠加素材文字
---@param conf table
---@param key string
---@return string
local function overlayText(conf, key)
    local p = conf[key]
    if type(p) ~= "string" or p == "" then return _("未设置") end
    return p:match("([^/]+)$") or p
end

--- 外圈文字
---@param conf table
---@param prefix string
---@return string
local function ringText(conf, prefix)
    local v = conf[prefix .. "ring"]
    if v == true then return _("双线") end
    if type(v) == "string" and v ~= "" then
        return require("moonbeautify.widgets.badge").RING_LABEL[v] or _("未设置")
    end
    return _("无")
end

--- 贴图文字
---@param conf table
---@param key string
---@return string
local function slotsText(conf, key)
    local m = conf[key]
    if type(m) ~= "table" then return _("空") end
    local n = 0
    for _k, v in pairs(m) do
        if type(v) == "string" and v ~= "" then n = n + 1 end
    end
    return n > 0 and T(_("%1 格已配图"), n) or _("空")
end

--- 转动只有开 / 关，开就是最快（约 24 秒一圈）
local SPIN_ON = 24

---@param conf table
---@param prefix string
---@return boolean
local function spinning(conf, prefix)
    return (tonumber(conf[prefix .. "spin"]) or 0) > 0
end

--- 从配置前缀还原显示名："badge_" → 吧唧1；"badge2_" → 吧唧2
---@param prefix string
---@return string
local function prefixTitle(prefix)
    local n = tonumber(prefix:match("^badge(%d*)_$") or "")
    if not n or n == 1 then return _("吧唧1") end
    return T(_("吧唧%1"), n)
end

--- 吧唧的设置。每个吧唧实例用 id 前缀区分（badge_ / badge2_ ...），互不影响。
---@param desktop table|nil
---@param prefix string
local function badgeSettings(desktop, prefix)
    local conf = Store.conf()
    local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])
    local items = {
        { value = "src", text = T(_("图片：%1（固定图 / 文件夹）"),
            Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file") == "folder"
                and _("文件夹") or _("固定一张")) },
        { value = "anchor", text = T(_("取景选区：%1"), focusText(focus)), enabled = true },
        { value = "shape", text = T(_("形状：%1"),
            ({ circle = _("圆形"), round = _("圆角"), square = _("直角") })[
                Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle")]) },
        { value = "size", text = T(_("尺寸：%1"), sizeText(conf, prefix .. "size")) },
        { value = "effects", text = T(_("特效：%1"), effectsText(conf, prefix .. "effects")) },
        { value = "overlay", text = T(_("叠加素材：%1"), overlayText(conf, prefix .. "overlay")) },
        { value = "ring", text = T(_("光环：%1"), ringText(conf, prefix)) },
        { value = "slots", text = T(_("贴图：%1"), slotsText(conf, prefix .. "slots")) },
        { value = "spin", text = T(_("转动：%1"), spinning(conf, prefix) and _("开") or _("关")) },
    }
    choose(prefixTitle(prefix), items, nil, function(value)
        if value == "src" then
            srcPage(desktop, prefix, T(_("%1图片"), prefixTitle(prefix)))
        elseif value == "anchor" then
            chooseFocus(select(1, require("moonbeautify.widgets.view").pickSrc(conf, prefix)), focus, function(v)
                applyFocusPrefixed(conf, prefix, v)
                Store.save()
                -- 不 repaint(desktop)：全屏选区关闭后再重建桌面叠层会把底下的
                -- 拓展/设置页重新画出来（表现为"确定后又弹一个页面"）。下次翻页自然刷新。
            end, desktop)
        elseif value == "shape" then
            choose(_("形状"), {
                { value = "circle", text = _("圆形") },
                { value = "round", text = _("圆角") },
                { value = "square", text = _("直角") },
            }, Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle"),
                function(v) put(desktop, prefix .. "shape", v) end)
        elseif value == "size" then
            choose(_("尺寸"), SIZES,
                Store.enum(conf, prefix .. "size", { s = true, m = true, l = true }, "m"),
                function(v) put(desktop, prefix .. "size", v) end)
        elseif value == "effects" then
            effectsPage(desktop, prefix .. "effects")
        elseif value == "overlay" then
            overlayPage(desktop, prefix .. "overlay")
        elseif value == "ring" then
            choose(_("光环（画在吧唧本体外面的一圈）"), {
                { value = "none", text = _("无") },
                { value = "double", text = _("双线（两条细环）") },
            }, (function()
                local v = conf[prefix .. "ring"]
                -- 旧配置的 true / beads / lace 统一按双线处理
                if v == true or v == "beads" or v == "lace" then return "double" end
                if type(v) == "string" and v ~= "" then return v end
                return "none"
            end)(), function(v)
                put(desktop, prefix .. "ring", v == "none" and nil or v)
            end)
        elseif value == "slots" then
            slotsPage(desktop, prefix .. "slots")
        elseif value == "spin" then
            choose(_("转动"), {
                { value = 0, text = _("关") },
                { value = SPIN_ON, text = _("开") },
            }, spinning(conf, prefix) and SPIN_ON or 0, function(v) put(desktop, prefix .. "spin", v) end)
        end
    end)
end

--- 相框的设置：呈现方式 / 图源 / 张数 / 取景选区。
---@param desktop table|nil
---@param prefix string 配置前缀，如 "frame_" / "frame2_"
local function frameSettings(desktop, prefix)
    local conf = Store.conf()
    local view = Store.enum(conf, prefix .. "view", { single = true, stack = true }, "stack")
    local count = math.max(1, math.min(9, tonumber(conf[prefix .. "count"]) or 5))
    local focus = require("moonbeautify.widgets.view").focusOf(conf[prefix .. "focus"])

    local viewText = view == "single" and _("单图铺满") or _("多图堆叠")
    local title = prefix == "frame_" and _("相框") or T(_("相框 %1"), prefix:match("^frame(%d*)_") or "2")
    local items = {
        { value = "view", text = T(_("呈现方式：%1"), viewText) },
        { value = "src", text = T(_("图片：%1（固定图 / 文件夹）"),
            Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file") == "folder"
                and _("文件夹") or _("固定一张")) },
    }
    -- 堆叠才有「张数」
    if view == "stack" then
        items[#items + 1] = { value = "count", text = T(_("张数：%1"), count) }
    end
    -- 取景选区只对单图有效；多图堆叠是整图完整显示，不裁切、不用选区。
    items[#items + 1] = view == "single"
        and { value = "anchor", text = T(_("取景选区：%1"), focusText(focus)), enabled = true }
        or  { value = "anchor", text = _("取景选区：（多图堆叠完整显示，不裁切）"), enabled = false }

    choose(title, items, nil, function(value)
        if value == "view" then
            choose(_("呈现方式"), {
                { value = "single", text = _("单图铺满（一张，填满裁边）") },
                { value = "stack", text = _("多图堆叠（方块窗，左右滑动翻页）") },
            }, view, function(v)
                put(desktop, prefix .. "view", v)
            end)
        elseif value == "src" then
            srcPage(desktop, prefix, T(_("%1图片"), title))
        elseif value == "count" then
            Spin:new{
                title = _("相框张数"),
                fields = { { value = count, min = 1, max = 9 } },
                callback = function(v) put(desktop, prefix .. "count", math.floor(v)) end,
            }:show()
        elseif value == "anchor" then
            chooseFocus(select(1, require("moonbeautify.widgets.view").pickSrc(conf, prefix)), focus, function(v)
                applyFocusPrefixed(conf, prefix, v)
                Store.save()
                -- 不 repaint(desktop)：避免全屏选区关闭后重建叠层导致拓展/设置页重现
            end, desktop)
        end
    end)
end

--- 设置入口（widget.settings(desktop, id)）
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param desktop table|nil
function M.show(prefix, desktop)
    return badgeSettings(desktop, prefix)
end

--- 相框设置入口
---@param prefix string
---@param desktop table|nil
function M.showFrame(prefix, desktop)
    return frameSettings(desktop, prefix)
end

-- 月读设置页入口 ------------------------------------------------------------

return M
