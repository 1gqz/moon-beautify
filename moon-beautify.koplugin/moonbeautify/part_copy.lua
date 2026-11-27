--- 把部件用到的图片复制到主题目录（.moon）之外的普通文件夹。
--- 复制后改写部件配置并落回当前设置/主题存档，这样 KOReader 文件管理器能直接看到图片，
--- 删掉主题包也不会让图片失效。
local lfs = require("libs/libkoreader-lfs")
local Parts = require("moonbeautify.parts")
local Store = require("moonbeautify.store")

local M = {}

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true }

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

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

local function isImageFile(path)
    local ext = path:lower():match("%.(%w+)$")
    return ext ~= nil and IMAGE_EXT[ext] == true
end

local function dirHasImage(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then return false end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" and isImageFile(name) then return true end
        end
    end
    return false
end

--- 枚举部件配置里指向图片文件或图片文件夹的字符串（去重）
function M.images(conf)
    local out, seen = {}, {}
    walk(conf, function(s)
        if type(s) ~= "string" or s == "" or seen[s] then return s end
        local attr = lfs.attributes(s)
        if not attr then return s end
        if attr.mode == "file" and isImageFile(s) then
            seen[s] = true
            out[#out + 1] = { path = s, dir = false }
        elseif attr.mode == "directory" and dirHasImage(s) then
            seen[s] = true
            out[#out + 1] = { path = s, dir = true }
        end
        return s
    end)
    return out
end

local function sameFile(a, b)
    local fa, fb = io.open(a, "rb"), io.open(b, "rb")
    if not fa or not fb then
        if fa then fa:close() end
        if fb then fb:close() end
        return false
    end
    local da, db = fa:read("*a"), fb:read("*a")
    fa:close()
    fb:close()
    return da == db
end

local function sameDir(a, b)
    local function files(dir)
        local out = {}
        if lfs.attributes(dir, "mode") ~= "directory" then return nil end
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then out[name] = dir .. "/" .. name end
        end
        return out
    end
    local fa, fb = files(a), files(b)
    if not fa or not fb then return false end
    for name, pa in pairs(fa) do
        if not fb[name] or not sameFile(pa, fb[name]) then return false end
    end
    for name in pairs(fb) do
        if not fa[name] then return false end
    end
    return true
end

local function usedNames(dir)
    local used = {}
    if lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do used[name] = true end
    end
    return used
end

local function copyFile(src, dst)
    local f = io.open(src, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    if not data then return false end
    local o = io.open(dst, "wb")
    if not o then return false end
    o:write(data)
    o:close()
    return true
end

local function copyDir(src, dst)
    if lfs.attributes(dst, "mode") ~= "directory" and not lfs.mkdir(dst) then return false end
    for name in lfs.dir(src) do
        if name ~= "." and name ~= ".." then
            local s, d = src .. "/" .. name, dst .. "/" .. name
            local mode = lfs.attributes(s, "mode")
            if mode == "directory" then
                copyDir(s, d)
            elseif mode == "file" then
                copyFile(s, d)
            end
        end
    end
    return true
end

local function uniqueName(used, base)
    if not used[base] then used[base] = true return base end
    local stem, ext = base:match("^(.*)%.(%w+)$")
    if not stem or stem == "" then stem, ext = base, "" end
    local i = 2
    while true do
        local candidate = stem .. "_" .. i .. (ext ~= "" and ("." .. ext) or "")
        if not used[candidate] then used[candidate] = true return candidate end
        i = i + 1
    end
end

--- 内容相同就复用目标文件，否则起新名字
local function destNameFor(used, targetDir, base, src, isDir)
    local want = isDir and "directory" or "file"
    local cmp = isDir and sameDir or sameFile
    local function sameAt(name)
        local path = targetDir .. "/" .. name
        return lfs.attributes(path, "mode") == want and cmp(src, path)
    end
    if sameAt(base) or not used[base] then used[base] = true return base end
    return uniqueName(used, base)
end

--- 把 part.conf 里的图片复制到 targetDir，返回改写后的配置和文件名列表
---@param conf table
---@param targetDir string
---@return table newConf, string[] files
function M.copyTo(conf, targetDir)
    local newConf = copy(conf) or {}
    if lfs.attributes(targetDir, "mode") ~= "directory" then lfs.mkdir(targetDir) end
    local used, repl, files = usedNames(targetDir), {}, {}
    for _, item in ipairs(M.images(newConf)) do
        local base = item.path:match("([^/\\]+)$") or "image"
        local name = destNameFor(used, targetDir, base, item.path, item.dir)
        local dest = targetDir .. "/" .. name
        if item.dir then
            if lfs.attributes(dest, "mode") ~= "directory" then copyDir(item.path, dest) end
        elseif lfs.attributes(dest, "mode") ~= "file" then
            copyFile(item.path, dest)
        end
        files[#files + 1] = name
        repl[item.path] = dest
    end
    walk(newConf, function(s) return repl[s] or s end)
    return newConf, files
end

--- 把改写后的配置落到当前设置（原生部件走各自数据层，其余合并回 ext.beautify）
function M.apply(part, newConf)
    if part.type == "wallpaper" then
        return require("moonbeautify.wallpaper_part").apply(newConf)
    end
    if part.type == "lockscreen" then
        return require("moonbeautify.lockscreen_part").apply(newConf)
    end
    local conf = Store.conf()
    Parts.merge(conf, newConf, part.slot)
    Store.save()
    return true
end

return M
