--[[--
对月读本体的若干轻量补丁（不改月读源码，只替换模块表上的函数）。

1. Icon.widget / Icon.label：name 看起来是图片路径（含 / 且后缀是图片）就画图，否则走原字体图标。
2. Tabbar.widget：按配置 tab_icons[tab.id] 把底栏格子的 icon 换成图片路径。
3. Base.build / Base.refresh：按组件自己的配置套背景图（widget_bg[组件 id]）、叠顶层图（widget_lace[组件 id]）；
   两者都按取景选区显示；不提供全组件通用背景/顶层图，组件尺寸不同会变形。
4. 首页并排组合、选图器目录记忆、输入法键盘背景分别由 rows.lua / 本文件 / 本文件处理。
5. 设置入口（settings.entries）另在 settings.lua。

全部包在 pcall 里，月读升级导致字段变化时最多失效，不影响启动。

@module moonbeautify.patch
--]]

local Theme = require("ui/themes")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")

local Image = require("ui/themes/widgets/image")
local Text = require("ui.themes.widgets.text")
local ImageUtil = require("utils.image")

local Store = require("moonbeautify.store")

local Patch = {}
local installed = false

--- 名字是不是图片路径：带目录分隔符且后缀是已知图片。
---@param name any
---@return boolean
local function isImagePath(name)
    return type(name) == "string" and name:find("/", 1, true) ~= nil and ImageUtil.suffix(name) ~= nil
end

--- 图标槽换成图片：方盒居中，保比例。
---@param path string
---@param size number 逻辑字号
---@return table
local function imageIcon(path, size)
    local box = Theme.px(size)
    return CenterContainer:new{
        dimen = Geom:new{ w = box, h = box },
        Image.widget{ src = path, width = box, height = box, stretch = false, style = {}, fallback = "" },
    }
end

--- 补丁 1：图标字体 -> 图片
local function patchIcon()
    local Icon = require("ui.themes.widgets.icon")
    if Icon._beautify then return end
    Icon._beautify = true

    local origWidget = Icon.widget
    Icon.widget = function(opts)
        if isImagePath(opts and opts.name) then return imageIcon(opts.name, opts.size or 24) end
        return origWidget(opts)
    end

    local origLabel = Icon.label

    --- 图片路径 + 文字的组合标签；text 缺失时只画图标
    ---@param opts table
    ---@return table
    local function labelWidget(opts)
        if not opts.text then return imageIcon(opts.name, opts.size or 24) end
        local color = opts.color or Theme.color(Theme.current().color.accent)
        local column = opts.direction == "column"
        local icon = imageIcon(opts.name, opts.size or 24)
        local text = Text.tint(TextWidget:new{
            text = opts.text,
            face = Theme.face(opts.face or "xx_smallinfofont", opts.font_size or 12),
            fgcolor = opts.text_color or color,
            max_width = opts.max_width,
        })
        local group = (column and VerticalGroup or HorizontalGroup):new{ align = "center" }
        group[1] = opts.trailing and text or icon
        group[2] = (column and VerticalSpan or HorizontalSpan):new{ width = opts.gap or Theme.px(4) }
        group[3] = opts.trailing and icon or text
        return group
    end

    Icon.label = function(opts)
        if not isImagePath(opts and opts.name) then return origLabel(opts) end
        -- 组合标签出错（字段变化等）就退回原生文字标签，不能让桌面画不出来
        local ok, result = pcall(labelWidget, opts)
        if ok and result then return result end
        return origLabel(opts)
    end
end

