--[[--
版本更新检查：复用月读自带的通用更新器（utils.plugin_update），
和「拓展」里其它插件一样——设置里有「检查更新」，启动后每天自动查一次，
发现新版弹对话框（带更新日志），点「下载并安装」就地替换并重启。

Release 约定（发版时必须遵守，否则这里认不出来）：
  tag        vX.Y.Z
  附件名     moon-beautify-X.Y.Z.zip    （不带 v，和 tag 只差前缀）
  附件地址   https://github.com/1gqz/moon-beautify/releases/download/<tag>/<附件名>

@module moonbeautify.core.update
--]]

local _ = require("moonbeautify.l10n")
local T = require("ffi/util").template

local Update = {}

local CHECK_INTERVAL = 24 * 60 * 60
local REPO = "1gqz/moon-beautify"

--- 本文件在 <插件根>/moonbeautify/core/update.lua，往上三级就是插件根目录
---@return string|nil
local function pluginRoot()
    local src = debug.getinfo(1, "S").source
    if type(src) ~= "string" then return nil end
    return (src:gsub("^@", "")):match("^(.*)/moonbeautify/core/[^/]+$")
end

--- 当前安装版本：直接读插件根的 _meta.lua，避免和打包时写的版本号对不上
---@return string|nil
local function installed()
    local root = pluginRoot()
    if not root then return nil end
    local chunk = loadfile(root .. "/_meta.lua")
    if not chunk then return nil end
    local ok, meta = pcall(chunk)
    if ok and type(meta) == "table" and type(meta.version) == "string" then return meta.version end
    return nil
end

---@return table Updater 实例（月读 0.8.0 起自带 utils.plugin_update，门禁已保证版本）
local function updater()
    if Update._updater then return Update._updater end
    Update._updater = require("utils.plugin_update").new{
        repo = REPO,
        -- 先走月读用的 GitHub 转发，挂了回落直连（和月读自己的更新同款）
        api_urls = {
            "https://api.ankio.net/gh/repos/" .. REPO .. "/releases/latest",
            "https://api.github.com/repos/" .. REPO .. "/releases/latest",
        },
        asset = function(tag)
            return "moon-beautify-" .. (tag:gsub("^v", "")) .. ".zip"
        end,
        archive = "moon-beautify-update.zip",
        job = "moonbeautify.update",
        -- 老旧 GitHub 响应没有 digest 字段，不强制校验
        digest_required = false,
        installed = installed,
        name = "moon-beautify.koplugin",
        parent = function(root) return root:match("^(.*)/[^/]+$") end,
        -- 空壳包不能盖掉正在跑的插件
        verify = function(name, staging)
            if name == "moon-beautify.koplugin" and not loadfile(staging .. "/" .. name .. "/_meta.lua") then
                return "not a moon-beautify archive"
            end
        end,
        text = {
            checking = _("正在检查更新…"),
            downloading = _("正在下载新版本…"),
            installing = _("正在安装新版本…"),
            failed = _("更新失败：%1"),
            title = _("更新日志"),
            latest = function() return installed() or "?" end,
            header = function(release, force)
                if force and not release.available then
                    return T(_("强制重装 %1（当前已是此版本）。下载并替换插件目录？"), release.version)
                end
                return T(_("发现新版本 %1（当前 %2）。下载并安装？"), release.version, release.installed or "?")
            end,
        },
    }
    return Update._updater
end

---@return string|nil version
function Update.version()
    return installed()
end

--- 自动检查开关（扩展设置页里的「自动检查更新」，缺省开）
---@return boolean
function Update.autoEnabled()
    return require("moonbeautify.core.store").conf().update_auto ~= false
end

---@param on boolean
function Update.setAuto(on)
    local Store = require("moonbeautify.core.store")
    Store.conf().update_auto = on and true or false
    Store.save()
end

--- 手动检查：设置页那一行
---@param force boolean|nil 已是此版本也重装
function Update.check(force)
    updater():manualCheck(pluginRoot(), force and true or nil)
end

--- 启动后自动查一次（每天最多一次）。没网 / 无更新 / 出错都完全静默。
function Update.autoCheck()
    if os.time() - (Update._checked_at or 0) < 60 then return end
    Update._checked_at = os.time()
    local Store = require("moonbeautify.core.store")
    local conf = Store.conf()
    if os.time() - (tonumber(conf.update_checked_at) or 0) < CHECK_INTERVAL then return end
    if not Update.autoEnabled() then return end
    local ok_net, connected = pcall(function() return require("ui/network/manager"):isConnected() end)
    if not ok_net or not connected then return end
    -- 读不到本地版本就不自动弹窗：没有基准版本会导致「永远提示有新版本」
    if not installed() then return end
    local u, root = updater(), pluginRoot()
    conf.update_checked_at = os.time()
    Store.save()
    u:check(function(release, err)
        if err or type(release) ~= "table" or not release.available then return end
        pcall(function() u:prompt(release, root) end)
    end)
end

--- 挂到月读的「桌面回到前台」事件上（不在插件 init 里抢跑网络请求）
function Update.install()
    require("utils.extension").add("desktop.activated", function() Update.autoCheck() end)
end

return Update
