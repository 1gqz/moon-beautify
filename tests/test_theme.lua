local T = require("helper")
local Theme = require("moonbeautify.theme")

local function badgeOf(name)
    for _, p in ipairs(Theme.parts(name)) do
        if p.slot == "badge1" then return p.conf.badge_src end
    end
end

T.test("theme: 主题名拒绝空名、纯点名和导入保留前缀", function()
    T.eq(Theme.sanitize(""), nil)
    T.eq(Theme.sanitize("."), nil)
    T.eq(Theme.sanitize(".."), nil)
    T.eq(Theme.sanitize(".import-x"), nil)
    T.eq(Theme.sanitize(" 我的/套装 "), "我的_套装")
end)

T.test("theme: 覆盖保存引用自身 assets 的主题不丢图", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local img = T.tmpdir() .. "/cat.png"
    T.write(img, "PNG")
    T.conf.badge_src = img
    T.ok(Theme.save("A"))
    -- 当前配置改成指向主题自己的存档图，再存一次
    T.conf.badge_src = root .. "/A/assets/cat.png"
    T.ok(Theme.save("A"))
    T.eq(T.read(root .. "/A/assets/cat.png"), "PNG")
    T.ok(T.read(root .. "/A/theme.lua"):find('"@assets/cat.png"', 1, true), "存档应使用 @assets 引用")
    T.eq(T.read(root .. "/A/.theme-new.lua"), nil)
    T.eq(badgeOf("A"), root .. "/A/assets/cat.png")
end)

T.test("theme: 目录不可写时保存失败且旧存档完好", function()
    if T.is_root then return end
    local root = T.tmpdir()
    Theme.setRoot(root)
    local img = T.tmpdir() .. "/a.png"
    T.write(img, "A")
    T.conf.badge_src = img
    T.ok(Theme.save("A"))
    local before = T.read(root .. "/A/theme.lua")
    T.chmod(555, root .. "/A")
    T.conf.badge_src = img:gsub("a%.png$", "b.png")
    T.write(T.conf.badge_src, "B")
    local ok = Theme.save("A")
    T.chmod(755, root .. "/A")
    T.eq(ok, false)
    T.eq(T.read(root .. "/A/theme.lua"), before)
end)

T.test("theme: updatePartConf 改写部件并保留其他部件", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local dir = T.tmpdir()
    T.write(dir .. "/a.png", "A")
    T.write(dir .. "/b.png", "B")
    T.conf.badge_src = dir .. "/a.png"
    T.conf.badge2_src = dir .. "/b.png"
    T.ok(Theme.save("A"))
    T.ok(Theme.updatePartConf("A", "badge1", { badge_src = "/elsewhere/a.png" }))
    T.eq(badgeOf("A"), "/elsewhere/a.png")
    local b2
    for _, p in ipairs(Theme.parts("A")) do
        if p.slot == "badge2" then b2 = p.conf.badge2_src end
    end
    T.eq(b2, root .. "/A/assets/b.png")
end)
