--[[--
统一的「图片怎么摆进框」配置：所有用图组件共用同一套术语、顺序和选项。

四种填充方式（与 moonbeautify.bg 的实现对应）：
  stretch  拉伸铺满   图直接拉到框大小，可能变形
  fill     填满裁边   等比放大到盖满框，多出的边裁掉，可按取景焦点选留哪块
  fit      完整留白   等比缩到刚好装进框，四周留白
  tile     平铺重复   先按宽缩放，再纵向重复（只适合底纹，花边/吧唧/相框不提供）

组件按需取子集：花边/吧唧/相框没有 tile。取景焦点只在 fill 时有用。

@module moonbeautify.fit
--]]--

local Fit = {}

--- 显示名。用户只要「填满裁边」一种，其余仅为兼容旧配置保留，不出现在选项里。
Fit.LABEL = {
    fill = "填满裁边",
    stretch = "拉伸铺满",
    fit = "完整留白",
    tile = "平铺重复",
}

--- 唯一展示的顺序。
Fit.ORDER = { "fill" }

--- 设置页选项：统一只有「填满裁边」。
---@param with_tile boolean|nil 兼容旧调用，忽略
---@return string[]
function Fit.modes(with_tile)
    return { "fill" }
end

--- 是否允许改取景选区：填满裁边始终可以。
---@param mode string|nil
---@return boolean
function Fit.needsAnchor(mode)
    return true
end

return Fit
