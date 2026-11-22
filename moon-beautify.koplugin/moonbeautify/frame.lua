--[[--
相框组件：两种呈现方式
  view = single  单图：一张图，可选「拉伸铺满 / 填满裁边 / 完整留白」
  view = stack   堆叠：多张裁成同样大小的方块窗，扇形叠放只露边，左右滑动翻页

配置前缀 <p>：
  view              single|stack，缺省 stack
  pick              file|folder，配 src / dir 指定图
  count             堆叠张数（1..9）
  mode              folder 取图顺序 daily|shuffle
  fit               single 的填充方式 stretch|fill|fit
  anchor_x / y      fill 时的取景焦点，0..1，缺省居中

@module moonbeautify.frame
--]]--

local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local BD = require("ui/bidi")
local Theme = require("ui/themes")
local Text = require("ui/themes.widgets.text")
local _ = require("gettext")

local Store = require("moonbeautify.store")
local Pick = require("moonbeautify.pick")
local Bg = require("moonbeautify.bg")
local Tilt = require("moonbeautify.tilt")

local Frame = {}

-- 翻页位置按前缀存，切页重建控件时保住；错开序列：中心 0，正负交替（沿对角线散开）。
-- 注意不要叫 focus：build() 里有同名局部变量表示取景选区，会遮蔽这里。
local carousel = {}
local MAX = 9
local FILL = { 0, 1, -1, 2, -2, 3, -3, 4, -4 }

