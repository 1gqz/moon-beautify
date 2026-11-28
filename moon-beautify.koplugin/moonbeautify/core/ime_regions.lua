--[[--
输入法按键分区（借鉴搜狗皮肤分区，不是整包导入）。

KOReader 全键盘对应关系：
  letter  A-Z 字母键
  number  数字键
  space   空格
  symbol  符号 / 标点
  func    功能键（Shift / 删除 / 回车 / SYM / 语言 / 方向）

配置在 ime_bg.regions[id] = { src, focus }；旧 key_src 视作 letter。

@module moonbeautify.core.ime_regions
--]]

local _ = require("moonbeautify.l10n")

local M = {}

--- 有序分区（设置 / 图例用）
M.ORDER = { "letter", "number", "space", "symbol", "func" }

M.LABEL = {
    letter = _("字母键"),
    number = _("数字键"),
    space = _("空格键"),
    symbol = _("符号键"),
    func = _("功能键"),
}

--- 功能键标签（KOReader 虚拟键盘常用符号）
local FUNC_LABEL = {
    [""] = true, -- shift
    [""] = true, -- caps
    [""] = true, -- backspace
    ["↵"] = true, -- enter (some fonts)
    ["↰"] = true,
    ["옵"] = true,
    ["⌥"] = true, -- SYM
    ["🌐"] = true, -- layout
    ["←"] = true,
    ["→"] = true,
    ["↑"] = true,
    ["↓"] = true,
}

--- 根据 VirtualKey 的 key / label 归区
---@param key table|string|nil VirtualKey 或纯字符串
---@return string region id
function M.of(key)
    local label, raw
    if type(key) == "table" then
        label = key.label
        raw = key.key
    else
        raw = key
    end
    label = label ~= nil and tostring(label) or ""
    raw = raw ~= nil and tostring(raw) or ""

    if label == "_" or raw == " " or label == " " then return "space" end
    if FUNC_LABEL[label] or FUNC_LABEL[raw] then return "func" end
    -- Enter 在 en_keyboard 里 label 可能是特殊字符且 key 是 "\n"
    if raw == "\n" or label == "\n" then return "func" end

    local ch = raw
    if ch == "" then ch = label end
    -- 单字符字母 / 数字
    if #ch == 1 or (ch:match("^[%z\1-\127]$") and #ch == 1) then
        if ch:match("[%a]") then return "letter" end
        if ch:match("%d") then return "number" end
    end
    -- UTF-8 拉丁字母少见；多数字母键 key 是单字节
    if ch:match("^%a$") then return "letter" end
    if ch:match("^%d$") then return "number" end

    -- 带 popup 的字母表项：key 仍是字母
    if type(key) == "table" and type(key.key) == "string" then
        local k = key.key
        if #k == 1 and k:match("%a") then return "letter" end
        if #k == 1 and k:match("%d") then return "number" end
    end

    if label ~= "" and FUNC_LABEL[label] then return "func" end
    if raw ~= "" or label ~= "" then return "symbol" end
    return "func"
end

--- 兼容旧配置：key_src → regions.letter
---@param item table|nil ime_bg
function M.migrate(item)
    if type(item) ~= "table" then return end
    if type(item.regions) ~= "table" then item.regions = {} end
    if type(item.key_src) == "string" and item.key_src ~= "" then
        local letter = item.regions.letter
        if type(letter) ~= "table" or not letter.src or letter.src == "" then
            item.regions.letter = {
                src = item.key_src,
                focus = type(item.key_focus) == "table" and item.key_focus or nil,
            }
        end
    end
end

--- 取某区皮肤 { src, focus }；无则尝试 letter、再旧 key_src
---@param item table|nil
---@param region string
---@return table|nil
function M.skin(item, region)
    if type(item) ~= "table" then return nil end
    M.migrate(item)
    local r = item.regions and item.regions[region]
    if type(r) == "table" and type(r.src) == "string" and r.src ~= "" then return r end
    if region ~= "letter" then
        local letter = item.regions and item.regions.letter
        -- 不自动回落到 letter：各区独立，没有就画默认键
    end
    return nil
end

--- 是否任一区或旧 key_src 有皮肤
---@param item table|nil
---@return boolean
function M.anySkin(item)
    if type(item) ~= "table" then return false end
    if type(item.key_src) == "string" and item.key_src ~= "" then return true end
    if type(item.regions) ~= "table" then return false end
    for _id, r in pairs(item.regions) do
        if type(r) == "table" and type(r.src) == "string" and r.src ~= "" then return true end
    end
    return false
end

--- 写入某区皮肤
---@param item table ime_bg（会被改）
---@param region string
---@param src string|nil
---@param focus table|nil
function M.setSkin(item, region, src, focus)
    if type(item) ~= "table" then return end
    if type(item.regions) ~= "table" then item.regions = {} end
    if type(src) ~= "string" or src == "" then
        item.regions[region] = nil
        if next(item.regions) == nil then item.regions = nil end
        if region == "letter" then item.key_src, item.key_focus = nil, nil end
        return
    end
    item.regions[region] = { src = src, focus = focus }
    -- 同步旧字段，主题/未升级路径还能看见字母键皮
    if region == "letter" then
        item.key_src = src
        item.key_focus = focus
    end
end

return M