--- 补丁 2：底栏图标按配置换图
local function patchTabbar()
    local Tabbar = require("ui.themes.widgets.tabbar")
    if Tabbar._beautify then return end
    Tabbar._beautify = true
    local orig = Tabbar.widget
    Tabbar.widget = function(opts)
        local ok, tabs = pcall(function()
            local map = Store.conf().tab_icons
            if type(map) ~= "table" or type(opts.tabs) ~= "table" then return nil end
            local copy, changed = {}, false
            for i, tab in ipairs(opts.tabs) do
                local path = map[tab.id]
                if type(path) == "string" and path ~= "" then
                    copy[i] = { id = tab.id, text = tab.text, icon = path, owner = tab.owner, after = tab.after }
                    changed = true
                else
                    copy[i] = tab
                end
            end
            return changed and copy or nil
        end)
        if ok and tabs then opts.tabs = tabs end
        -- 图标顺序：tab_order 里配置了的格子按用户顺序排，没配置的（扩展格子等）保持原顺序跟在后面
        local okr, ordered = pcall(function()
            local order = Store.conf().tab_order
            if type(order) ~= "table" or #order == 0 or type(opts.tabs) ~= "table" or #opts.tabs < 2 then
                return nil
            end
            local rank = {}
            for i, id in ipairs(order) do
                if type(id) == "string" and rank[id] == nil then rank[id] = i end
            end
            local idx, copy = {}, {}
            for i, tab in ipairs(opts.tabs) do
                idx[tab] = i
                copy[i] = tab
            end
            table.sort(copy, function(a, b)
                local ra, rb = rank[a.id], rank[b.id]
                if ra and rb then
                    if ra ~= rb then return ra < rb end
                    return idx[a] < idx[b]
                end
                if ra then return true end
                if rb then return false end
                return idx[a] < idx[b]
            end)
            for i, tab in ipairs(copy) do
                if tab ~= opts.tabs[i] then return copy end
            end
            return nil
        end)
        if okr and ordered then opts.tabs = ordered end
        return orig(opts)
    end
end

--- 组件内容内边距：widget_pad.all 统一，组件自己的键覆盖（0 = 不收）
---@param conf table
---@param id string
---@return integer
local function padOf(conf, id)
    local map = conf.widget_pad
    if type(map) ~= "table" then return 0 end
    local own = map[id]
    local v = tonumber((own ~= nil) and own or map.all) or 0
    if v < 0 then v = 0 end
    if v > 24 then v = 24 end
    return math.floor(v)
end

--- 吧唧 / 相框有自己的设置入口，不参与通用组件背景、花边、内边距包裹。
---@param id string|nil
---@return boolean
local function isBadgeOrFrame(id)
    if type(id) ~= "string" then return false end
    local bare = id:match("ext%.beautify%.(.+)$") or id
    return bare:match("^badge%d*$") ~= nil or bare:match("^frame%d*$") ~= nil
end

--- 补丁 3：组件背景 + 花边包裹
---@param self table 组件实例（Base 子类）
---@param widget table 组件内容
---@return table
local function decorate(self, widget)
    if isBadgeOrFrame(self.id) then return widget end
    local ok, wrapped = pcall(function()
        local conf = Store.conf()
        -- 顶层图：逐组件设置（false/空串表示关）
        -- 值是字符串（旧格式，纯路径）或表 { src = 路径, focus = 取景选区 }
        -- 显示方式与组件背景一致：统一按取景选区，没设选区就按整图铺满。
        local lace, laceFocus
        local laceConf = conf.widget_lace
        if type(laceConf) == "table" then lace = laceConf[self.id] end
        if type(lace) == "table" then
            laceFocus = require("moonbeautify.view").focusOf(lace.focus)
            lace = lace.src
        end
        if type(lace) ~= "string" or lace == "" then
            lace = nil
        elseif not laceFocus then
            laceFocus = { x = 0, y = 0, w = 1, h = 1 }
        end
        local item = type(conf.widget_bg) == "table" and conf.widget_bg[self.id] or nil
        local hasBg = type(item) == "table" and type(item.src) == "string" and item.src ~= ""
        local bgAnchor = hasBg and { x = tonumber(item.ax) or 0.5, y = tonumber(item.ay) or 0.5 } or nil
        local bgFocus = hasBg and require("moonbeautify.view").focusOf(item.focus) or nil
        local pad = padOf(conf, self.id)
        if not hasBg and not lace and pad <= 0 then return nil end
        -- 有内边距时组件是按缩小尺寸建的（_beautify_full 记着整槽尺寸），居中放回去
        local dims = self._beautify_full
        local opts = self.opts or {}
        local w = (dims and dims.w) or opts.width or widget.dimen and widget.dimen.w
        local h = (dims and dims.h) or opts.height or widget.dimen and widget.dimen.h
        if not (w and h) then return nil end
        local inner = widget
        if dims and pad > 0 then
            inner = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, widget }
        end
        return require("moonbeautify.view").background(w, h,
            hasBg and item.src or nil, hasBg and (tonumber(item.veil) or 0) or 0, inner, lace,
            hasBg and item.fit or nil, bgAnchor, bgFocus, laceFocus)
    end)
    if ok and wrapped then return wrapped end
    return widget
