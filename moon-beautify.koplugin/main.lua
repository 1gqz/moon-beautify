-- 月读扩展约定：main.lua 返回一个空的 WidgetContainer 就行，本体逻辑都在
-- moon_source.lua（扩展描述）和 moonbeautify/（子模块）里。
local WidgetContainer = require("ui/widget/container/widgetcontainer")

return WidgetContainer:new{ name = "moonbeautify" }
