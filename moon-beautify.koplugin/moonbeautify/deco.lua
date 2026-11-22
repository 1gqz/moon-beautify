--[[--
装饰层：带透明通道 PNG 的按需渲染缓存 + 混合工具。

- Deco.frame：把一张透明 PNG（花边框）画在组件内容之上，中间镂空不挡内容。
- 填充方式：stretch（拉伸铺满，缺省）/ fill（等比放大裁边，不变形）/ fit（等比缩小完整显示，留白）。
  花边是透明叠层，tile 没意义，故不提供。
- 渲染结果按（路径 + 模式 + 尺寸）缓存，同一素材反复画不重新解码。

@module moonbeautify.deco
--]]

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")

local Deco = {}

--- 支持的填充方式 → 设置界面显示名（统一取自 moonbeautify.fit）
local Fit = require("moonbeautify.fit")
Deco.MODES = {
    stretch = Fit.LABEL.stretch,
    fill = Fit.LABEL.fill,
    fit = Fit.LABEL.fit,
}

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

--- 按模式算渲染尺寸
local function scaledSize(iw, ih, w, h, mode)
    if mode == "fill" then
        local s = math.max(w / iw, h / ih)
        return math.max(1, math.ceil(iw * s)), math.max(1, math.ceil(ih * s))
    elseif mode == "fit" then
        local s = math.min(w / iw, h / ih)
        return math.max(1, math.ceil(iw * s)), math.max(1, math.ceil(ih * s))
    end
    return w, h
end

--- 把解码出的 bb 规范化成 BB8A（统一带透明通道）。
--- MuPDF 解码 RGBA PNG 得到的是预乘 BBRGB32，blitFrom 对它是直接拷贝
--- （透明处变纯黑），所以这里统一转成 BB8A；万一源没有 alpha 通道
--- （解码成 BB8），按「暗=墨、亮=透明」从灰度反推 alpha 兜底。
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
                        -- 源图没有 alpha 通道：按「暗=墨、亮=透明」反推
                        a = 255 - gray
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

--- 把规范化后的源按模式画进 w×h 的 BB8A（fill 裁边 / fit 居中留白 / stretch 直铺）
--- src 已规范化为 BB8A，out 也是 BB8A，全程同类型 alphablitFrom，不碰跨类型 blit。
---@param src table BB8A
---@param w number
---@param h number
---@param mode string
---@param ax number|nil 取景焦点 x：0=贴左，0.5=居中，1=贴右
---@param ay number|nil 取景焦点 y：0=贴上，0.5=居中，1=贴下
---@return table BB8A
local function place(src, w, h, mode, ax, ay)
    local sw, sh = src:getWidth(), src:getHeight()
    -- 新建 BB8A 缓冲已零初始化（全透明），fit 的留白天然不挡内容
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A)
    if mode == "fit" then
        out:alphablitFrom(src, math.floor((w - sw) / 2), math.floor((h - sh) / 2), 0, 0, sw, sh)
    elseif mode == "fill" then
        -- 等比放大后按焦点裁切，与背景的 fill 行为一致
        local sx = math.floor((sw - w) * (ax or 0.5))
        local sy = math.floor((sh - h) * (ay or 0.5))
        out:alphablitFrom(src, 0, 0, sx, sy, w, h)
    else
        out:alphablitFrom(src, 0, 0, 0, 0, w, h)
    end
    src:free()
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

--- 把 PNG 渲染成 w×h 的 BB8A（按模式 / 选区），缓存后返回。
---@param path string
---@param w number
---@param h number
---@param mode string|nil
---@param anchor table|nil { x = 0..1, y = 0..1 } fill 时裁切焦点，缺省居中
---@param focus table|nil { x, y, w, h } 选区（0..1，相对原图），给出时优先
---@return table|nil blitbuffer BB8A
function Deco.render(path, w, h, mode, anchor, focus)
    w, h = math.floor(w), math.floor(h)
    if type(path) ~= "string" or path == "" or w < 1 or h < 1 then return nil end
    -- 统一只用「填满裁边」；旧配置存的 stretch/fit 都按 fill
    mode = "fill"
    local ax = math.max(0, math.min(1, tonumber(anchor and anchor.x) or 0.5))
    local ay = math.max(0, math.min(1, tonumber(anchor and anchor.y) or 0.5))
    local fkey = ""
    if type(focus) == "table" and tonumber(focus.w) and tonumber(focus.h) then
        fkey = "#focus" .. (focus.x or 0) .. "," .. (focus.y or 0) .. "," .. focus.w .. "," .. focus.h
    end
    local key = path .. "#" .. mode .. "#" .. w .. "x" .. h .. "#" .. ax .. "," .. ay .. fkey
    local hit = cache[key]
    if hit then return hit end
    local iw, ih = nativeSize(path)
    if not iw or iw < 1 or ih < 1 then return nil end
    if fkey ~= "" then
        -- 选区：原图矩形 -> 解码到「放大后盖满目标」的尺寸 -> toBB8A -> 裁矩形
        local fx = math.max(0, math.min(1, focus.x or 0))
        local fy = math.max(0, math.min(1, focus.y or 0))
        local fw = math.max(0.01, math.min(1 - fx, focus.w or 1))
        local fh = math.max(0.01, math.min(1 - fy, focus.h or 1))
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
    local sw, sh = scaledSize(iw, ih, w, h, mode)
    local ok, decoded = pcall(function() return RenderImage:renderImageFile(path, false, sw, sh) end)
    if not ok or not decoded then return nil end
    local norm = toBB8A(decoded, sw, sh)
    if not norm then return nil end
    local out = place(norm, w, h, mode, ax, ay)
    cache[key] = out
    return out
end

--- 花边控件：把透明 PNG 按填充方式画在「内容之上」（中间镂空处不挡内容）
local Frame = Widget:extend{}
Frame.is_deco_frame = true

function Frame:getSize()
    return self.dimen
end

function Frame:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    -- 解码/转换/混合整条链路都包 pcall：花边图损坏或格式异常时安静跳过，
    -- 绝不让它把异常抛到绘制栈里中断整页渲染（背景层同样有此保护）。
    pcall(function()
        local src = Deco.render(self.src, self.dimen.w, self.dimen.h, self.mode, self.anchor, self.focus)
        if not src then return end
        -- alphablitFrom 才会按源图 alpha 混合（blitFrom 是直接拷贝）
        bb:alphablitFrom(src, x, y, 0, 0, self.dimen.w, self.dimen.h)
    end)
end

--- 造一个花边控件
---@param src string 透明 PNG 路径
---@param w number
---@param h number
---@param mode string|nil 填充方式 stretch/fill/fit
---@param anchor table|nil { x = 0..1, y = 0..1 } fill 时裁切焦点
---@param focus table|nil { x, y, w, h } 选区（0..1），给出时优先
---@return table
function Deco.frame(src, w, h, mode, anchor, focus)
    return Frame:new{ dimen = Geom:new{ w = w, h = h }, src = src, mode = mode, anchor = anchor, focus = focus }
end

--- 清缓存（配置改了模式/图，旧缓存留着也不会错，只是浪费内存）
function Deco.clear()
    for _k, v in pairs(cache) do
        pcall(function() v:free() end)
    end
    cache = {}
    native = {}
end

return Deco
