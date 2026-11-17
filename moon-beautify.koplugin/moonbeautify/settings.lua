--[[--
设置界面：组件自己的设置（首页编辑态的齿轮）+ 月读设置页里的两行入口（底栏图标 / 组件背景）。

都是月读自己的控件（List、PathPicker、Spin、Row），选完写扩展配置、落盘、重画。

@module moonbeautify.settings
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local Spin = require("ui.themes.widgets.spin")
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
    pcall(function() UIManager:setDirty(desktop, "full") end)
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
---@param title string
---@param items table[]
---@param current any
---@param on_select fun(value: any)
local function choose(title, items, current, on_select)
    List:new{
        title = title,
        items = items,
        current = current,
        centered = true,
        on_select = function(value)
            if value == nil then return end
            on_select(value)
        end,
    }:show()
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

--- 从配置前缀还原显示名："badge_" → 吧唧；"badge2_" → 吧唧 2
---@param prefix string
---@return string
local function prefixTitle(prefix)
    local n = tonumber(prefix:match("^badge(%d*)_$") or "")
    if not n or n == 1 then return _("吧唧") end
    return T(_("吧唧 %1"), n)
end

--- 吧唧的设置。每个吧唧实例用 id 前缀区分（badge_ / badge2_ ...），互不影响。
---@param desktop table|nil
---@param prefix string
local function badgeSettings(desktop, prefix)
    local conf = Store.conf()
    local items = {
        { value = "src", text = T(_("图片：%1（固定图 / 文件夹）"),
            Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file") == "folder"
                and _("文件夹") or _("固定一张")) },
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

--- 设置入口（widget.settings(desktop, id)）
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param desktop table|nil
function Settings.show(prefix, desktop)
    return badgeSettings(desktop, prefix)
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
    List:new{
        title = _("底栏图标"),
        subtitle = _("建议用方形单色小图标（PNG），会缩到图标大小"),
        items = items,
        current = nil,
        centered = true,
        on_select = function(id)
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

--- 单个组件的背景：选图 / 不透明度 / 移除
---@param desktop table|nil
---@param comp table { id, label }
local function widgetBgDialog(desktop, comp)
    local conf = Store.conf()
    local all = type(conf.widget_bg) == "table" and conf.widget_bg or {}
    local item = all[comp.id]
    local veil = type(item) == "table" and tonumber(item.veil) or 0
    choose(comp.label, {
        { value = "pick", text = _("选一张背景图…") },
        { value = "veil", text = T(_("内容提亮：%1%"), veil) },
        { value = "reset", text = _("移除背景"), enabled = item ~= nil },
    }, nil, function(value)
        local function save(mutate)
            local c = Store.conf()
            c.widget_bg = type(c.widget_bg) == "table" and c.widget_bg or {}
            mutate(c.widget_bg)
            if next(c.widget_bg) == nil then c.widget_bg = nil end
            Store.save()
            repaint(desktop)
        end
        if value == "pick" then
            pickPath(desktop, type(item) == "table" and item.src or nil, true, function(path)
                save(function(bg)
                    bg[comp.id] = bg[comp.id] or {}
                    bg[comp.id].src = path
                end)
            end)
        elseif value == "veil" then
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
    for _idx, comp in ipairs(componentList()) do
        items[#items + 1] = {
            value = comp.id,
            text = comp.label,
            mandatory = type(all[comp.id]) == "table" and _("已设") or nil,
        }
    end
    choose(_("组件背景"), items, nil, function(id)
        for _i, comp in ipairs(componentList()) do
            if comp.id == id then return widgetBgDialog(desktop, comp) end
        end
    end)
end

--- 依次点两个组件，存成一组并排
---@param desktop table|nil
---@param first string|nil 已选的第一个组件 id
local function pickPair(desktop, first)
    local list = componentList()
    local labels = {}
    for _i, comp in ipairs(list) do labels[comp.id] = comp.label end
    if not first then
        local items = {}
        for _i, comp in ipairs(list) do items[#items + 1] = { value = comp.id, text = comp.label } end
        return choose(_("第一个组件"), items, nil, function(id) pickPair(desktop, id) end)
    end
    -- 第二个：排除已选的那个和跟它同组的
    local items = {}
    for _i, comp in ipairs(list) do
        if comp.id ~= first then items[#items + 1] = { value = comp.id, text = comp.label } end
    end
    choose(T(_("和「%1」并排"), labels[first] or first), items, nil, function(id)
        local c = Store.conf()
        c.rows = type(c.rows) == "table" and c.rows or {}
        c.rows[#c.rows + 1] = { first, id }
        Store.save()
        repaint(desktop)
    end)
end

--- 组件花边总入口：all 统一配所有组件，组件自己的键可覆盖
---@param desktop table|nil
local function widgetLacePage(desktop)
    local conf = Store.conf()
    local map = type(conf.widget_lace) == "table" and conf.widget_lace or {}
    local items = {}
    local all = map.all
    items[#items + 1] = {
        value = "all",
        text = T(_("全部组件：%1"), (type(all) == "string" and all ~= "")
            and (all:match("([^/]+)$") or all) or _("未设置")),
        mandatory = type(all) == "string" and all ~= "" and _("统一花边") or nil,
    }
    local labels = {}
    for _idx, comp in ipairs(componentList()) do
        labels[comp.id] = comp.label
        local own = map[comp.id]
        items[#items + 1] = {
            value = comp.id,
            text = comp.label,
            mandatory = (type(own) == "string" and own ~= "" and _("单独") or nil),
        }
    end
    List:new{
        title = _("组件花边"),
        subtitle = _("先配「全部组件」，再给个别组件换图或关掉"),
        items = items,
        centered = true,
        on_select = function(value)
            local target = value == "all" and "all" or value
            local current = type(map[target]) == "string" and map[target] or nil
            choose(value == "all" and _("全部组件") or (labels[value] or value), {
                { value = "pick", text = _("选一张花边（透明 PNG）…") },
                { value = "reset", text = _("移除花边"), enabled = current ~= nil },
            }, nil, function(v)
                local c = Store.conf()
                if v == "pick" then
                    pickPath(desktop, current, true, function(path)
                        c.widget_lace = type(c.widget_lace) == "table" and c.widget_lace or {}
                        c.widget_lace[target] = path
                        Store.save()
                        repaint(desktop)
                    end)
                elseif v == "reset" then
                    c.widget_lace = type(c.widget_lace) == "table" and c.widget_lace or {}
                    c.widget_lace[target] = nil
                    if next(c.widget_lace) == nil then c.widget_lace = nil end
                    Store.save()
                    repaint(desktop)
                end
            end)
        end,
    }:show()
end

--- 并排组合管理页
---@param desktop table|nil
local function rowsPage(desktop)
    local conf = Store.conf()
    local groups = type(conf.rows) == "table" and conf.rows or {}
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

--- 月读设置页（外观分组）里的两行入口。
---@param desktop table|nil
---@return table[]
function Settings.entries(desktop)
    local conf = Store.conf()
    local tab_map = type(conf.tab_icons) == "table" and conf.tab_icons or {}
    local tab_count = 0
    for _k in pairs(tab_map) do tab_count = tab_count + 1 end
    local bg_map = type(conf.widget_bg) == "table" and conf.widget_bg or {}
    local bg_count = 0
    for _k in pairs(bg_map) do bg_count = bg_count + 1 end
    local row_count = type(conf.rows) == "table" and #conf.rows or 0
    local lace_map = type(conf.widget_lace) == "table" and conf.widget_lace or {}
    local lace_count = 0
    for _k in pairs(lace_map) do lace_count = lace_count + 1 end
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
            id = "widget_bg",
            group = "appearance",
            order = 41,
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
    }
end

return Settings
