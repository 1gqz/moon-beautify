local T = require("helper")
local Parts = require("moonbeautify.themes.parts")

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

--- rows 是追加写入的，顺序不算语义，比较前排一下
local function norm(conf)
    local out = copy(conf)
    if type(out.rows) == "table" then
        table.sort(out.rows, function(a, b) return table.concat(a, ",") < table.concat(b, ",") end)
    end
    return out
end

local function sample()
    return {
        badge_src = "/img/b1.png",
        badge2_src = "/img/b2.png",
        widget_bg = { clock = { src = "/img/c.png" }, weather = { src = "/img/w.png" } },
        widget_pad = { clock = 4, weather = 8 },
        rows = { { "clock", "weather" }, { "todo", "calendar" } },
    }
end

T.test("parts: 合并一个组件不清掉其他组件的分片和并排", function()
    local conf = sample()
    Parts.merge(conf, { widget_bg = { clock = { src = "/new/c.png" } } }, "comp_clock")
    T.eq(conf.widget_bg.weather, { src = "/img/w.png" })
    T.eq(conf.widget_bg.clock, { src = "/new/c.png" })
    T.eq(conf.widget_pad, { weather = 8 })
    T.eq(norm(conf).rows, { { "todo", "calendar" } })
end)

T.test("parts: 组件部件取出再合并回去配置不变", function()
    local conf = sample()
    local part = Parts.extract(conf, "comp_clock")
    Parts.merge(conf, part, "comp_clock")
    T.eq(norm(conf), norm(sample()))
end)

T.test("parts: 拆成部件再整包合并等于原配置", function()
    T.eq(norm(Parts.union(Parts.splitConf(sample()))), norm(sample()))
end)

T.test("parts: 启用部件后用备份停用能还原", function()
    local conf = sample()
    local backup = Parts.extract(conf, "comp_clock")
    Parts.merge(conf, { widget_bg = { clock = { src = "/theme/c.png" } } }, "comp_clock")
    Parts.merge(conf, backup, "comp_clock")
    T.eq(norm(conf), norm(sample()))
end)

T.test("parts: badge2_ 不归 badge1", function()
    T.eq(Parts.extract(sample(), "badge1"), { badge_src = "/img/b1.png" })
    T.eq(Parts.extract(sample(), "badge2"), { badge2_src = "/img/b2.png" })
end)
