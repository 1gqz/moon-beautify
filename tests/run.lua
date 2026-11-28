--- 用法：在仓库根目录执行 luajit tests/run.lua
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path
local T = require("helper")

for _, name in ipairs({ "test_parts", "test_theme", "test_part_copy", "test_l10n", "test_moon_check" }) do
    dofile(here .. "/" .. name .. ".lua")
end

local failed = 0
for _, case in ipairs(T.cases) do
    T.conf, T.native = {}, {}
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
        print("ok   " .. case.name)
    else
        failed = failed + 1
        print("FAIL " .. case.name .. "\n" .. err)
    end
end
for _, dir in ipairs(T.cleanup or {}) do
    T.sh("chmod -R u+w '" .. dir .. "' && rm -rf '" .. dir .. "'")
end

print(string.format("\n%d 个用例，%d 个失败", #T.cases, failed))
os.exit(failed == 0 and 0 or 1)
