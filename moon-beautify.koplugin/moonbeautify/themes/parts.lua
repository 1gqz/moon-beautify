--- 主题部件模型（v2）
--- 把原来「一整包 conf」拆成可独立启用/停用的部件，支持按类型/主题包分组。
local M = {}

--- 这些键是本机状态，不参与主题存档与图片收编。
--- theme_group_dim 是旧主题页留下的键，仅为兼容旧配置保留，当前界面不再读写。
M.LOCAL_KEYS = {
    theme_parts = true,
    part_backups = true,
    theme_group_dim = true,
}

--- 槽位定义。prefix/exact 决定一个配置键归哪个部件。
--- 顺序无关，匹配时按 key 长度优先，避免 badge_ 抢走 badge2_。
local SLOTS = {
    { slot = "tab_icons",  type = "icons",     label = "底栏图标", exact = { "tab_icons", "tab_order" } },
    { slot = "badge1",     type = "badge",     label = "吧唧 1",   prefix = { "badge_" } },
    { slot = "badge2",     type = "badge",     label = "吧唧 2",   prefix = { "badge2_" } },
    { slot = "badge3",     type = "badge",     label = "吧唧 3",   prefix = { "badge3_" } },
    { slot = "badge4",     type = "badge",     label = "吧唧 4",   prefix = { "badge4_" } },
    { slot = "frame1",     type = "frame",     label = "相框 1",   prefix = { "frame_" } },
    { slot = "frame2",     type = "frame",     label = "相框 2",   prefix = { "frame2_" } },
    { slot = "ime",        type = "ime",       label = "输入法键盘背景", exact = { "ime_bg" } },
}
M.TYPE_LABEL = {
    icons = "底栏图标",
    badge = "吧唧",
    frame = "相框",
    component = "组件配置",
    wallpaper = "界面壁纸",
    lockscreen = "锁屏壁纸",
    ime = "输入法键盘背景",
    misc = "其他",
}

M.TYPE_ICON = {
    icons = "dashboard_customize",
    badge = "badge",
    frame = "crop",
    component = "dashboard_customize",
    wallpaper = "wallpaper",
    lockscreen = "lock",
    ime = "keyboard",
    misc = "more_horiz",
}

--- 收拢后的类型层级：背景/花边/间距/排列都归到「组件」。
local GROUP_BY_TYPE = {
    icons = "icons",
    badge = "badge",
    frame = "frame",
    bg = "component",
    lace = "component",
    layout = "component",
    wallpaper = "wallpaper",
    lockscreen = "lockscreen",
    ime = "ime",
}

function M.groupOfType(type)
    return GROUP_BY_TYPE[type] or type or "misc"
end

local bySlot = {}
for _, spec in ipairs(SLOTS) do bySlot[spec.slot] = spec end

--- 部件 id：主题名/槽位，例如 "A的套装/badge1"
function M.partId(theme, slot)
    return tostring(theme) .. "/" .. tostring(slot)
end

function M.parsePartId(id)
    if type(id) ~= "string" then return nil, nil end
    local theme, slot = id:match("^(.*)/([^/]+)$")
    return theme, slot
end

