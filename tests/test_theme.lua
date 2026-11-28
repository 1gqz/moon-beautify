local T = require("helper")
local Theme = require("moonbeautify.themes.theme")

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

T.test("theme: 选图器能选的 svg 和图片文件夹都收进主题", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local src = T.tmpdir()
    T.write(src .. "/icon.svg", "<svg/>")
    T.sh("mkdir -p '" .. src .. "/frames'")
    T.write(src .. "/frames/2.jpg", "J2")
    T.write(src .. "/frames/1.jpg", "J1")
    T.conf.badge_src = src .. "/icon.svg"
    T.conf.frame_dir = src .. "/frames"
    T.ok(Theme.save("S"))
    T.eq(T.read(root .. "/S/assets/icon.svg"), "<svg/>")
    T.eq(T.read(root .. "/S/assets/frames/1.jpg"), "J1")
    local saved = T.read(root .. "/S/theme.lua")
    T.ok(saved:find('"@assets/icon.svg"', 1, true), "svg 应改成 @assets 引用")
    T.ok(saved:find('"@assets/frames"', 1, true), "文件夹应改成 @assets 引用")
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

T.test("theme: theme.lua 在空环境里执行，碰不到 os", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local marker = T.tmpdir() .. "/keep"
    T.write(marker, "x")
    T.sh("mkdir -p '" .. root .. "/Evil'")
    T.write(root .. "/Evil/theme.lua", 'os.remove("' .. marker .. '") return { conf = {} }')
    T.eq((Theme.apply("Evil")), false)
    T.eq(T.read(marker), "x")
end)

T.test("theme: unsaved 识别没存进主题的外观配置", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    T.eq(Theme.unsaved(), false)
    local img = T.tmpdir() .. "/a.png"
    T.write(img, "A")
    T.conf.badge_src = img
    T.eq(Theme.unsaved(), true)
    T.ok(Theme.save("A"))
    T.ok(Theme.apply("A"))
    T.eq(Theme.unsaved(), false)
    T.conf.badge_scale = 2
    T.eq(Theme.unsaved(), true)
end)

T.test("theme: 改过壁纸再应用带壁纸的主题算有未保存修改", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local src = T.tmpdir()
    T.write(src .. "/w.png", "W")
    T.write(src .. "/x.png", "X")
    T.native["features.wallpaper"] = { wallpaper_enabled = true, wallpaper_custom_image = src .. "/w.png" }
    T.ok(Theme.save("A"))
    T.ok(Theme.apply("A"))
    local wp = T.native["features.wallpaper"]
    T.eq(wp.wallpaper_custom_image, root .. "/A/assets/w.png")
    T.eq(Theme.unsaved("A"), false)
    wp.wallpaper_custom_image = src .. "/x.png"
    T.eq(Theme.dirty("A"), true)
    T.eq(Theme.unsaved("A"), true)
end)

T.test("theme: 没有应用中的主题时，壁纸会被目标主题覆盖也要提醒", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local src = T.tmpdir()
    T.write(src .. "/w.png", "W")
    T.native["features.wallpaper"] = { wallpaper_enabled = true, wallpaper_custom_image = src .. "/w.png" }
    T.ok(Theme.save("A"))
    T.native["features.wallpaper"] = { wallpaper_enabled = false }
    T.eq(Theme.unsaved("A"), true)
end)

T.test("theme: 壁纸部件启用再停用还原原来的壁纸", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local src = T.tmpdir()
    T.write(src .. "/w.png", "W")
    T.write(src .. "/mine.png", "M")
    T.native["features.wallpaper"] = { wallpaper_enabled = true, wallpaper_custom_image = src .. "/w.png" }
    T.ok(Theme.save("A"))
    T.native["features.wallpaper"] = { wallpaper_enabled = true, wallpaper_custom_image = src .. "/mine.png" }
    T.ok(Theme.applyPart("A", "wallpaper", true))
    T.eq(T.native["features.wallpaper"].wallpaper_custom_image, root .. "/A/assets/w.png")
    T.eq(T.conf.theme_parts, { wallpaper = "A/wallpaper" })
    T.ok(Theme.applyPart("A", "wallpaper", false))
    T.eq(T.native["features.wallpaper"].wallpaper_custom_image, src .. "/mine.png")
    T.eq(T.conf.theme_parts, {})
end)

T.test("theme: 存档的整包 conf 由部件拼出，改部件后两边一致", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local src = T.tmpdir()
    T.write(src .. "/a.png", "A")
    T.conf.badge_src = src .. "/a.png"
    T.conf.badge_scale = 2
    T.ok(Theme.save("A"))
    T.ok(Theme.updatePartConf("A", "badge1", { badge_src = "/elsewhere/a.png", badge_scale = 3 }))
    local data = dofile(root .. "/A/theme.lua")
    T.eq(data.conf, { badge_src = "/elsewhere/a.png", badge_scale = 3 })
    T.eq(data.kind, "moonbeautify-theme")
end)

T.test("theme: 删部件回收没人用的图，保留其他部件和当前设置在用的图", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local src = T.tmpdir()
    T.write(src .. "/a.png", "A")
    T.write(src .. "/b.png", "B")
    T.sh("mkdir -p '" .. src .. "/frames'")
    T.write(src .. "/frames/1.jpg", "J1")
    T.conf.badge_src = src .. "/a.png"
    T.conf.badge2_src = src .. "/b.png"
    T.conf.frame_dir = src .. "/frames"
    T.ok(Theme.save("A"))
    -- 用户把主题里的 b.png 挪去当吧唧 3，原来的吧唧都清掉
    T.conf.badge_src, T.conf.badge2_src, T.conf.frame_dir = nil, nil, nil
    T.conf.badge3_src = root .. "/A/assets/b.png"
    T.ok(Theme.deletePart("A", "badge1"))
    T.ok(Theme.deletePart("A", "badge2"))
    -- 剩下的只该是：当前设置在用的 b.png、frame1 部件的 frames、以及封面（收编顺序随 pairs，不固定）
    local cover = dofile(root .. "/A/theme.lua").cover:match("^@assets/([^/]+)")
    local want = { ["b.png"] = true, frames = true, [cover] = true }
    local got = {}
    for name in io.popen("ls '" .. root .. "/A/assets'"):lines() do got[name] = true end
    T.eq(got, want)
    T.eq(T.read(root .. "/A/assets/frames/1.jpg"), "J1")
end)

T.test("theme: 删除应用中的主题时引用转给内容相同的另一套", function()
    local root = T.tmpdir()
    Theme.setRoot(root)
    local img = T.tmpdir() .. "/a.png"
    T.write(img, "SAME")
    T.conf.badge_src = img
    T.ok(Theme.save("A"))
    T.ok(Theme.save("B"))
    T.ok(Theme.apply("A"))
    T.eq(T.conf.badge_src, root .. "/A/assets/a.png")
    T.ok(Theme.delete("A"))
    T.eq(T.conf.badge_src, root .. "/B/assets/a.png")
    T.eq(T.conf.active_theme, "B")
end)

T.test("theme: 壁纸部件的键跟着月读的壁纸设置走", function()
    local MOD = "moonbeautify.themes.wallpaper_part"
    local saved, savedPreload = package.loaded[MOD], package.preload["features.wallpaper.setting"]
    package.loaded[MOD], package.loaded["features.wallpaper.setting"] = nil, nil
    package.preload["features.wallpaper.setting"] = function()
        return { defaults = { wallpaper_brand_new = true }, keys = { "wallpaper_image_home" } }
    end
    local W = require(MOD)
    package.loaded[MOD], package.preload["features.wallpaper.setting"] = saved, savedPreload
    package.loaded["features.wallpaper.setting"] = nil
    T.eq(W.matches({ wallpaper_brand_new = true }), false)
    T.eq(W.matches({ wallpaper_source = "x" }), false)
    T.eq(W.matches({ wallpaper_not_a_key = 1 }), true)
end)
