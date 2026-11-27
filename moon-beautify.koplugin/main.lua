-- 月读扩展约定：main.lua 返回一个空的 WidgetContainer 就行，本体逻辑都在
-- moon_source.lua（扩展描述）和 moonbeautify/（子模块）里。
-- 月读没装或低于 0.8.0 时只弹一次提示，什么都不做（moon_source.lua 自己也会拦）。
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local problem = require("moonbeautify.core.moon_check").problem()
if not problem then return WidgetContainer:new{ name = "moonbeautify" } end

-- KOReader 给文件管理器和阅读器各建一个实例，提示只弹一次。
local shown = false
return WidgetContainer:extend{
    name = "moonbeautify",
    init = function()
        if shown then return end
        shown = true
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = problem })
    end,
}
