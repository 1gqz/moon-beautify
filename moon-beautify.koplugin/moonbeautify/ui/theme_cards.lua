--[[--
主题部件的卡片、图片网格、并排关系行和部件操作菜单。

@module moonbeautify.ui.theme_cards
--]]

local lfs = require("libs/libkoreader-lfs")
local Image = require("utils.image")
local Row = require("ui.themes.widgets.row")
local Pick = require("moonbeautify.core.pick")
local _ = require("moonbeautify.l10n")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template
local Store = require("moonbeautify.core.store")
local Theme = require("moonbeautify.themes.theme")
local Common = require("moonbeautify.ui.common")
local repaint, pickPath, choose, componentList, toast, refreshOverlay = Common.repaint, Common.pickPath, Common.choose, Common.componentList, Common.toast, Common.refreshOverlay

local M = {}

--- 部件：启用/停用、查看信息
---@param desktop table|nil
---@param part table Theme.parts() 返回的部件
local function themePartItem(desktop, part)
    local Theme = require("moonbeautify.themes.theme")
    local conf = Store.conf()
    local active = conf.theme_parts and conf.theme_parts[part.slot] == part.id

    local PartCopy = require("moonbeautify.themes.part_copy")
    local imageCount = #PartCopy.images(part.conf)
    local items = {
        { value = "toggle", text = active and _("停用这个部件") or _("启用这个部件"),
          mandatory = active and _("当前已启用") or _("只替换它负责的设置") },
    }
    if imageCount > 0 then
        items[#items + 1] = { value = "copy", text = _("复制到其他文件夹"),
            mandatory = T(_("%1 项图片/文件夹改用新路径，可脱离主题包"), tostring(imageCount)) }
    end
    items[#items + 1] = { value = "delete", text = _("删除这个部件"), mandatory = _("从主题包移除并清理图片") }
    choose(_(part.name or part.id), items, nil, function(v)
        if v == "toggle" then
            local ok, err = Theme.applyPart(part.theme, part.slot, not active)
            if ok then
                refreshOverlay(desktop)
                repaint(desktop)
                toast(active and _("已停用部件") or _("已启用部件"))
            else
                toast(T(_("操作失败：%1"), err or ""))
            end
        elseif v == "copy" then
            pickPath(desktop, nil, false, function(dir)
                local newConf, files, failed = PartCopy.copyTo(part.conf, dir)
                if #files == 0 then
                    toast(failed > 0 and _("复制失败，请检查目标文件夹是否可写")
                        or _("没有可复制的图片"))
                    return
                end
                PartCopy.apply(part, newConf)
                local ok, err = Theme.updatePartConf(part.theme, part.slot, newConf)
                repaint(desktop)
                refreshOverlay(desktop)
                if not ok then
                    toast(T(_("图片已复制，但主题存档没改成：%1"), err or ""), 5)
                elseif failed > 0 then
                    toast(T(_("已复制 %1 项，%2 项失败（保留原路径）"),
                        tostring(#files), tostring(failed)), 5)
                else
                    toast(T(_("已复制 %1 项图片到 %2，之后可以删除原主题包"),
                        tostring(#files), dir), 5)
                end
            end)
        elseif v == "delete" then
            choose(_("确认删除部件"), {
                { value = "yes", text = _("删除"), mandatory = _(part.name or part.slot) },
                { value = "no", text = _("取消") },
            }, nil, function(confirm)
                if confirm ~= "yes" then return end
                local ok, err = Theme.deletePart(part.theme, part.slot)
                if ok then
                    refreshOverlay(desktop)
                    repaint(desktop)
                    toast(_("已删除部件"))
                else
                    toast(T(_("删除失败：%1"), err or ""))
                end
            end)
        end
    end)
end

local function resolveCardAsset(raw, theme)
    if type(raw) ~= "string" or raw == "" then return nil end
    if raw:sub(1, 8) == "@assets/" then
        local dir = Theme.dir(theme)
        if not dir then return nil end
        return dir .. "/assets/" .. raw:sub(9)
    end
    return raw
end

--- 收集一个部件里的全部图片：单图直接列，文件夹展开成多张
local function collectPartImages(part)
    local out, seen = {}, {}
    local function add(path)
        if not path or seen[path] then return end
        local mode = lfs.attributes(path, "mode")
        if mode == "file" then
            if Image.suffix(path) then
                seen[path] = true
                out[#out + 1] = path
            end
        elseif mode == "directory" then
            seen[path] = true
            for _i, p in ipairs(Pick.listImages(path)) do
                if not seen[p] then seen[p] = true; out[#out + 1] = p end
            end
        end
    end
    local function walk(v)
        if type(v) == "string" then
            add(resolveCardAsset(v, part.theme))
        elseif type(v) == "table" then
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _i, k in ipairs(keys) do walk(v[k]) end
        end
    end
    walk(part.conf)
    return out
end

--- 图片缩略图网格：按可用宽度均分列宽，居中对齐，行距收紧
---@return table widget, integer 实际行数
local function imageGrid(paths, width, thumb, max_rows)
    local UITheme = require("ui.themes")
    local ImageWidget = require("ui.themes.widgets.image")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local t = UITheme.current()
    local gap = UITheme.px(t.space.xs)
    thumb = thumb or UITheme.px(48)
    local per_row = math.max(1, math.floor((width + gap) / (thumb + gap)))
    local rows, row, n = {}, HorizontalGroup:new{}, 0
    for _i, path in ipairs(paths) do
        if max_rows and #rows >= max_rows then break end
        if n > 0 and n % per_row == 0 then
            rows[#rows + 1] = row
            row = HorizontalGroup:new{}
        end
        if n % per_row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = ImageWidget.widget{
            src = path, width = thumb, height = thumb,
            style = { border = 0, shadow = 0 }, alpha = true, stretch = true,
        }
        n = n + 1
    end
    if #row > 0 then rows[#rows + 1] = row end  -- 正好铺满一行时也要收进去

    local out = VerticalGroup:new{ align = "center" }
    for i, r in ipairs(rows) do
        if i > 1 then out[#out + 1] = VerticalSpan:new{ width = gap } end
        local used = 0
        for _i, widget in ipairs(r) do used = used + widget:getSize().w end
        local rest = math.max(0, width - used)
        out[#out + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = math.floor(rest / 2) },
            r,
            HorizontalSpan:new{ width = rest - math.floor(rest / 2) },
        }
    end
    return out, #rows
end

--- 一个主题里只有一份的类型：页面/分组标题已经说明是什么，行内不再重复写部件名
local SINGLETON_PART_TYPES = {
    icons = true, wallpaper = true, lockscreen = true, ime = true,
}

local function partNeedsLabel(typeKey)
    return not SINGLETON_PART_TYPES[typeKey]
end

--- 缩略图尺寸：壁纸、锁屏壁纸、键盘背景显著放大，其它部件保持图标大小
local function thumbForType(typeKey)
    local UITheme = require("ui.themes")
    if typeKey == "wallpaper" or typeKey == "lockscreen" or typeKey == "ime" then
        return UITheme.px(112)
    end
    return UITheme.px(44)
end

--- 虚线分隔：短横 + 空隙交替
local function dashedLine(width, color, h)
    local UITheme = require("ui.themes")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LineWidget = require("ui/widget/linewidget")
    local Blitbuffer = require("ffi/blitbuffer")
    local g = HorizontalGroup:new{}
    local dash, space, x = UITheme.px(8), UITheme.px(5), 0
    while x < width do
        local w = math.min(dash, width - x)
        g[#g + 1] = LineWidget:new{
            background = Blitbuffer.Color8(color), dimen = Geom:new{ w = w, h = h },
        }
        x = x + w
        if x < width then
            local s = math.min(space, width - x)
            g[#g + 1] = HorizontalSpan:new{ width = s }
            x = x + s
        end
    end
    return g
end

--- 单个部件的一行：多实例类型显示部件名，单例类型只显示图片
---@param is_last boolean 是否为该主题最后一行（最后一行实线，其余虚线）
local function partImagesRow(desktop, part, width, typeKey, is_last)
    local UITheme = require("ui.themes")
    local Geom = require("ui/geometry")
    local Text = require("ui.themes.widgets.text")
    local Tap = require("ui.themes.widgets.tap")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local t = UITheme.current()
    local show_label = partNeedsLabel(typeKey)
    local label = show_label and _(part.name or part.label or part.slot or part.type) or nil
    local imgs = collectPartImages(part)
    local thumb = thumbForType(typeKey)
    local gap = show_label and UITheme.px(t.space.md) or 0
    local label_w = 0
    if show_label then
        label_w = math.min(UITheme.px(120), math.max(UITheme.px(72), math.floor(width * 0.24)))
    end

    local grid = imageGrid(imgs, width - label_w - gap, thumb)
    local row_h = math.max(grid:getSize().h, thumb + UITheme.px(t.space.sm) * 2)
    local content
    if show_label then
        local label_wd = CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = row_h },
            Text.line("caption", label, { width = label_w - UITheme.px(t.space.xs) * 2,
                color = UITheme.color(t.color.chrome) }),
        }
        content = CenterContainer:new{
            dimen = Geom:new{ w = width, h = row_h },
            HorizontalGroup:new{ align = "center", label_wd, HorizontalSpan:new{ width = gap }, grid },
        }
    else
        content = CenterContainer:new{ dimen = Geom:new{ w = width, h = row_h }, grid }
    end
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local divider = math.max(1, UITheme.px(t.row.divider))
    local line = is_last
        and LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = width, h = divider },
        }
        or dashedLine(width, t.color.rule, divider)
    local wrapped = VerticalGroup:new{ align = "left", content, line }
    if desktop then
        return Tap.wrap(wrapped, function() themePartItem(desktop, part) end)
    end
    return wrapped
end

--- 并排关系去重用的稳定键
local function relationKey(row)
    local ids = {}
    for _i, id in ipairs(type(row) == "table" and row or {}) do
        if id ~= nil and id ~= "" then ids[#ids + 1] = tostring(id) end
    end
    table.sort(ids)
    return table.concat(ids, "|")
end

--- 从部件槽位还原组件 id（comp_clock → clock）
local function partCompId(part)
    return type(part.slot) == "string" and part.slot:match("^comp_(.+)$") or nil
end

--- 并排成员显示名：系统组件用官方名称，合成组件用部件名兜底
local function relationLabels(parts)
    local labels = {}
    for _i, comp in ipairs(componentList()) do
        labels[comp.id] = comp.label or comp.id
    end
    for _i, part in ipairs(parts) do
        local id = partCompId(part)
        if id and not labels[id] then labels[id] = _(part.name or part.label or id) end
    end
    return labels
end

local function relationText(row, labels)
    local names = {}
    for _i, id in ipairs(row or {}) do
        names[#names + 1] = labels[tostring(id)] or tostring(id)
    end
    return table.concat(names, " + ")
end

--- 并排组合单独成行：图标、编号、成员名，避免跟普通组件图片混在一起
local function relationRow(desktop, info, width, labels, index, is_last)
    local UITheme = require("ui.themes")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local t = UITheme.current()
    local divider = math.max(1, UITheme.px(t.row.divider))
    local line = is_last
        and LineWidget:new{
            background = Blitbuffer.Color8(t.color.rule),
            dimen = Geom:new{ w = width, h = divider },
        }
        or dashedLine(width, t.color.rule, divider)
    local row = Row.widget({
        width = width,
        icon = "view_column",
        title = T(_("并排组合 %1"), tostring(index)),
        subtitle = relationText(info.row, labels),
        chevron = true,
        divider = false,
        callback = desktop and function() themePartItem(desktop, info.part) end or nil,
    })
    return VerticalGroup:new{ align = "left", row, line }
end

--- 部件按来源主题分组。
--- 组件页每个主题只保留主题标题：先列有图片的组件，再列并排组合关系。
local function appendCardGrid(desktop, parts, typeKey)
    local groups = {}
    for _i, part in ipairs(parts) do
        local src = part.theme or _("未知主题")
        if not groups[src] then groups[src] = {} end
        groups[src][#groups[src] + 1] = part
    end
    local names = {}
    for n in pairs(groups) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then
        return { { title = _("部件"), rows = { function(iw)
            return Row.widget({ width = iw, icon = "palette", chevron = false,
                title = _("还没有部件"), subtitle = _("先保存或导入一套主题") })
        end } } }
    end
    local sections = {}
    for _i, name in ipairs(names) do
        local group = groups[name]
        if typeKey == "component" then
            local images, relations, seen = {}, {}, {}
            local labels = relationLabels(group)
            for _i, part in ipairs(group) do
                if #collectPartImages(part) > 0 then
                    images[#images + 1] = part
                end
                for _i, row in ipairs(type(part.conf) == "table" and type(part.conf.rows) == "table"
                        and part.conf.rows or {}) do
                    local key = relationKey(row)
                    if key ~= "" and not seen[key] then
                        seen[key] = true
                        relations[#relations + 1] = { part = part, row = row, text = relationText(row, labels) }
                    end
                end
            end
            table.sort(relations, function(a, b) return a.text < b.text end)
            local total = #images + #relations
            local rows = {}
            for _i, part in ipairs(images) do
                local last = _i == total
                rows[#rows + 1] = function(iw)
                    return partImagesRow(desktop, part, iw, typeKey, last)
                end
            end
            for _i, info in ipairs(relations) do
                local last = (#images + _i) == total
                rows[#rows + 1] = function(iw)
                    return relationRow(desktop, info, iw, labels, _i, last)
                end
            end
            if #rows > 0 then
                sections[#sections + 1] = {
                    title = name, rows = rows, title_style = "body", title_bold = true,
                }
            end
        else
            local rows = {}
            for _i, part in ipairs(group) do
                rows[#rows + 1] = function(iw)
                    return partImagesRow(desktop, part, iw, typeKey, _i == #group)
                end
            end
            sections[#sections + 1] = {
                title = name, rows = rows, title_style = "body", title_bold = true,
            }
        end
    end
    return sections
end

M.collectPartImages = collectPartImages
M.partImagesRow = partImagesRow
M.appendCardGrid = appendCardGrid

return M
