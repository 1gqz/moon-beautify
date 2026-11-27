local T = require("helper")
local Check = require("moonbeautify.core.moon_check")

T.test("moon_check: 没装月读拒绝", function()
    T.ok(Check.check(nil), "nil 版本应拒绝")
end)

T.test("moon_check: 0.8.0 及以上放行", function()
    for _, v in ipairs({ "0.8.0", "v0.8.0", "0.8.1", "0.10.0", "1.0.0", "0.8.0-beta.1", "0.0.0-dev" }) do
        T.eq(Check.check(v), nil, v)
    end
end)

T.test("moon_check: 低于 0.8.0 或版本号乱码拒绝", function()
    for _, v in ipairs({ "0.7.9", "0.7.10", "0.1.0", "0.0.0", "", "abc" }) do
        T.ok(Check.check(v), v .. " 应拒绝")
    end
    T.ok(Check.check("0.7.2"):find("0.7.2", 1, true), "提示里要带当前版本")
end)

--- 测试进程的 package.path 里有月读源码，模拟「require 不到 bookversion」得先挡住它
local function withoutBookversion(fn)
    package.loaded["bookversion"] = nil
    package.preload["bookversion"] = function() error("absent") end
    local ok, err = pcall(fn)
    package.preload["bookversion"] = nil
    if not ok then error(err, 0) end
end

T.test("moon_check: 仓库里没有同级 book.koplugin 时视为没装", function()
    withoutBookversion(function()
        T.eq(Check.moonVersion(), nil)
        T.ok(Check.problem())
    end)
end)

T.test("moon_check: require 不到时读同级 book.koplugin/bookversion.lua", function()
    local plugins = T.tmpdir()
    T.sh("mkdir -p '" .. plugins .. "/book.koplugin' && ln -s \"$(cd '" .. T.repo .. "' && pwd)/moon-beautify.koplugin\" '"
        .. plugins .. "/moon-beautify.koplugin' && printf 'return \"0.7.2\"\\n' > '" .. plugins .. "/book.koplugin/bookversion.lua'")
    withoutBookversion(function()
        local Mod = dofile(plugins .. "/moon-beautify.koplugin/moonbeautify/core/moon_check.lua")
        T.eq(Mod.moonVersion(), "0.7.2")
        T.ok(Mod.problem(), "0.7.2 应拒绝")
    end)
end)
