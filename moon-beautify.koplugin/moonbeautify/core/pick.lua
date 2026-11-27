--[[--
图片文件枚举与挑选。

@module moonbeautify.core.pick
--]]

local lfs = require("libs/libkoreader-lfs")
local Fs = require("utils.fs")
local Image = require("utils.image")

local Pick = {}

-- LuaJIT 的 math.random 默认种子固定：不播种的话每次开机"随机"序列都一样
math.randomseed(os.time())

--- 列一个文件夹里的图片，全路径，按名字排序。目录不存在或不是目录返回空表。
---@param dir string
---@return string[]
function Pick.listImages(dir)
    local out = {}
    if type(dir) ~= "string" or dir == "" then return out end
    for _i, name in ipairs(Fs.list(dir)) do
        local p = dir .. "/" .. name
        if name:sub(1, 1) ~= "." and Image.suffix(name) and lfs.attributes(p, "mode") == "file" then
            out[#out + 1] = p
        end
    end
    return out
end

--- 当天是今年的第几天（1 起），拿来做"每天一张"的稳定序号。
---@return number
function Pick.dayIndex()
    return tonumber(os.date("%j")) or 1
end

--- 按节奏从图片列表里挑一张。
--- daily：以"年天"为种子稳定取一张，当天内重复构建结果一致（墨水屏友好）；
--- shuffle：每次调用随机。
---@param list string[]
---@param mode string "daily" | "shuffle"
---@return string|nil
function Pick.choose(list, mode)
    local n = #list
    if n == 0 then return nil end
    if mode == "shuffle" then
        return list[math.random(n)]
    end
    return list[((Pick.dayIndex() - 1) % n) + 1]
end

return Pick