end

local function patchHome()
    local Base = require("desktop.pages.home.base")
    if Base._beautify then return end
    Base._beautify = true

    local origBuild = Base.build
    Base.build = function(self, ctx, opts)
        -- 内边距：把组件按缩小后的宽高建出来，槽位本身保持原尺寸，
        -- decorate 里再居中放回去——背景 / 边框 / 花边仍铺满整槽。
        local build_opts = opts
        local pad = padOf(Store.conf(), self.id)
        local full
        if pad > 0 and opts and tonumber(opts.width) and tonumber(opts.height) then
            local w, h = math.floor(opts.width), math.floor(opts.height)
            full = { w = w, h = h }
            self._beautify_full = full
            build_opts = {}
            for k, v in pairs(opts) do build_opts[k] = v end
            build_opts.width = math.max(24, w - pad * 2)
            build_opts.height = math.max(24, h - pad * 2)
        else
            self._beautify_full = nil
        end
        local slot = origBuild(self, ctx, build_opts)
        if slot then
            if full and slot.dimen then
                slot.dimen.w, slot.dimen.h = full.w, full.h
            end
            if slot[1] then slot[1] = decorate(self, slot[1]) end
        end
        return slot
    end

    -- 整体替换 refresh：重建内容后重新套装饰
    Base.refresh = function(self)
        local slot = self.slot
        if not slot then return end
        local old = slot[1]
        slot[1] = decorate(self, self:createWidget())
        if old then old:free() end
        self:dirty()
    end
end

--- 补丁 4：首页「同一行并排」——接管 layout.build / paginate（仅配置了组合时生效）
local function patchRows()
    require("moonbeautify.rows").install()
end

--- 补丁 5：选图器的「上次目录」记忆。
--- 月读自己的壁纸/锁屏/设备头像选择器都走 ui.themes.widgets.path_picker，
--- 这里统一记一个 last_dir：谁先选过图，后面所有选择器（含吧唧/组件背景）都从那里开。
--- 已经显式配过路径的（组件自己的 src/dir、壁纸自己的图）不受影响，仍从自己那个目录开。
local function patchPicker()
    local lfs = require("libs/libkoreader-lfs")
    local PathPicker = require("ui.themes.widgets.path_picker")
    if PathPicker._beautify then return end
    PathPicker._beautify = true

    local function isDir(path)
        return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "directory"
    end

    --- 记住这次选的目录：选文件记它所在目录，选目录就记目录本身
    ---@param picked string
    ---@param select_file boolean
    local function remember(picked, select_file)
        if type(picked) ~= "string" or picked == "" then return end
        local dir = select_file and picked:match("^(.*)/") or picked
        if isDir(dir) then
            local conf = Store.conf()
            if conf.last_dir ~= dir then
                conf.last_dir = dir
                Store.save()
            end
        end
    end

    local orig_init = PathPicker.init
    PathPicker.init = function(self)
        local home = require("apps/filemanager/filemanagerutil").getHomeFolder()
        local last = Store.conf().last_dir
        -- 传进来的是「用户目录」这种没信息量的兜底，或者干脆不是有效目录 → 用上次的
        if isDir(last) and (not isDir(self.path) or self.path == home) then
            self.path = last
        end
        local orig_select = self.on_select
        if type(orig_select) == "function" then
            self.on_select = function(picked)
                pcall(remember, picked, self.select_file)
                return orig_select(picked)
            end
        end
        return orig_init(self)
    end
end

