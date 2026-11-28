--[[--
组件背景的填充方式（拉伸 / 填满 / 居中 / 平铺）。

月读自带的 Image 组件只有「拉伸」一种（stretch = true，宽高一起改，比例会变形），
这里补三种：

  stretch  拉伸   图直接拉到 w×h（可能变形，原来的行为）
  fill     填满   按比例放大到刚好盖住整块，多出来的边裁掉（不变形、不留白）
  fit      居中   按比例缩到刚好装进整块，四周留空（不变形、留白透出页面底色）
  tile     平铺   先按宽度缩放，再纵向重复铺买（适合小花纹/爱心这类底纹）

实现要点：
- 只解码一次：结果按（路径 + 模式 + 尺寸）缓存，之后每次 paint 只是一次 blit。
- 用 alphablitFrom（透明处按 alpha 混合），图案 PNG 的透明区域能透出页面底色。
- 全部包 pcall：解码失败就不画（该组件退回纯页面底色），不影响首页渲染。

@module moonbeautify.render.bg
--]]--

local RenderImage = require("ui/renderimage")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Theme = require("ui/themes")
local Image = require("utils.image")

local Bg = {}

--- 支持的填充方式 → 设置界面显示名（统一取自 moonbeautify.render.fit）
local Fit = require("moonbeautify.render.fit")
Bg.MODES = {
    stretch = Fit.LABEL.stretch,
    fill = Fit.LABEL.fill,
    fit = Fit.LABEL.fit,
    tile = Fit.LABEL.tile,
}

--- 源图原始尺寸缓存（避免每次重新解码大图）
local native = {}
--- 缩放结果缓存
local cache = {}

local lfs = require("libs/libkoreader-lfs")

--- 路径 + 修改时间，避免同路径换图仍命中旧解码
local function fileMtime(path)
    return lfs.attributes(path, "modification") or 0
end

local function fileKey(path)
    return path .. "@" .. tostring(fileMtime(path))
end

--- 读原图尺寸：先读文件头，认不出（svg 等）才整图解一次，解完立刻释放
---@param path string
---@return number|nil, number|nil
local function nativeSize(path)
    local mod = fileMtime(path)
    local hit = native[path]
    if hit and hit[3] == mod then return hit[1], hit[2] end
    local w, h = Image.dimensions(path)
    if not w then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(path, false) end)
        if not ok or not bb then return nil, nil end
        w, h = bb:getWidth(), bb:getHeight()
        bb:free()
    end
    native[path] = { w, h, mod }
    return w, h
end
Bg.nativeSize = nativeSize

--- 按模式算出「要渲染多大」和「从哪切」
---@param iw number 原宽
---@param ih number 原高
---@param w number 目标宽
---@param h number 目标高
---@param mode string
---@return number sw, number sh 渲染尺寸
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

--- 把 src 的一块 blit 到 bb（优先 alpha 混合，失败退回直接拷贝）
local function blit(bb, src, dx, dy, sx, sy, sw, sh)
    local ok = pcall(function() bb:alphablitFrom(src, dx, dy, sx, sy, sw, sh) end)
    if not ok then pcall(function() bb:blitFrom(src, dx, dy, sx, sy, sw, sh) end) end
end

--- 取（缩放好的）源图，带缓存
---@param path string
---@param mode string
---@param w number
---@param h number
---@return table|nil bb, number dw, number dh
local function prepared(path, mode, w, h)
    local key = fileKey(path) .. "#" .. mode .. "#" .. w .. "x" .. h
    local hit = cache[key]
    if hit then return hit[1], hit[2], hit[3] end
    local iw, ih = nativeSize(path)
    if not iw or iw < 1 or ih < 1 then return nil end
    local sw, sh = scaledSize(iw, ih, w, h, mode)
    local ok, bb = pcall(function() return RenderImage:renderImageFile(path, false, sw, sh) end)
    if not ok or not bb then return nil end
    cache[key] = { bb, bb:getWidth(), bb:getHeight() }
    return bb, bb:getWidth(), bb:getHeight()
end

--- 取「整图解码到 dw×dh」的源，带缓存（选区裁切复用）
local function decodedAt(path, dw, dh)
    local key = fileKey(path) .. "#crop#" .. dw .. "x" .. dh
    local hit = cache[key]
    if hit then return hit[1], hit[2], hit[3] end
    local ok, bb = pcall(function() return RenderImage:renderImageFile(path, false, dw, dh) end)
    if not ok or not bb then return nil end
    cache[key] = { bb, bb:getWidth(), bb:getHeight() }
    return bb, bb:getWidth(), bb:getHeight()
end

