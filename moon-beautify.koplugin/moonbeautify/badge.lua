--[[--
拟真吧唧的合成器（圆形 / 圆角 / 直角）。

分层：
  底图 base  —— 旋转/裁切好的照片 + 金属倒角 + 侧影 + 用户叠加素材
                + 光环（双线环）
  特效层     —— 每帧只画几十个像素（细闪/雨滴/星星，见 moonbeautify.effects）

形状统一用「圆角矩形的有符号距离」算：
  circle → 圆角半径 = 边长/2（退化成圆）
  round  → 圆角半径 = 边长 * 0.16
  square → 圆角半径 = 0（直角）
所以三种形状共用一套倒角、侧影、裁切逻辑，只是圆角不同。

base 只在「角度变了 / 尺寸变了 / 素材变了」时重算；每帧的开销是
「一次 blitFrom + 几百次 setPixel」，所以转动可以做得很细（每帧几度），
不是原来的 90° 跳一下。

@module moonbeautify.badge
--]]

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")

local Effects = require("moonbeautify.effects")

local C8 = Blitbuffer.Color8

local Badge = {}

-- 动画节拍（秒）。墨水屏再快没意义，慢一点残影反而少
Badge.TICK = 0.8

-- 光环样式 → 显示名（设置界面用），只保留双线
Badge.RING_LABEL = { double = "双线" }

--- 形状 → 圆角半径
---@param shape string "circle" | "round" | "square"
---@param d number 边长
---@return number
local function cornerOf(shape, d)
    if shape == "circle" then return d / 2 end
    if shape == "round" then return math.max(2, d * 0.16) end
    return 0
end
Badge.cornerOf = cornerOf

--- 圆角矩形的有符号距离（<= 0 在内部）
---@param w number
---@param h number
---@param rc number 圆角半径
---@param x number
---@param y number
---@return number
local function sdf(w, h, rc, x, y)
    local hw, hh = w / 2, h / 2
    local px, py = x + 0.5 - hw, y + 0.5 - hh
    local dx, dy = math.abs(px) - (hw - rc), math.abs(py) - (hh - rc)
    local ox, oy = math.max(dx, 0), math.max(dy, 0)
    return math.sqrt(ox * ox + oy * oy) + math.min(math.max(dx, dy), 0) - rc
end



--- 取源图灰度（越界夹边）
local function sampleGray(sbb, x, y)
    local w, h = sbb:getWidth(), sbb:getHeight()
    if x < 0 then x = 0 elseif x > w - 1 then x = w - 1 end
    if y < 0 then y = 0 elseif y > h - 1 then y = h - 1 end
    return sbb:getPixel(math.floor(x), math.floor(y)):getColor8().a
end



--- 把用户素材按 alpha 叠上去（只叠在形状内）
---@param bb table 目标
---@param w number 素材（也就是吧唧本体）边长
---@param h number
---@param path string|nil
---@param rc number 圆角半径：素材也跟着裁成同样的形状
---@param ox number|nil 吧唧本体在目标位图里的横向偏移（开外圈/装饰时本体往里缩）
---@param oy number|nil 纵向偏移
local function blendOverlay(bb, w, h, path, rc, ox, oy)
    if type(path) ~= "string" or path == "" then return end
    ox, oy = ox or 0, oy or 0
    local obb = RenderImage:renderImageFile(path, false, w, h)
    if not obb then return end
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if sdf(w, h, rc, x, y) <= 0 then
                local px = obb:getPixel(x, y)
                -- 源图可能是 Color8（无 alpha）或 Color8A（带 alpha，字段 .a=亮度 / .alpha=透明度）
                local ca = px.getColor8A and px:getColor8A() or px
                local alpha = ca.alpha
                if alpha then
                    if alpha > 6 then
                        local dst = bb:getPixel(x + ox, y + oy):getColor8().a
                        bb:setPixel(x + ox, y + oy, C8(math.floor(dst + (ca.a - dst) * alpha / 255)))
                    end
                else
                    -- 没有透明通道：直接按亮度覆盖
                    bb:setPixel(x + ox, y + oy, C8(px:getColor8().a))
                end
            end
        end
    end
end



--- 外圈环墨色（墨水屏友好：中灰偏深，既显眼又不刺眼）
local RING_INK = 72

