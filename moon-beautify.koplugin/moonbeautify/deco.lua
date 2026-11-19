--[[--
装饰层：带透明通道 PNG 的按需渲染缓存 + 混合工具。

- Deco.frame：把一张透明 PNG（花边框）画在组件内容之上，中间镂空不挡内容。
- 渲染结果按（路径 + 尺寸）缓存，同一素材反复画不重新解码。

@module moonbeautify.deco
--]]

local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")

local Deco = {}

-- 渲染缓存：素材不算大，强引用即可（一张 400x300 BB8A 约 240KB）
local cache = {}

--- 把 PNG 渲染成 w×h 的 BB8A（统一带透明通道），缓存后返回。
--- MuPDF 解码 RGBA PNG 得到的是预乘 BBRGB32，blitFrom 对它是直接拷贝
--- （透明处变纯黑），所以这里统一转成 BB8A；万一源没有 alpha 通道
--- （解码成 BB8），按「暗=墨、亮=透明」从灰度反推 alpha 兜底。
---@param path string
---@param w number
---@param h number
---@return table|nil blitbuffer BB8A
function Deco.render(path, w, h)
    w, h = math.floor(w), math.floor(h)
    if type(path) ~= "string" or path == "" or w < 1 or h < 1 then return nil end
    local key = path .. "#" .. w .. "x" .. h
    local hit = cache[key]
    if hit then return hit end
    local ok, bb = pcall(function()
        return RenderImage:renderImageFile(path, false, w, h)
    end)
    if not ok or not bb then return nil end
    -- 一律规范化成 BB8A：BBRGB32 虽然也带 alpha 字段，但 blitFrom 对它是直接拷贝
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
    cache[key] = out
    return out
end

--- 花边控件：把一张透明 PNG 铺满给定矩形画在「内容之上」
--- （blitFrom 对带 alpha 的源会自动按透明度混合，中间镂空处不挡内容）
local Frame = Widget:extend{}
Frame.is_deco_frame = true

function Frame:getSize()
    return self.dimen
end

function Frame:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local src = Deco.render(self.src, self.dimen.w, self.dimen.h)
    if not src then return end
    -- alphablitFrom 才会按源图 alpha 混合（blitFrom 是直接拷贝）
    pcall(function()
        bb:alphablitFrom(src, x, y, 0, 0, self.dimen.w, self.dimen.h)
    end)
end

--- 造一个花边控件
---@param src string 透明 PNG 路径
---@param w number
---@param h number
---@return table
function Deco.frame(src, w, h)
    return Frame:new{ dimen = Geom:new{ w = w, h = h }, src = src }
end

return Deco
