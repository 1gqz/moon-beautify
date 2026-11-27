local T = require("helper")
local PartCopy = require("moonbeautify.themes.part_copy")

T.test("part_copy: 复制到可写目录改写路径", function()
    local src = T.tmpdir() .. "/a.png"
    T.write(src, "PNG")
    local dest = T.tmpdir()
    local conf, files, failed = PartCopy.copyTo({ badge_src = src }, dest)
    T.eq(failed, 0)
    T.eq(files, { "a.png" })
    T.eq(conf.badge_src, dest .. "/a.png")
    T.eq(T.read(dest .. "/a.png"), "PNG")
end)

T.test("part_copy: 复制失败时保留原路径并计数", function()
    if T.is_root then return end
    local src = T.tmpdir() .. "/a.png"
    T.write(src, "PNG")
    local dest = T.tmpdir()
    T.chmod(555, dest)
    local conf, files, failed = PartCopy.copyTo({ badge_src = src }, dest)
    T.chmod(755, dest)
    T.eq(failed, 1)
    T.eq(files, {})
    T.eq(conf.badge_src, src)
end)