--- 光环把吧唧本体往里缩多少：返回内缩边距
---@param w number 控件边长
---@param ring string|boolean|nil
---@return number
local function marginOf(w, ring)
    local m = 0
    if ring then m = math.floor(w * 0.07) end
    return (w - m * 2 >= 24) and m or 0
end

--- 把一个像素画进位图（目标 BB8A，写 C8 会转成不透明像素）
local function putPixel(bb, w, h, x, y, ink)
    x, y = math.floor(x), math.floor(y)
    if x < 0 or x >= w or y < 0 or y >= h then return end
    bb:setPixel(x, y, C8(ink))
end

--- 1px 细环（圆）：只画 |距离 - r| < 0.9 的像素
local function thinCircle(bb, w, h, cx, cy, r)
    local k = math.ceil(r) + 2
    for yy = -k, k do
        for xx = -k, k do
            local d = math.sqrt(xx * xx + yy * yy)
            if math.abs(d - r) < 0.9 then
                putPixel(bb, w, h, cx + xx, cy + yy, RING_INK)
            end
        end
    end
end

--- 圆角矩形描边（外扩 p 像素的圆角边框）
local function ringRect(bb, w, h, p, rc)
    local ow, oh = w - p * 2, h - p * 2
    if ow < 8 or oh < 8 then return end
    local orc = cornerOf("round", math.min(ow, oh))
    if rc == 0 then orc = 0 end
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local sd = sdf(ow, oh, orc, x - p, y - p)
            if math.abs(sd) < 0.8 then
                putPixel(bb, w, h, x, y, RING_INK)
            end
        end
    end
end

--- 光环：圆形画双线环；圆角 / 直角画外扩的双层描边
---@param bb table
---@param w number
---@param h number
---@param di number 本体边长
---@param margin number 内缩边距
---@param shape string
local function paintRing(bb, w, h, di, margin, shape)
    local cx, cy = w / 2, h / 2
    local band = (w - di) / 2

    if shape == "circle" then
        local inner_r = di / 2
        -- 双线环
        thinCircle(bb, w, h, cx, cy, inner_r + band * 0.40)
        thinCircle(bb, w, h, cx, cy, inner_r + band * 0.80)
    else
        -- 圆角 / 直角：外扩一圈的双层圆角矩形描边
        ringRect(bb, w, h, math.max(2, margin * 0.5), cornerOf(shape, di))
        ringRect(bb, w, h, math.max(4, margin * 0.9), cornerOf(shape, di))
    end
end

--- 底图：照片（可旋转）+ 倒角 + 侧影 + 叠加素材 + 光环
--- 用 BB8A：没画到的角落 alpha=0，paintTo 用 alphablitFrom 时透出壁纸
---@param sbb table 已经缩放到 w×h 的源图（静态图或动图的某一帧）
---@param w number
---@param h number
---@param angle number 弧度
---@param overlay string|nil
---@param shape string
---@param ring string|boolean|nil 光环开关
---@param own boolean|nil 是否要在算完后释放 sbb（静态图每次新建，动图帧是复用的）
---@return table|nil, number 位图, 本体边长
local function plateBase(sbb, w, h, angle, overlay, shape, ring, own)
    if not sbb then return nil end

    -- 开了光环时本体往里缩，让出一圈空间
    local margin = marginOf(w, ring)
    local di = w - margin * 2

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    local rc = cornerOf(shape, di)
    local cx, cy = margin + di / 2, margin + di / 2
    local ca, sa = math.cos(angle or 0), math.sin(angle or 0)

    for y = 0, h - 1 do
        local dy = y + 0.5 - cy
        for x = 0, w - 1 do
            local dx = x + 0.5 - cx
            local sd = sdf(di, di, rc, x - margin, y - margin)
            local v
            if sd <= 0 then
                v = sampleGray(sbb, dx * ca - dy * sa + cx, dx * sa + dy * ca + cy)
                -- 边缘渐暗 → 内圈亮线 → 外圈暗线，做出一圈金属倒角
                if sd > -5 then v = v - (sd + 5) * 3 end
                if sd > -1.1 then
                    v = 38
                elseif sd > -2.8 then
                    v = 232
                end
            else
                -- 侧影：同一个形状整体往右下偏 2/3 像素
                local sd2 = sdf(di, di, rc, x - margin - 2.0, y - margin - 3.0)
                if sd2 <= -1 then
                    v = 200
                elseif sd2 <= 0.6 then
                    v = 236
                end
            end
            if v then
                if v < 0 then v = 0 elseif v > 255 then v = 255 end
                bb:setPixel(x, y, C8(math.floor(v)))
            end
        end
    end

    blendOverlay(bb, di, di, overlay, rc, margin, margin)
    if ring then paintRing(bb, w, h, di, margin, shape) end
    if own then pcall(function() sbb:free() end) end
    return bb, di
