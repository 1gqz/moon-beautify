local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
if not package.path:find(PLUGIN_DIR .. "/?.lua", 1, true) then
    package.path = PLUGIN_DIR .. "/?.lua;" .. package.path
end
local _ = require("moonbeautify.l10n")
return {
    name = "moonbeautify",
    fullname = _("月华美化"),
    version = "0.1.4",
    description = _("月读扩展：首页吧唧与相框组件，组件背景与花边、并排组合、底栏图标、输入法键盘背景，以及可分享的部件化主题包。所有配置在「设置 → 外观 → 月华美化」，不改月读本体，卸载不丢配置。"),
}