--- 补丁 6：输入法键盘背景 + 按键透明度。
--- 两个 hook 点：
---   1) CenterContainer.paintTo（整个键盘绘制）：铺背景图
---   2) 按键内部 FrameContainer.paintTo（key[1]）：关白底 + 半透明提亮 + 格子边框常驻。
---      必须挂在 FrameContainer 而不是 VirtualKey：点击高亮时 KOReader 用
---      widgetRepaint(self[1]) 只重绘按键自身，绕过 VirtualKey.paintTo。
--- 不碰 widget 树结构：候选词条依赖 kb[1][1][1][1] 固定链、kb.layout 导航。
local function patchKeyboard()
    local VK = require("ui/widget/virtualkeyboard")
    if VK._beautify_ime_bg then return end
    VK._beautify_ime_bg = true

    local orig_addKeys = VK.addKeys
    VK.addKeys = function(self, ...)
        orig_addKeys(self, ...)
        -- 关掉按键点击闪烁：invert() 会画出 focus 高亮（白格子），并在 e-ink 上
        -- 经 yieldToEPDC 保持那一帧，导致"按完格子发白"。只在有键盘背景时逐个按键关，
        -- 不改 KOReader 全局的 flash_keyboard 设置（移除背景后用户原设置照常生效）。
        pcall(function()
            local item = Store.conf().ime_bg
            if type(item) == "table" and type(item.src) == "string" and item.src ~= "" then
                local vg = self[1] and self[1][1] and self[1][1][1] and self[1][1][1][1]
                if type(vg) == "table" then
                    for _i, row in ipairs(vg) do
                        if type(row) == "table" then
                            for _j, key in ipairs(row) do
                                if type(key) == "table" then key.flash_keyboard = false end
                            end
                        end
                    end
                end
            end
        end)
        pcall(function()
            local center = self[1] and self[1][1] and self[1][1][1]
            if not (center and center.paintTo and center.dimen) then return end

            -- 1) 整个键盘绘制时铺背景图
            if not center._beautify_bg then
                center._beautify_bg = true
                local orig_paint = center.paintTo
                center.paintTo = function(widget, bb, x, y)
                    local item = Store.conf().ime_bg
                    local has_src = type(item) == "table" and type(item.src) == "string" and item.src ~= ""
                    local w, h = widget.dimen.w, widget.dimen.h
                    if has_src and w and h and w > 0 and h > 0 then
                        pcall(function()
                            require("moonbeautify.bg").layer(item.src, w, h, nil, nil, item.focus):paintTo(bb, x, y)
                            local veil = tonumber(item.veil) or 0
                            if veil > 0 then bb:lightenRect(x, y, w, h, veil / 100) end
                        end)
                    end
                    return orig_paint(widget, bb, x, y)
                end
            end

            -- 2) 逐个 hook 按键内部 FrameContainer（key[1]）的 paintTo。
            --    Color 是 cdata：一律用 rawget + type 判断，不用 == / ~=。
            local vg = center[1]
            if type(vg) ~= "table" then return end
            for _i, row in ipairs(vg) do
                if type(row) == "table" then
                    for _j, key in ipairs(row) do
                        local frame = type(key) == "table" and key[1]
                        if type(frame) == "table" and frame.paintTo and type(rawget(frame, "background")) == "cdata"
                                and not frame._beautify_keyalpha then
                            frame._beautify_keyalpha = true
                            local orig_frame_paint = frame.paintTo
                            frame.paintTo = function(widget, bb, fx, fy)
                                local item = Store.conf().ime_bg
                                local alpha = (type(item) == "table" and tonumber(item.key_alpha)) or 0
                                if alpha > 100 then alpha = 100 end
                                local bg = rawget(widget, "background")
                                if alpha > 0 and type(bg) == "cdata" then
                                    local white = (100 - alpha) / 100 * 0.4
                                    local d = widget.dimen
                                    if white > 0 and d then
                                        pcall(function() bb:lightenRect(fx, fy, d.w, d.h, white) end)
                                    end
                                    -- 关白底（false 短路 if self.background），格子用常驻内边框
                                    local saved_bg, saved_inner = bg, widget.inner_bordersize
                                    widget.background = false
                                    local focus_bs = type(key) == "table" and key.focused_bordersize or nil
                                    if type(focus_bs) == "number" and focus_bs > 0 then
                                        widget.inner_bordersize = focus_bs
                                    end
                                    local ok, err = pcall(orig_frame_paint, widget, bb, fx, fy)
                                    widget.background = saved_bg
                                    widget.inner_bordersize = saved_inner
                                    if not ok then error(err) end
                                else
                                    return orig_frame_paint(widget, bb, fx, fy)
                                end
                            end
                        end
                    end
                end
            end
        end)
    end
end
--- 安装全部补丁（幂等）。
function Patch.install()
    if installed then return end
    installed = true
    for _idx, fn in ipairs({ patchIcon, patchTabbar, patchHome, patchRows, patchPicker, patchKeyboard }) do
        local ok, err = pcall(fn)
        if not ok then
            pcall(function() require("utils.log").error("moonbeautify patch failed:", tostring(err)) end)
        end
    end
end

return Patch
