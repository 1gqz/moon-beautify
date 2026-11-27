local T = require("helper")

local plugin = T.repo .. "/moon-beautify.koplugin"

--- 源码里所有需要翻译的文案：_() 的字面量参数，加上 parts.lua 里存进主题、显示时才翻译的部件名
local function sourceKeys()
    local keys = {}
    local files = io.popen("find '" .. plugin .. "' -name '*.lua' -not -path '*/l10n/*' -not -name l10n.lua")
    for path in files:lines() do
        local labels = path:match("/themes/parts%.lua$")
        for line in T.read(path):gmatch("[^\n]+") do
            if not line:match("^%s*%-%-") then
                for lit in line:gmatch("[^%w_.]_%(%s*(\"[^\"\\]*\")") do keys[load("return " .. lit)()] = path end
                if labels then
                    for lit in line:gmatch("\"([^\"]*)\"") do
                        if lit:find("[\228-\233]") then keys[lit] = path end
                    end
                end
            end
        end
    end
    files:close()
    return keys
end

local function placeholders(s)
    local out = {}
    for p in s:gmatch("%%%d") do out[#out + 1] = p end
    for p in s:gmatch("%%s") do out[#out + 1] = p end
    table.sort(out)
    return table.concat(out, " ")
end

for _, lang in ipairs({ "en", "zh_TW" }) do
    T.test("l10n: " .. lang .. " 覆盖全部文案且没有多余条目", function()
        local catalog = dofile(plugin .. "/moonbeautify/l10n/" .. lang .. ".lua")
        local keys = sourceKeys()
        local missing, stale, broken = {}, {}, {}
        for k in pairs(keys) do
            if not catalog[k] then missing[#missing + 1] = k end
        end
        for k, v in pairs(catalog) do
            if not keys[k] then stale[#stale + 1] = k end
            if placeholders(k) ~= placeholders(v) then broken[#broken + 1] = k end
        end
        table.sort(missing) table.sort(stale) table.sort(broken)
        T.eq(missing, {}, "缺译文")
        T.eq(stale, {}, "源码里已不存在的条目")
        T.eq(broken, {}, "占位符对不上")
    end)
end

T.test("l10n: 语言选择与格式化", function()
    local L = require("moonbeautify.l10n")
    T.eq(L.candidates("zh_CN"), {})
    T.eq(L.candidates("zh_HK"), { "zh_TW" })
    T.eq(L.candidates("en_US"), { "en" })
    T.eq(L.candidates("fr_FR"), { "fr_FR", "fr", "en" })
    L.load("en")
    T.eq(L("月华美化"), "Moon Beautify")
    T.eq(L("写不了 %s", "/x"), "Cannot write /x")
    T.eq(L("没有这条"), "没有这条")
    L.load("zh_CN")
    T.eq(L("写不了 %s", "/x"), "写不了 /x")
end)

T.dumpKeys = sourceKeys