end



local Painted = Widget:extend{}
Painted.is_badge = true

-- 动画：所有在屏上的吧唧共用一个节拍（声明在 Painted 之前，free() 要用）
local live = setmetatable({}, { __mode = "k" })
local running = false

function Painted:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.buf then
        -- 缓冲是 BB8A：没画到的角落 alpha=0，alphablitFrom 按透明度混合，
        -- 形状外的角落和吧唧周边（外圈环之外的空隙）都透出壁纸
        bb:alphablitFrom(self.buf, x, y, 0, 0, self.dimen.w, self.dimen.h)
    end
    self._screen = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    if self.animated then Badge.watch(self) end
end

function Painted:getSize() return self.dimen end

--- 被容器释放时（翻页 / 组件重建 / 退出桌面）停掉动画并释放位图，
--- 否则 tick 循环会一直对着已经不在屏幕上的旧坐标 setDirty（耗电 + 残影）。
function Painted:free()
    live[self] = nil
    self._screen = nil
    if self.buf then
        self.buf:free()
        self.buf = nil
    end
    if self.base then
        self.base:free()
        self.base = nil
        self.base_angle = nil
        self.base_frame = nil
        self.inner = nil
    end
    if self.frame_bbs then
        for _k, v in pairs(self.frame_bbs) do pcall(function() v:free() end) end
        self.frame_bbs = nil
    end
    if self.frames then
        pcall(function() self.frames:free() end)
        self.frames = nil
    end
end



--- 取当前该用的源图：动图取当前帧（解过的留着复用），静态图现解一张
---@param widget table
---@return table|nil bb, boolean own
local function sourceOf(widget)
    local w, h = widget.dimen.w, widget.dimen.h
    if widget.frames then
        local n = #widget.frames
        if n < 1 then return nil end
        local i = ((widget.frame or 1) - 1) % n + 1
        local cache = widget.frame_bbs
        if not cache then cache = {}; widget.frame_bbs = cache end
        local bb = cache[i]
        if not bb then
            -- 帧缓存上限：动图帧多了只留最近用到的，别把内存吃光
            local count = 0
            for _k in pairs(cache) do count = count + 1 end
            if count >= 24 then
                for k, v in pairs(cache) do
                    pcall(function() v:free() end)
                    cache[k] = nil
                end
            end
            local ok, got = pcall(widget.frames[i])
            if ok and got then
                bb = got
                cache[i] = got
            end
        end
        return bb, false
    end
    local ok, bb = pcall(function() return RenderImage:renderImageFile(widget.src, false, w, h) end)
    if ok and bb then return bb, true end
    return nil
end

--- 重算底图（角度或帧变了才真的算）
local function ensureBase(widget)
    local angle = widget.angle or 0
    local frame = widget.frames and (widget.frame or 1) or 0
    if widget.base and widget.base_angle == angle and (widget.base_frame or 0) == frame then return true end
    local sbb, own = sourceOf(widget)
    if not sbb then return false end
    local base, inner = plateBase(sbb, widget.dimen.w, widget.dimen.h, angle,
        widget.overlay, widget.shape, widget.ring, own)
    if not base then return false end
    if widget.base then pcall(function() widget.base:free() end) end
    widget.base, widget.base_angle, widget.inner, widget.base_frame = base, angle, inner, frame
    return true
end

--- 画一帧：底图 + 特效
local function compose(widget)
    if not ensureBase(widget) then return false end
    local w, h = widget.dimen.w, widget.dimen.h
    -- 本体往里缩了（光环），特效也要缩进本体范围内，别落在环上
    local di = widget.inner or w
    if not widget.buf then
        widget.buf = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    end
    widget.buf:blitFrom(widget.base, 0, 0, 0, 0, w, h)
    if widget.effects then
        local shape
        if widget.shape == "circle" then
            shape = { cx = w / 2, cy = h / 2, r = di / 2 - 1 }
        elseif widget.shape == "round" then
            shape = { rect = true, rc = cornerOf("round", di) }
        else
            shape = { rect = true, rc = 0 }
        end
        Effects.paint(widget.buf, w, h, widget.effects, widget.phase or 0, shape)
    end
    return true
