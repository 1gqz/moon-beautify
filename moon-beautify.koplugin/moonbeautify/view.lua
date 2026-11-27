--[[--
组件画面：图片占满给定区域，配月读主题的 image 表面（底色 + 边框）。

- 吧唧支持三种形状：圆形（Box radius=999 自动裁掉圆外四角）、圆角、直角。
- 图片用月读的 ui.themes.widgets.image：本地路径直接解，没出图前透出表面底色。
- "保持比例"对应内核 stretch = false（按比例缩进目标框），"填满"是 stretch = true（拉满，可能变形）。

@module moonbeautify.view
--]]

local Theme = require("ui/themes")
local Box = require("ui/themes/widgets/box")
local Image = require("ui/themes/widgets/image")
local CenterContainer = require("ui/widget/container/centercontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")
local Text = require("ui.themes.widgets.text")

local Store = require("moonbeautify.store")

local View = {}

--- 背景叠层：先画图，按 veil 提亮，再画组件内容，最后叠花边。内容尺寸与组件槽一致。
local Stack = WidgetContainer:extend{}

function Stack:getSize()
    return self.dimen
end

function Stack:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self[1] then self[1]:paintTo(bb, x, y) end
    if (self.veil or 0) > 0 then
        bb:lightenRect(x, y, self.dimen.w, self.dimen.h, self.veil / 100)
    end
    if self[2] then self[2]:paintTo(bb, x, y) end
    -- 花边画在最上面：透明处透出内容，不透明处盖住内容
    if self.lace then self.lace:paintTo(bb, x, y) end
end

--- 没配置 / 没图时的占位：居中一行灰字。
---@param w number
---@param h number
---@param text string
---@return table
function View.placeholder(w, h, text)
    local t = Theme.current()
    local pad = Theme.px(t.space.xs)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Text.line("caption", text, { width = w - pad * 2, color = t.color.muted }),
    }
end

--- 圆形图片：直径取 min(宽, 高)，Box 的 radius 夹到短边一半即正圆，圆外像素还原。
---@param w number
---@param h number
---@param src string
---@return table
function View.circle(w, h, src)
    local t = Theme.current()
    local d = math.max(1, math.min(w, h))
    local border = Theme.px(1)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        Box:new{
            style = { bg = t.color.page, radius = 999, border = 1, border_color = t.color.rule },
            width = d,
            height = d,
            Image.widget{
                src = src,
                width = d - border * 2,
                height = d - border * 2,
                stretch = true,
                style = {},
                fallback = "",
            },
        },
    }
end

--- 图片层：贴图条铺满整行，吧唧居中盖在它上面
local Over = WidgetContainer:extend{}

function Over:getSize()
    return self.dimen
end

function Over:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local main = self[1]
    if main then
        local s = main:getSize()
        main:paintTo(bb, x + math.floor((self.dimen.w - s.w) / 2), y + math.floor((self.dimen.h - s.h) / 2))
    end
    if self[2] then self[2]:paintTo(bb, x, y) end
end

--- 取当前该显示的图：固定一张，或文件夹里按节奏挑
---@param conf table
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@return string|nil, boolean 图片路径, 是否"只是没配"（用于给不同提示）
function View.pickSrc(conf, prefix)
    local pick = Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file")
    local lfs = require("libs/libkoreader-lfs")
    if pick == "folder" then
        local dir = conf[prefix .. "dir"]
        if type(dir) ~= "string" or dir == "" then return nil, false end
        local list = require("moonbeautify.pick").listImages(dir)
        if #list == 0 then return nil, true end
        local mode = Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily")
        return require("moonbeautify.pick").choose(list, mode), true
    end
    local src = conf[prefix .. "src"]
    if type(src) ~= "string" or src == "" then return nil, false end
    if lfs.attributes(src, "mode") ~= "file" then return nil, true end
    return src, true
end

--- 把吧唧塞进贴图条之上（没贴图就居中一个）
---@param w number
---@param h number
---@param slots table|nil
---@param main table
---@return table
local function mount(w, h, slots, main)
    if not slots then
        return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, main }
    end
    return Over:new{
        dimen = Geom:new{ w = w, h = h },
        main,
        slots,
    }
