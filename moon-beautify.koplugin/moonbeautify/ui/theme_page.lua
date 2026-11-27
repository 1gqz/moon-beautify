--[[--
主题页：保存、导入、按类型/按主题浏览与预览。

@module moonbeautify.ui.theme_page
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local Row = require("ui.themes.widgets.row")
local Input = require("ui.themes.widgets.input")
local Overlay = require("desktop.pages.setting.overlay")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Theme = require("moonbeautify.themes.theme")
local Common = require("moonbeautify.ui.common")
local repaint, pickPath, choose, toast, refreshOverlay = Common.repaint, Common.pickPath, Common.choose, Common.toast, Common.refreshOverlay
local Cards = require("moonbeautify.ui.theme_cards")
local collectPartImages, partImagesRow, appendCardGrid = Cards.collectPartImages, Cards.partImagesRow, Cards.appendCardGrid

local M = {}

local themeTypePartsPage -- 二级页面前置声明

--- 保存当前配置为主题
---@param desktop table|nil
local function themeSave(desktop)
    local dialog = Input:new{
        title = _("主题名字"),
        fields = { { text = "", hint = _("例如 主题1") } },
        ok_text = _("保存"),
        callback = function(value)
            local Theme = require("moonbeautify.themes.theme")
            local safe = Theme.sanitize(value)
            if not safe then
                toast(_("名字不能为空"))
                return
            end
            if lfs.attributes(Theme.root() .. "/" .. safe, "mode") == "directory" then
                toast(_("该名称已被占用"))
                return
            end
            local ok, dir_or_err = Theme.save(safe)
            if ok then
                -- 保存当前配置只是做一份快照，不等于应用它。
                -- 当前配置仍指向本地图片/原主题，所以 active_theme 不能改，
                -- 否则新主题会显示“应用中”，但部件改动影响不到当前配置。
                refreshOverlay(desktop)
                toast(T(_("已保存为主题：%1（未应用）"), safe))
            else
                toast(T(_("保存失败：%1"), dir_or_err or ""))
            end
        end,
    }
    -- 选择器关闭动画期间直接开输入框会被顶掉，等下一帧再弹
    local deferred = false
    if UIManager.nextTick then
        deferred = pcall(function()
            UIManager:nextTick(function() dialog:show() end)
        end)
    end
    if not deferred then dialog:show() end
end

--- 从 zip 导入主题
---@param desktop table|nil
local function themeImport(desktop)
    local start = Store.conf().last_dir
    if not (type(start) == "string" and start ~= ""
        and lfs.attributes(start, "mode") == "directory") then
        start = require("apps/filemanager/filemanagerutil").getHomeFolder()
    end
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = true,
        filter = function(name) return name:lower():match("%.zip$") ~= nil end,
        on_select = function(path)
            local Theme = require("moonbeautify.themes.theme")
            local ok, name_or_err = Theme.importZip(path)
            if ok then
                refreshOverlay(desktop)
                toast(T(_("已导入主题：%1"), name_or_err))
            else
                toast(T(_("导入失败：%1"), name_or_err or ""))
            end
        end,
    }:show()
end

local function typeGridRow(desktop, width, rowTypes)
    local UITheme = require("ui.themes")
    local Parts = require("moonbeautify.themes.parts")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local gap = UITheme.px(UITheme.current().space.sm)
    local cell_w = math.floor((width - gap) / 2)
    local row = HorizontalGroup:new{}
    local function addCell(item, index)
        if not item then return end
        if index > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Row.widget({
            width = cell_w,
            icon = Parts.TYPE_ICON[item.key] or "palette",
            title = item.label or item.key,
            subtitle = T(_("%1 个已导入部件"), tostring(item.count)),
            chevron = true,
            callback = function()
                Overlay.push(desktop, themeTypePartsPage(desktop, item.key, item.label))
            end,
        })
    end
    addCell(rowTypes[1], 1)
    addCell(rowTypes[2], 2)
    return row
end

--- 主题预览页：按部件类型分组，把该主题下的图片全列出来
local function themePreviewPage(desktop, name)
    return {
        title = name,
        sections = function()
            local Theme = require("moonbeautify.themes.theme")
            local Parts = require("moonbeautify.themes.parts")
            local buckets = {}
            for _i, part in ipairs(Theme.parts(name)) do
                if #collectPartImages(part) > 0 then
                    local key = part.group or Parts.groupOfType(part.type)
                    if not buckets[key] then
                        buckets[key] = { label = _(Parts.TYPE_LABEL[key] or key), parts = {} }
                    end
                    buckets[key].parts[#buckets[key].parts + 1] = part
                end
            end
            local keys = {}
            for k in pairs(buckets) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local sections = {}
            for _i, k in ipairs(keys) do
                local group = buckets[k]
                local rows = {}
                for _i, part in ipairs(group.parts) do
                    rows[#rows + 1] = function(iw)
                        return partImagesRow(desktop, part, iw, k, _i == #group.parts)
                    end
                end
                sections[#sections + 1] = {
                    title = group.label, rows = rows, title_style = "body", title_bold = true,
                }
            end
            if #sections == 0 then
                sections[1] = { title = _("预览"), rows = { function(iw)
                    return Row.widget({ width = iw, icon = "palette", chevron = false,
                        title = _("这个主题没有图片"), subtitle = _("只有设置项") })
                end } }
            end
            return sections
        end,
    }
end

--- 单个主题：预览 / 应用 / 导出 / 删除
---@param desktop table|nil
---@param name string
---@param active string|nil 当前应用中的主题名
local function themeItem(desktop, name, active)
    local applied = name == active
    choose(name, {
        { value = "preview", text = _("预览"),
          mandatory = _("查看该主题的所有图片") },
        { value = "apply", text = _("应用"),
          mandatory = applied and _("当前正在使用中") or _("点击应用") },
        { value = "export", text = _("导出主题 zip"),
          mandatory = _("导到指定文件夹") },
        { value = "delete", text = _("删除"),
          mandatory = applied and _("使用中的主题无法删除") or _("删掉存档和图片") },
    }, nil, function(v)
        local Theme = require("moonbeautify.themes.theme")
        if v == "preview" then
            Overlay.push(desktop, themePreviewPage(desktop, name))
        elseif v == "apply" then
            local ok, err = Theme.apply(name)
            if ok then
                refreshOverlay(desktop)
                repaint(desktop)
                toast(_("已使用该主题"))
            else
                toast(T(_("应用失败：%1"), err or ""))
            end
        elseif v == "export" then
            pickPath(desktop, nil, false, function(dir)
                local ok, path_or_err = Theme.export(name, dir)
                if ok then
                    toast(T(_("已导出：%1"), path_or_err), 5)
                else
                    toast(T(_("导出失败：%1"), path_or_err or ""))
                end
            end)
        elseif v == "delete" then
            local ok, err = Theme.delete(name)
            if ok then
                refreshOverlay(desktop)
                toast(_("已删除主题"))
            elseif err == "beautify_in_use" then
                toast(_("应用中删除失败，请先应用其他主题"))
            else
                toast(T(_("删除失败：%1"), err or _("主题目录删不掉")))
            end
        end
    end)
end

--- 部件类型页：整页只列各种部件类型
local function themeTypesPageTable(desktop)
    return {
        title = _("部件类型"),
        sections = function()
            local Theme = require("moonbeautify.themes.theme")
            local Parts = require("moonbeautify.themes.parts")
            local counts = {}
            for _i, part in ipairs(Theme.allParts()) do
                local key = part.group or Parts.groupOfType(part.type)
                counts[key] = (counts[key] or 0) + 1
            end
            local types = {}
            for _i, key in ipairs({ "icons", "badge", "frame", "component",
                                   "wallpaper", "lockscreen", "ime" }) do
                types[#types + 1] = { key = key, label = _(Parts.TYPE_LABEL[key] or key),
                                      count = counts[key] or 0 }
            end
            local rows = {}
            for i = 1, #types, 2 do
                local pair = { types[i], types[i + 1] }
                rows[#rows + 1] = function(iw) return typeGridRow(desktop, iw, pair) end
            end
            return { { rows = rows } }
        end,
    }
end

--- 某个部件类型下的部件页
themeTypePartsPage = function(desktop, typeKey, label)
    return {
        title = label or _(require("moonbeautify.themes.parts").TYPE_LABEL[typeKey] or typeKey),
        sections = function()
            local Theme = require("moonbeautify.themes.theme")
            local Parts = require("moonbeautify.themes.parts")
            local parts = {}
            for _i, part in ipairs(Theme.allParts()) do
                local group = part.group or Parts.groupOfType(part.type)
                if group == typeKey then parts[#parts + 1] = part end
            end
            return appendCardGrid(desktop, parts, typeKey)
        end,
    }
end

--- 主题类型页：整页罗列已导入主题
local function themeTypeListPage(desktop)
    return {
        title = _("主题类型"),
        sections = function()
            local Theme = require("moonbeautify.themes.theme")
            local active = Store.conf().active_theme
            local rows = {}
            for _idx, name in ipairs(Theme.list()) do
                rows[#rows + 1] = function(iw)
                    local n, kb = Theme.stat(name)
                    local applied = name == active
                    return Row.widget({
                        width = iw, icon = "palette", title = name,
                        subtitle = T(_("%1 张图 · %2 KB"), n, kb),
                        status = applied and (Theme.dirty(name) and _("应用中（有修改）") or _("应用中")) or nil,
                        status_on = applied, chevron = true,
                        callback = function() themeItem(desktop, name, active) end,
                    })
                end
            end
            if #rows == 0 then
                rows[1] = function(iw)
                    return Row.widget({ width = iw, icon = "palette", chevron = false,
                        title = _("还没有主题"), subtitle = _("先保存当前配置，或导入一个 zip") })
                end
            end
            return { { rows = rows } }
        end,
    }
end

--- 主题主页：保存与导入 + 主题使用
---@param desktop table|nil
---@return table page
local function themePageTable(desktop)
    return {
        title = _("主题"),
        sections = function()
            return {
                { title = _("保存与导入"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "save", chevron = true,
                            title = _("当前配置保存为主题"),
                            subtitle = _("保存当前整套设置配置"),
                            callback = function() themeSave(desktop) end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "download", chevron = true,
                            title = _("导入主题 zip"),
                            subtitle = _("不管 zip 在哪，导入即归档到固定目录"),
                            callback = function() themeImport(desktop) end,
                        })
                    end,
                } },
                { title = _("主题使用"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "dashboard_customize", chevron = true,
                            title = _("按部件类型"),
                            subtitle = _("底栏图标 / 吧唧 / 相框 / 壁纸…"),
                            callback = function() Overlay.push(desktop, themeTypesPageTable(desktop)) end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "palette", chevron = true,
                            title = _("按主题类型"),
                            subtitle = _("按导入的套装查看，可预览里面各部件"),
                            callback = function() Overlay.push(desktop, themeTypeListPage(desktop)) end,
                        })
                    end,
                } },
            }
        end,
    }
end

M.pageTable = themePageTable

return M
