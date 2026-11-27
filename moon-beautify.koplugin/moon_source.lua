--[[--
月读扩展描述：不是书源。往首页加吧唧 / 相框组件，并补丁底栏图标、组件背景与顶层图、并排组合、壁纸与键盘美化等。

契约（api = 1，id = ext.<name>，provides.source = false）：
  home_widgets 简写表 { id, title, icon, build = fun(ctx, w, h), heightRange = fun(ctx, opts), settings = fun(desktop, id) }
  build 返回占满 w × h 的控件；settings 让首页编辑态出现设置按钮（设置里抛错会被月读记日志）。
  provides.features.setting 往「设置 → 外观」加「月华美化」页，全部配置项都在里面。
组件 id 由月读补成 ext.beautify.<短名>，发布后不要改。

--]]

local _ = require("moonbeautify.l10n")

local ID = "ext.beautify"

-- 月读低于 0.8.0：不装补丁、不登记任何能力，提示由 main.lua 弹。
if require("moonbeautify.core.moon_check").problem() then
    return { api = 1, id = ID, provides = { source = false } }
end

-- 加载信号：月读首次访问源注册表时 dofile 本文件；日志里有这行说明描述表被认了。
pcall(function()
    local Log = require("utils.log")
    Log.dbg("moonbeautify descriptor loaded")
    if Log.flush then Log.flush() end
end)

-- 补丁：图标图片化 / 底栏换图 / 组件背景。必须在首页第一次 build 之前装上（本文件就是那个时机）。
pcall(function() require("moonbeautify.core.patch").install() end)

-- 更新检查：挂到「桌面回到前台」，每天最多查一次（和月读自己的更新检查同一个事件）
pcall(function() require("moonbeautify.core.update").install() end)

--- 高度按可用宽度的比例报，跟屏幕大小无关；用户在编辑态里还能自己拖。
--- 这里按「最大档」给足高度，具体直径由设置里的尺寸决定（s/m/l 缩放边长），
--- 这样改尺寸只动吧唧大小，不会把整页排版顶来顶去。
local RATIO = 0.62

---@param opts table|nil { width }
---@return { height: number }
local function heightOf(opts)
    local w = (opts and opts.width) or 540
    return { height = math.max(60, math.floor(w * RATIO)) }
end

--- 相框组件：一叠照片，左右滑动翻看。高度按宽度给一个偏方的比例。
--- 别设太高：超高组件占满整页会把首页翻页条和滑动翻页空间挤没。
local FRAME_RATIO = 0.62
local function frameWidget(id, title)
    local prefix = id .. "_"
    return {
        id = id,
        title = title,
        icon = "image",
        heightRange = function(_ctx, opts)
            local w = (opts and opts.width) or 540
            return { height = math.max(80, math.floor(w * FRAME_RATIO)) }
        end,
        build = function(_ctx, w, h)
            return require("moonbeautify.widgets.frame").build(w, h, prefix)
        end,
        settings = function(desktop, _id)
            require("moonbeautify.ui.widget_page").showFrame(prefix, desktop)
        end,
    }
end

--- 造一个吧唧组件。月读的首页组件按 id 唯一，所以想放多个吧唧就得有多个 id，
--- 每个 id 用「id + 下划线」当自己的配置前缀（badge_ / badge2_ / ...），互不干扰。
---@param id string
---@param title string
---@return table
local function badgeWidget(id, title)
    local prefix = id .. "_"
    return {
        id = id, -- 月读补成 ext.beautify.<id>
        title = title,
        icon = "image",
        heightRange = function(_ctx, opts) return heightOf(opts) end,
        build = function(_ctx, w, h)
            return require("moonbeautify.widgets.view").badge(w, h, prefix)
        end,
        settings = function(desktop, _id)
            -- 不在这里 pcall：月读的 guard 会 pcall 并记日志，套两层会把错误吞掉。
            require("moonbeautify.ui.widget_page").show(prefix, desktop)
        end,
    }
end

return {
    api = 1,
    id = ID,
    provides = {
        source = false,
        home_widgets = {
            badgeWidget("badge", _("吧唧1")),
            badgeWidget("badge2", _("吧唧2")),
            badgeWidget("badge3", _("吧唧3")),
            badgeWidget("badge4", _("吧唧4")),
            frameWidget("frame", _("相框1")),
            frameWidget("frame2", _("相框2")),
        },
        features = {
            setting = {
                entries = function(desktop)
                    return require("moonbeautify.ui.settings").entries(desktop)
                end,
            },
        },
    },
}