end

local function tick()
    running = false
    local any
    for w in pairs(live) do
        if w._screen then
            any = true
            w.phase = ((w.phase or 0) + Badge.TICK / 6) % 1
            if w.period and w.period > 0 then
                w.angle = ((w.angle or 0) + 2 * math.pi * Badge.TICK / w.period) % (2 * math.pi)
            end
            -- 动图：每个节拍换一帧（墨水屏上 0.8 秒一帧，够用也不拖影）
            if w.frames and #w.frames > 1 then
                w.frame = ((w.frame or 1) % #w.frames) + 1
            end
            if compose(w) then
                -- KOReader 的 setDirty(widget, mode, region, dither)：region 必须是 Geom。
                -- "all" 把顶层窗口标脏（_repaint 只画脏控件，吧唧是嵌入控件，必须靠它被画到），
                -- Geom 区域把 e-ink 刷新限制在吧唧范围内，整页只重绘缓冲不上屏。
                -- （region 传非法值会让 _refresh 报错被 pcall 吞掉，脏标记残留导致全屏刷新）
                local scr = w._screen
                pcall(function()
                    UIManager:setDirty("all", "ui", Geom:new{ x = scr.x, y = scr.y, w = scr.w, h = scr.h })
                end)
            end
        end
    end
    if any then
        running = true
        UIManager:scheduleIn(Badge.TICK, tick)
    end
end

--- 参与动画（幂等）
---@param widget table
function Badge.watch(widget)
    if not widget.animated then return end
    live[widget] = true
    if running then return end
    running = true
    UIManager:scheduleIn(Badge.TICK, tick)
end



--- 从配置里取特效集合（只认三种内置）
---@param list table|nil
---@return table|nil
local function effectsOf(list)
    if type(list) ~= "table" then return nil end
    local out, n = {}, 0
    for k in pairs(Effects.kinds) do
        if list[k] then out[k], n = true, n + 1 end
    end
    return n > 0 and out or nil
end



--- 造一个吧唧控件
---@param w number 可用宽
---@param h number 可用高
---@param src string 已确定的一张图
---@param opts table|nil { shape, effects, overlay, spin, ring }
---@return table|nil
function Badge.widget(w, h, src, opts)
    if type(src) ~= "string" or src == "" then return nil end
    opts = opts or {}
    -- 三种形状都是「正方形内切」，只是圆角不同
    local d = math.max(24, math.floor(math.min(w, h)))
    local effects = effectsOf(opts.effects)
    local period = tonumber(opts.spin) or 0
    -- 光环：true 或合法样式字符串都开（旧配置的 beads/lace 统一按双线处理）
    local ring
    if opts.ring == true then
        ring = "double"
    elseif type(opts.ring) == "string" and Badge.RING_LABEL[opts.ring] then
        ring = opts.ring
    end

    -- 动图：GIF / 动态 WebP。KOReader 自带 GifLib 解码，want_frames = true 时
    -- 返回一个「调用即得该帧位图」的函数表；静态图仍然返回一张位图。
    -- 动图关掉（opts.anim == false）或不是动图时 frames 为 nil，走原来的静态路径。
    local frames
    local lower = src:lower()
    local maybe_anim = opts.anim ~= false and (lower:match("%.gif$") ~= nil or lower:match("%.webp$") ~= nil)
    if maybe_anim then
        local ok, got = pcall(function() return RenderImage:renderImageFile(src, true, d, d) end)
        if ok and type(got) == "table" and #got > 1 then frames = got end
    end

    local widget = Painted:new{
        dimen = Geom:new{ w = d, h = d },
        src = src,
        shape = opts.shape or "circle",
        overlay = opts.overlay,
        effects = effects,
        ring = ring,
        period = period > 0 and period or nil,
        angle = 0,
        phase = 0,
        frames = frames,
        frame = frames and 1 or nil,
        animated = (effects ~= nil) or (period > 0) or (frames ~= nil),
    }
    if not compose(widget) then
        -- 动图解码失败：退回静态渲染再试一次
        if frames then
            widget.frames, widget.frame, widget.base_frame = nil, nil, nil
            pcall(function() frames:free() end)
            widget.animated = (effects ~= nil) or (period > 0)
            if compose(widget) then return widget end
        end
        return nil
    end
    return widget
end

return Badge