local function owns(spec, key)
    if type(key) ~= "string" then return false end
    for _, k in ipairs(spec.exact or {}) do
        if key == k then return true end
    end
    for _, p in ipairs(spec.prefix or {}) do
        if key:sub(1, #p) == p then return true end
    end
    return false
end

local function specFor(key)
    -- 长前缀优先：badge2_ 要先于 badge_ 命中
    local best, bestLen
    for _, spec in ipairs(SLOTS) do
        for _, p in ipairs(spec.prefix or {}) do
            if key:sub(1, #p) == p and (not bestLen or #p > bestLen) then
                best, bestLen = spec, #p
            end
        end
    end
    if best then return best end
    for _, spec in ipairs(SLOTS) do
        if owns(spec, key) then return spec end
    end
    return { slot = "misc", type = "misc", label = "其他" }
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
M.copy = copy

--- 深度相等；number 留序列化精度容差（存档读回来的小数会差最后几位）
local function equal(a, b)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) == "number" then return math.abs(a - b) < 1e-9 end
    if type(a) ~= "table" then return false end
    for k, v in pairs(a) do
        if not equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
M.equal = equal

--- 递归改写配置里的字符串值：table 原地改，fn 返回 nil 会删掉该键
function M.walk(value, fn)
    if type(value) ~= "table" then return value end
    for k, v in pairs(value) do
        if type(v) == "string" then
            value[k] = fn(v)
        elseif type(v) == "table" then
            M.walk(v, fn)
        end
    end
    return value
end

--- 界面壁纸/锁屏存在月读原生设置里，不在 ext.beautify；各由一个模块读写（capture/apply/matches/shareable）
M.NATIVE_TYPES = { "wallpaper", "lockscreen" }
local NATIVE_MOD = {}
for _, t in ipairs(M.NATIVE_TYPES) do NATIVE_MOD[t] = "moonbeautify.themes." .. t .. "_part" end

--- 原生部件类型对应的读写模块；美化配置部件返回 nil
function M.native(ptype)
    local mod = NATIVE_MOD[ptype]
    return mod and require(mod) or nil
end

--- 组件部件负责的按组件 id 分片的配置表
local COMP_KEYS = { "widget_bg", "widget_lace", "widget_pad", "widget_border" }
local COMP_KEY_SET = {}
for _, key in ipairs(COMP_KEYS) do COMP_KEY_SET[key] = true end

local function compIdOfSlot(slot)
    if type(slot) ~= "string" then return nil end
    return slot:match("^comp_(.+)$")
end

local function rowHasComp(row, id)
    if type(row) ~= "table" then return false end
    for _, member in ipairs(row) do
        if member == id then return true end
    end
    return false
end

local function rowKey(row)
    if type(row) ~= "table" then return nil end
    local members = {}
    for _, member in ipairs(row) do members[#members + 1] = tostring(member) end
    table.sort(members)
    return table.concat(members, "\0")
end

local function componentLabel(id)
    if id == "all" then return "全部组件通用" end
    local ok, list = pcall(function()
        return require("desktop.pages.home.registry").list()
    end)
    if ok and type(list) == "table" then
        for _, comp in ipairs(list) do
            if comp.id == id then return comp.label or id end
        end
    end
    return id
end

--- 取属于某个槽位的配置键（深拷贝）
function M.extract(conf, slot)
    local out = {}
    if type(conf) ~= "table" then return out end
    local comp_id = compIdOfSlot(slot)
    if comp_id then
        for _, key in ipairs(COMP_KEYS) do
            -- 通用背景/花边已废弃，不能从旧配置里捞回 comp_all
            if not (comp_id == "all" and (key == "widget_bg" or key == "widget_lace")) then
                local map = conf[key]
                if type(map) == "table" and map[comp_id] ~= nil then
                    out[key] = { [comp_id] = copy(map[comp_id]) }
                end
            end
        end
        if type(conf.rows) == "table" then
            local rows = {}
            for _, row in ipairs(conf.rows) do
                if rowHasComp(row, comp_id) then rows[#rows + 1] = copy(row) end
            end
            if #rows > 0 then out.rows = rows end
        end
        return out
    end
    local spec = bySlot[slot]
    for k, v in pairs(conf) do
        if M.LOCAL_KEYS[k] then
            -- 部件库状态不属于任何部件
        elseif spec then
            if owns(spec, k) then out[k] = copy(v) end
        elseif specFor(k).slot == slot then
            out[k] = copy(v)
        end
    end
    return out
end

--- 从配置里清掉某个部件负责的键
function M.clear(conf, slot)
    if type(conf) ~= "table" then return end
    local comp_id = compIdOfSlot(slot)
    if comp_id then
        for _, key in ipairs(COMP_KEYS) do
            local map = conf[key]
            if type(map) == "table" and map[comp_id] ~= nil then
                map[comp_id] = nil
                if next(map) == nil then conf[key] = nil end
            end
        end
        if type(conf.rows) == "table" then
            local rows = {}
            for _, row in ipairs(conf.rows) do
                if not rowHasComp(row, comp_id) then rows[#rows + 1] = row end
            end
            conf.rows = #rows > 0 and rows or nil
        end
        return
    end
    local spec = bySlot[slot]
    for k in pairs(conf) do
        if spec then
            if owns(spec, k) then conf[k] = nil end
        elseif specFor(k).slot == slot then
            conf[k] = nil
        end
    end
end

--- 把 part.conf 合并进配置（只覆盖它负责的键）。
--- 组件部件的 widget_* 表与 rows 由多个组件共享，只能按组件 id 写入分片、按行追加。
function M.merge(conf, partConf, slot)
    if type(conf) ~= "table" or type(partConf) ~= "table" then return end
    M.clear(conf, slot)
    local comp = compIdOfSlot(slot) ~= nil
    for k, v in pairs(partConf) do
        if M.LOCAL_KEYS[k] then
            -- 部件库状态不属于任何部件
        elseif comp and k == "rows" and type(v) == "table" then
            conf.rows = type(conf.rows) == "table" and conf.rows or {}
            for _, row in ipairs(v) do conf.rows[#conf.rows + 1] = copy(row) end
        elseif comp and COMP_KEY_SET[k] and type(v) == "table" then
            conf[k] = type(conf[k]) == "table" and conf[k] or {}
            for id, item in pairs(v) do conf[k][id] = copy(item) end
        else
            conf[k] = copy(v)
        end
    end
end

--- 复制一份配置，去掉 partConf 里自带的 rows（用于取“启用前”的干净备份）
function M.withoutRows(conf, partConf)
    local out = copy(conf)
    if type(out) ~= "table" or type(partConf) ~= "table"
        or type(partConf.rows) ~= "table" then return out end
    local incoming = {}
    for _, row in ipairs(partConf.rows) do
        local key = rowKey(row)
        if key then incoming[key] = true end
    end
    local rows = {}
    for _, row in ipairs(type(out.rows) == "table" and out.rows or {}) do
        if not incoming[rowKey(row)] then rows[#rows + 1] = row end
    end
    out.rows = #rows > 0 and rows or nil
    return out
end

--- 从配置里移除某个组件参与的所有并排组合（all 不拥有 rows，不能清）
function M.stripComponent(conf, slot)
    if type(conf) ~= "table" then return conf end
    local id = compIdOfSlot(slot)
    if not id or id == "all" then return conf end
    if type(conf.rows) == "table" then
        local rows = {}
        for _, row in ipairs(conf.rows) do
            if not rowHasComp(row, id) then rows[#rows + 1] = row end
        end
        conf.rows = #rows > 0 and rows or nil
    end
    return conf
end

--- 当前配置是否与这个部件一致（整包应用后 theme_parts 为空时也能识别）
function M.matches(conf, partConf, slot)
    if type(partConf) ~= "table" then return false end
    if type(conf) ~= "table" then return false end
    local id = compIdOfSlot(slot)
    if id then
        for _, key in ipairs(COMP_KEYS) do
            local want = partConf[key]
            if type(want) == "table" then
                if type(conf[key]) ~= "table" or not equal(want[id], conf[key][id]) then
                    return false
                end
            end
        end
        if type(partConf.rows) == "table" then
            local wantRows = {}
            for _, row in ipairs(partConf.rows) do
                if rowHasComp(row, id) then
                    local key = rowKey(row)
                    if key then wantRows[key] = true end
                end
            end
            local liveRows = {}
            for _, row in ipairs(type(conf.rows) == "table" and conf.rows or {}) do
                if rowHasComp(row, id) then
                    local key = rowKey(row)
                    if wantRows[key] then liveRows[key] = true end
                end
            end
            local wc, lc = 0, 0
            for _ in pairs(wantRows) do wc = wc + 1 end
            for _ in pairs(liveRows) do lc = lc + 1 end
            if wc ~= lc then return false end
        end
        return true
    end
    for k, v in pairs(partConf) do
        if not M.LOCAL_KEYS[k] and not equal(v, conf[k]) then return false end
    end
    return true
end

--- 拆配置：一套 v1 主题会拆出多个部件；未识别的键进 misc。
---@return table[] parts 每项 { slot, type, label, conf }
function M.splitConf(conf)
    conf = conf or {}
    local buckets = {}
    local order = {}
    local function add(slot, part_type, label, part_conf)
        if not buckets[slot] then
            buckets[slot] = { slot = slot, type = part_type, label = label, conf = {} }
            order[#order + 1] = slot
        end
        for k, v in pairs(part_conf or {}) do buckets[slot].conf[k] = v end
    end

    for k, v in pairs(conf) do
        if not M.LOCAL_KEYS[k] and not COMP_KEY_SET[k] and k ~= "rows" then
            local spec = specFor(k)
            add(spec.slot, spec.type, spec.label, { [k] = v })
        end
    end

    -- 组件整体打包：一个组件 = 它的背景 + 花边 + 间距 + 并排关系
    local compIds = {}
    local function mark(id)
        if type(id) == "string" and id ~= "" then compIds[id] = true end
    end
    for _, key in ipairs(COMP_KEYS) do
        if type(conf[key]) == "table" then
            for id in pairs(conf[key]) do
                -- 背景/花边的 all 已废弃：组件大小不同会变形，不再生成通用部件
                if id == "all" then
                    if key == "widget_pad" or key == "widget_border" then mark("all") end
                else mark(id) end
            end
        end
    end
    if type(conf.rows) == "table" then
        for _, row in ipairs(conf.rows) do
            for _, id in ipairs(row or {}) do mark(id) end
        end
    end
    for id in pairs(compIds) do
        local slot = "comp_" .. id
        add(slot, "component", componentLabel(id), M.extract(conf, slot))
    end

    table.sort(order)
    local out = {}
    for _, slot in ipairs(order) do out[#out + 1] = buckets[slot] end
    return out
end

--- 合并若干部件配置（整包应用时用）
function M.union(parts)
    local out = {}
    for _, part in ipairs(parts or {}) do
        -- 壁纸/锁屏属于月读原生配置，不混进 ext.beautify
        if not NATIVE_MOD[part.type] then
            M.merge(out, part.conf, part.slot)
        end
    end
    return out
end

--- 把一份部件配置写进当前设置：原生部件交给月读设置，其余合并进 conf。
--- value 传空表等于清掉这个部件负责的配置。
function M.put(conf, ptype, slot, value)
    local native = M.native(ptype)
    if native then return native.apply(value) end
    M.merge(conf, value, slot)
    return true
end

--- 给部件补上 id / theme / 显示名等元数据（原地返回）
function M.decorate(parts, themeName)
    for _, part in ipairs(parts or {}) do
        part.theme = part.theme or themeName
        part.id = part.id or M.partId(themeName, part.slot)
        part.type = part.type or "misc"
        part.group = part.group or M.groupOfType(part.type)
        part.name = part.name or part.label or M.TYPE_LABEL[part.group]
            or M.TYPE_LABEL[part.type] or part.slot
    end
    return parts
end

return M
