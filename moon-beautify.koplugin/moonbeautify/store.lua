--[[--
配置存取。扩展自己的独立配置表（settings/ext.beautify.lua），不碰月读自己的分区。

键（均以「实例 id + 下划线」为前缀：badge_ / badge2_ / badge3_ / badge4_）：
  <p>pick      string  "file"（固定一张，缺省）| "folder"（文件夹里挑一张）
  <p>src       string  固定图片的绝对路径（pick = file）
  <p>dir       string  图片文件夹绝对路径（pick = folder）
  <p>mode      string  "daily"（每天一张，缺省）| "shuffle"（每次刷新随机）
  <p>shape     string  "circle"（缺省，圆形）| "round"（圆角）| "square"（直角）
  <p>size      string  "s" | "m"（缺省）| "l"
  <p>spin      number  转动：转一圈的秒数，0/缺省为不转（按每帧几度平滑推进）
  <p>effects   table   启用的特效：{ glitter = true, rain = true, stars = true }（细闪/雨滴/星星）
  <p>overlay   string  叠加素材（带透明通道的 PNG），方形素材按圆形裁切后压在照片上
  <p>slots     table   贴图：{ [1..8] = 图片绝对路径 }，田字摆法（上排 1–4、下排 5–8）；
                      并排（组合）时只显示中间两列，即 2、3 与 6、7 四格
  <p>ring      string  吧唧光环："double"（双线，缺省 true 同此）
  tab_icons    table   tab.id → 图片绝对路径，替换底栏图标
  widget_bg    table   组件 id → { src = 背景图绝对路径, veil = 0-100 内容提亮 }
  widget_lace  table   组件花边：组件 id → 路径字符串（旧）或 { src = 透明 PNG 路径, fit = stretch|fill|fit }；
                       all = 全部组件统一花边，组件 id 可覆盖（false/空 = 关）
  widget_lace_fit  —   花边填充方式已并入 widget_lace 的表中，不再单独占键
  rows         table   并排组合：{ { 组件id, 组件id }, ... }，同一页的同组成员合成一行
  last_dir     string  上一次选图用过的目录；没单独配路径的选图器都从这里打开（与界面壁纸共用）

@module moonbeautify.store
--]]

local Settings = require("utils.settings")

local ID = "ext.beautify"

local Store = { ID = ID }

--- 扩展配置表（月读保证同一张表，改完调 save() 落盘）
function Store.conf()
    return Settings.getSource(ID)
end

function Store.save()
    Settings.saveSource(ID)
end

--- 字符串键取枚举值，非法或缺省都回 fallback
function Store.enum(conf, key, values, fallback)
    local v = conf[key]
    if type(v) == "string" and values[v] ~= nil then return v end
    return fallback
end

return Store
