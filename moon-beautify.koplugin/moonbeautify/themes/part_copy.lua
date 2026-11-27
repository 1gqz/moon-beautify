--- 把部件用到的图片复制到主题目录（.moon）之外的普通文件夹。
--- 复制后改写部件配置并落回当前设置/主题存档，这样 KOReader 文件管理器能直接看到图片，
--- 删掉主题包也不会让图片失效。
local lfs = require("libs/libkoreader-lfs")
local Fs = require("utils.fs")
local Image = require("utils.image")
local Paths = require("utils.paths")
local Parts = require("moonbeautify.themes.parts")
local Pick = require("moonbeautify.core.pick")
local Store = require("moonbeautify.core.store")

local M = {}

local copy = Parts.copy

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

--- 枚举部件配置里指向图片文件或图片文件夹的字符串（去重）
function M.images(conf)
    local out, seen = {}, {}
    walk(conf, function(s)
        if type(s) ~= "string" or s == "" or seen[s] then return s end
        local attr = lfs.attributes(s)
        if not attr then return s end
        if attr.mode == "file" and Image.suffix(s) then
            seen[s] = true
            out[#out + 1] = { path = s, dir = false }
        elseif attr.mode == "directory" and #Pick.listImages(s) > 0 then
            seen[s] = true
            out[#out + 1] = { path = s, dir = true }
        end
        return s
    end)
    return out
end

local function sameFile(a, b)
    local da = Fs.read(a)
    return da ~= nil and da == Fs.read(b)
end

local function sameDir(a, b)
    local function files(dir)
        if lfs.attributes(dir, "mode") ~= "directory" then return nil end
        local out = {}
        for _i, name in ipairs(Fs.list(dir)) do out[name] = dir .. "/" .. name end
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
    for _i, name in ipairs(Fs.list(dir)) do used[name] = true end
    return used
end

local function copyFile(src, dst)
    local data = Fs.read(src)
    return data ~= nil and Fs.write(dst, data) == true
end

local function copyDir(src, dst)
    if not Paths.ensureDir(dst) then return false end
    local ok = true
    for _i, name in ipairs(Fs.list(src)) do
        local s, d = src .. "/" .. name, dst .. "/" .. name
        local mode = lfs.attributes(s, "mode")
        if mode == "directory" then
            ok = copyDir(s, d) and ok
        elseif mode == "file" then
            ok = copyFile(s, d) and ok
        end
    end
    return ok
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

--- 把 part.conf 里的图片复制到 targetDir，返回改写后的配置、文件名列表和失败数。
--- 复制失败的图片保留原路径，不能把配置指到不存在的文件。
---@param conf table
---@param targetDir string
---@return table newConf, string[] files, integer failed
function M.copyTo(conf, targetDir)
    local newConf = copy(conf) or {}
    Paths.ensureDir(targetDir)
    local used, repl, files, failed = usedNames(targetDir), {}, {}, 0
    for _, item in ipairs(M.images(newConf)) do
        local base = item.path:match("([^/\\]+)$") or "image"
        local name = destNameFor(used, targetDir, base, item.path, item.dir)
        local dest = targetDir .. "/" .. name
        local ok = true
        if item.dir then
            if lfs.attributes(dest, "mode") ~= "directory" then ok = copyDir(item.path, dest) end
        elseif lfs.attributes(dest, "mode") ~= "file" then
            ok = copyFile(item.path, dest)
        end
        if ok then
            files[#files + 1] = name
            repl[item.path] = dest
        else
            failed = failed + 1
        end
    end
    walk(newConf, function(s) return repl[s] or s end)
    return newConf, files, failed
end

--- 把改写后的配置落到当前设置（原生部件走各自数据层，其余合并回 ext.beautify）
function M.apply(part, newConf)
    if part.type == "wallpaper" then
        return require("moonbeautify.themes.wallpaper_part").apply(newConf)
    end
    if part.type == "lockscreen" then
        return require("moonbeautify.themes.lockscreen_part").apply(newConf)
    end
    local conf = Store.conf()
    Parts.merge(conf, newConf, part.slot)
    Store.save()
    return true
end

return M
