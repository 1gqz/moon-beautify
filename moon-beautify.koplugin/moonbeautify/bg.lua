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

@module moonbeautify.bg
--]]--

local RenderImage = require("ui/renderimage")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")

local Bg = {}

--- 支持的填充方式 → 设置界面显示名
Bg.MODES = {
    stretch = "拉伸（铺满）",
    fill = "填满（裁边）",
    fit = "居中（完整）",
    tile = "平铺（重复）",
}

--- 源图原始尺寸缓存（避免每次重新解码大图）
local native = {}
--- 缩放结果缓存
local cache = {}

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
    elseif mode == "tile" then
        local s = w / iw
        return w, math.max(1, math.ceil(ih * s))
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
    local key = path .. "#" .. mode .. "#" .. w .. "x" .. h
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

--- 背景控件：只负责把图按模式画进给定矩形
local Layer = Widget:extend{}
Layer.is_bg_layer = true

function Layer:getSize() return self.dimen end

function Layer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local mode = self.mode or "stretch"
    pcall(function()
        local src, sw, sh = prepared(self.src, mode, w, h)
        if not src then return end
        if mode == "fit" then
            blit(bb, src, x + math.floor((w - sw) / 2), y + math.floor((h - sh) / 2), 0, 0, sw, sh)
        elseif mode == "tile" then
            if sh >= h then
                blit(bb, src, x, y, 0, 0, w, h)
            else
                local ty = 0
                while ty < h do
                    blit(bb, src, x, y + ty, 0, 0, w, math.min(sh, h - ty))
                    ty = ty + sh
                end
            end
        elseif mode == "fill" then
            -- 等比放大后居中裁切：左右/上下各切掉超出的部分
            blit(bb, src, x, y, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
        else
            blit(bb, src, x, y, 0, 0, w, h)
        end
    end)
end

--- 造一个背景层
---@param path string
---@param w number
---@param h number
---@param mode string|nil
---@return table
function Bg.layer(path, w, h, mode)
    if not Bg.MODES[mode] then mode = "stretch" end
    return Layer:new{ dimen = Geom:new{ w = w, h = h }, src = path, mode = mode }
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
