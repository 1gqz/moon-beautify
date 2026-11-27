--[[--
装饰层：顶层图片的按需渲染缓存 + 混合工具。

- Deco.frame：把一张图片画在组件内容之上。透明 PNG 保留镂空，不透明图片整张盖住组件。
- 显示方式与组件背景一致：统一按取景选区铺满；没有选区就按整图铺满。
- 渲染结果按（路径 + 选区 + 尺寸）缓存，同一素材反复画不重新解码。

@module moonbeautify.deco
--]]

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")

local Deco = {}

-- 渲染缓存：素材不算大，强引用即可（一张 400x300 BB8A 约 240KB）
local cache = {}
-- 原图尺寸缓存
local native = {}

--- 读原图尺寸（只解一次，解完立刻释放）
---@param path string
---@return number|nil, number|nil
local function nativeSize(path)
    local hit = native[path]
    if hit then return hit[1], hit[2] end
    local ok, bb = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not ok or not bb then return nil, nil end
    local w, h = bb:getWidth(), bb:getHeight()
    bb:free()
    native[path] = { w, h }
    return w, h
end

--- 把解码出的 bb 规范化成 BB8A（统一带透明通道）。
--- MuPDF 解码 RGBA PNG 得到的是预乘 BBRGB32，blitFrom 对它是直接拷贝
--- （透明处变纯黑），所以这里统一转成 BB8A。
--- 有透明通道就按原透明显示；没有透明通道就当普通图片，整张不透明盖住组件。
---@param bb table 解码结果
---@param w number 输出宽
---@param h number 输出高
---@return table|nil BB8A
local function toBB8A(bb, w, h)
    if not bb then return nil end
    local bw, bh = bb:getWidth(), bb:getHeight()
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    -- 只有 Color8A / ColorRGB32 的像素带 alpha 字段；BB8（灰度）的像素是
    -- Color8，只有 a 一个字段，直接读 px.alpha 会在真机上抛
    -- 「struct Color8 has no member named 'alpha'」。这里先探一次再决定用哪种取法。
    local probe = bb:getPixel(0, 0)
    local ok_alpha, probe_alpha = pcall(function() return probe.alpha end)
    local has_alpha = ok_alpha and probe_alpha ~= nil
    for y = 0, h - 1 do
        if y < bh then
            for x = 0, w - 1 do
                if x < bw then
                    local px = bb:getPixel(x, y)
                    local gray = px:getColor8().a
                    local a
                    if has_alpha then
                        a = px.alpha
                    else
                        -- 源图没有透明通道：作为普通图片整张盖住组件
                        a = 255
                    end
                    if a > 0 then
                        out:setPixel(x, y, Blitbuffer.Color8A(gray, a))
                    end
                end
            end
        end
    end
    bb:free()
    return out
end

--- 从已按选区放大解码的 BB8A 源里，居中取 w×h（同类型 alphablitFrom，安全）。
--- sww/shh 是选区放大后的尺寸（>= w/h），超出的方向居中裁掉。
local function placeCrop(src, w, h, sx, sy, sww, shh)
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    local ox = math.max(0, math.floor((sww - w) / 2))
    local oy = math.max(0, math.floor((shh - h) / 2))
    local bx = math.max(0, math.min(sx + ox, src:getWidth() - w))
    local by = math.max(0, math.min(sy + oy, src:getHeight() - h))
    local ok = pcall(function() out:alphablitFrom(src, 0, 0, bx, by, w, h) end)
    if not ok then pcall(function() out:blitFrom(src, 0, 0, bx, by, w, h) end) end
    src:free()
    return out
end

--- 把图片按取景选区渲染成 w×h 的 BB8A，缓存后返回。
--- 与组件背景一致：没有选区就按整图铺满。
---@param path string
---@param w number
---@param h number
---@param focus table|nil { x, y, w, h } 选区（0..1，相对原图）
---@return table|nil blitbuffer BB8A
function Deco.render(path, w, h, focus)
    w, h = math.floor(w), math.floor(h)
    if type(path) ~= "string" or path == "" or w < 1 or h < 1 then return nil end
    if type(focus) ~= "table" or not tonumber(focus.w) or not tonumber(focus.h) then
        focus = { x = 0, y = 0, w = 1, h = 1 }
    end
    local fx = math.max(0, math.min(1, tonumber(focus.x) or 0))
    local fy = math.max(0, math.min(1, tonumber(focus.y) or 0))
    local fw = math.max(0.01, math.min(1 - fx, tonumber(focus.w) or 1))
    local fh = math.max(0.01, math.min(1 - fy, tonumber(focus.h) or 1))
    local fkey = "#focus" .. fx .. "," .. fy .. "," .. fw .. "," .. fh
    local key = path .. "#" .. fkey .. "#" .. w .. "x" .. h
    local hit = cache[key]
    if hit then return hit end
    local iw, ih = nativeSize(path)
    if not iw or iw < 1 or ih < 1 then return nil end
    -- 选区：原图矩形 -> 解码到「放大后盖满目标」的尺寸 -> toBB8A -> 裁矩形
    local sx, sy = math.floor(fx * iw), math.floor(fy * ih)
    local sww, shh = math.max(1, math.floor(fw * iw)), math.max(1, math.floor(fh * ih))
    local sc = math.max(w / sww, h / shh)
    local cap = math.min(4096 / iw, 4096 / ih)
    if sc > cap then sc = cap end
    local dw, dh = math.max(1, math.ceil(iw * sc)), math.max(1, math.ceil(ih * sc))
    local ok, decoded = pcall(function() return RenderImage:renderImageFile(path, false, dw, dh) end)
    if not ok or not decoded then return nil end
    local norm = toBB8A(decoded, dw, dh)
    if not norm then return nil end
    local dsx = math.floor(sx * sc)
    local dsy = math.floor(sy * sc)
    local dsw = math.max(1, math.floor(sww * sc))
    local dsh = math.max(1, math.floor(shh * sc))
    local out = placeCrop(norm, w, h, dsx, dsy, dsw, dsh)
    cache[key] = out
    return out
end

--- 顶层图控件：把图片按取景选区画在「内容之上」（透明处透出内容，不透明处盖住内容）
local Frame = Widget:extend{}
Frame.is_deco_frame = true

function Frame:getSize()
    return self.dimen
end

function Frame:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    -- 解码/转换/混合整条链路都包 pcall：图片损坏或格式异常时安静跳过，
    -- 绝不让它把异常抛到绘制栈里中断整页渲染（背景层同样有此保护）。
    pcall(function()
        local src = Deco.render(self.src, self.dimen.w, self.dimen.h, self.focus)
        if not src then return end
        -- alphablitFrom 才会按源图 alpha 混合（blitFrom 是直接拷贝）
        bb:alphablitFrom(src, x, y, 0, 0, self.dimen.w, self.dimen.h)
    end)
end

--- 造一个顶层图控件
---@param src string 图片路径（透明 PNG 保留镂空，普通图片整张覆盖）
---@param w number
---@param h number
---@param focus table|nil { x, y, w, h } 选区（0..1），缺省整图
---@return table
function Deco.frame(src, w, h, focus)
    return Frame:new{ dimen = Geom:new{ w = w, h = h }, src = src, focus = focus }
end

--- 清缓存（配置改了选区/图，旧缓存留着也不会错，只是浪费内存）
function Deco.clear()
    for _k, v in pairs(cache) do
        pcall(function() v:free() end)
    end
    cache = {}
    native = {}
end

return Deco
