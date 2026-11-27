--[[--
主题包：整套美化配置 + 图片素材，存成固定目录里的可切换主题，也能打包成 zip 分享。

固定目录（Path.root 之下，真机是 koreader/.moon/beautify/themes/<主题名>/）：
    theme.lua   -- return { name = "chiikawa1", conf = {...}, parts = {...} }
    assets/     -- 主题用到的全部图片

v2 主题包除了整包 conf，还带 parts（可独立启用/停用的部件列表）；v1 老包照常兼容。

theme.lua 里图片路径写成 "@assets/文件名"，应用时替换成主题目录下的绝对路径——
同一份主题拷到任何设备都直接可用，图片文件名冲突自动重编号。

- 保存主题：把当前配置快照成主题（图片收编进 assets），不改变“应用中”的主题
- 应用主题：合并回当前配置（排除 last_dir 等本机状态键），改过的配置随时能切回来
- 导出 zip：theme.lua + assets 打包（moonbeautify.zip，STORED）
- 导入 zip：解到主题目录（用月读自带的 ffi/archiver.Reader），名字取包内 theme.lua 的
  name 字段，没有就用 zip 文件名；同名主题直接覆盖

zip 包是一段 Lua 代码 + 图片，导入等于执行 theme.lua——只导入自己信任的文件。

@module moonbeautify.theme
--]]--

local lfs = require("libs/libkoreader-lfs")
local Log = require("utils.log")
local Parts = require("moonbeautify.parts")
local WallpaperPart = require("moonbeautify.wallpaper_part")
local LockscreenPart = require("moonbeautify.lockscreen_part")

local Theme = {}

--- 主题包格式标识与版本：theme.lua 返回值里带 kind = THEME_KIND 才认作月读美化主题包
local THEME_KIND = "moonbeautify-theme"
local THEME_FORMAT = 2

--- 本机状态类键：不进主题、主题里出现也忽略
local LOCAL_KEYS = {
    last_dir = true,
    update_checked_at = true,
    update_auto = true,
    active_theme = true,
}
for k in pairs(Parts.LOCAL_KEYS) do LOCAL_KEYS[k] = true end

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true }
local ASSET_MARK = "@assets/"

