--[[--
设置界面：组件自己的设置（首页编辑态的齿轮）+ 月读设置页里的外观与主题入口（底栏图标、组件背景/顶层图、并排组合、主题管理）。

都是月读自己的控件（List、PathPicker、Spin、Row），选完写扩展配置、落盘、重画。

@module moonbeautify.settings
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local Spin = require("ui.themes.widgets.spin")
local Input = require("ui.themes.widgets.input")
local Overlay = require("desktop.pages.setting.overlay")
local Image = require("utils.image")
local _ = require("gettext")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template

local Store = require("moonbeautify.store")

local Settings = {}

--- 选完设置重画首页（桌面还在就整屏刷一次）
---@param desktop table|nil
local function repaint(desktop)
    if not desktop then return end
    pcall(function() desktop:updateView() end)
    -- desktop:updateView 里已顺带重刷设置页；这里标全屏让整条 window stack 一起重画
    pcall(function() UIManager:setDirty("all", "ui") end)
end

--- 记下配置、落盘、重画
---@param desktop table|nil
---@param key string
---@param value any
local function put(desktop, key, value)
    Store.conf()[key] = value
    Store.save()
    repaint(desktop)
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

--- 弹路径选择器。
---@param desktop table|nil
---@param current string|nil 当前路径（文件或目录）
---@param is_file boolean 选文件 or 选目录
---@param apply fun(path: string)
local function pickPath(desktop, current, is_file, apply)
    local start
    if type(current) == "string" and current ~= "" then
        local dir = is_file and current:match("^(.*)/") or current
        if dir and lfs.attributes(dir, "mode") == "directory" then start = dir end
    end
    -- 自己没配过 → 用上次任意选图器用过的目录（和界面壁纸共用同一份记忆）
    local last = Store.conf().last_dir
    if not start and type(last) == "string" and last ~= "" and lfs.attributes(last, "mode") == "directory" then
        start = last
    end
    start = start or require("apps/filemanager/filemanagerutil").getHomeFolder()
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = is_file,
        filter = is_file and function(name) return Image.suffix(name) ~= nil end or nil,
        on_select = function(path)
            local dir = is_file and path:match("^(.*)/") or path
            if type(dir) == "string" and dir ~= "" and lfs.attributes(dir, "mode") == "directory" then
                Store.conf().last_dir = dir
            end
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
    local dlg = List:new{
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
    if desktop then
        local okov, Overlay = pcall(require, "desktop.pages.setting.overlay")
        if okov and Overlay and Overlay.closeAll then
            pcall(Overlay.closeAll, desktop)
        end
    end
    require("moonbeautify.focus_picker"):new{
        path = type(path) == "string" and path ~= "" and path or nil,
        current = focus,
        on_select = function(x, y, w, h) apply({ x = x, y = y, w = w, h = h }) end,
    }:show()
end

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
    local Effects = require("moonbeautify.effects")
    local cur = Store.conf()[key]
    if type(cur) ~= "table" then cur = {} end
    local items = {}
    for _i, id in ipairs({ "glitter", "rain", "stars" }) do
        items[#items + 1] = { value = id, text = (cur[id] and "✓ " or "　") .. _(Effects.LABEL[id]) }
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
    choose(_(title), items, nil, function(v)
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
    local Effects = require("moonbeautify.effects")
    local t = conf[key]
    if type(t) ~= "table" then return _("无") end
    local out = {}
    for _i, id in ipairs({ "glitter", "rain", "stars" }) do
        if t[id] then out[#out + 1] = _(Effects.LABEL[id]) end
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
    if v == true then return _("珠链") end
    if type(v) == "string" and v ~= "" then
        return _(require("moonbeautify.badge").RING_LABEL[v] or _("未设置"))
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
    local focus = require("moonbeautify.view").focusOf(conf[prefix .. "focus"])
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
            srcPage(desktop, prefix, prefixTitle(prefix) .. _("图片"))
        elseif value == "anchor" then
            chooseFocus(select(1, require("moonbeautify.view").pickSrc(conf, prefix)), focus, function(v)
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
    local focus = require("moonbeautify.view").focusOf(conf[prefix .. "focus"])

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
                require("moonbeautify.frame").reset(prefix)
            end)
        elseif value == "src" then
            srcPage(desktop, prefix, title .. _("图片"))
        elseif value == "count" then
            Spin:new{
                title = _("相框张数"),
                fields = { { value = count, min = 1, max = 9 } },
                callback = function(v) put(desktop, prefix .. "count", math.floor(v)) end,
            }:show()
        elseif value == "anchor" then
            chooseFocus(select(1, require("moonbeautify.view").pickSrc(conf, prefix)), focus, function(v)
                applyFocusPrefixed(conf, prefix, v)
                Store.save()
                -- 不 repaint(desktop)：避免全屏选区关闭后重建叠层导致拓展/设置页重现
                require("moonbeautify.frame").reset(prefix)
            end, desktop)
        end
    end)
end

--- 设置入口（widget.settings(desktop, id)）
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param desktop table|nil
function Settings.show(prefix, desktop)
    return badgeSettings(desktop, prefix)
end

--- 相框设置入口
---@param prefix string
---@param desktop table|nil
function Settings.showFrame(prefix, desktop)
    return frameSettings(desktop, prefix)
end

-- 月读设置页入口 ------------------------------------------------------------

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
        local focus = type(item) == "table" and require("moonbeautify.view").focusOf(item.focus) or nil
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
            local focus = type(item) == "table" and require("moonbeautify.view").focusOf(item.focus) or nil
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
        local focus = type(item.focus) == "table" and require("moonbeautify.view").focusOf(item.focus) or nil
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
            local focus = type(item.focus) == "table" and require("moonbeautify.view").focusOf(item.focus) or nil
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

local refreshThemePage -- 前置声明，定义在 themePageTable 之后
local themeTypePartsPage -- 二级页面前置声明

--- 轻提示（KOReader 原生 InfoMessage：左侧信息图标，点一下即关，默认 2 秒自动消失）
---@param text string
---@param seconds number|nil
local function themeToast(text, seconds)
    if not text or text == "" then return end
    pcall(function()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = seconds or 2,
        })
    end)
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
        themeToast(delta < 0 and _("已经在最前面了") or _("已经在最后面了"))
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
        themeToast(_("回到桌面后再设置"))
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
                themeToast(_("已恢复默认顺序"))
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

--- 保存当前配置为主题
---@param desktop table|nil
local function themeSave(desktop)
    local dialog = Input:new{
        title = _("主题名字"),
        fields = { { text = "", hint = _("例如 主题1") } },
        ok_text = _("保存"),
        callback = function(value)
            local Theme = require("moonbeautify.theme")
            local safe = Theme.sanitize(value)
            if not safe then
                themeToast(_("名字不能为空"))
                return
            end
            if lfs.attributes(Theme.root() .. "/" .. safe, "mode") == "directory" then
                themeToast(_("该名称已被占用"))
                return
            end
            local ok, dir_or_err = Theme.save(safe)
            if ok then
                -- 保存当前配置只是做一份快照，不等于应用它。
                -- 当前配置仍指向本地图片/原主题，所以 active_theme 不能改，
                -- 否则新主题会显示“应用中”，但部件改动影响不到当前配置。
                refreshThemePage(desktop)
                themeToast(T(_("已保存为主题：%1（未应用）"), safe))
            else
                themeToast(T(_("保存失败：%1"), dir_or_err or ""))
            end
        end,
    }
    -- 选择器关闭动画期间直接开输入框会被顶掉，等下一帧再弹
    local deferred = false
    if UIManager.nextTick then
        deferred = pcall(function()
            UIManager:nextTick(function() dialog:show() end)
        end)
    end
    if not deferred then dialog:show() end
end

--- 从 zip 导入主题
---@param desktop table|nil
local function themeImport(desktop)
    local start = Store.conf().last_dir
    if not (type(start) == "string" and start ~= ""
        and lfs.attributes(start, "mode") == "directory") then
        start = require("apps/filemanager/filemanagerutil").getHomeFolder()
    end
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = true,
        filter = function(name) return name:lower():match("%.zip$") ~= nil end,
        on_select = function(path)
            local Theme = require("moonbeautify.theme")
            local ok, name_or_err = Theme.importZip(path)
            if ok then
                refreshThemePage(desktop)
                themeToast(T(_("已导入主题：%1"), name_or_err))
            else
                themeToast(T(_("导入失败：%1"), name_or_err or ""))
            end
        end,
    }:show()
end

--- 部件：启用/停用、查看信息
---@param desktop table|nil
---@param part table Theme.parts() 返回的部件
local function themePartItem(desktop, part)
    local Theme = require("moonbeautify.theme")
    local conf = Store.conf()
    local active = conf.theme_parts and conf.theme_parts[part.slot] == part.id

    local PartCopy = require("moonbeautify.part_copy")
    local imageCount = #PartCopy.images(part.conf)
    local items = {
        { value = "toggle", text = active and _("停用这个部件") or _("启用这个部件"),
          mandatory = active and _("当前已启用") or _("只替换它负责的设置") },
    }
    if imageCount > 0 then
        items[#items + 1] = { value = "copy", text = _("复制到其他文件夹"),
            mandatory = T(_("%1 项图片/文件夹改用新路径，可脱离主题包"), tostring(imageCount)) }
    end
    items[#items + 1] = { value = "delete", text = _("删除这个部件"), mandatory = _("从主题包移除并清理图片") }
    choose(part.name or part.id, items, nil, function(v)
        if v == "toggle" then
            local ok, err = Theme.applyPart(part.theme, part.slot, not active)
            if ok then
                refreshThemePage(desktop)
                repaint(desktop)
                themeToast(active and _("已停用部件") or _("已启用部件"))
            else
                themeToast(T(_("操作失败：%1"), err or ""))
            end
        elseif v == "copy" then
            pickPath(desktop, nil, false, function(dir)
                local newConf, files = PartCopy.copyTo(part.conf, dir)
                if #files == 0 then
                    themeToast(_("没有可复制的图片"))
                    return
                end
                PartCopy.apply(part, newConf)
                Theme.updatePartConf(part.theme, part.slot, newConf)
                repaint(desktop)
                refreshThemePage(desktop)
                themeToast(T(_("已复制 %1 项图片到 %2，之后可以删除原主题包"),
                    tostring(#files), dir), 5)
            end)
        elseif v == "delete" then
            choose(_("确认删除部件"), {
                { value = "yes", text = _("删除"), mandatory = part.name or part.slot },
                { value = "no", text = _("取消") },
            }, nil, function(confirm)
                if confirm ~= "yes" then return end
                local ok, err = Theme.deletePart(part.theme, part.slot)
                if ok then
                    refreshThemePage(desktop)
                    repaint(desktop)
                    themeToast(_("已删除部件"))
                else
                    themeToast(T(_("删除失败：%1"), err or ""))
                end
            end)
        end
    end)
end

--- 部件卡片：预览图 + 标题 + 来源，两列网格里的一格
local Theme = require("moonbeautify.theme")
local CARD_IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true }

local function resolveCardAsset(raw, theme)
    if type(raw) ~= "string" or raw == "" then return nil end
    if raw:sub(1, 8) == "@assets/" then
        local dir = Theme.dir(theme)
        if not dir then return nil end
        return dir .. "/assets/" .. raw:sub(9)
    end
    return raw
end

--- 收集一个部件里的全部图片：单图直接列，文件夹展开成多张
local function collectPartImages(part)
    local out, seen = {}, {}
    local function add(path)
        if not path or seen[path] then return end
        local mode = lfs.attributes(path, "mode")
        if mode == "file" then
            local ext = path:lower():match("%.(%w+)$")
            if ext and CARD_IMAGE_EXT[ext] then
                seen[path] = true
                out[#out + 1] = path
            end
        elseif mode == "directory" then
            seen[path] = true
            local names = {}
            for n in lfs.dir(path) do
                if n ~= "." and n ~= ".." then
                    local p = path .. "/" .. n
                    if lfs.attributes(p, "mode") == "file" then
                        local e = n:lower():match("%.(%w+)$")
                        if e and CARD_IMAGE_EXT[e] then names[#names + 1] = p end
                    end
                end
            end
            table.sort(names)
            for _, p in ipairs(names) do
                if not seen[p] then seen[p] = true; out[#out + 1] = p end
            end
        end
    end
    local function walk(v)
        if type(v) == "string" then
            add(resolveCardAsset(v, part.theme))
        elseif type(v) == "table" then
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do walk(v[k]) end
        end
    end
    walk(part.conf)
    return out
end

--- 图片缩略图网格：按可用宽度均分列宽，居中对齐，行距收紧
---@return table widget, integer 实际行数
local function imageGrid(paths, width, thumb, max_rows)
    local UITheme = require("ui.themes")
    local ImageWidget = require("ui.themes.widgets.image")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local t = UITheme.current()
    local gap = UITheme.px(t.space.xs)
    thumb = thumb or UITheme.px(48)
    local per_row = math.max(1, math.floor((width + gap) / (thumb + gap)))
    local rows, row, n = {}, HorizontalGroup:new{}, 0
    for _, path in ipairs(paths) do
        if max_rows and #rows >= max_rows then break end
        if n > 0 and n % per_row == 0 then
            rows[#rows + 1] = row
            row = HorizontalGroup:new{}
        end
        if n % per_row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = ImageWidget.widget{
            src = path, width = thumb, height = thumb,
            style = { border = 0, shadow = 0 }, alpha = true, stretch = true,
        }
        n = n + 1
    end
    if #row > 0 then rows[#rows + 1] = row end  -- 正好铺满一行时也要收进去

    local out = VerticalGroup:new{ align = "center" }
    for i, r in ipairs(rows) do
        if i > 1 then out[#out + 1] = VerticalSpan:new{ width = gap } end
        local used = 0
        for _, widget in ipairs(r) do used = used + widget:getSize().w end
        local rest = math.max(0, width - used)
        out[#out + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = math.floor(rest / 2) },
            r,
            HorizontalSpan:new{ width = rest - math.floor(rest / 2) },
        }
    end
    return out, #rows
end

local function typeGridRow(desktop, width, rowTypes)
    local UITheme = require("ui.themes")
    local Parts = require("moonbeautify.parts")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local gap = UITheme.px(UITheme.current().space.sm)
    local cell_w = math.floor((width - gap) / 2)
    local row = HorizontalGroup:new{}
    local function addCell(item, index)
        if not item then return end
        if index > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Row.widget({
            width = cell_w,
            icon = Parts.TYPE_ICON[item.key] or "palette",
            title = item.label or item.key,
            subtitle = T(_("%1 个已导入部件"), tostring(item.count)),
            chevron = true,
            callback = function()
                Overlay.push(desktop, themeTypePartsPage(desktop, item.key, item.label))
            end,
        })
    end
    addCell(rowTypes[1], 1)
    addCell(rowTypes[2], 2)
    return row
end

--- 一个主题里只有一份的类型：页面/分组标题已经说明是什么，行内不再重复写部件名
local SINGLETON_PART_TYPES = {
    icons = true, wallpaper = true, lockscreen = true, ime = true,
}

local function partNeedsLabel(typeKey)
    return not SINGLETON_PART_TYPES[typeKey]
end

--- 缩略图尺寸：壁纸、锁屏壁纸、键盘背景显著放大，其它部件保持图标大小
local function thumbForType(typeKey)
    local UITheme = require("ui.themes")
    if typeKey == "wallpaper" or typeKey == "lockscreen" or typeKey == "ime" then
        return UITheme.px(112)
    end
    return UITheme.px(44)
end

--- 虚线分隔：短横 + 空隙交替
local function dashedLine(width, color, h)
    local UITheme = require("ui.themes")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LineWidget = require("ui/widget/linewidget")
    local Blitbuffer = require("ffi/blitbuffer")
    local g = HorizontalGroup:new{}
    local dash, space, x = UITheme.px(8), UITheme.px(5), 0
    while x < width do
        local w = math.min(dash, width - x)
        g[#g + 1] = LineWidget:new{
            background = Blitbuffer.Color8(color), dimen = Geom:new{ w = w, h = h },
        }
        x = x + w
        if x < width then
            local s = math.min(space, width - x)
            g[#g + 1] = HorizontalSpan:new{ width = s }
            x = x + s
        end
    end
    return g
end

--- 单个部件的一行：多实例类型显示部件名，单例类型只显示图片
---@param is_last boolean 是否为该主题最后一行（最后一行实线，其余虚线）
local function partImagesRow(desktop, part, width, typeKey, is_last)
    local UITheme = require("ui.themes")
    local Geom = require("ui/geometry")
    local Text = require("ui.themes.widgets.text")
    local Tap = require("ui.themes.widgets.tap")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local t = UITheme.current()
    local show_label = partNeedsLabel(typeKey)
    local label = show_label and (part.name or part.label or part.slot or part.type) or nil
    local imgs = collectPartImages(part)
    local thumb = thumbForType(typeKey)
    local gap = show_label and UITheme.px(t.space.md) or 0
    local label_w = 0
    if show_label then
        label_w = math.min(UITheme.px(120), math.max(UITheme.px(72), math.floor(width * 0.24)))
    end

    local grid = imageGrid(imgs, width - label_w - gap, thumb)
    local row_h = math.max(grid:getSize().h, thumb + UITheme.px(t.space.sm) * 2)
    local content
    if show_label then
        local label_wd = CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = row_h },
            Text.line("caption", label, { width = label_w - UITheme.px(t.space.xs) * 2,
                color = UITheme.color(t.color.chrome) }),
        }
        content = CenterContainer:new{
            dimen = Geom:new{ w = width, h = row_h },
            HorizontalGroup:new{ align = "center", label_wd, HorizontalSpan:new{ width = gap }, grid },
        }
    else
        content = CenterContainer:new{ dimen = Geom:new{ w = width, h = row_h }, grid }
    end
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local divider = math.max(1, UITheme.px(t.row.divider))
    local line = is_last
        and LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = width, h = divider },
        }
        or dashedLine(width, t.color.rule, divider)
    local wrapped = VerticalGroup:new{ align = "left", content, line }
    if desktop then
        return Tap.wrap(wrapped, function() themePartItem(desktop, part) end)
    end
    return wrapped
end

--- 主题预览页：按部件类型分组，把该主题下的图片全列出来
local function themePreviewPage(desktop, name)
    return {
        title = name,
        sections = function()
            local Theme = require("moonbeautify.theme")
            local Parts = require("moonbeautify.parts")
            local buckets = {}
            for _, part in ipairs(Theme.parts(name)) do
                if #collectPartImages(part) > 0 then
                    local key = part.group or Parts.groupOfType(part.type)
                    if not buckets[key] then
                        buckets[key] = { label = Parts.TYPE_LABEL[key] or key, parts = {} }
                    end
                    buckets[key].parts[#buckets[key].parts + 1] = part
                end
            end
            local keys = {}
            for k in pairs(buckets) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local sections = {}
            for _, k in ipairs(keys) do
                local group = buckets[k]
                local rows = {}
                for _i, part in ipairs(group.parts) do
                    rows[#rows + 1] = function(iw)
                        return partImagesRow(desktop, part, iw, k, _i == #group.parts)
                    end
                end
                sections[#sections + 1] = {
                    title = group.label, rows = rows, title_style = "body", title_bold = true,
                }
            end
            if #sections == 0 then
                sections[1] = { title = _("预览"), rows = { function(iw)
                    return Row.widget({ width = iw, icon = "palette", chevron = false,
                        title = _("这个主题没有图片"), subtitle = _("只有设置项") })
                end } }
            end
            return sections
        end,
    }
end

--- 单个主题：预览 / 应用 / 导出 / 删除
---@param desktop table|nil
---@param name string
---@param active string|nil 当前应用中的主题名
local function themeItem(desktop, name, active)
    local applied = name == active
    choose(name, {
        { value = "preview", text = _("预览"),
          mandatory = _("查看该主题的所有图片") },
        { value = "apply", text = _("应用"),
          mandatory = applied and _("当前正在使用中") or _("点击应用") },
        { value = "export", text = _("导出主题 zip"),
          mandatory = _("导到指定文件夹") },
        { value = "delete", text = _("删除"),
          mandatory = applied and _("使用中的主题无法删除") or _("删掉存档和图片") },
    }, nil, function(v)
        local Theme = require("moonbeautify.theme")
        if v == "preview" then
            Overlay.push(desktop, themePreviewPage(desktop, name))
        elseif v == "apply" then
            local ok, err = Theme.apply(name)
            if ok then
                refreshThemePage(desktop)
                repaint(desktop)
                themeToast(_("已使用该主题"))
            else
                themeToast(T(_("应用失败：%1"), err or ""))
            end
        elseif v == "export" then
            pickPath(desktop, nil, false, function(dir)
                local ok, path_or_err = Theme.export(name, dir)
                if ok then
                    themeToast(T(_("已导出：%1"), path_or_err), 5)
                else
                    themeToast(T(_("导出失败：%1"), path_or_err or ""))
                end
            end)
        elseif v == "delete" then
            local ok, err = Theme.delete(name)
            if ok then
                refreshThemePage(desktop)
                themeToast(_("已删除主题"))
            elseif err == "beautify_in_use" then
                themeToast(_("应用中删除失败，请先应用其他主题"))
            else
                themeToast(T(_("应用中删除失败，%1"), err or _("主题目录删不掉")))
            end
        end
    end)
end

--- 并排关系去重用的稳定键
local function relationKey(row)
    local ids = {}
    for _, id in ipairs(type(row) == "table" and row or {}) do
        if id ~= nil and id ~= "" then ids[#ids + 1] = tostring(id) end
    end
    table.sort(ids)
    return table.concat(ids, "|")
end

--- 从部件槽位还原组件 id（comp_clock → clock）
local function partCompId(part)
    return type(part.slot) == "string" and part.slot:match("^comp_(.+)$") or nil
end

--- 并排成员显示名：系统组件用官方名称，合成组件用部件名兜底
local function relationLabels(parts)
    local labels = {}
    for _, comp in ipairs(componentList()) do
        labels[comp.id] = comp.label or comp.id
    end
    for _, part in ipairs(parts) do
        local id = partCompId(part)
        if id and not labels[id] then labels[id] = part.name or part.label or id end
    end
    return labels
end

local function relationText(row, labels)
    local names = {}
    for _, id in ipairs(row or {}) do
        names[#names + 1] = labels[tostring(id)] or tostring(id)
    end
    return table.concat(names, " + ")
end

--- 并排组合单独成行：图标、编号、成员名，避免跟普通组件图片混在一起
local function relationRow(desktop, info, width, labels, index, is_last)
    local UITheme = require("ui.themes")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local t = UITheme.current()
    local divider = math.max(1, UITheme.px(t.row.divider))
    local line = is_last
        and LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = width, h = divider },
        }
        or dashedLine(width, t.color.rule, divider)
    local row = Row.widget({
        width = width,
        icon = "view_column",
        title = T(_("并排组合 %1"), tostring(index)),
        subtitle = relationText(info.row, labels),
        chevron = true,
        divider = false,
        callback = desktop and function() themePartItem(desktop, info.part) end or nil,
    })
    return VerticalGroup:new{ align = "left", row, line }
end

--- 部件按来源主题分组。
--- 组件页每个主题只保留主题标题：先列有图片的组件，再列并排组合关系。
local function appendCardGrid(desktop, parts, typeKey)
    local groups = {}
    for _i, part in ipairs(parts) do
        local src = part.theme or _("未知主题")
        if not groups[src] then groups[src] = {} end
        groups[src][#groups[src] + 1] = part
    end
    local names = {}
    for n in pairs(groups) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then
        return { { title = _("部件"), rows = { function(iw)
            return Row.widget({ width = iw, icon = "palette", chevron = false,
                title = _("还没有部件"), subtitle = _("先保存或导入一套主题") })
        end } } }
    end
    local sections = {}
    for _i, name in ipairs(names) do
        local group = groups[name]
        if typeKey == "component" then
            local images, relations, seen = {}, {}, {}
            local labels = relationLabels(group)
            for _, part in ipairs(group) do
                if #collectPartImages(part) > 0 then
                    images[#images + 1] = part
                end
                for _, row in ipairs(type(part.conf) == "table" and type(part.conf.rows) == "table"
                        and part.conf.rows or {}) do
                    local key = relationKey(row)
                    if key ~= "" and not seen[key] then
                        seen[key] = true
                        relations[#relations + 1] = { part = part, row = row, text = relationText(row, labels) }
                    end
                end
            end
            table.sort(relations, function(a, b) return a.text < b.text end)
            local total = #images + #relations
            local rows = {}
            for _i, part in ipairs(images) do
                local last = _i == total
                rows[#rows + 1] = function(iw)
                    return partImagesRow(desktop, part, iw, typeKey, last)
                end
            end
            for _i, info in ipairs(relations) do
                local last = (#images + _i) == total
                rows[#rows + 1] = function(iw)
                    return relationRow(desktop, info, iw, labels, _i, last)
                end
            end
            if #rows > 0 then
                sections[#sections + 1] = {
                    title = name, rows = rows, title_style = "body", title_bold = true,
                }
            end
        else
            local rows = {}
            for _i, part in ipairs(group) do
                rows[#rows + 1] = function(iw)
                    return partImagesRow(desktop, part, iw, typeKey, _i == #group)
                end
            end
            sections[#sections + 1] = {
                title = name, rows = rows, title_style = "body", title_bold = true,
            }
        end
    end
    return sections
end

--- 部件类型页：整页只列各种部件类型
local function themeTypesPageTable(desktop)
    return {
        title = _("部件类型"),
        sections = function()
            local Theme = require("moonbeautify.theme")
            local Parts = require("moonbeautify.parts")
            local counts = {}
            for _, part in ipairs(Theme.allParts()) do
                local key = part.group or Parts.groupOfType(part.type)
                counts[key] = (counts[key] or 0) + 1
            end
            local types = {}
            for _, key in ipairs({ "icons", "badge", "frame", "component",
                                   "wallpaper", "lockscreen", "ime" }) do
                types[#types + 1] = { key = key, label = Parts.TYPE_LABEL[key] or key,
                                      count = counts[key] or 0 }
            end
            local rows = {}
            for i = 1, #types, 2 do
                local pair = { types[i], types[i + 1] }
                rows[#rows + 1] = function(iw) return typeGridRow(desktop, iw, pair) end
            end
            return { { rows = rows } }
        end,
    }
end

--- 某个部件类型下的部件页
themeTypePartsPage = function(desktop, typeKey, label)
    return {
        title = label or require("moonbeautify.parts").TYPE_LABEL[typeKey] or typeKey,
        sections = function()
            local Theme = require("moonbeautify.theme")
            local Parts = require("moonbeautify.parts")
            local parts = {}
            for _, part in ipairs(Theme.allParts()) do
                local group = part.group or Parts.groupOfType(part.type)
                if group == typeKey then parts[#parts + 1] = part end
            end
            return appendCardGrid(desktop, parts, typeKey)
        end,
    }
end

--- 主题类型页：整页罗列已导入主题
local function themeTypeListPage(desktop)
    return {
        title = _("主题类型"),
        sections = function()
            local Theme = require("moonbeautify.theme")
            local active = Store.conf().active_theme
            local rows = {}
            for _idx, name in ipairs(Theme.list()) do
                rows[#rows + 1] = function(iw)
                    local n, kb = Theme.stat(name)
                    local applied = name == active
                    return Row.widget({
                        width = iw, icon = "palette", title = name,
                        subtitle = T(_("%1 张图 · %2 KB"), n, kb),
                        status = applied and (Theme.dirty(name) and _("应用中（有修改）") or _("应用中")) or nil,
                        status_on = applied, chevron = true,
                        callback = function() themeItem(desktop, name, active) end,
                    })
                end
            end
            if #rows == 0 then
                rows[1] = function(iw)
                    return Row.widget({ width = iw, icon = "palette", chevron = false,
                        title = _("还没有主题"), subtitle = _("先保存当前配置，或导入一个 zip") })
                end
            end
            return { { rows = rows } }
        end,
    }
end

--- 主题主页：保存与导入 + 主题使用
---@param desktop table|nil
---@return table page
local function themePageTable(desktop)
    return {
        title = _("主题"),
        sections = function()
            return {
                { title = _("保存与导入"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "save", chevron = true,
                            title = _("当前配置保存为主题"),
                            subtitle = _("保存当前整套设置配置"),
                            callback = function() themeSave(desktop) end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "download", chevron = true,
                            title = _("导入主题 zip"),
                            subtitle = _("不管 zip 在哪，导入即归档到固定目录"),
                            callback = function() themeImport(desktop) end,
                        })
                    end,
                } },
                { title = _("主题使用"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "dashboard_customize", chevron = true,
                            title = _("按部件类型"),
                            subtitle = _("底栏图标 / 吧唧 / 相框 / 壁纸…"),
                            callback = function() Overlay.push(desktop, themeTypesPageTable(desktop)) end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "palette", chevron = true,
                            title = _("按主题类型"),
                            subtitle = _("按导入的套装查看，可预览里面各部件"),
                            callback = function() Overlay.push(desktop, themeTypeListPage(desktop)) end,
                        })
                    end,
                } },
            }
        end,
    }
end

--- 让当前主题页重新取数据（sections 是函数，rebuild 会重新调用）
---@param desktop table|nil
function refreshThemePage(desktop)
    if not desktop then return end
    local ov = desktop.settings_overlay
    if not ov then return end
    pcall(function()
        ov.page = nil      -- 列表变短后旧页码会越界，重置回第一页
        ov:rebuild()
        UIManager:setDirty(ov, "ui")
    end)
end

--- 依次点两个组件，存成一组并排（一个组件只能进一组）
---@param desktop table|nil
---@param first string|nil 已选的第一个组件 id
local function pickPair(desktop, first)
    local list = componentList()
    local labels = {}
    for _i, comp in ipairs(list) do labels[comp.id] = comp.label end
    local index = require("moonbeautify.rows").groupIndex(Store.conf().rows)
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
        themeToast(_("其余组件都已有组合，没有可并排的了"))
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

--- 组件顶层图总入口：逐个组件设置（与组件背景一样用取景选区）
---@param desktop table|nil
local function widgetLacePage(desktop)
    local Deco = require("moonbeautify.deco")
    local focusOf = require("moonbeautify.view").focusOf
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
                    require("moonbeautify.deco").clear()
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
                    require("moonbeautify.deco").clear()
                    Store.save()
                    repaint(desktop)
                    refreshDlg()
                end
            end)
        end,
    }:show()
end

--- 并排组合管理页
---@param desktop table|nil
local function rowsPage(desktop)
    local conf = Store.conf()
    -- 自愈：旧版本可能存过成员重叠的组合（渲染层只认先出现的那组），打开本页时清掉
    local cleaned, changed = require("moonbeautify.rows").cleanGroups(conf.rows)
    if changed then
        conf.rows = #cleaned > 0 and cleaned or nil
        Store.save()
        repaint(desktop)
        themeToast(_("清理了与其他组合重叠的无效组合"))
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

--- 月读设置页（外观分组）里的外观与主题入口。
---@param desktop table|nil
---@return table[]
function Settings.entries(desktop)
    local conf = Store.conf()
    local tab_map = type(conf.tab_icons) == "table" and conf.tab_icons or {}
    local tab_count = 0
    for _k in pairs(tab_map) do tab_count = tab_count + 1 end
    local bg_map = type(conf.widget_bg) == "table" and conf.widget_bg or {}
    local bg_count = 0
    for k in pairs(bg_map) do if k ~= "all" then bg_count = bg_count + 1 end end
    local row_count = type(conf.rows) == "table" and #conf.rows or 0
    local lace_map = type(conf.widget_lace) == "table" and conf.widget_lace or {}
    local lace_count = 0
    for k in pairs(lace_map) do if k ~= "all" then lace_count = lace_count + 1 end end
    return {
        {
            id = "tab_icons",
            group = "appearance",
            order = 40,
            row = function(iw)
                return Row.widget({
                    width = iw,
                    icon = "dashboard",
                    title = _("底栏图标"),
                    subtitle = tab_count > 0 and T(_("已自定义 %1 个"), tab_count) or _("用图片替换底栏图标"),
                    chevron = true,
                    callback = function() tabIconsPage(desktop) end,
                })
            end,
        },
        {
            id = "tab_order",
            group = "appearance",
            order = 40.5,
            row = function(iw)
                local custom = type(conf.tab_order) == "table" and #conf.tab_order > 0 or false
                return Row.widget({
                    width = iw,
                    icon = "swap_vert",
                    title = _("图标顺序"),
                    subtitle = custom and _("底栏图标已重新排列") or _("调整底栏图标的先后"),
                    chevron = true,
                    callback = function() tabOrderPage(desktop) end,
                })
            end,
        },
        {
            id = "widget_bg",
            group = "appearance",
            order = 42,
            row = function(iw)
                return Row.widget({
                    width = iw,
                    icon = "image",
                    title = _("组件背景"),
                    subtitle = bg_count > 0 and T(_("已设置 %1 个组件"), bg_count) or _("给首页组件加背景图"),
                    chevron = true,
                    callback = function() widgetBgPage(desktop) end,
                })
            end,
        },
        {
            id = "ime_bg",
            group = "appearance",
            order = 42.5,
            row = function(iw)
                local has_ime = type(conf.ime_bg) == "table" and type(conf.ime_bg.src) == "string"
                return Row.widget({
                    width = iw,
                    icon = "image",
                    title = _("输入法背景"),
                    subtitle = has_ime and _("已给键盘设背景图") or _("给输入法键盘加一张背景图"),
                    chevron = true,
                    callback = function() imeBgDialog(desktop) end,
                })
            end,
        },
        {
            id = "widget_lace",
            group = "appearance",
            order = 42,
            row = function(iw)
                return Row.widget({
                    width = iw,
                    icon = "border_style",
                    title = _("组件花边"),
                    subtitle = lace_count > 0 and T(_("%1 个组件已配"), lace_count) or _("给首页组件加一圈花边"),
                    chevron = true,
                    callback = function() widgetLacePage(desktop) end,
                })
            end,
        },
        {
            id = "rows",
            group = "appearance",
            order = 43,
            row = function(iw)
                return Row.widget({
                    width = iw,
                    icon = "view_column",
                    title = _("并排组合"),
                    subtitle = row_count > 0 and T(_("已有 %1 组"), row_count) or _("两个组件挤同一行"),
                    chevron = true,
                    callback = function() rowsPage(desktop) end,
                })
            end,
        },
        {
            id = "theme",
            group = "appearance",
            order = 44,
            row = function(iw)
                local themes = require("moonbeautify.theme").list()
                local count = #themes
                return Row.widget({
                    width = iw,
                    icon = "save",
                    title = _("主题"),
                    subtitle = count > 0 and T(_("%1 套已保存，可随时切换"), count)
                        or _("整套美化连图片存档、分享、一键切换"),
                    chevron = true,
                    callback = function()
                        Overlay.push(desktop, themePageTable(desktop))
                    end,
                })
            end,
        },
        -- 扩展自己的设置页（设置 → 系统 → 本机 → 美化），更新检查放这里，不混进外观
        (function()
            local Update = require("moonbeautify.update")
            local ver = Update.version()
            local title = ver and T(_("美化（%1）"), ver) or _("美化")
            return {
                id = "main",
                group = "system",
                order = 56,
                icon = "settings_suggest",
                title = title,
                subtitle = _("外观增强"),
                page = {
                    title = title,
                    sections = function()
                        local on = Update.autoEnabled()
                        return {
                            { title = _("更新"), rows = {
                                function(iw)
                                    return Row.widget({
                                        width = iw, chevron = false, kind = "toggle", icon = "update",
                                        title = _("自动检查更新"),
                                        subtitle = _("每天最多一次，发现新版本时弹窗提示"),
                                        status = on and _("开") or _("关"), status_on = on,
                                        callback = function()
                                            Update.setAuto(not on)
                                            if desktop then pcall(function() desktop:updateView() end) end
                                        end,
                                    })
                                end,
                                function(iw)
                                    return Row.widget({
                                        width = iw, chevron = false, kind = "action", icon = "settings_suggest",
                                        title = _("检查更新"),
                                        status = ver or "", status_on = true,
                                        callback = function() Update.check(false) end,
                                    })
                                end,
                            } },
                        }
                    end,
                },
            }
        end)(),
    }
end

return Settings
