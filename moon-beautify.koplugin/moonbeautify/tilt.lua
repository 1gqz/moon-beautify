--[[--
灰度透视图块：把一张图片绕竖直轴做透视倾斜（一侧近、一侧远，近大远小），
用于相框卡片堆的四周层，像一张斜插着的照片。

性能要点（针对 e-ink 设备）：
- 解码直接到目标尺寸，绝不按原图全尺寸解码（原图动辄几千万像素，极慢）；
- 缩放 + 旋转合并成一次逐像素循环（原来两遍，减半）；
- 结果用强引用缓存 + FIFO 上限：角度档位有限，翻几轮后全部命中，翻页零计算；
- 像素只取 :getColor8().a 写进 BB8A，全程不碰跨类型 blit（沿用已验证路线）；
- 整条链路包 pcall，失败返回 nil 让调用方回退彩色图块。

@module moonbeautify.tilt
--]]

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local nativeSize = require("moonbeautify.bg").nativeSize

local C8A = Blitbuffer.Color8A
local Tilt = {}

-- 强引用缓存 + FIFO 淘汰：条目有限（张数 × 角度档位），翻几轮后稳定命中
local cache = {}
local order = {}
local CACHE_MAX = 48

local function cachePut(key, buf)
    if cache[key] then return end
    cache[key] = buf
    order[#order + 1] = key
    if #order > CACHE_MAX then
        local old = table.remove(order, 1)
        cache[old] = nil
    end
end

--- 生成「透视倾斜」后的 BB8A：图片绕竖直轴转一个角度，一侧靠近观察者（放大变宽）、
--- 一侧远离（缩小变窄），形成近大远小的梯形立体感。
--- 做法：对每个目标像素做逆透视映射回源图坐标（一次循环完成 fit 缩放 + 透视）。
--- 像素访问沿用 badge.lua 验证过的 dec:getPixel():getColor8().a。
local function build(path, s, angle)
    local iw0, ih0 = nativeSize(path)
    if not iw0 or iw0 < 1 or ih0 < 1 then return nil end
    local k = math.min(s / iw0, s / ih0)
    local dw, dh = math.max(1, math.ceil(iw0 * k)), math.max(1, math.ceil(ih0 * k))
    local ok, dec = pcall(function() return RenderImage:renderImageFile(path, false, dw, dh) end)
    if not ok or not dec then return nil end
    local iw, ih = dec:getWidth(), dec:getHeight()
    if iw < 1 or ih < 1 then pcall(function() dec:free() end); return nil end
    local out = Blitbuffer.new(s, s, Blitbuffer.TYPE_BB8A)
    local c = (s - 1) / 2
    -- 限制最大角度，避免透视形变过猛/除零
    local yaw = angle
    if yaw > 0.52 then yaw = 0.52 elseif yaw < -0.52 then yaw = -0.52 end
    local ca, sa = math.cos(yaw), math.sin(yaw)
    local D = 2.8 * (c > 0 and c or 1)          -- 焦距：越小透视越强
    local scale = math.min(s / iw, s / ih)     -- 整图 fit 进 s×s 的缩放
    local hw, hh = iw / 2, ih / 2
    for y = 0, s - 1 do
        local sy = y - c
        for x = 0, s - 1 do
            local sx = x - c
            -- 屏幕坐标 → 倾斜平面坐标：近侧被拉宽、远侧被压窄
            local denom = D * ca + sx * sa
            if math.abs(denom) > 0.001 then
                local u = sx * D / denom            -- 平面横向
                local depth = D - u * sa            -- 该点深度
                local v = sy * depth / D            -- 纵向随深度近大远小
                local px = math.floor(hw + u / scale)
                local py = math.floor(hh + v / scale)
                if px >= 0 and px < iw and py >= 0 and py < ih then
                    local lv = dec:getPixel(px, py):getColor8().a
                    out:setPixel(x, y, C8A(math.floor(lv), 255))
                end
            end
        end
    end
    pcall(function() dec:free() end)
    return out
end

local Tilted = Widget:extend{}
Tilted.is_tilt = true

function Tilted:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.buf then
        pcall(function()
            bb:alphablitFrom(self.buf, x, y, 0, 0, self.dimen.w, self.dimen.h)
        end)
    end
end

--- 构造灰度倾斜图块；失败返回 nil，调用方回退彩色图块。
function Tilt.frame(path, s, angle)
    if type(path) ~= "string" or path == "" or not s or s < 2 then return nil end
    -- 角度量化到 1 度：档位更少、缓存命中率更高，视觉上足够
    local aq = math.floor(angle * 180 / math.pi + 0.5)
    local key = path .. "#" .. s .. "#" .. aq
    local hit = cache[key]
    if hit then
        return Tilted:new{ dimen = Geom:new{ w = s, h = s }, buf = hit }
    end
    local ok, buf = pcall(build, path, s, aq * math.pi / 180)
    if not ok or not buf then return nil end
    cachePut(key, buf)
    return Tilted:new{ dimen = Geom:new{ w = s, h = s }, buf = buf }
end

return Tilt
