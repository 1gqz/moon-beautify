--[[--
吧唧上的动态特效层。三种内置：细闪、雨滴、星星。

设计要点：特效只画「点」，不碰底图。调用方每帧先把缓存好的底图 blit 过来，
再让这里叠一层几十个像素的点，所以一帧的开销是「一次 memcpy + 几百次 setPixel」，
在一秒一帧的刷新节奏下几乎不占时间。

坐标与相位都是确定性的（同一格图每次位置一致），
只有 phase 在推进 —— 这样加帧、换帧都不会闪烁错位。

@module moonbeautify.render.effects
--]]

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("moonbeautify.l10n")

local C8 = Blitbuffer.Color8

local Effects = {}

Effects.kinds = { glitter = true, rain = true, stars = true }

Effects.LABEL = { glitter = _("细闪"), rain = _("雨滴"), stars = _("星星") }



--- 局部确定性随机（不动全局种子）
local function rng(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s / 2147483647
    end
end



local spots, stars, drops = {}, {}, {}

--- 特效元素只跟尺寸/形状有关，缓存一份
local function geometry(w, h, shape)
    local key = table.concat({ w, h, shape.rect and "r" or "c", shape.r or 0, shape.rc or 0 }, "|")
    if spots[key] then return spots[key], stars[key], drops[key] end

    local rand = rng(w * 7919 + h * 104729)
    local function pick()
        local x, y
        if shape.rect then
            x, y = rand() * (w - 2) + 1, rand() * (h - 2) + 1
        else
            local a, rr = rand() * math.pi * 2, math.sqrt(rand()) * (shape.r - 3)
            x, y = shape.cx + math.cos(a) * rr, shape.cy + math.sin(a) * rr
        end
        return x, y
    end

    local gl = {}
    for i = 1, 22 do
        local x, y = pick()
        gl[i] = { x = x, y = y, off = rand(), size = rand() < 0.35 and 2 or 1 }
    end

    local st = {}
    for i = 1, 5 do
        local x, y = pick()
        st[i] = { x = x, y = y, off = rand(), base = 5 + math.floor(rand() * 4) }
    end

    local dr = {}
    for i = 1, 12 do
        local x = shape.rect and (rand() * (w - 2) + 1) or (shape.cx - shape.r + rand() * shape.r * 2)
        dr[i] = {
            x = x,
            y0 = rand(),
            speed = 0.7 + rand() * 0.9,
            len = 5 + math.floor(rand() * 8),
        }
    end

    spots[key], stars[key], drops[key] = gl, st, dr
    return gl, st, dr
end



--- 圆 / 圆角矩形 / 矩形内的像素判定
local function inside(shape, x, y)
    if x < 0 or y < 0 or x > shape.w - 1 or y > shape.h - 1 then return false end
    if shape.rect then
        local rc = shape.rc or 0
        if rc <= 0 then return true end
        local hw, hh = shape.w / 2, shape.h / 2
        local dx = math.abs(x + 0.5 - hw) - (hw - rc)
        local dy = math.abs(y + 0.5 - hh) - (hh - rc)
        local ox, oy = math.max(dx, 0), math.max(dy, 0)
        return math.sqrt(ox * ox + oy * oy) + math.min(math.max(dx, dy), 0) - rc <= 0
    end
    local dx, dy = x + 0.5 - shape.cx, y + 0.5 - shape.cy
    return dx * dx + dy * dy <= shape.r * shape.r
end



local function put(bb, shape, x, y, v)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if inside(shape, x, y) then bb:setPixel(x, y, C8(v < 0 and 0 or (v > 255 and 255 or math.floor(v)))) end
end



--- 细闪：成片闪烁的小点点（白芯 + 灰晕，亮照片上也看得见）
local function glitter(bb, shape, list, phase)
    for i = 1, #list do
        local p = list[i]
        local f = 0.5 + 0.5 * math.sin((phase * 3 + p.off) * math.pi * 2)
        if f > 0.5 then
            local arm = p.size
            -- 晕：先压一圈中灰，撑出对比
            for dy = -arm - 1, arm + 1 do
                for dx = -arm - 1, arm + 1 do
                    if dx * dx + dy * dy <= (arm + 1) * (arm + 1) then
                        put(bb, shape, p.x + dx, p.y + dy, 110)
                    end
                end
            end
            put(bb, shape, p.x, p.y, 255)
            for k = 1, arm do
                put(bb, shape, p.x - k, p.y, 235)
                put(bb, shape, p.x + k, p.y, 235)
                put(bb, shape, p.x, p.y - k, 235)
                put(bb, shape, p.x, p.y + k, 235)
            end
        end
    end
end



--- 雨滴：下落的细线，身子偏暗、头部一点亮（深色照片和浅色照片都能看出来）
local function rain(bb, shape, list, phase)
    for i = 1, #list do
        local d = list[i]
        local y = ((d.y0 + phase * d.speed) % 1.08 - 0.04) * shape.h
        for k = 0, d.len do
            local t = k / d.len
            put(bb, shape, d.x, y + k, 55 + 45 * t)
        end
        -- 头部亮点 + 两侧 1px 亮边，远看是一滴往下掉的水
        put(bb, shape, d.x, y, 255)
        put(bb, shape, d.x + 1, y + 1, 200)
        put(bb, shape, d.x - 1, y + 2, 200)
    end
end



--- 星星：缩放的实心五角星（轮廓亮、内部暗，灰阶下也有层次）
---@param bb table
---@param shape table
---@param cx number
---@param cy number
---@param radius number
---@param phase number
local function star(bb, shape, cx, cy, radius, phase)
    local inner = radius * (0.42 + 0.1 * math.sin(phase * math.pi * 4))
    local pts = {}
    for i = 0, 9 do
        local ang = -math.pi / 2 + i * math.pi / 5
        local rr = (i % 2 == 0) and radius or inner
        pts[#pts + 1] = { x = cx + math.cos(ang) * rr, y = cy + math.sin(ang) * rr }
    end
    for i = 1, #pts do
        local a, b = pts[i], pts[i % #pts + 1]
        local steps = math.max(math.abs(b.x - a.x), math.abs(b.y - a.y))
        steps = math.max(1, math.floor(steps * 1.5))
        for k = 0, steps do
            local t = k / steps
            put(bb, shape, a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 255)
        end
    end
    -- 中心一点提亮，远看是一颗会呼吸的星
    put(bb, shape, cx, cy, 255)
end



--- 画一层特效
---@param bb table 目标位图（G8）
---@param w number
---@param h number
---@param enabled table { glitter, rain, stars }
---@param phase number 0..1 连续相位
---@param shape table { rect=true } 或 { cx, cy, r }
function Effects.paint(bb, w, h, enabled, phase, shape)
    if type(enabled) ~= "table" then return end
    shape.w, shape.h = w, h
    local gl, st, dr = geometry(w, h, shape)

    if enabled.rain then rain(bb, shape, dr, phase) end
    if enabled.glitter then glitter(bb, shape, gl, phase) end
    if enabled.stars then
        for i = 1, #st do
            local s = st[i]
            local pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin((phase * 2 + s.off) * math.pi * 2))
            star(bb, shape, s.x, s.y, math.max(3, s.base * pulse), phase + s.off)
        end
    end
end



return Effects