--- 逐级建目录：lfs.mkdir 只建最后一级，父目录缺失时会失败（Kindle 首次保存就栽在这）
---@param path string 绝对或相对路径
---@return boolean
local function mkdirp(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local abs = path:sub(1, 1) == "/"
    local acc, first = abs and "/" or "", true
    for seg in path:gmatch("[^/]+") do
        acc = (first and abs) and acc .. seg or (acc == "" and seg or acc .. "/" .. seg)
        first = false
        if lfs.attributes(acc, "mode") ~= "directory" and not lfs.mkdir(acc) then
            return false
        end
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function note(...)
    local args = { ... }
    pcall(function()
        local out = {}
        for i = 1, #args do out[i] = tostring(args[i]) end
        Log.warn(table.concat(out, " "))
        if Log.flush then Log.flush() end
    end)
end

--- 测试可注入根目录；正常走 Paths.root()/beautify/themes
function Theme.setRoot(dir)
    Theme._root = dir
end

function Theme.root()
    if Theme._root then return Theme._root end
    local Paths = require("utils.paths")
    return Paths.root() .. "/beautify/themes"
end

--- 主题名收成安全的目录名：保留中英文数字点横线下划线，其余换 _，空名字拒绝
---@param name any
---@return string|nil
function Theme.sanitize(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w%._%-\128-\255]", "_")
    name = name:gsub("_+$", ""):gsub("^_+", "")
    if name == "" then return nil end
    if #name > 48 then name = name:sub(1, 48) end
    return name
end

function Theme.dir(name)
    local safe = Theme.sanitize(name)
    if not safe then return nil end
    return Theme.root() .. "/" .. safe
end

function Theme.exists(name)
    local dir = Theme.dir(name)
    return dir ~= nil and lfs.attributes(dir .. "/theme.lua", "mode") == "file"
end

--- 删目录树
---@param path string
---@return boolean
local function removeTree(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) ~= nil end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            if not removeTree(path .. "/" .. name) then return false end
        end
    end
    return lfs.rmdir(path) ~= nil
end

--- 已保存的主题名列表（排序）；顺手清掉上次导入崩溃残留的暂存目录
---@return string[]
function Theme.list()
    local out = {}
    local root = Theme.root()
    if lfs.attributes(root, "mode") ~= "directory" then return out end
    for name in lfs.dir(root) do
        if name:sub(1, 8) == ".import-"
            and lfs.attributes(root .. "/" .. name, "mode") == "directory" then
            removeTree(root .. "/" .. name)   -- 孤儿暂存目录，自愈
        elseif name ~= "." and name ~= ".."
            and lfs.attributes(root .. "/" .. name, "mode") == "directory"
            and lfs.attributes(root .. "/" .. name .. "/theme.lua", "mode") == "file" then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end


--- 主题占用统计：图片张数 + 总大小（KB）
---@param name string
---@return integer images, integer kb
function Theme.stat(name)
    local dir = Theme.dir(name)
    local images, bytes = 0, 0
    local assets = dir and (dir .. "/assets") or nil
    if assets and lfs.attributes(assets, "mode") == "directory" then
        local function count(d)
            for f in lfs.dir(d) do
                if f ~= "." and f ~= ".." then
                    local p = d .. "/" .. f
                    local attr = lfs.attributes(p)
                    if attr and attr.mode == "directory" then
                        count(p)
                    elseif attr and attr.mode == "file" then
                        images = images + 1
                        bytes = bytes + (attr.size or 0)
                    end
                end
            end
        end
        count(assets)
    end
    return images, math.ceil(bytes / 1024)
end

--- 值序列化成 Lua 字面量（配置里只有 string / number / boolean / table）
local function dump(value, depth, seen, out)
    local t = type(value)
    if t == "string" then
        out[#out + 1] = string.format("%q", value)
    elseif t == "number" then
        out[#out + 1] = string.format("%.14g", value)
    elseif t == "boolean" then
        out[#out + 1] = tostring(value)
    elseif t == "table" then
        if seen[value] or depth > 10 then
            out[#out + 1] = "nil"
            return
        end
        seen[value] = true
        out[#out + 1] = "{\n"
        for k, v in pairs(value) do
            out[#out + 1] = string.rep(" ", (depth + 1) * 2)
            if type(k) == "string" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                out[#out + 1] = k
            elseif type(k) == "string" then
                out[#out + 1] = "[" .. string.format("%q", k) .. "]"
            else
                out[#out + 1] = "[" .. tostring(k) .. "]"
            end
            out[#out + 1] = " = "
            dump(v, depth + 1, seen, out)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = string.rep(" ", depth * 2) .. "}"
    else
        out[#out + 1] = "nil"
    end
end

local function serialize(data)
    local out = {
        "-- moon-beautify 主题包（月读美化插件）\n"
        .. "-- 图片路径是 @assets/ 相对引用，随包的 assets/ 文件夹走\nreturn " }
    dump(data, 0, {}, out)
    out[#out + 1] = "\n"
    return table.concat(out)
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepcopy(v) end
    return out
end

--- 递归改写字符串值（返回新值；table 原地遍历）
local function walk(value, fn)
    if type(value) ~= "table" then return value end
    for k, v in pairs(value) do
        if type(v) == "string" then
            value[k] = fn(v)
        elseif type(v) == "table" then
            walk(v, fn)
        end
    end
    return value
end

--- assets 里已用的文件名
local function usedNames(assetsDir)
    local used = {}
    if lfs.attributes(assetsDir, "mode") == "directory" then
        for name in lfs.dir(assetsDir) do
            if name ~= "." and name ~= ".." then used[name] = true end
        end
    end
    return used
end

local function uniqueName(used, base)
    if not used[base] then
        used[base] = true
        return base
    end
    local stem, ext = base:match("^(.*)%.(%w+)$")
    if not stem or stem == "" then stem, ext = base, "bin" end
    local i = 2
    while true do
        local candidate = stem .. "_" .. i .. "." .. ext
        if not used[candidate] then
            used[candidate] = true
            return candidate
        end
        i = i + 1
    end
end

--- 目录里是否有图片（壁纸的文件夹轮换靠它判断要不要整目录收编）
local function dirHasImage(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return false end
    for name in lfs.dir(dir) do
        local p = dir .. "/" .. name
        if name ~= "." and name ~= ".." and lfs.attributes(p, "mode") == "file" then
            local ext = name:lower():match("%.(%w+)$")
            if ext and IMAGE_EXT[ext] then return true end
        end
    end
    return false
end

local function dirFirstImage(dir)
    for name in lfs.dir(dir) do
        local p = dir .. "/" .. name
        if name ~= "." and name ~= ".." and lfs.attributes(p, "mode") == "file" then
            local ext = name:lower():match("%.(%w+)$")
            if ext and IMAGE_EXT[ext] then return name end
        end
    end
    return nil
end

--- 递归复制目录，返回复制的图片数
local function copyAssetDir(src, dst)
    if lfs.attributes(dst, "mode") ~= "directory" and not lfs.mkdir(dst) then return 0 end
    local n = 0
    for name in lfs.dir(src) do
        if name ~= "." and name ~= ".." then
            local s, d = src .. "/" .. name, dst .. "/" .. name
            local mode = lfs.attributes(s, "mode")
            if mode == "directory" then
                n = n + copyAssetDir(s, d)
            elseif mode == "file" then
                local f = io.open(s, "rb")
                local data = f and f:read("*a") or nil
                if f then f:close() end
                if data then
                    local o = io.open(d, "wb")
                    if o then o:write(data) o:close() n = n + 1 end
                end
            end
        end
    end
    return n
end

--- 目录名去重：不走 uniqueName 的「强制补扩展名」逻辑
local function uniqueDirName(used, base)
    if not used[base] then used[base] = true return base end
    local i = 2
    while true do
        local candidate = base .. "_" .. i
        if not used[candidate] then used[candidate] = true return candidate end
        i = i + 1
    end
end

--- 把配置里指向真实图片/图片文件夹的路径收编进 assetsDir，改成 @assets/ 引用
--- 同一个源文件多处引用只收编一份；文件夹整目录收编，写 @assets/目录名
---@param conf table
---@param assetsDir string
---@return integer copied 收编的文件数
---@return string|nil first 第一张收编的文件名（当封面用）
local function collectAssets(conf, assetsDir)
    local used = usedNames(assetsDir)
    local copied = 0
    local first = nil
    local seen = {}  -- 源路径 → assets 文件名/目录名
    walk(conf, function(s)
        local ext = s:lower():match("%.(%w+)$")
        if not ext or not IMAGE_EXT[ext] then
            if not dirHasImage(s) then return s end
            if seen[s] then return ASSET_MARK .. seen[s] end
            local base = s:match("([^/\\]+)$") or "folder"
            local name = uniqueDirName(used, base)
            local n = copyAssetDir(s, assetsDir .. "/" .. name)
            if n == 0 then return s end
            seen[s] = name
            copied = copied + n
            if not first then first = name .. "/" .. (dirFirstImage(s) or "") end
            return ASSET_MARK .. name
        end
        if lfs.attributes(s, "mode") ~= "file" then return s end
        if seen[s] then return ASSET_MARK .. seen[s] end
        local src, oerr = io.open(s, "rb")
        if not src then return s end
        local data = src:read("*a")
        src:close()
        if not data or data == "" then return s end
        local base = s:match("([^/\\]+)$") or "asset.bin"
        local asset = uniqueName(used, base)
        local dest = io.open(assetsDir .. "/" .. asset, "wb")
        if not dest then return s end
        dest:write(data)
        dest:close()
        seen[s] = asset
        copied = copied + 1
        if not first then first = asset end
        return ASSET_MARK .. asset
    end)
    return copied, first
end

--- @assets/ 引用换回主题目录下的绝对路径
local function remapAssets(conf, assetsDir)
    walk(conf, function(s)
        if s:sub(1, #ASSET_MARK) == ASSET_MARK then
            return assetsDir .. "/" .. s:sub(#ASSET_MARK + 1)
        end
        return s
    end)
end

--- 通用背景/花边已废弃：组件尺寸不同会变形，读取/保存时都忽略；
--- 旧包里还有一条指向 comp_all 的自引用并排，也要清掉。
local function stripGlobalDecor(conf)
    if type(conf) ~= "table" then return end
    for _, key in ipairs({ "widget_bg", "widget_lace" }) do
        local map = conf[key]
        if type(map) == "table" then
            map.all = nil
            if next(map) == nil then conf[key] = nil end
        end
    end
    if type(conf.rows) == "table" then
        local rows = {}
        for _, row in ipairs(conf.rows) do
            local legacy = false
            for _, id in ipairs(type(row) == "table" and row or {}) do
                if id == "comp_all" or id == "all" then legacy = true break end
            end
            if not legacy then rows[#rows + 1] = row end
        end
        conf.rows = #rows > 0 and rows or nil
    end
end

--- 当前配置（深拷贝、剔除本机状态键）
local function snapshotConf()
    local Store = require("moonbeautify.store")
    local conf = {}
    for k, v in pairs(Store.conf()) do
        if not LOCAL_KEYS[k] then conf[k] = deepcopy(v) end
    end
    stripGlobalDecor(conf)
    return conf
end

--- 两配置深度比较（键集合与值完全一致才相等；number 留序列化精度容差）
local function confEq(a, b)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= "table" then
        if ta == "number" then return math.abs(a - b) < 1e-9 end
        return a == b
    end
    local n = 0
    for k, v in pairs(a) do
        if not confEq(v, b[k]) then return false end
        n = n + 1
    end
    for _ in pairs(b) do n = n - 1 end
    return n == 0
end

--- 目录 assets 的内容签名：文件内容 → 文件名（比较两套图是否一样用它）
---@param dir string
---@return table
local function sigOf(dir)
    local sigs = {}
    local assets = dir .. "/assets"
    if lfs.attributes(assets, "mode") ~= "directory" then return sigs end
    for f in lfs.dir(assets) do
        local p = assets .. "/" .. f
        if lfs.attributes(p, "mode") == "file" then
            local fd = io.open(p, "rb")
            if fd then
                local d = fd:read("*a")
                fd:close()
                if d and d ~= "" then sigs[d] = f end
            end
        end
    end
    return sigs
end

--- 顺序无关的简单内容哈希（FNV 变体，取模保证不丢精度）
---@param h number
---@param s string
---@return number
local function hAdd(h, s)
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967291
    end
    return h
end

local HASH_CACHE = {}

--- 图片内容身份键："大小-哈希"。缓存按（路径,大小,修改时间）失效，
--- 同一张图拷到不同目录内容不变 → 键相同，正是「应用」与「存档」能对齐的关键。
---@param path string
---@return string|nil
local function imgKey(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local ck = path .. "\1" .. tostring(attr.size) .. "\1" .. tostring(attr.modification)
    local hit = HASH_CACHE[ck]
    if hit then return hit end
    local fd = io.open(path, "rb")
    if not fd then return nil end
    local h = 5381
    while true do
        local chunk = fd:read(4096)
        if not chunk then break end
        h = hAdd(h, chunk)
    end
    fd:close()
    local key = tostring(attr.size) .. "-" .. tostring(h)
    HASH_CACHE[ck] = key
    return key
end

--- 目录内容身份键：按文件名排序，把每张图的内容键串起来（跨设备路径不同也能对齐）
---@param dir string
---@return string|nil
local function dirKey(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return nil end
    local names = {}
    for name in lfs.dir(dir) do
        local p = dir .. "/" .. name
        if name ~= "." and name ~= ".." and lfs.attributes(p, "mode") == "file" then
            local ext = name:lower():match("%.(%w+)$")
            if ext and IMAGE_EXT[ext] then names[#names + 1] = name end
        end
    end
    table.sort(names)
    local h = 5381
    for _, name in ipairs(names) do
        h = hAdd(h, name)
        h = hAdd(h, imgKey(dir .. "/" .. name) or name)
    end
    return #names .. "-" .. tostring(h)
end

--- 图片引用归一化：@assets/xxx 还原成 assetsDir 下的绝对路径，
--- 再换成内容身份键 "@img/<键>"；文件夹换成 "@dir/<目录内容键>"；其他原样返回
---@param s string
---@param assetsDir string
---@return string
local function imgRef(s, assetsDir)
    if s:sub(1, #ASSET_MARK) == ASSET_MARK then
        s = assetsDir .. "/" .. s:sub(#ASSET_MARK + 1)
    end
    local ext = s:lower():match("%.(%w+)$")
    if not ext or not IMAGE_EXT[ext] then
        if lfs.attributes(s, "mode") == "directory" then
            return "@dir/" .. (dirKey(s) or s)
        end
        return s
    end
    local key = imgKey(s)
    return key and ("@img/" .. key) or s
end

--- 第一处不一致的路径（诊断日志用；键名拼成 a.b.c 形式）
---@param a any 当前值
---@param b any 存档值
---@param path string|nil
---@return string|nil
local function firstDiff(a, b, path)
    path = path or ""
    if a == b then return nil end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return path .. " (type " .. ta .. " vs " .. tb .. ")" end
    if ta ~= "table" then
        if ta == "number" and math.abs(a - b) < 1e-9 then return nil end
        return string.format("%s (%s vs %s)", path, tostring(a), tostring(b))
    end
    for k, v in pairs(a) do
        local d = firstDiff(v, b[k], path .. "." .. tostring(k))
        if d then return d end
    end
    for k in pairs(b) do
        if a[k] == nil then return path .. "." .. tostring(k) .. " (only in theme)" end
    end
    return nil
end

--- 应用中的主题是否被改过（当前配置与存档有出入）
--- 图片一侧不比文件名、不比路径，统一换成「内容身份键」再比：
--- assets 里允许存在同内容多副本（保存主题时同一张图从不同路径收编很常见），
--- 按文件名归一化会随机撞到哪份副本上，导致刚应用完就误报「有修改」。
---@param name string
---@return boolean
function Theme.dirty(name)
    local dir = Theme.dir(name)
    if not dir then return false end
    local chunk = loadfile(dir .. "/theme.lua")
    if not chunk then return false end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return false end

    local assetsDir = dir .. "/assets"
    local expected, cur

    local active = require("moonbeautify.store").conf().theme_parts or {}
    if type(data.parts) == "table" and #data.parts > 0 and next(active) ~= nil then
        -- 启用了部件：只比较当前启用的部件，混搭不该被当成「整包被改过」
        -- 整包应用会清空 theme_parts，此时没有启用项，退回整包比较才能发现用户改了配置
        local live = snapshotConf()
        expected, cur = {}, {}
        for _, p in ipairs(Theme.parts(name)) do
            -- 壁纸/锁屏在月读原生配置里，不混进 ext.beautify 的脏标记比较
            if p.type ~= "wallpaper" and p.type ~= "lockscreen" and active[p.slot] == p.id then
                Parts.merge(expected, p.conf, p.slot)
                for k, v in pairs(Parts.extract(live, p.slot)) do cur[k] = v end
            end
        end
    else
        if type(data.conf) ~= "table" then return false end
        -- v1：整包比较
        expected = data.conf
        cur = snapshotConf()
    end

    -- 主题存档侧：@assets/xxx 先还原成绝对路径，再统一换内容键
    walk(expected, function(s) return imgRef(s, assetsDir) end)
    -- 当前配置侧：本来就是绝对路径，直接换内容键
    walk(cur, function(s) return imgRef(s, assetsDir) end)

    local same = confEq(cur, expected)
    if not same then
        -- 还报差异就留一条日志，直接指出是哪个键（排查用，不影响功能）
        note("moonbeautify theme dirty", Theme.sanitize(name), firstDiff(cur, expected) or "?")
    end
    return not same
end


--- 把当前配置里指向 fromDir 的图片引用转给内容完全相同的另一套主题
--- （两套主题一模一样时删其一：引用无缝挪到另一套，不用先手动切换）
---@param fromDir string
---@return boolean 是否转移成功
local function redirectRefs(fromDir)
    local Store = require("moonbeautify.store")
    local prefix = fromDir .. "/"
    local myName = fromDir:match("([^/]+)$")
    local conf = Store.conf()
    -- 收集本主题被引用的图片（按内容比对，与文件名无关）
    local refs = {}
    walk(conf, function(s)
        if type(s) == "string" and s:sub(1, #prefix) == prefix
            and lfs.attributes(s, "mode") == "file" then
            refs[s] = true
        end
        return s
    end)
    if not next(refs) then return false end
    for _i, other in ipairs(Theme.list()) do
        if Theme.sanitize(other) ~= myName then
            local odir = Theme.dir(other)
            if odir then
                local osigs = sigOf(odir)
                if next(osigs) then
                    -- 每张被引用的图都能在另一套的 assets 里找到同内容文件才转
                    local repl, okAll = {}, true
                    for p in pairs(refs) do
                        local fd = io.open(p, "rb")
                        local d = fd and fd:read("*a") or nil
                        if fd then fd:close() end
                        local f = d and osigs[d] or nil
                        if f then
                            repl[p] = odir .. "/assets/" .. f
                        else
                            okAll = false
                            break
                        end
                    end
                    if okAll then
                        walk(conf, function(s)
                            return repl[s] or s
                        end)
                        if conf.active_theme == myName then
                            conf.active_theme = Theme.sanitize(other)
                        end
                        Store.save()
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- 界面壁纸是否真的有可分享的图：开关开、且明确选了图片或有图的文件夹。
--- “开 + 未选择”只会在主题里留下一个空壁纸部件，直接跳过。
---@param conf table|nil
---@return boolean
local function wallpaperHasAsset(conf)
    if type(conf) ~= "table" or conf.wallpaper_enabled == false then return false end
    for key, value in pairs(conf) do
        local is_image_key = key == "wallpaper_custom_image" or key:match("^wallpaper_image_") ~= nil
        if is_image_key and type(value) == "string" and value ~= "" then
            local mode = lfs.attributes(value, "mode")
            if mode == "file" then
                local ext = value:lower():match("%.(%w+)$")
                if ext and IMAGE_EXT[ext] then return true end
            elseif mode == "directory" and dirHasImage(value) then
                return true
            end
        end
    end
    return false
end

--- 把当前配置存成主题（同名覆盖）。只生成快照，不改变应用中的主题。
---@param name string
---@return boolean ok, string|nil err
function Theme.save(name)
    local safe = Theme.sanitize(name)
    if not safe then return false, "名字不能为空" end
    local dir = Theme.root() .. "/" .. safe
    if not mkdirp(dir) then
        return false, "建不了主题目录"
    end
    removeTree(dir .. "/assets")
    if not lfs.mkdir(dir .. "/assets") then return false, "建不了 assets 目录" end
    local conf = snapshotConf()
    local copied, first = collectAssets(conf, dir .. "/assets")
    -- 存档里保留 @assets/ 相对引用：应用/读取部件时才换成当前主题目录的绝对路径，
    -- 这样导出的 zip 在别的设备上也不会断图。
    -- v2：整包 conf 保留给旧版/整包应用；parts 供部件库独立启用停用。
    local parts = Parts.decorate(Parts.splitConf(conf), safe)
    -- 界面壁纸：月读原生配置在 features.wallpaper，单独捕获成一个部件。
    -- 只在开关开着且确实有图片/有图文件夹时收录，避免空壁纸部件。
    local wpConf = WallpaperPart.capture()
    if wallpaperHasAsset(wpConf) then
        local wpPart = {
            slot = "wallpaper", type = "wallpaper", label = "界面壁纸",
            name = "界面壁纸", conf = wpConf,
        }
        local n, wpFirst = collectAssets(wpPart.conf, dir .. "/assets")
        copied = copied + n
        Parts.decorate({ wpPart }, safe)
        parts[#parts + 1] = wpPart
        if not first then first = wpFirst end
    end
    -- 锁屏壁纸：只在月读合成锁屏启用（compose）时才收录，ko 模式不生成空部件
    local lsConf = LockscreenPart.capture()
    if lsConf.lock_screen == "compose" then
        local lsPart = {
            slot = "lockscreen", type = "lockscreen", label = "锁屏壁纸",
            name = "锁屏壁纸", conf = lsConf,
        }
        local n, lsFirst = collectAssets(lsPart.conf, dir .. "/assets")
        copied = copied + n
        Parts.decorate({ lsPart }, safe)
        parts[#parts + 1] = lsPart
        if not first then first = lsFirst end
    end
    for _, part in ipairs(parts) do part.conf = deepcopy(part.conf) end
    local file, werr = io.open(dir .. "/theme.lua", "w")
    if not file then return false, werr or "写不了 theme.lua" end
    file:write(serialize({
        kind = THEME_KIND,          -- 格式标识：导入时先认身份
        version = THEME_FORMAT,     -- 格式版本：将来 conf 键结构升级时做迁移判断
        name = safe,
        conf = conf,                -- 兼容 v1：整包应用
        parts = parts,              -- v2：可组合部件
        cover = first and (ASSET_MARK .. first) or nil,   -- 列表缩略图
    }))
    file:close()
    note("moonbeautify theme saved", safe, copied .. " assets")
    return true, dir
end

--- 应用主题（合并进当前配置）
---@param name string
---@return boolean ok, string|nil err
function Theme.apply(name)
    local dir = Theme.dir(name)
    if not dir or lfs.attributes(dir .. "/theme.lua", "mode") ~= "file" then
        return false, "主题不存在"
    end
    local chunk, err = loadfile(dir .. "/theme.lua")
    if not chunk then return false, "theme.lua 损坏：" .. tostring(err) end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.conf) ~= "table" then
        return false, "主题文件内容不对"
    end
    stripGlobalDecor(data.conf)
    remapAssets(data.conf, dir .. "/assets")
    -- 原生配置部件：整包应用时一起复刻保存时的壁纸/锁屏配置
    local appliedWallpaperId, appliedLockscreenId
    for _, part in ipairs(type(data.parts) == "table" and data.parts or {}) do
        if type(part.conf) ~= "table" then
            -- 跳过
        elseif part.type == "wallpaper" then
            local wp = deepcopy(part.conf)
            remapAssets(wp, dir .. "/assets")
            WallpaperPart.apply(wp)
            appliedWallpaperId = part.id or Parts.partId(Theme.sanitize(name) or name, part.slot or "wallpaper")
        elseif part.type == "lockscreen" then
            local ls = deepcopy(part.conf)
            remapAssets(ls, dir .. "/assets")
            LockscreenPart.apply(ls)
            appliedLockscreenId = part.id or Parts.partId(Theme.sanitize(name) or name, part.slot or "lockscreen")
        end
    end
    local Store = require("moonbeautify.store")
    local conf = Store.conf()
    local hasBeauty = false
    for k in pairs(data.conf) do
        if not LOCAL_KEYS[k] then hasBeauty = true break end
    end
    if hasBeauty then
        -- 彻底替换：存档里没有的外观键一律清掉，保证应用后与主题原样一致
        for k in pairs(conf) do
            if not LOCAL_KEYS[k] then conf[k] = nil end
        end
        for k, v in pairs(data.conf) do
            if not LOCAL_KEYS[k] then conf[k] = v end
        end
        -- 整包应用后，旧的部件启用记录不再有效（避免部件库和当前配置对不上）
        conf.theme_parts = nil
        conf.part_backups = nil
    elseif appliedWallpaperId or appliedLockscreenId then
        -- 兼容旧版纯壁纸/纯锁屏包：只记对应部件状态，不清空用户整套美化配置
        conf.theme_parts = type(conf.theme_parts) == "table" and conf.theme_parts or {}
        if appliedWallpaperId then conf.theme_parts.wallpaper = appliedWallpaperId end
        if appliedLockscreenId then conf.theme_parts.lockscreen = appliedLockscreenId end
    end
    conf.active_theme = Theme.sanitize(name)
    Store.save()
    note("moonbeautify theme applied", Theme.sanitize(name))
    return true
end

--- 读取主题包数据（v1/v2 通用）
local function loadThemeData(name)
    local dir = Theme.dir(name)
    if not dir or lfs.attributes(dir .. "/theme.lua", "mode") ~= "file" then
        return nil, nil
    end
    local chunk, err = loadfile(dir .. "/theme.lua")
    if not chunk then return nil, nil end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return nil, nil end
    return data, dir
end

--- 一套主题的部件列表（v2 直接读 parts；v1 从 conf 现场拆分）
---@param name string
---@return table[] parts 每项 { id, theme, slot, type, label, name, conf }
function Theme.parts(name)
    local data, dir = loadThemeData(name)
    if not data then return {} end
    local raw = (type(data.parts) == "table" and #data.parts > 0)
        and data.parts or Parts.splitConf(data.conf or {})
    local out = {}
    for _, p in ipairs(raw) do
        local q = deepcopy(p)
        q.conf = type(q.conf) == "table" and q.conf or {}
        stripGlobalDecor(q.conf)
        remapAssets(q.conf, dir .. "/assets")
        -- 旧的“全部组件通用”部件不再作为用户可见部件显示
        if q.slot ~= "comp_all" then
            -- 导入时主题可能改名，部件的 theme/id 必须以当前目录名为准
            q.theme = Theme.sanitize(name) or name
            q.slot = q.slot or "misc"
            q.id = Parts.partId(q.theme, q.slot)
            out[#out + 1] = q
        end
    end
    return Parts.decorate(out, Theme.sanitize(name) or name)
end

--- 把某个部件的配置改写回主题存档（图片外搬后让主题本身也指向新路径）
---@param name string
---@param slot string
---@param partConf table
---@return boolean ok, string|nil err
function Theme.updatePartConf(name, slot, partConf)
    local data, dir = loadThemeData(name)
    if not data or not dir then return false, "主题不存在" end
    if type(partConf) ~= "table" then return false, "配置不对" end
    local safe = Theme.sanitize(name) or name
    local raw = (type(data.parts) == "table" and #data.parts > 0)
        and data.parts or Parts.splitConf(data.conf or {})
    local found
    for _, p in ipairs(raw) do
        if p.slot == slot then found = p break end
    end
    if not found then return false, "部件不存在" end
    local ptype = found.type
    found.conf = deepcopy(partConf)
    if ptype ~= "wallpaper" and ptype ~= "lockscreen" then
        data.conf = type(data.conf) == "table" and data.conf or {}
        Parts.merge(data.conf, partConf, slot)
    end
    data.kind = THEME_KIND
    data.version = THEME_FORMAT
    data.name = safe
    data.parts = raw
    local file, werr = io.open(dir .. "/theme.lua", "w")
    if not file then return false, werr or "写不了 theme.lua" end
    file:write(serialize(data))
    file:close()
    note("moonbeautify theme part retargeted", safe .. "/" .. slot)
    return true
end

--- 所有主题的所有部件（部件库数据源）
function Theme.allParts()
    local out = {}
    for _, name in ipairs(Theme.list()) do
        for _, p in ipairs(Theme.parts(name)) do out[#out + 1] = p end
    end
    return out
end

--- 启用/停用单个部件。启用时记录当前值作为备份，停用时可还原。
---@param name string 主题名
---@param slot string 部件槽位
---@param enable boolean true 启用，false 停用
---@return boolean ok, string|nil err
function Theme.applyPart(name, slot, enable)
    local part
    for _, p in ipairs(Theme.parts(name)) do
        if p.slot == slot then part = p break end
    end
    if not part then return false, "部件不存在" end
    local Store = require("moonbeautify.store")
    local conf = Store.conf()
    conf.part_backups = type(conf.part_backups) == "table" and conf.part_backups or {}
    conf.theme_parts = type(conf.theme_parts) == "table" and conf.theme_parts or {}

    -- 界面壁纸走 features.wallpaper，备份/还原/应用都交给壁纸数据层
    if part.type == "wallpaper" then
        if enable then
            if not conf.part_backups[slot] then
                conf.part_backups[slot] = WallpaperPart.capture()
            end
            WallpaperPart.apply(part.conf)
            conf.theme_parts[slot] = part.id
        else
            WallpaperPart.apply(conf.part_backups[slot] or {})
            conf.part_backups[slot] = nil
            conf.theme_parts[slot] = nil
        end
        conf.active_theme = Theme.sanitize(name)
        Store.save()
        note("moonbeautify theme wallpaper part toggled", part.id, enable and "on" or "off")
        return true
    end

    -- 锁屏走 features.lockscreen，同样不混进 ext.beautify
    if part.type == "lockscreen" then
        if enable then
            if not conf.part_backups[slot] then
                conf.part_backups[slot] = LockscreenPart.capture()
            end
            LockscreenPart.apply(part.conf)
            conf.theme_parts[slot] = part.id
        else
            LockscreenPart.apply(conf.part_backups[slot] or {})
            conf.part_backups[slot] = nil
            conf.theme_parts[slot] = nil
        end
        conf.active_theme = Theme.sanitize(name)
        Store.save()
        note("moonbeautify theme lockscreen part toggled", part.id, enable and "on" or "off")
        return true
    end

    if enable then
        if not conf.part_backups[slot] then
            local base = part.type == "component"
                and Parts.withoutRows(conf, part.conf) or conf
            conf.part_backups[slot] = Parts.extract(base, slot)
        end
        Parts.merge(conf, part.conf, slot)
        conf.theme_parts[slot] = part.id
    else
        local backup = conf.part_backups[slot]
        if backup then
            Parts.merge(conf, backup, slot)
            conf.part_backups[slot] = nil
        else
            Parts.clear(conf, slot)
        end
        conf.theme_parts[slot] = nil
    end
    conf.active_theme = Theme.sanitize(name)
    Store.save()
    note("moonbeautify theme part toggled", part.id, enable and "on" or "off")
    return true
end

--- 删除主题里的单个部件（v1 主题会先转为 v2 再删）
---@param name string
---@param slot string
---@return boolean ok, string|nil err
function Theme.deletePart(name, slot)
    local data, dir = loadThemeData(name)
    if not data or not dir then return false, "主题不存在" end
    local safe = Theme.sanitize(name) or name
    local raw = (type(data.parts) == "table" and #data.parts > 0)
        and deepcopy(data.parts) or Parts.splitConf(data.conf or {})
    local removed
    for i, p in ipairs(raw) do
        if p.slot == slot then removed = p table.remove(raw, i) break end
    end
    if not removed then return false, "部件不存在" end

    -- 删组件部件时，把其它部件里引用了它的并排组合一起清掉；
    -- 清完变空的组件部件（比如只剩一条组合）也一并移除。
    if removed.type == "component" then
        local kept = {}
        for _, p in ipairs(raw) do
            if type(p.conf) == "table" then
                Parts.stripComponent(p.conf, slot)
                if p.type == "component" and next(p.conf) == nil then
                    -- 丢掉空部件
                else
                    kept[#kept + 1] = p
                end
            else
                kept[#kept + 1] = p
            end
        end
        raw = kept
    end

    Parts.decorate(raw, safe)
    local conf = Parts.union(raw)
    stripGlobalDecor(conf)

    -- 整包应用后 theme_parts 会被清空；这里同时按配置内容判断这个部件是否正在生效
    local Store = require("moonbeautify.store")
    local live = Store.conf()
    local pid = Parts.partId(safe, slot)
    local remapped = deepcopy(removed.conf or {})
    remapAssets(remapped, dir .. "/assets")
    local inUse = type(live.theme_parts) == "table" and live.theme_parts[slot] == pid
    if not inUse and removed.type == "wallpaper" then
        inUse = WallpaperPart.matches(remapped)
    elseif not inUse and removed.type == "lockscreen" then
        inUse = LockscreenPart.matches(remapped)
    elseif not inUse then
        inUse = Parts.matches(live, remapped, slot)
    end
    if inUse then
        local backup = type(live.part_backups) == "table" and live.part_backups[slot] or nil
        if removed.type == "wallpaper" then
            WallpaperPart.apply(backup or {})
        elseif removed.type == "lockscreen" then
            LockscreenPart.apply(backup or {})
        elseif backup then
            if removed.type == "component" then
                backup = Parts.withoutRows(backup, removed.conf)
                Parts.stripComponent(backup, slot)
            end
            Parts.merge(live, backup, slot)
        else
            Parts.clear(live, slot)
        end
        if type(live.part_backups) == "table" then live.part_backups[slot] = nil end
        if type(live.theme_parts) == "table" then live.theme_parts[slot] = nil end
        Store.save()
    end

    -- 回收不再被任何部件/封面引用的图片（assets 下可能有壁纸文件夹）
    local assetsDir = dir .. "/assets"
    local used = {}
    local function mark(s)
        if type(s) == "string" then
            local f = s:match("^@assets/(.+)$")
            if f then
                used[f] = true
                local abs = assetsDir .. "/" .. f
                if lfs.attributes(abs, "mode") == "directory" then
                    local function openDir(d, rel)
                        for n in lfs.dir(d) do
                            if n ~= "." and n ~= ".." then
                                local p = d .. "/" .. n
                                used[rel .. n] = true
                                if lfs.attributes(p, "mode") == "directory" then
                                    openDir(p, rel .. n .. "/")
                                end
                            end
                        end
                    end
                    openDir(abs, f .. "/")
                end
            end
        end
        return s   -- walk 会把返回值写回，必须原样返回，不能清空配置
    end
    mark(data.cover)
    walk(conf, mark)
    walk(raw, mark)
    -- 当前设置里仍在用的绝对路径也要保住，别删掉正在显示的图片
    local function markLive(s)
        if type(s) == "string" then
            local prefix = assetsDir .. "/"
            if s:sub(1, #prefix) == prefix then
                local rel = s:sub(#prefix + 1)
                used[rel] = true
                local abs = assetsDir .. "/" .. rel
                if lfs.attributes(abs, "mode") == "directory" then
                    local function openDir(d, pre)
                        for n in lfs.dir(d) do
                            if n ~= "." and n ~= ".." then
                                local p = d .. "/" .. n
                                used[pre .. n] = true
                                if lfs.attributes(p, "mode") == "directory" then
                                    openDir(p, pre .. n .. "/")
                                end
                            end
                        end
                    end
                    openDir(abs, rel .. "/")
                end
            end
        end
        return s
    end
    walk(live, markLive)
    local function prune(d, parent)
        for f in lfs.dir(d) do
            if f ~= "." and f ~= ".." then
                local p = d .. "/" .. f
                if lfs.attributes(p, "mode") == "directory" then
                    prune(p, parent .. f .. "/")
                    local empty = true
                    for n in lfs.dir(p) do
                        if n ~= "." and n ~= ".." then empty = false break end
                    end
                    if empty then lfs.rmdir(p) end
                elseif not used[parent .. f] then
                    os.remove(p)
                end
            end
        end
    end
    if lfs.attributes(assetsDir, "mode") == "directory" then prune(assetsDir, "") end

    data.kind = THEME_KIND
    data.version = THEME_FORMAT
    data.name = safe
    data.conf = conf
    data.parts = raw
    local file, werr = io.open(dir .. "/theme.lua", "w")
    if not file then return false, werr or "写不了 theme.lua" end
    file:write(serialize(data))
    file:close()
    note("moonbeautify theme part deleted", pid)
    return true
end

--- 删除主题
---@param name string
---@return boolean ok, string|nil err
function Theme.delete(name)
    local dir = Theme.dir(name)
    if not dir then return false, "名字不合法" end
    if lfs.attributes(dir, "mode") ~= "directory" then return false, "主题不存在" end
    -- 当前配置若还引用着该主题「真实存在」的图片，删掉会产生悬空路径：优先转给内容相同的
    -- 另一套主题，转移不成才拒绝。路径还在但图片已经没了（空主题/图被清过）不算占用，
    -- 顺手把这些失效路径清掉，否则最后一个主题会因假引用永远删不掉。
    local prefix = dir .. "/"
    local Store = require("moonbeautify.store")
    local live = Store.conf()
    local used, dangling = false, {}
    walk(live, function(s)
        if type(s) == "string" and s:sub(1, #prefix) == prefix then
            if lfs.attributes(s, "mode") == "file" then used = true else dangling[s] = true end
        end
        return s
    end)
    if used and not redirectRefs(dir) then
        return false, "beautify_in_use"
    end
    if next(dangling) then
        walk(live, function(s)
            if dangling[s] then return nil end   -- 不能直接 and nil or s：nil or s 会退回原值
            return s
        end)
    end
    -- 月读原生的界面壁纸 / 锁屏壁纸也可能引用主题图片（把主题里的图设成了壁纸），说明来源
    local okMS, MoonSettings = pcall(require, "utils.settings")
    local nativeHits, nativeDangling = {}, {}
    if okMS and MoonSettings then
        for _, spec in ipairs({ { "features.wallpaper", "界面壁纸" }, { "features.lockscreen", "锁屏壁纸" } }) do
            local ok, conf = pcall(function() return MoonSettings.get(spec[1]) end)
            if ok and type(conf) == "table" then
                for key, v in pairs(conf) do
                    if type(v) == "string" and v:sub(1, #prefix) == prefix then
                        if lfs.attributes(v, "mode") == "file" then
                            nativeHits[#nativeHits + 1] = spec[2]
                        else
                            nativeDangling[#nativeDangling + 1] = { conf, key, spec[1] }
                        end
                        break
                    end
                end
            end
        end
    end
    if #nativeHits > 0 then
        local tip = table.concat(nativeHits, "、") .. "正在使用本主题下的图片"
        if table.concat(nativeHits, ""):find("界面壁纸", 1, true) then
            tip = tip .. "；可先在壁纸部件菜单里「复制到其他文件夹」"
        end
        return false, tip
    end
    for _, hit in ipairs(nativeDangling) do
        hit[1][hit[2]] = nil
        pcall(function() MoonSettings.save(hit[3], hit[1]) end)
    end
    if not removeTree(dir) then return false, "删不掉主题目录" end
    -- 悬空标记一并清掉：active_theme、该主题的部件启用记录与备份
    local safe = Theme.sanitize(name)
    local changed = next(dangling) ~= nil or #nativeDangling > 0
    if live.active_theme == safe then live.active_theme = nil changed = true end
    local stale = {}
    if type(live.theme_parts) == "table" then
        for slot, id in pairs(live.theme_parts) do
            if Parts.parsePartId(id) == safe then
                stale[slot] = true
                live.theme_parts[slot] = nil
                changed = true
            end
        end
        if next(live.theme_parts) == nil then live.theme_parts = nil end
    end
    if type(live.part_backups) == "table" then
        for slot in pairs(stale) do
            live.part_backups[slot] = nil
            changed = true
        end
        if next(live.part_backups) == nil then live.part_backups = nil end
    end
    if changed then Store.save() end
    note("moonbeautify theme deleted", Theme.sanitize(name))
    return true
end

--- 导出主题成 zip（写到 destDir/<主题名>.zip）
---@param name string
---@param destDir string
---@return boolean ok, string|nil path_or_err
function Theme.export(name, destDir)
    local dir = Theme.dir(name)
    if not dir or lfs.attributes(dir .. "/theme.lua", "mode") ~= "file" then
        return false, "主题不存在"
    end
    local safe = Theme.sanitize(name)
    local src = io.open(dir .. "/theme.lua", "rb")
    if not src then return false, "读不了 theme.lua" end
    local themeData = src:read("*a")
    src:close()
    local files = { { name = "theme.lua", data = themeData } }
    local assetsDir = dir .. "/assets"
    local function addDir(d, prefix)
        for name in lfs.dir(d) do
            if name ~= "." and name ~= ".." then
                local p = d .. "/" .. name
                local mode = lfs.attributes(p, "mode")
                if mode == "directory" then
                    addDir(p, prefix .. name .. "/")
                elseif mode == "file" then
                    local f = io.open(p, "rb")
                    if f then
                        files[#files + 1] = { name = prefix .. name, data = f:read("*a") }
                        f:close()
                    end
                end
            end
        end
    end
    if lfs.attributes(assetsDir, "mode") == "directory" then addDir(assetsDir, "assets/") end
    local Zip = require("moonbeautify.zip")
    local path = destDir .. "/" .. safe .. ".zip"
    local ok, err = Zip.write(path, files)
    if not ok then
        note("moonbeautify theme export failed", path, err)
        return false, err
    end
    note("moonbeautify theme exported", path, #files - 1 .. " assets")
    return true, path
end

--- 导入 zip 成主题
---@param zipPath string
---@return boolean ok, string|nil name_or_err
function Theme.importZip(zipPath)
    if type(zipPath) ~= "string" or zipPath == ""
        or lfs.attributes(zipPath, "mode") ~= "file" then
        return false, "zip 文件不存在"
    end
    local root = Theme.root()
    if not mkdirp(root) then
        return false, "建不了主题目录"
    end
    local staging = root .. "/.import-" .. tostring(os.time())
    removeTree(staging)
    if not lfs.mkdir(staging) then return false, "建不了暂存目录" end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(zipPath) then
        removeTree(staging)
        return false, reader.err or "打不开 zip"
    end
    for entry in reader:iterate() do
        -- 只解相对路径，防 zip 路径穿越
        if entry.path and not entry.path:match("%.%.") and entry.path:sub(1, 1) ~= "/" then
            reader:extractToPath(entry.path, staging .. "/" .. entry.path)
        end
    end
    local rerr = reader.err
    reader:close()
    if rerr then
        removeTree(staging)
        return false, "解压失败：" .. tostring(rerr)
    end
    -- theme.lua 在包根或一级子目录
    local base
    if lfs.attributes(staging .. "/theme.lua", "mode") == "file" then
        base = staging
    else
        for n in lfs.dir(staging) do
            if n ~= "." and n ~= ".."
                and lfs.attributes(staging .. "/" .. n .. "/theme.lua", "mode") == "file" then
                base = staging .. "/" .. n
            end
        end
    end
    if not base then
        removeTree(staging)
        return false, "zip 里没有 theme.lua"
    end
    local chunk = loadfile(base .. "/theme.lua")
    -- 不能写 `chunk and pcall(chunk) or false`：and/or 会把 pcall 的多值截成单值，
    -- data 永远是 nil（曾经导致包内 name 字段失效，主题名一直取 zip 文件名）
    local ok, data
    if chunk then ok, data = pcall(chunk) end
    -- 身份校验：声明了 kind 但不是月读美化主题的包，明确拒绝（旧包没写 kind，照收，向后兼容）
    if ok and type(data) == "table" and data.kind ~= nil and data.kind ~= THEME_KIND then
        removeTree(staging)
        return false, "这不是月读美化的主题包"
    end
    local cname = (ok and type(data) == "table") and data.name or nil
    local zipName = zipPath:match("([^/\\]+)$")
    local fromFile = zipName and zipName:match("^(.*)%.[%w]+$") or zipName
    local name = Theme.sanitize(cname or fromFile) or "theme"
    local dest = root .. "/" .. name
    removeTree(dest)
    if not os.rename(base, dest) then
        removeTree(staging)
        return false, "挪不进主题目录"
    end
    removeTree(staging)
    note("moonbeautify theme imported", name, zipPath)
    return true, name
end

return Theme
