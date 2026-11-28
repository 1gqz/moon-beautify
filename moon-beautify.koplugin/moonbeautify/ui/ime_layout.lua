--[[--
输入法布局预览：按当前 KOReader 键盘行列画格子。
点某个键 → 为该分区（字母/数字/空格/符号/功能）设皮肤；点背景 → 设键盘壁纸。

@module moonbeautify.ui.ime_layout
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Settings = require("ui.themes.widgets.settings")
local Spin = require("ui.themes.widgets.spin")
local _ = require("moonbeautify.l10n")
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Regions = require("moonbeautify.core.ime_regions")
local Common = require("moonbeautify.ui.common")
local repaint, focusText, pickPath, chooseFocus =
    Common.repaint, Common.focusText, Common.pickPath, Common.chooseFocus

local Screen = Device.screen
local LAYER = 2


--- Theme.color 在彩色设备上是 ColorRGB32，不能再塞进 Color8。
local function fill(bb, x, y, w, h, color)
    if Theme.isRgb(color) then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        bb:paintRect(x, y, w, h, color)
    end
end

local Layout = Modal:extend{
    name = "moonbeautify_ime_layout",
    covers_fullscreen = true,
    dismissable = true,
    swipe_dismiss = "off",
}

local function inside(px, py, r)
    return r and px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

local function nameOf(path)
    if type(path) ~= "string" or path == "" then return nil end
    return path:match("([^/]+)$") or path
end

local function imeItem()
    local item = Store.conf().ime_bg
    if type(item) ~= "table" then item = {} end
    Regions.migrate(item)
    return item
end

local function normalizeIme(bg)
    if type(bg) ~= "table" then return nil end
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
    if not Regions.anySkin(bg) then
        bg.key_src, bg.key_focus = nil, nil
    end
    if not (has_bg or Regions.anySkin(bg) or (tonumber(bg.key_alpha) or 0) > 0) then
        return nil
    end
    return bg
end

local function saveIme(desktop, mutate, quiet)
    local c = Store.conf()
    c.ime_bg = type(c.ime_bg) == "table" and c.ime_bg or {}
    mutate(c.ime_bg)
    c.ime_bg = normalizeIme(c.ime_bg)
    Store.save()
    if not quiet then repaint(desktop) end
end

--- 月读「输入法增强」入口（没有月读时退回普通 en 键位）
local function moonIME()
    local ok, IME = pcall(require, "features.ime")
    if ok and IME then return IME end
    return nil
end

local function moonRegistry()
    local ok, Registry = pcall(require, "features.ime.registry")
    if ok and Registry then return Registry end
    return nil
end

local function currentMethodId()
    local IME = moonIME()
    if IME and IME.layout then return IME.layout() end
    return "pinyin"
end

local function methodLabel(id)
    local Registry = moonRegistry()
    if Registry then
        local m = Registry.get(id)
        if m and m.label then return m.label end
    end
    return id
end

--- 列出月读输入法增强里的布局（拼音 / 九宫格 / 五笔…），仅预览，不改用户设置
local function layoutItems()
    local IME = moonIME()
    local items = {}
    if IME and IME.layouts then
        for _i, method in ipairs(IME.layouts()) do
            items[#items + 1] = { value = method.id, text = method.label }
        end
    end
    if #items == 0 then
        items[1] = { value = "en", text = _("英文") }
    end
    return items
end

--- 注音：在 zh_CN 键位上补 - , . /（对齐 features.ime.candidate_bar）
local function applyZhuyinKeys(keys)
    local util = require("util")
    keys[1][11] = { "-", "-", "-", "-" }
    if keys[3] and keys[3][10] and keys[3][10][1] then
        keys[3][10][2] = util.tableDeepCopy(keys[3][10][1])
    end
    local row = keys[4]
    if not row then return end
    if row[1] and row[1].label then table.remove(row, 1) end
    table.insert(row, #row, { ",", ",", ",", "," })
    table.insert(row, #row, { ".", ".", ".", "." })
    table.insert(row, #row, { "/", "/", "/", "/" })
    row[#row].width = 1.0
end

local function primaryChar(layer_val)
    if type(layer_val) == "table" then return layer_val[1] end
    return layer_val
end

--- 按月读输入法 profile 生成预览用 keys（深拷贝，不污染 zh_CN 模块）
local function keysForMethod(id)
    local util = require("util")
    if id == "en" then
        return require("ui/data/keyboardlayouts/en_keyboard").keys
    end
    local ok, layout = pcall(require, "ui/data/keyboardlayouts/zh_CN_keyboard")
    if not ok or type(layout) ~= "table" or type(layout.keys) ~= "table" then
        return require("ui/data/keyboardlayouts/en_keyboard").keys
    end
    local keys = util.tableDeepCopy(layout.keys)
    local Registry = moonRegistry()
    local profile = Registry and Registry.get(id) or nil
    if not profile then return keys end

    if profile.rows then
        local rows = profile.rows(keys)
        for i = #keys, 1, -1 do keys[i] = nil end
        for i, row in ipairs(rows) do keys[i] = row end
        return keys
    end
    if profile.id == "zhuyin" then
        applyZhuyinKeys(keys)
    end
    local labels = profile.labels
    if type(labels) ~= "table" then return keys end
    -- 字根/韵母键帽可关：跟上月读 ime_keycaps
    if profile.optional_labels then
        local show = true
        pcall(function()
            show = require("utils.settings").get("features.ime").ime_keycaps == true
        end)
        if not show then return keys end
    end
    for _i, row in ipairs(keys) do
        for _j, key in ipairs(row) do
            if type(key) == "table" then
                for layer = 1, 2 do
                    local raw = primaryChar(key[layer])
                    local code = type(raw) == "string" and raw:lower() or nil
                    local label = code and labels[code]
                    if label then
                        local value = key[layer]
                        local alt = profile.show_codes and code:upper() or nil
                        if type(value) == "table" then
                            value.label = label
                            value.alt_label = alt
                        else
                            key[layer] = { label = label, alt_label = alt, value }
                        end
                    end
                end
            end
        end
    end
    return keys
end

local function loadKeys(method_id)
    method_id = method_id or currentMethodId()
    return keysForMethod(method_id), method_id
end

local function cellInfo(row, col, keys)
    local cell = keys[row][col]
    local layer_val = cell[LAYER]
    local label, width_factor, key
    if type(layer_val) == "table" then
        key = layer_val[1]
        label = layer_val.label
        width_factor = layer_val.width
    else
        key = layer_val
    end
    width_factor = width_factor or cell.width or 1.0
    label = label or cell.label or key or "?"
    local probe = { key = key, label = label or cell.label }
    if cell.label == "_" and cell[LAYER] == " " then
        label = _("空格")
        probe = { key = " ", label = "_" }
    elseif key == " " or label == " " then
        label = _("空格")
        probe = { key = " ", label = "_" }
    end
    local region = Regions.of(probe)
    return tostring(label), width_factor, region, probe
end

function Layout:init()
    Modal.init(self)
    local t = Theme.current()
    self.color_page = Theme.color(t.color.page)
    self.color_ink = Theme.color(t.color.ink)
    self.color_accent = Theme.color(t.color.accent or t.color.ink)
    self.tok_ink = t.color.ink

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = sw, sh
    self.margin = math.max(8, math.floor(math.min(sw, sh) * 0.03))
    self.top_h = math.max(56, math.floor(sh * 0.12))
    self.bot_h = math.max(64, math.floor(sh * 0.12))

    self.keys, self.method_id = loadKeys(self.method_id)
    self:layoutKeys()
    self:buildChrome()
    self:rebuildLayers()

    local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events.TapModal = nil
    self.ges_events.SwipeModal = nil
    self.ges_events.LayoutTap = { GestureRange:new{ ges = "tap", range = full } }
end

--- 一行的宽度因子合计。九宫格首行 5 键因子加起来是 10，不能按键数均分。
local function rowUnitCount(keys, row_i)
    local sum, row = 0, keys[row_i]
    if not row then return 1 end
    for j = 1, #row do
        local _label, width_factor = cellInfo(row_i, j, keys)
        sum = sum + (tonumber(width_factor) or 1)
    end
    return math.max(sum, 0.01)
end

function Layout:layoutKeys()
    local keys = self.keys
    local key_padding = Size.padding.small
    local padding = 0
    -- 与底栏按钮同侧边距，整框水平居中（真机 VirtualKeyboard 全宽贴边，预览要对齐底栏视觉）
    local side = math.max(8, math.floor(self.screen_w * 0.02))
    local width = self.screen_w - side * 2
    local compact = false
    pcall(function() compact = G_reader_settings:isTrue("keyboard_key_compact") end)
    local keys_height = compact and 48 or 64
    local height = Screen:scaleBySize(keys_height * #keys)
    local border = Size.border.default

    -- base = 因子 1.0 的键宽。
    -- QWERTY：因子和 F = 键数 n，等价 VK 的 (W-(n+1)*pad)/n。
    -- 九宫格：F=10、n=5，必须除 F；再用 (W-pad)/F - pad，否则行宽会撑破容器。
    local units = rowUnitCount(keys, 1)
    local base_key_width = math.floor((width - 2 * padding - key_padding) / units) - key_padding
    if base_key_width < 1 then base_key_width = 1 end
    local base_key_height = math.floor((height - (#keys + 1) * key_padding - 2 * padding) / #keys)

    local frame_w, frame_h = width, height
    local frame_x, frame_y = side, self.screen_h - self.bot_h - frame_h
    if frame_y < self.top_h then
        frame_y = self.top_h
        frame_h = math.max(80, self.screen_h - self.bot_h - self.top_h)
        base_key_height = math.floor((frame_h - (#keys + 1) * key_padding - 2 * padding) / #keys)
    end

    self.kb = Geom:new{ x = frame_x, y = frame_y, w = frame_w, h = frame_h }
    self.inner = Geom:new{
        x = frame_x + border + padding,
        y = frame_y + border + padding,
        w = frame_w - 2 * border - 2 * padding,
        h = frame_h - 2 * border - 2 * padding,
    }

    -- 对齐 VirtualKeyboard：base 公式已按 (#keys+1)*padding 预留两侧余量，
    -- 行宽只计键间 padding，整行再在 inner 里水平居中。
    local cells = {}
    local y = self.inner.y + key_padding
    for i = 1, #keys do
        local row, row_w = {}, 0
        for j = 1, #keys[i] do
            local label, width_factor, region = cellInfo(i, j, keys)
            local key_width = math.floor((base_key_width + key_padding) * width_factor) - key_padding
            row[#row + 1] = {
                rel_x = row_w, w = key_width, h = base_key_height,
                label = label, region = region,
            }
            row_w = row_w + key_width
            if j < #keys[i] then row_w = row_w + key_padding end
        end
        local ox = self.inner.x + math.max(0, math.floor((self.inner.w - row_w) / 2))
        for _j, cell in ipairs(row) do
            cells[#cells + 1] = {
                x = ox + cell.rel_x, y = y, w = cell.w, h = cell.h,
                label = cell.label, region = cell.region,
            }
        end
        y = y + base_key_height + key_padding
    end
    self.cells = cells
end

function Layout:buildChrome()
    local ink = self.tok_ink
    local pad = math.max(8, math.floor(self.screen_w * 0.02))
    local reset_w = math.min(160, math.floor(self.screen_w * 0.28))
    local title_w = math.max(40, self.screen_w - self.margin * 2 - reset_w - 8)
    self.title_widget = Text.line("title", _("输入法布局"), { width = title_w })
    self.hint_widget = Text.line("caption",
        T(_("点键设分区 · 点缝隙换壁纸 · 当前 %1"), methodLabel(self.method_id or "pinyin")),
        { width = self.screen_w - self.margin * 2 })

    -- 右上角：恢复默认
    local rh = math.max(36, math.floor(self.top_h * 0.45))
    self.btn_reset = Geom:new{
        x = self.screen_w - self.margin - reset_w,
        y = math.floor(self.top_h * 0.15),
        w = reset_w, h = rh,
    }
    self.t_reset = Text.line("caption", _("恢复默认"), { width = reset_w, color = ink })

    local bh = math.max(44, math.floor(self.bot_h * 0.7))
    local by = self.screen_h - bh - math.floor((self.bot_h - bh) / 2)
    local gap = math.max(6, math.floor(pad * 0.6))
    local n = 4
    local bw = math.floor((self.screen_w - pad * 2 - gap * (n - 1)) / n)
    self.btn_bg = Geom:new{ x = pad, y = by, w = bw, h = bh }
    self.btn_layout = Geom:new{ x = pad + (bw + gap), y = by, w = bw, h = bh }
    self.btn_regions = Geom:new{ x = pad + (bw + gap) * 2, y = by, w = bw, h = bh }
    self.btn_done = Geom:new{ x = pad + (bw + gap) * 3, y = by, w = bw, h = bh }
    self.t_bg = Text.line("body", _("背景"), { width = bw, color = ink })
    self.t_layout = Text.line("body", _("布局"), { width = bw, color = ink })
    self.t_regions = Text.line("body", _("分区"), { width = bw, color = ink })
    self.t_done = Text.line("body", _("完成"), { width = bw, color = ink })
end

function Layout:rebuildLayers()
    local item = imeItem()
    self.bg_layer = nil
    self._skin_cache = {}
    if type(item.src) == "string" and item.src ~= "" and self.kb then
        pcall(function()
            self.bg_layer = require("moonbeautify.render.bg").layer(
                item.src, self.kb.w, self.kb.h, nil, nil, item.focus)
        end)
    end
end

--- 同 src+尺寸只解码一次；46 键各造一层会把模拟器直接撑死。
function Layout:skinLayer(src, w, h, focus)
    if type(src) ~= "string" or src == "" then return nil end
    self._skin_cache = self._skin_cache or {}
    local key = src .. ":" .. tostring(w) .. "x" .. tostring(h)
    local hit = self._skin_cache[key]
    if hit ~= nil then return hit ~= false and hit or nil end
    local layer = nil
    pcall(function()
        layer = require("moonbeautify.render.bg").layer(src, w, h, nil, nil, focus)
    end)
    self._skin_cache[key] = layer or false
    return layer
end

function Layout:drawButton(bb, ox, r, label)
    if not r then return end
    local page, ink = self.color_page, self.color_ink
    fill(bb, ox + r.x, r.y, r.w, r.h, page)
    local bw = 2
    fill(bb, ox + r.x, r.y, r.w, bw, ink)
    fill(bb, ox + r.x, r.y + r.h - bw, r.w, bw, ink)
    fill(bb, ox + r.x, r.y, bw, r.h, ink)
    fill(bb, ox + r.x + r.w - bw, r.y, bw, r.h, ink)
    if label then
        local lh, lw = 24, nil
        if type(label.getSize) == "function" then
            local ok, sz = pcall(function() return label:getSize() end)
            if ok and sz then
                if sz.h then lh = sz.h end
                if sz.w then lw = sz.w end
            end
        end
        local ty = r.y + math.max(2, math.floor((r.h - lh) / 2))
        local tx = ox + r.x + math.max(2, math.floor((r.w - (lw or r.w)) / 2))
        label:paintTo(bb, tx, ty)
    end
end

function Layout:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    fill(bb, x, y, self.screen_w, self.screen_h, self.color_page)

    if self.title_widget then
        self.title_widget:paintTo(bb, x + self.margin, y + math.floor(self.top_h * 0.15))
    end
    self:drawButton(bb, x, self.btn_reset, self.t_reset)
    if self.hint_widget then
        self.hint_widget:paintTo(bb, x + self.margin, y + math.floor(self.top_h * 0.55))
    end

    local kb = self.kb
    local ink, page, accent = self.color_ink, self.color_page, self.color_accent
    fill(bb, x + kb.x, y + kb.y, kb.w, kb.h, page)
    if self.bg_layer then
        self.bg_layer:paintTo(bb, x + kb.x, y + kb.y)
        local veil = tonumber(imeItem().veil) or 0
        if veil > 0 then
            pcall(function() bb:lightenRect(x + kb.x, y + kb.y, kb.w, kb.h, veil / 100) end)
        end
    end
    local lw = 2
    fill(bb, x + kb.x, y + kb.y, kb.w, lw, ink)
    fill(bb, x + kb.x, y + kb.y + kb.h - lw, kb.w, lw, ink)
    fill(bb, x + kb.x, y + kb.y, lw, kb.h, ink)
    fill(bb, x + kb.x + kb.w - lw, y + kb.y, lw, kb.h, ink)

    local item = imeItem()
    local alpha = tonumber(item.key_alpha) or 0
    for _i, cell in ipairs(self.cells) do
        local cx, cy = x + cell.x, y + cell.y
        local skin = Regions.skin(item, cell.region)
        if skin then
            local layer = self:skinLayer(skin.src, cell.w, cell.h, skin.focus)
            if layer then layer:paintTo(bb, cx, cy) end
            if alpha > 0 then
                local white = (100 - alpha) / 100 * 0.4
                if white > 0 then pcall(function() bb:lightenRect(cx, cy, cell.w, cell.h, white) end) end
            end
        else
            fill(bb, cx, cy, cell.w, cell.h, page)
            if alpha > 0 then
                local white = (100 - alpha) / 100 * 0.4
                if white > 0 then pcall(function() bb:lightenRect(cx, cy, cell.w, cell.h, white) end) end
            end
        end
        local border = skin and accent or ink
        fill(bb, cx, cy, cell.w, 1, border)
        fill(bb, cx, cy + cell.h - 1, cell.w, 1, border)
        fill(bb, cx, cy, 1, cell.h, border)
        fill(bb, cx + cell.w - 1, cy, 1, cell.h, border)
        -- 文字按真实宽高在键内水平+垂直居中（不要 width=键宽再左对齐画）
        local label = cell._label
        if not label then
            label = Text.line("caption", cell.label)
            cell._label = label
            local lh, lw = 18, nil
            if type(label.getSize) == "function" then
                local ok, sz = pcall(function() return label:getSize() end)
                if ok and sz then
                    if sz.h then lh = sz.h end
                    if sz.w then lw = sz.w end
                end
            end
            cell._label_h, cell._label_w = lh, lw
        end
        local lh, lw = cell._label_h or 18, cell._label_w
        local tx = cx + math.max(0, math.floor((cell.w - (lw or cell.w)) / 2))
        local ty = cy + math.max(0, math.floor((cell.h - lh) / 2))
        label:paintTo(bb, tx, ty)
    end

    self:drawButton(bb, x, self.btn_bg, self.t_bg)
    self:drawButton(bb, x, self.btn_layout, self.t_layout)
    self:drawButton(bb, x, self.btn_regions, self.t_regions)
    self:drawButton(bb, x, self.btn_done, self.t_done)
end

function Layout:refresh()
    self:rebuildLayers()
    for _i, cell in ipairs(self.cells or {}) do
        cell._label, cell._label_h, cell._label_w = nil, nil, nil
    end
    UIManager:setDirty(self, "ui")
end

function Layout:pickRegion(region)
    local desktop = self.desktop
    local item = imeItem()
    local cur = Regions.skin(item, region)
    local title = Regions.LABEL[region] or region
    pickPath(desktop, cur and cur.src or nil, true, function(path)
        saveIme(desktop, function(bg)
            Regions.setSkin(bg, region, path, cur and cur.focus or nil)
        end)
        Common.toast(T(_("已设%1皮肤"), title))
        self:refresh()
    end)
end

function Layout:openBgSettings()
    local desktop = self.desktop
    local self_ref = self
    Settings:new{
        title = _("键盘背景"),
        items = function(page)
            local item = imeItem()
            local focus = type(item.focus) == "table"
                and require("moonbeautify.widgets.view").focusOf(item.focus) or nil
            return {
                {
                    title = _("背景图"),
                    status = nameOf(item.src) or _("未选择"),
                    chevron = true,
                    callback = function()
                        pickPath(desktop, item.src, true, function(path)
                            saveIme(desktop, function(bg) bg.src = path end)
                            self_ref:refresh()
                            pcall(function() page:updateView() end)
                        end)
                        return false
                    end,
                },
                {
                    title = _("取景选区"),
                    status = focusText(focus),
                    chevron = true,
                    callback = function()
                        chooseFocus(item.src, focus, function(v)
                            saveIme(desktop, function(bg)
                                bg.focus = { x = v.x, y = v.y, w = v.w, h = v.h }
                            end, true)
                            self_ref:refresh()
                            pcall(function() page:updateView() end)
                        end, desktop)
                        return false
                    end,
                },
                {
                    title = _("内容提亮"),
                    status = (tonumber(item.veil) or 0) .. "%",
                    chevron = true,
                    callback = function()
                        Spin:new{
                            title = _("内容提亮"),
                            fields = { {
                                value = tonumber(item.veil) or 0, min = 0, max = 90, step = 10,
                                format = function(v) return v .. "%" end,
                            } },
                            callback = function(v)
                                saveIme(desktop, function(bg) bg.veil = math.floor(v) end)
                                self_ref:refresh()
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
                        saveIme(desktop, function(bg) bg.src, bg.focus, bg.veil = nil, nil, nil end)
                        self_ref:refresh()
                        pcall(function() page:updateView() end)
                    end,
                },
            }
        end,
    }:show()
end

--- 分区列表：每区一行，点进去换图 / 清掉
function Layout:openRegionList()
    local desktop = self.desktop
    local self_ref = self
    Settings:new{
        title = _("按键分区"),
        items = function(page)
            -- 不用 { note = ... }：Row.note 会给「有图标的行」留图标槽，
            -- 这批分区行没图标，说明文字就会空出一截。五行标题已经说清了。
            local item = imeItem()
            local rows = {}
            for _i, id in ipairs(Regions.ORDER) do
                local skin = Regions.skin(item, id)
                rows[#rows + 1] = {
                    title = Regions.LABEL[id],
                    status = nameOf(skin and skin.src) or _("未设置"),
                    chevron = true,
                    callback = function()
                        Settings:new{
                            title = Regions.LABEL[id],
                            items = function(sub)
                                local cur = Regions.skin(imeItem(), id)
                                return {
                                    {
                                        title = _("选一张图…"),
                                        status = nameOf(cur and cur.src) or _("未选择"),
                                        chevron = true,
                                        callback = function()
                                            pickPath(desktop, cur and cur.src or nil, true, function(path)
                                                saveIme(desktop, function(bg)
                                                    Regions.setSkin(bg, id, path, cur and cur.focus or nil)
                                                end)
                                                self_ref:refresh()
                                                pcall(function() sub:updateView() end)
                                                pcall(function() page:updateView() end)
                                            end)
                                            return false
                                        end,
                                    },
                                    {
                                        title = _("取景选区"),
                                        status = focusText(cur and cur.focus),
                                        chevron = true,
                                        callback = function()
                                            local now = Regions.skin(imeItem(), id)
                                            chooseFocus(now and now.src, now and now.focus, function(v)
                                                saveIme(desktop, function(bg)
                                                    local src = now and now.src
                                                    if src then
                                                        Regions.setSkin(bg, id, src, { x = v.x, y = v.y, w = v.w, h = v.h })
                                                    end
                                                end, true)
                                                self_ref:refresh()
                                                pcall(function() sub:updateView() end)
                                                pcall(function() page:updateView() end)
                                            end, desktop)
                                            return false
                                        end,
                                    },
                                    {
                                        title = _("清除此区"),
                                        chevron = false,
                                        callback = function()
                                            saveIme(desktop, function(bg) Regions.setSkin(bg, id, nil) end)
                                            self_ref:refresh()
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
            return rows
        end,
    }:show()
end

function Layout:hitCell(px, py)
    for _i, cell in ipairs(self.cells) do
        if inside(px, py, cell) then return cell end
    end
    return nil
end

function Layout:switchLayout()
    local List = require("ui.themes.widgets.list")
    local self_ref = self
    List:new{
        title = _("键盘布局"),
        items = layoutItems(),
        current = self.method_id,
        centered = true,
        on_select = function(id)
            if not id or id == self_ref.method_id then return end
            self_ref.keys, self_ref.method_id = loadKeys(id)
            self_ref:layoutKeys()
            for _i, cell in ipairs(self_ref.cells or {}) do
                cell._label, cell._label_h, cell._label_w = nil, nil, nil
                cell._skin_key, cell._skin_layer = nil, nil
            end
            self_ref:buildChrome()
            self_ref:rebuildLayers()
            UIManager:setDirty(self_ref, "ui")
        end,
    }:show()
end

function Layout:restoreDefault()
    saveIme(self.desktop, function(bg)
        for k in pairs(bg) do bg[k] = nil end
    end)
    local c = Store.conf()
    c.ime_skin_name = nil
    Store.save()
    self:refresh()
    Common.toast(_("已恢复默认"))
end

function Layout:onLayoutTap(_arg, ges)
    if self._closed then return true end
    if not ges or not ges.pos then return true end
    local px, py = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    if inside(px, py, self.btn_done) then self:close() return true end
    if inside(px, py, self.btn_reset) then self:restoreDefault() return true end
    if inside(px, py, self.btn_layout) then self:switchLayout() return true end
    if inside(px, py, self.btn_bg) then self:openBgSettings() return true end
    if inside(px, py, self.btn_regions) then self:openRegionList() return true end
    local cell = self:hitCell(px, py)
    if cell then
        self:pickRegion(cell.region)
        return true
    end
    if inside(px, py, self.kb) then
        local item = imeItem()
        pickPath(self.desktop, item.src, true, function(path)
            saveIme(self.desktop, function(bg) bg.src = path end)
            self:refresh()
        end)
        return true
    end
    return true
end

local M = {}

---@param desktop table|nil
---@param parent table|nil
function M.show(desktop, parent)
    Layout:new{
        desktop = desktop,
        close_callback = function()
            if parent then pcall(function() parent:updateView() end) end
        end,
    }:show()
end

return M