--- 把选区 focus={x,y,w,h}（0..1，相对原图）铺满目标 w×h。
--- 做法：整图解码到覆盖目标所需尺寸，再从对应源矩形 blitFrom 到 framebuffer。
--- 源与目标都是 framebuffer 可用类型，blit() 内部已有 fallback，绝不新建 BB8A。
local function paintFocus(bb, x, y, w, h, path, focus)
    local iw, ih = nativeSize(path)
    if not iw or iw < 1 or ih < 1 then return end
    local fx = math.max(0, math.min(1, focus.x or 0))
    local fy = math.max(0, math.min(1, focus.y or 0))
    local fw = math.max(0.01, math.min(1 - fx, focus.w or 1))
    local fh = math.max(0.01, math.min(1 - fy, focus.h or 1))
    -- 源矩形（按原图像素）
    local sx = math.floor(fx * iw)
    local sy = math.floor(fy * ih)
    local sw = math.max(1, math.floor(fw * iw))
    local sh = math.max(1, math.floor(fh * ih))
    -- 把整图解码到：让「源矩形」放大后正好覆盖目标。
    -- 等比放大保证不变形，再按目标裁；限制解码尺寸上限，避免选区极小时解出巨图爆内存。
    local scale = math.max(w / sw, h / sh)
    local MAX_DIM = 4096
    local cap = math.min(MAX_DIM / iw, MAX_DIM / ih)
    if scale > cap then scale = cap end
    if scale < 1 / 1024 then return end
    local dw = math.max(1, math.ceil(iw * scale))
    local dh = math.max(1, math.ceil(ih * scale))
    local src = decodedAt(path, dw, dh)
    if not src then return end
    -- 源矩形在解码图上的位置（按实际 scale，可能因上限被压低）
    local dsx = math.floor(sx * scale)
    local dsy = math.floor(sy * scale)
    local dsw = math.floor(sw * scale)
    local dsh = math.floor(sh * scale)
    if dsw < 1 or dsh < 1 then return end
    -- 目标框内居中（等比放大后某方向会溢出，裁掉）
    local ox = math.floor((dsw - w) / 2)
    local oy = math.floor((dsh - h) / 2)
    ox = math.max(0, ox); oy = math.max(0, oy)
    -- 大图 + 极小选区时 scale 可能被上限压低，使 dsw/dsh 小于目标；
    -- 此时把源矩形夹进解码图边界，避免 alphablitFrom 越界崩溃/花屏。
    local bw = math.min(w, math.max(1, dw - dsx - ox))
    local bh = math.min(h, math.max(1, dh - dsy - oy))
    local sx0 = math.max(0, math.min(dsx + ox, dw - bw))
    local sy0 = math.max(0, math.min(dsy + oy, dh - bh))
    blit(bb, src, x, y, sx0, sy0, bw, bh)
end

--- 背景控件：只负责把图按模式画进给定矩形
local Layer = Widget:extend{}
Layer.is_bg_layer = true

function Layer:getSize() return self.dimen end

function Layer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    -- 多图堆叠用 contain：整图等比缩放装进方框，居中留白、不裁切；
    -- 其余组件统一「填满裁边」（旧配置 stretch/fit/tile 也按 fill）。
    pcall(function()
        if self.contain then
            -- 先用页面底色铺满方框，避免透明图片/留白处露出下面的图层
            local t = Theme.current()
            bb:paintRect(x, y, w, h, Blitbuffer.Color8(Theme.color(t.color.page)))
            local src, sw, sh = prepared(self.src, "fit", w, h)
            if src then
                -- fit 解码尺寸取整可能比目标多 1 像素，夹住避免画出方框、原点为负
                sw, sh = math.min(sw, w), math.min(sh, h)
                local dx = x + math.max(0, math.floor((w - sw) / 2))
                local dy = y + math.max(0, math.floor((h - sh) / 2))
                blit(bb, src, dx, dy, 0, 0, sw, sh)
            end
            return
        end
        if self.focus then
            paintFocus(bb, x, y, w, h, self.src, self.focus)
            return
        end
        local src, sw, sh = prepared(self.src, "fill", w, h)
        if not src then return end
        -- 等比放大后按锚点裁切：anchor 0=贴左/上，0.5=居中，1=贴右/下
        local sx = math.floor((sw - w) * (self.anchor_x or 0.5))
        local sy = math.floor((sh - h) * (self.anchor_y or 0.5))
        blit(bb, src, x, y, sx, sy, w, h)
    end)
end

--- 造一个背景层
---@param path string
---@param w number
---@param h number
---@param mode string|nil
---@param anchor table|nil { x = 0..1, y = 0..1 } fill 模式下裁切焦点，缺省居中 { x = 0.5, y = 0.5 }
---@param focus table|nil { x, y, w, h } 选区（0..1），给出时优先于 mode/anchor，把选区铺满目标
---@param contain boolean|nil true=整图完整显示（等比缩放留白、不裁切、忽略选区），缺省 false
---@return table
function Bg.layer(path, w, h, mode, anchor, focus, contain)
    if not Bg.MODES[mode] then mode = "stretch" end
    local ax = anchor and tonumber(anchor.x) or 0.5
    local ay = anchor and tonumber(anchor.y) or 0.5
    ax = math.max(0, math.min(1, ax))
    ay = math.max(0, math.min(1, ay))
    local f
    if type(focus) == "table" and tonumber(focus.w) and tonumber(focus.h) then
        f = { x = tonumber(focus.x) or 0, y = tonumber(focus.y) or 0,
              w = tonumber(focus.w) or 1, h = tonumber(focus.h) or 1 }
    end
    return Layer:new{ dimen = Geom:new{ w = w, h = h }, src = path, mode = mode,
        anchor_x = ax, anchor_y = ay, focus = f, contain = contain and true or false }
end

--- 清缓存（配置改了尺寸/图，旧缓存留着也不会错，只是浪费内存）
function Bg.clear()
    for _k, v in pairs(cache) do
        pcall(function() v[1]:free() end)
    end
    cache = {}
    native = {}
end

return Bg
