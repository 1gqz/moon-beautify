--[[--
月读设置页「外观 → 美化 → 月华美化」入口：本扩展的全部配置项集中在这一页。
「美化」小节由 core.patch 在打开外观组时拆出，不改月读源码。

@module moonbeautify.ui.settings
--]]

local Row = require("ui.themes.widgets.row")
local Overlay = require("desktop.pages.setting.overlay")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local TabPage = require("moonbeautify.ui.tab_page")
local DecorPage = require("moonbeautify.ui.decor_page")
local RowsPage = require("moonbeautify.ui.rows_page")
local ThemePage = require("moonbeautify.ui.theme_page")

local Settings = {}

--- 月读设置页「外观 → 美化 → 月华美化」：本扩展的全部配置项集中在这一页。
---@param desktop table|nil
---@return table[]
function Settings.entries(desktop)
    local Update = require("moonbeautify.core.update")
    local function count(map)
        local n = 0
        for k in pairs(type(map) == "table" and map or {}) do if k ~= "all" then n = n + 1 end end
        return n
    end
    local function nav(icon, title, subtitle, open)
        return function(iw)
            return Row.widget({
                width = iw, icon = icon, title = title, subtitle = subtitle,
                chevron = true, callback = open,
            })
        end
    end
    local function sections()
        local conf = Store.conf()
        local tab_count = count(conf.tab_icons)
        local bg_count = count(conf.widget_bg)
        local lace_count = count(conf.widget_lace)
        local row_count = type(conf.rows) == "table" and #conf.rows or 0
        local custom_order = type(conf.tab_order) == "table" and #conf.tab_order > 0
        local ime = type(conf.ime_bg) == "table" and conf.ime_bg or nil
        local has_ime_bg = ime and type(ime.src) == "string" and ime.src ~= ""
        local key_alpha = ime and tonumber(ime.key_alpha) or 0
        local Regions = require("moonbeautify.core.ime_regions")
        if ime then Regions.migrate(ime) end
        local has_ime_key = ime and (Regions.anySkin(ime) or key_alpha > 0)
        local theme_count = #require("moonbeautify.themes.theme").list()
        local ver = Update.version()
        local auto = Update.autoEnabled()
        local wp_on, ls_on = false, false
        pcall(function() wp_on = require("features.wallpaper").anyEnabled() end)
        pcall(function() ls_on = require("features.lockscreen.settings").isCompose() end)
        --- 打开月读原生设置页（壁纸 / 锁屏）；失败提示需要月读
        local function openMoon(build)
            local ok, page = pcall(build)
            if ok and page then
                Overlay.push(desktop, page)
            else
                require("moonbeautify.ui.common").toast(_("需要月读"))
            end
        end
        return {
            { title = _("首页"), rows = {
                nav("dashboard", _("底栏图标"),
                    tab_count > 0 and T(_("已自定义 %1 个"), tab_count)
                        or custom_order and _("底栏图标已重新排列")
                        or _("换图标、调整顺序"),
                    function() Overlay.push(desktop, TabPage.page(desktop)) end),
                nav("image", _("组件背景"),
                    bg_count > 0 and T(_("已设置 %1 个组件"), bg_count) or _("给首页组件加背景图"),
                    function() DecorPage.bgPage(desktop) end),
                nav("border_style", _("组件花边"),
                    lace_count > 0 and T(_("%1 个组件已配"), lace_count) or _("给首页组件加一圈花边"),
                    function() DecorPage.lacePage(desktop) end),
                nav("view_column", _("并排组合"),
                    row_count > 0 and T(_("已有 %1 组"), row_count) or _("两个组件挤同一行"),
                    function() RowsPage.page(desktop) end),
            } },
            { title = _("壁纸"), rows = {
                nav("wallpaper", _("界面壁纸"),
                    wp_on and _("开 · 月读外观设置") or _("关 · 月读外观设置"),
                    function()
                        openMoon(function()
                            return require("features.wallpaper.setting").entries(desktop)[1].page
                        end)
                    end),
                nav("lock", _("锁屏壁纸"),
                    ls_on and _("开 · 月读安全设置") or _("关 · 月读安全设置"),
                    function()
                        openMoon(function()
                            return require("features.lockscreen.setting").entries(desktop)[1].page
                        end)
                    end),
            } },
            { title = _("输入法"), rows = {
                nav("apps", _("输入法"),
                    (has_ime_bg or has_ime_key)
                        and (has_ime_bg and has_ime_key and _("已设置背景与按键")
                            or has_ime_bg and _("已设置背景图")
                            or (type(ime.key_src) == "string" and ime.key_src ~= ""
                                and _("已设置按键皮肤")
                                or T(_("透明度 %1%"), key_alpha)))
                        or _("分区键皮 · 布局预览"),
                    function() require("moonbeautify.ui.ime_layout").show(desktop) end),
            } },
            { title = _("主题"), rows = {
                nav("save", _("主题"),
                    theme_count > 0 and T(_("%1 套已保存，可随时切换"), theme_count)
                        or _("整套美化连图片存档、分享、一键切换"),
                    function() Overlay.push(desktop, ThemePage.pageTable(desktop)) end),
            } },
            { title = _("更新"), rows = {
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "toggle", icon = "update",
                        title = _("自动检查更新"),
                        subtitle = _("每天最多一次，发现新版本时弹窗提示"),
                        status = auto and _("开") or _("关"), status_on = auto,
                        callback = function()
                            Update.setAuto(not auto)
                            if desktop then pcall(function() desktop:updateView() end) end
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "action", icon = "settings_suggest",
                        title = _("检查更新"),
                        status = ver or "", status_on = true,
                        callback = function() Update.check(false) end,
                    })
                end,
            } },
        }
    end
    return {
        {
            id = "main",
            group = "appearance",
            order = 44,
            icon = "auto_awesome",
            title = _("月华美化"),
            subtitle = _("吧唧、相框、组件外观与主题"),
            page = { title = _("月华美化"), sections = sections },
        },
    }
end

return Settings
