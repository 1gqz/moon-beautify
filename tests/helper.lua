--- 测试环境：把 KOReader 的依赖换成桌面可跑的替身，月读的纯 Lua 工具（utils.fs 等）直接用源码。
--- lfs 用 shell 命令实现，只覆盖插件实际用到的接口。
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local repo = here .. "/.."
local moon = os.getenv("MOON_SRC")
if not moon then
    io.stderr:write("需要月读源码：MOON_SRC=/path/to/book.koplugin luajit tests/run.lua\n")
    os.exit(2)
end
package.path = repo .. "/moon-beautify.koplugin/?.lua;" .. moon .. "/?.lua;" .. package.path

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function sh(cmd)
    local p = io.popen(cmd)
    local s = p:read("*a")
    p:close()
    return s
end
local function run(cmd) local ok = os.execute(cmd) return ok == true or ok == 0 end

local lfs = {}
function lfs.attributes(p, what)
    local mode = sh("if [ -d " .. q(p) .. " ]; then echo directory; elif [ -f " .. q(p) .. " ]; then echo file; fi"):gsub("%s", "")
    if mode == "" then return nil end
    local size = mode == "file" and tonumber((sh("wc -c < " .. q(p)):gsub("%s", ""))) or 0
    local t = { mode = mode, size = size, modification = 0 }
    if what then return t[what] end
    return t
end
lfs.symlinkattributes = lfs.attributes
function lfs.dir(p)
    if lfs.attributes(p, "mode") ~= "directory" then error("cannot open " .. p) end
    local names = { ".", ".." }
    for n in sh("ls -A " .. q(p)):gmatch("[^\n]+") do names[#names + 1] = n end
    local i = 0
    return function() i = i + 1 return names[i] end
end
function lfs.mkdir(p) return run("mkdir " .. q(p) .. " 2>/dev/null") or nil end
function lfs.rmdir(p) return run("rmdir " .. q(p) .. " 2>/dev/null") or nil end

local T = { conf = {}, sh = run, repo = repo }

package.preload["libs/libkoreader-lfs"] = function() return lfs end
package.preload["utils.log"] = function() return { warn = function() end } end
package.preload["utils.settings"] = function()
    return {
        getSource = function() return T.conf end, saveSource = function() end,
        get = function() return {} end, save = function() end,
    }
end
package.preload["datastorage"] = function() return { getDataDir = function() return os.tmpname() end } end
package.preload["ffi/sha2"] = function() return { md5 = function(s) return s end } end
package.preload["features.wallpaper.setting"] = function() error("absent") end
package.preload["features.lockscreen.setting"] = function() error("absent") end

--- 每个用例一个空临时目录
function T.tmpdir()
    local dir = os.tmpname()
    os.remove(dir)
    assert(run("mkdir -p " .. q(dir)))
    T.cleanup = T.cleanup or {}
    T.cleanup[#T.cleanup + 1] = dir
    return dir
end

function T.write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

function T.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function T.chmod(mode, path) assert(run("chmod " .. mode .. " " .. q(path))) end

--- root 无视权限位，只读目录类用例在 root 下跑不出失败路径
T.is_root = sh("id -u"):gsub("%s", "") == "0"

local function dump(v)
    if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. dump(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
T.dump = dump

function T.eq(got, want, msg)
    if dump(got) ~= dump(want) then
        error((msg or "不相等") .. "\n  期望: " .. dump(want) .. "\n  实际: " .. dump(got), 2)
    end
end

function T.ok(v, msg)
    if not v then error(msg or "断言失败", 2) end
end

T.cases = {}
function T.test(name, fn) T.cases[#T.cases + 1] = { name = name, fn = fn } end

return T