--- 按配置取照片路径列表（最多 count 张）。
---@param c table
---@param prefix string
---@return string[]
local function photos(c, prefix)
    local pick = Store.enum(c, prefix .. "pick", { file = true, folder = true }, "file")
    local count = math.max(1, math.min(MAX, tonumber(c[prefix .. "count"]) or 5))
    if pick == "folder" then
        local list = Pick.listImages(c[prefix .. "dir"])
        if #list == 0 then return {} end
        local mode = Store.enum(c, prefix .. "mode", { daily = true, shuffle = true }, "daily")
        local start = mode == "shuffle" and math.random(#list) or ((Pick.dayIndex() - 1) % #list) + 1
        local out = {}
        for i = 0, count - 1 do
            out[#out + 1] = list[((start + i - 1) % #list) + 1]
        end
        return out
    end
    local src = c[prefix .. "src"]
    if type(src) == "string" and src ~= "" then return { src } end
    return {}
end

local function anchorOf(c, prefix)
    return {
        x = tonumber(c[prefix .. "anchor_x"]) or 0.5,
        y = tonumber(c[prefix .. "anchor_y"]) or 0.5,
    }
end

local function focusOf(c, prefix)
    return require("moonbeautify.view").focusOf(c[prefix .. "focus"])
end

local function placeholder(W, H, avail_w)
    return CenterContainer:new{
        dimen = Geom:new{ w = W, h = H },
        Text.line("caption", _("相框：未设置照片"), { width = avail_w, color = Theme.current().color.muted }),
    }
end

--- 造相框控件，返回占满 w × h 的控件。
---@param w number
---@param h number
---@param prefix string
---@return table
function Frame.build(w, h, prefix)
    local c = Store.conf()
    local W, H = math.max(1, w), math.max(1, h)
    local pad = Theme.px(Theme.current().space.xs)
    local avail_w, avail_h = math.max(1, W - pad * 2), math.max(1, H - pad * 2)
    local view = Store.enum(c, prefix .. "view", { single = true, stack = true }, "stack")
    local list = photos(c, prefix)
    if #list == 0 then return placeholder(W, H, avail_w) end

    local anchor = anchorOf(c, prefix)
    local focus = focusOf(c, prefix)

    -- 单图：一张铺满，填充方式三选一。
    if view == "single" then
        local fit = Store.enum(c, prefix .. "fit", { stretch = true, fill = true, fit = true }, "stretch")
        return CenterContainer:new{
            dimen = Geom:new{ w = W, h = H },
            Bg.layer(list[1], avail_w, avail_h, fit, anchor, focus),
        }
    end

    -- 堆叠：扇形摊开——中心那张最大、不旋转（彩色），四周越小越斜（灰度）。
    -- 几何要点：中心图不能大到把四周图全盖住；相邻中心距取边长的一半，让每张都露出约一半。
    local n = #list
    local max_dist = math.max(1, math.floor(n / 2))  -- FILL 序列里 |dist| 的最大值
    -- 中心边长：n 张按「每张露出约一半」横排，算能放下的最大边长
    local c_side = math.floor(math.min(avail_w / (0.5 * n + 0.5), avail_h * 0.62))
    c_side = math.max(80, c_side)
    local step_x = math.max(2, math.floor(c_side * 0.5))       -- 相邻中心距
    local shrink = math.max(1, math.floor(c_side * 0.13))      -- 每级缩小量
    local min_side = math.max(24, math.floor(c_side * 0.38))   -- 最小边长
    local cx, cy = math.floor(avail_w / 2), math.floor(avail_h / 2)
    -- 倾角按层数归一化：最外层固定 MAX_TILT，内层按比例递减，几张图层次都清晰。
    -- 这样不会出现「最外两层角度都被上限截断、看起来一样斜」。
    local MAX_TILT = 28 * math.pi / 180

    local function makeContent()
        local f = carousel[prefix] or 1
        if f < 1 or f > n then f = 1; carousel[prefix] = f end
        local slots = {}
        for idx = 1, n do
            local step = (idx - f - 1) % n
            local dist = FILL[step + 1] or FILL[#FILL]
            slots[#slots + 1] = { idx = idx, dist = dist, path = list[idx] }
        end
        -- 越靠两端（|dist| 大）的先画在底，中心那张最后画盖在最上面。
        table.sort(slots, function(a, b) return math.abs(a.dist) > math.abs(b.dist) end)

        local overlap = OverlapGroup:new{ dimen = Geom:new{ w = avail_w, h = avail_h }, overlap_offset = { 0, 0 } }
        for _i, s in ipairs(slots) do
            local ad = math.abs(s.dist)
            local sde = math.max(min_side, c_side - ad * shrink)
            local content
            if s.dist == 0 then
                -- 中心：彩色，整图完整显示，不旋转
                content = Bg.layer(s.path, sde, sde, "fill", anchor, nil, true)
            else
                -- 四周：灰度透视倾斜（越靠边越斜），失败则回退彩色普通图块
                local angle = (s.dist / max_dist) * MAX_TILT
                content = Tilt.frame(s.path, sde, angle)
                    or Bg.layer(s.path, sde, sde, "fill", anchor, nil, true)
            end
            local cell = WidgetContainer:new{ dimen = Geom:new{ w = sde, h = sde }, content }
            -- 各自按中心对齐；越靠边越往两侧、略微往下压，形成扇形摊开
            local ox = cx - math.floor(sde / 2) + s.dist * step_x
            local oy = cy - math.floor(sde / 2) + math.floor(ad * shrink * 0.5)
            cell.overlap_offset = {
                math.max(0, math.min(ox, avail_w - sde)),
                math.max(0, math.min(oy, avail_h - sde)),
            }
            overlap[#overlap + 1] = cell
        end
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, overlap }
    end

    -- host 构造时就带子控件：保证 paintTo 会写入 dimen.x/y，range 才能命中。
    local host = InputContainer:new{ dimen = Geom:new{ w = W, h = H }, makeContent() }
    host.ges_events = {
        FrameSwipe = { GestureRange:new{ ges = "swipe", range = function() return host.dimen end } },
    }

    function host:onFrameSwipe(a, b)
        -- 月读不同版本传手势的位置不一致，两种都接。
        local ges = nil
        if type(a) == "table" and a.direction then ges = a
        elseif type(b) == "table" and b.direction then ges = b end
        local dir = BD.flipDirectionIfMirroredUILayout(ges and ges.direction)
        if dir ~= "west" and dir ~= "east" then return false end
        if n < 2 then return false end
        local f = carousel[prefix] or 1
        carousel[prefix] = ((f - 1 + (dir == "west" and 1 or -1)) % n) + 1
        host[1] = makeContent()
        UIManager:setDirty("all", "ui")
        return true
    end

    return host
end

--- 设置页改了配置后调用；纯展示无需状态，保留空实现兼容调用方。
function Frame.reset(_prefix) end

return Frame