end

--- 尺寸档位 → 吧唧边长占可用短边的比例
local SIZE_SCALE = { s = 0.60, m = 0.80, l = 1.00 }

--- 吧唧：拟真（圆/圆角/直角 + 倒角 / 侧影 / 高光 / 特效 / 叠加素材 / 慢转）+ 贴图条
---@param w number
---@param h number
---@param prefix string|nil 配置前缀，缺省 "badge_"
---@return table
--- 读选区配置：{ x, y, w, h }（0..1）。非法或缺省返回 nil。
---@param value any
---@return table|nil
function View.focusOf(value)
    if type(value) ~= "table" then return nil end
    local x, y = tonumber(value.x), tonumber(value.y)
    local w, h = tonumber(value.w), tonumber(value.h)
    if not (x and y and w and h) then return nil end
    if w <= 0 or h <= 0 then return nil end
    return { x = x, y = y, w = w, h = h }
end

function View.badge(w, h, prefix)
    prefix = prefix or "badge_"
    local conf = Store.conf()
    local src = View.pickSrc(conf, prefix)
    local slots = require("moonbeautify.slots").build(w, h, conf[prefix .. "slots"])
    if not src then
        if slots then return mount(w, h, slots, View.placeholder(w, h, "")) end
        return View.placeholder(w, h, "在组件设置里选一张图或一个文件夹")
    end
    local size = Store.enum(conf, prefix .. "size", { s = true, m = true, l = true }, "m")
    local scale = SIZE_SCALE[size] or SIZE_SCALE.m
    local opts = {
        shape = Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle"),
        effects = conf[prefix .. "effects"],
        overlay = conf[prefix .. "overlay"],
        spin = tonumber(conf[prefix .. "spin"]) or 0,
        ring = conf[prefix .. "ring"],
        fit = Store.enum(conf, prefix .. "fit", { stretch = true, fill = true, fit = true }, "stretch"),
        ax = tonumber(conf[prefix .. "anchor_x"]) or 0.5,
        ay = tonumber(conf[prefix .. "anchor_y"]) or 0.5,
        focus = View.focusOf(conf[prefix .. "focus"]),
    }
    local ok, widget = pcall(require("moonbeautify.badge").widget,
        math.max(24, math.floor(w * scale)), math.max(24, math.floor(h * scale)), src, opts)
    if not ok then
        pcall(function() require("utils.log").warn("moonbeautify badge:", tostring(widget)) end)
    end
    if not (ok and widget) then
        -- 合成失败：退回最朴素的圆图，至少能看
        return mount(w, h, slots, View.circle(w, h, src))
    end
    return mount(w, h, slots, widget)
end

--- 给任意组件内容套一层背景图 / 顶层图（补丁用）。src 可以为空（只加顶层图或内边距）。
---@param w number
---@param h number
---@param src string|nil 背景图绝对路径
---@param veil number 0-100 提亮比例，越大内容越清楚
---@param inner table 组件内容
---@param lace string|nil 顶层图片（透明 PNG 保留镂空，普通图片整张覆盖）
---@param fit string|nil 背景填充方式（兼容旧配置，当前背景按取景铺满）
---@param anchor table|nil 背景取景焦点 { x, y }
---@param focus table|nil 背景选区 { x, y, w, h }
---@param laceFocus table|nil 顶层图选区 { x, y, w, h }
---@return table
function View.background(w, h, src, veil, inner, lace, fit, anchor, focus, laceFocus)
    local stack = Stack:new{ dimen = Geom:new{ w = w, h = h } }
    if type(src) == "string" and src ~= "" then
        stack[1] = require("moonbeautify.bg").layer(src, w, h, fit, anchor, focus)
    end
    stack[2] = inner
    stack.veil = veil
    if type(lace) == "string" and lace ~= "" then
        stack.lace = require("moonbeautify.deco").frame(lace, w, h, laceFocus)
    end
    return stack
end

return View
