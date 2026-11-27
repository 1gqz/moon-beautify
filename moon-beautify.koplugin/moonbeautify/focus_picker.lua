--[[--
取景选区拖拽：全屏显示预览图，图上拖一个选区框（可移动 / 拉四角改大小），
图片可缩放，松手后点「确定」把选区 {x,y,w,h}（0..1，相对原图）回调。

安全要点：
- 预览图复用 moonbeautify.bg 的 layer（blit 到 framebuffer，项目验证过），
  不自建 BB8A 做跨类型 blit；选区框只用 framebuffer 的 paintRect 画线。
- 缩放只改变预览显示尺寸（整数倍放大解码），选区坐标始终相对原图 0..1。

交互：
- 手指落在框内拖动 = 移动选区；落在四角小方块 = 拉角改大小；点框外 = 移动选区中心到此处
- 双指缩放 / 底部 + − 按钮 = 放大缩小预览（便于精确选）
- 底部「取消」「确定」：确定回调选区，取消直接关；返回键 = 取消

@module moonbeautify.focus_picker
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local _ = require("gettext")

local Screen = Device.screen

-- 老款 Kindle（非 MTK 平台）电子纸控制器在连续 "ui" 快刷大面积图片时残影明显，
-- 手势结束时补一次整屏刷新；新平台保持原样。
local needEndRefresh = Device:isKindle() and not Device:isMTK()

local function endRefresh(widget)
    if needEndRefresh then
        UIManager:setDirty(widget, "full")
    end
end

local time = require("ui/time")

local DRAG_INTERVAL = 0.25
local last_drag_refresh = time.now() - time.s(DRAG_INTERVAL)

local function dragDirty(widget)
    if not needEndRefresh then
        UIManager:setDirty(widget, "ui")
        return
    end
    -- 老 Kindle 上 ui/partial/flashpartial 都压不住整屏极性交替；
    -- 只有 full 能可靠重置波形。做节流，避免每个触摸事件都全刷。
    local now = time.now()
    if time.to_s(now - last_drag_refresh) < DRAG_INTERVAL then return end
    last_drag_refresh = now
    UIManager:setDirty(widget, "full")
end

local Picker = Modal:extend{
    name = "moonbeautify_focus_picker",
    covers_fullscreen = true,
    dismissable = true,
    swipe_dismiss = "off",
}

local MIN_W = 0.05
local MAX_ZOOM = 4
local MAX_DIM = 4096

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- 点是否在矩形内
local function inside(px, py, r)
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

function Picker:init()
    Modal.init(self)
    local t = Theme.current()
    self.color_page = Theme.color(t.color.page)
    self.color_ink = Theme.color(t.color.ink)
    self.color_accent = Theme.color(t.color.accent or t.color.ink)
    -- 按钮配色令牌：普通按钮深字浅底，确定按钮白字深底
    self.tok_ink = t.color.ink
    self.tok_page = t.color.page

    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = math.max(8, math.floor(math.min(sw, sh) * 0.03))
    local top_h = math.max(36, math.floor(sh * 0.07))
    local bot_h = math.max(140, math.floor(sh * 0.23))
    local avail_w = math.max(1, sw - margin * 2)
    local avail_h = math.max(1, sh - top_h - bot_h)
    self.screen_w, self.screen_h = sw, sh
    self.top_h, self.bot_h = top_h, bot_h
    self.margin = margin

    self.iw, self.ih = nil, nil
    if type(self.path) == "string" and self.path ~= "" then
        self.iw, self.ih = require("moonbeautify.bg").nativeSize(self.path)
        if self.iw and (self.iw < 1 or self.ih < 1) then self.iw, self.ih = nil, nil end
    end
    self.zoom = 1
    self.touching = false
    self.drag = nil -- "move" | "nw" | "ne" | "sw" | "se" | nil

    -- 选区初始化：优先传入的 focus，否则整图
    local c = self.current
    if type(c) == "table" and tonumber(c.w) and tonumber(c.h) and c.w > 0 and c.h > 0 then
        self.focus = {
            x = clamp(tonumber(c.x) or 0, 0, 1),
            y = clamp(tonumber(c.y) or 0, 0, 1),
            w = clamp(tonumber(c.w) or 1, MIN_W, 1),
            h = clamp(tonumber(c.h) or 1, MIN_W, 1),
        }
        self.focus.x = math.min(self.focus.x, 1 - self.focus.w)
        self.focus.y = math.min(self.focus.y, 1 - self.focus.h)
    else
        self.focus = { x = 0, y = 0, w = 1, h = 1 }
    end

    self.title_widget = Text.line("title", _("取景选区 · 拖动/拉角选区域"), { width = avail_w })
    self.hint_widget = Text.line("caption", _("框内拖动=移动 · 拉角=缩放 · 点框外=移到此处"), { width = avail_w })

    local full = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events.TapModal = nil
    self.ges_events.SwipeModal = nil
    -- 自己的 tap handler：按钮点击在这里处理并消费事件，
    -- 绝不让 tap 穿透到全屏弹窗底下的桌面底栏。
    self.ges_events.PickTap = { GestureRange:new{ ges = "tap", range = full } }
    self.ges_events.PickTouch = { GestureRange:new{ ges = "touch", range = full } }
    self.ges_events.PickPan = {
        GestureRange:new{ ges = "pan", range = full },
        GestureRange:new{ ges = "hold_pan", range = full },
    }
    self.ges_events.PickRelease = {}
    for _i, ges in ipairs({ "pan_release", "hold_release" }) do
        self.ges_events.PickRelease[#self.ges_events.PickRelease + 1] =
            GestureRange:new{ ges = ges, range = full }
    end
    self.ges_events.PickPinch = { GestureRange:new{ ges = "pinch", range = full } }

    self:rebuildImage()
    self:buildButtons()
end

--- 按当前 zoom 重建预览图层与显示矩形
function Picker:rebuildImage()
    if not (self.iw and self.ih) or type(self.path) ~= "string" or self.path == "" then
        self.layer = nil
        self.img = Geom:new{ x = self.margin, y = self.top_h,
            w = self.screen_w - self.margin * 2,
            h = self.screen_h - self.top_h - self.bot_h }
        return
    end
    local avail_w = self.screen_w - self.margin * 2
    local avail_h = self.screen_h - self.top_h - self.bot_h
    local scale = math.min(avail_w / self.iw, avail_h / self.ih) * self.zoom
    -- 放大到 4 倍时预览可能超过 4096 像素边长，按上限截住，避免解出巨图撑爆内存
    scale = math.min(scale, MAX_DIM / self.iw, MAX_DIM / self.ih)
    local dw = math.max(1, math.floor(self.iw * scale))
    local dh = math.max(1, math.floor(self.ih * scale))
    local ok, layer = pcall(function()
        if needEndRefresh then
            -- 老 Kindle 上 bg 的跨类型 blit 回退会把透明区画成黑块；
            -- deco 先规范化成 BB8A 再混合，和花边图走的是同一条安全路径。
            return require("moonbeautify.deco").frame(self.path, dw, dh)
        end
        return require("moonbeautify.bg").layer(self.path, dw, dh, "stretch", nil)
    end)
    self.layer = ok and layer or nil
    self.img = Geom:new{
        x = math.floor((self.screen_w - dw) / 2),
        y = self.top_h + math.floor((avail_h - dh) / 2),
        w = dw, h = dh,
    }
end

function Picker:buildButtons()
    local pad = math.max(8, math.floor(self.screen_w * 0.02))
    local bh = math.max(44, math.floor(self.bot_h * 0.42))
    local by = self.screen_h - bh - pad
    -- 四个按钮等宽同一行：取消 / 缩小 / 放大 / 确定
    local gap = pad
    local bw = math.floor((self.screen_w - pad * 2 - gap * 3) / 4)
    self.btn_cancel   = Geom:new{ x = pad, y = by, w = bw, h = bh }
    self.btn_zoom_out = Geom:new{ x = pad + (bw + gap), y = by, w = bw, h = bh }
    self.btn_zoom_in  = Geom:new{ x = pad + (bw + gap) * 2, y = by, w = bw, h = bh }
    self.btn_ok       = Geom:new{ x = pad + (bw + gap) * 3, y = by, w = bw, h = bh }
    -- 统一样式：浅底深字 + 细边框
    local ink_tok = self.tok_ink
    self.t_cancel   = Text.line("body", _("取消"), { width = bw, color = ink_tok })
    self.t_zoom_out = Text.line("body", _("缩小"), { width = bw, color = ink_tok })
    self.t_zoom_in  = Text.line("body", _("放大"), { width = bw, color = ink_tok })
    self.t_ok       = Text.line("body", _("确定"), { width = bw, color = ink_tok })
end

--- 选区(0..1) -> 屏幕像素矩形
function Picker:focusRect()
    local im = self.img
    local f = self.focus
    return Geom:new{
        x = im.x + f.x * im.w,
        y = im.y + f.y * im.h,
        w = f.w * im.w,
        h = f.h * im.h,
    }
end

--- 屏幕像素 -> 选区(0..1)，夹进 [0,1]
function Picker:pxToFocus(px, py)
    local im = self.img
    if im.w <= 0 or im.h <= 0 then return self.focus.x, self.focus.y end
    local x = clamp((px - im.x) / im.w, 0, 1)
    local y = clamp((py - im.y) / im.h, 0, 1)
    return x, y
end

local HANDLE = 22
function Picker:hitHandle(px, py, r)
    local hz = HANDLE
    if math.abs(px - r.x) <= hz and math.abs(py - r.y) <= hz then return "nw" end
    if math.abs(px - (r.x + r.w)) <= hz and math.abs(py - r.y) <= hz then return "ne" end
    if math.abs(px - r.x) <= hz and math.abs(py - (r.y + r.h)) <= hz then return "sw" end
    if math.abs(px - (r.x + r.w)) <= hz and math.abs(py - (r.y + r.h)) <= hz then return "se" end
    return nil
end

function Picker:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.screen_w, self.screen_h, Blitbuffer.Color8(self.color_page))

    if self.title_widget then self.title_widget:paintTo(bb, x + self.margin, y + math.floor(self.top_h / 3)) end
    -- 提示文字放在图片实际底边下方（img 在可用区里垂直居中，底边是 img.y+img.h，不是 top_h+img.h），
    -- 且贴住按钮区上沿，避免被图片盖住。
    if self.hint_widget then
        local img_bottom = self.img.y + self.img.h
        local btn_top = self.btn_cancel and self.btn_cancel.y or (self.screen_h - self.bot_h)
        local hh = 24
        if type(self.hint_widget.getSize) == "function" then
            local ok, sz = pcall(function() return self.hint_widget:getSize() end)
            if ok and sz and sz.h then hh = sz.h end
        end
        -- 提示放在图片底边与按钮上沿之间，居中；不压按钮、不压图片
        local hy = math.max(img_bottom + 4, btn_top - hh - 6)
        self.hint_widget:paintTo(bb, x + self.margin, y + hy)
    end

    if self.layer then
        self.layer:paintTo(bb, x + self.img.x, y + self.img.y)
    else
        local msg = Text.line("caption", _("（无预览图，仅设置选区比例）"), { width = self.img.w })
        msg:paintTo(bb, x + self.img.x + math.floor(self.img.w / 6), y + self.img.y + math.floor(self.img.h / 2))
    end

    -- 选区框 + 四角手柄
    local r = self:focusRect()
    local ink = Blitbuffer.Color8(self.color_accent)
    local lw = 3
    bb:paintRect(x + r.x, y + r.y, r.w, lw, ink)
    bb:paintRect(x + r.x, y + r.y + r.h - lw, r.w, lw, ink)
    bb:paintRect(x + r.x, y + r.y, lw, r.h, ink)
    bb:paintRect(x + r.x + r.w - lw, y + r.y, lw, r.h, ink)
    local hz = math.max(8, math.floor(HANDLE / 2))
    for _, hx in ipairs({ r.x, r.x + r.w }) do
        for _, hy in ipairs({ r.y, r.y + r.h }) do
            bb:paintRect(x + hx - hz, y + hy - hz, hz * 2, hz * 2, ink)
        end
    end

    self:drawButton(bb, x, self.btn_cancel, self.t_cancel)
    self:drawButton(bb, x, self.btn_zoom_out, self.t_zoom_out)
    self:drawButton(bb, x, self.btn_zoom_in, self.t_zoom_in)
    self:drawButton(bb, x, self.btn_ok, self.t_ok)
end

--- 统一按钮样式：浅底深字 + 细边框。
function Picker:drawButton(bb, ox, r, label)
    if not r then return end
    local page = Blitbuffer.Color8(self.color_page)
    local ink = Blitbuffer.Color8(self.color_ink)
    bb:paintRect(ox + r.x, r.y, r.w, r.h, page)
    local bw = 2
    bb:paintRect(ox + r.x, r.y, r.w, bw, ink)
    bb:paintRect(ox + r.x, r.y + r.h - bw, r.w, bw, ink)
    bb:paintRect(ox + r.x, r.y, bw, r.h, ink)
    bb:paintRect(ox + r.x + r.w - bw, r.y, bw, r.h, ink)
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
        -- 水平居中：有实际文字宽度就按它算，取不到则退回按钮宽度。
        local tx = ox + r.x + math.max(2, math.floor((r.w - (lw or r.w)) / 2))
        label:paintTo(bb, tx, ty)
    end
end

--- tap 在手指抬起时触发，且此时弹窗还在栈顶。按钮点击放这里处理，
--- 返回 true 把事件吃掉，避免穿透到弹窗底下的桌面底栏。
function Picker:onPickTap(_arg, ges)
    if self._closed then return true end
    if not ges or not ges.pos then return true end
    local px, py = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    if inside(px, py, self.btn_ok) then self:commit()
    elseif inside(px, py, self.btn_cancel) then self:close()
    elseif inside(px, py, self.btn_zoom_in) then self:zoomBy(1)
    elseif inside(px, py, self.btn_zoom_out) then self:zoomBy(-1)
    end
    return true -- 始终消费 tap，绝不穿透
end

function Picker:onPickTouch(_arg, ges)
    if not ges or not ges.pos then return true end
    local px, py = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    -- 按钮区域：不在 touch 阶段动作（否则 tap 会穿透到底栏）。
    -- 只标住目标，等 tap 阶段处理；这里不进入拖框。
    if inside(px, py, self.btn_ok) or inside(px, py, self.btn_cancel)
        or inside(px, py, self.btn_zoom_in) or inside(px, py, self.btn_zoom_out) then
        self.touching = false
        self.drag = nil
        return true
    end
    local r = self:focusRect()
    self.drag = self:hitHandle(px, py, r) or "move"
    if self.drag == "move" and not inside(px, py, r) then
        -- 点框外：把选区中心移到此处
        local f = self.focus
        local cx, cy = self:pxToFocus(px, py)
        f.x = clamp(cx - f.w / 2, 0, 1 - f.w)
        f.y = clamp(cy - f.h / 2, 0, 1 - f.h)
        self.drag_start = { x = px, y = py, fx = f.x, fy = f.y }
    else
        self.drag_start = { x = px, y = py, fx = self.focus.x, fy = self.focus.y,
            fw = self.focus.w, fh = self.focus.h }
    end
    self.touching = true
    dragDirty(self)
    return true
end

function Picker:onPickPan(_arg, ges)
    if not self.touching or not ges or not ges.pos then return true end
    local px, py = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    local ds = self.drag_start
    local im = self.img
    if not ds or im.w <= 0 or im.h <= 0 then return true end
    local f = self.focus
    local dx = (px - ds.x) / im.w
    local dy = (py - ds.y) / im.h
    if self.drag == "move" then
        f.x = clamp(ds.fx + dx, 0, 1 - f.w)
        f.y = clamp(ds.fy + dy, 0, 1 - f.h)
    else
        -- 拉角：左/右改 w、上/下改 h，另一角固定
        local x0, y0, x1, y1
        if self.drag == "nw" then x0, y0, x1, y1 = ds.fx + ds.fw, ds.fy + ds.fh, ds.fx + dx, ds.fy + dy
        elseif self.drag == "ne" then x0, y0, x1, y1 = ds.fx, ds.fy + ds.fh, ds.fx + ds.fw + dx, ds.fy + dy
        elseif self.drag == "sw" then x0, y0, x1, y1 = ds.fx + ds.fw, ds.fy, ds.fx + dx, ds.fy + ds.fh + dy
        else x0, y0, x1, y1 = ds.fx, ds.fy, ds.fx + ds.fw + dx, ds.fy + ds.fh + dy end
        local nx = math.min(x0, x1)
        local ny = math.min(y0, y1)
        local nw = math.max(MIN_W, math.abs(x1 - x0))
        local nh = math.max(MIN_W, math.abs(y1 - y0))
        nx = clamp(nx, 0, 1 - nw)
        ny = clamp(ny, 0, 1 - nh)
        f.x, f.y, f.w, f.h = nx, ny, math.min(nw, 1 - nx), math.min(nh, 1 - ny)
    end
    dragDirty(self)
    return true
end

function Picker:onPickRelease(_arg, ges)
    if self.touching then self.touching = false end
    self.drag = nil
    endRefresh(self)
    return true
end

function Picker:zoomBy(dir)
    local old = self.zoom
    if dir > 0 then self.zoom = math.min(MAX_ZOOM, old * 1.5)
    else self.zoom = math.max(1, old / 1.5) end
    if math.abs(self.zoom - old) > 0.001 then
        -- 缩放改变了图片显示矩形，进行中的拖拽基准已失效，取消它避免选区跳位
        self.touching, self.drag, self.drag_start = false, nil, nil
        self:rebuildImage()
        dragDirty(self)
        endRefresh(self)
    end
end

function Picker:onPickPinch(_arg, ges)
    -- pinch 手势：ges.scale > 1 放大，< 1 缩小（不同版本可能字段名不同，兼容）
    local s = ges and (ges.scale or ges.zoom)
    if not s then return true end
    self.zoom = clamp(self.zoom * s, 1, MAX_ZOOM)
    -- 缩放改变了图片显示矩形，取消进行中的拖拽，避免松手时选区跳位
    self.touching, self.drag, self.drag_start = false, nil, nil
    self:rebuildImage()
    dragDirty(self)
    endRefresh(self)
    return true
end

function Picker:commit()
    if self._done then return end
    self._done = true
    local x, y, w, h = self.focus.x, self.focus.y, self.focus.w, self.focus.h
    local cb = self.on_select
    self.on_select = nil
    -- 先关弹窗再回调（项目里 IconPicker:choose 的写法）。
    -- apply 只落盘、不做整栈 repaint，配合这里避免把底下的拓展/设置页重新画出来。
    self:close()
    if cb then cb(x, y, w, h) end
end

function Picker:close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self, "ui")
    -- 每一档缩放都解码过一张预览，关窗后不再需要
    require("moonbeautify.bg").clear()
    require("moonbeautify.deco").clear()
end

function Picker:onSetRotationMode()
    return true
end

-- 返回键 = 取消（只关窗，不回调选区）
function Picker:dismiss()
    self:close()
end

return Picker
