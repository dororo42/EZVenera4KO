--[[
EZVenera for KOReader — main.lua
插件入口：生命周期 + 主菜单。REQ: R1.1/R1.2/R1.4，R5.1（无长按红线）。

菜单结构（全部普通菜单项，ADR-005）：
  工具 → EZVenera 漫画
    ├─ 浏览漫画源      （M2：browser.lua；引擎可用性门控）
    ├─ 收藏夹          （library.lua：本地持久化，一键回到某本书）
    ├─ 阅读历史        （library.lua：直接续读上次那一章）
    ├─ 管理漫画源      （M2：sources.lua）
    ├─ 网络代理        （M1：proxyconf 子菜单）
    └─ 引擎与状态
]]

local _ = require("gettext")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Settings = require("settings")
local Library = require("library")
local ProxyConf = require("proxyconf")
local NetClient = require("netclient")
local CoreFix = require("corefix")

local EzVenera = WidgetContainer:extend{
    name = "ezvenera",
    is_doc_only = false,
}

function EzVenera:init()
    self.settings = Settings.open()
    self.library = Library.new(self.settings)
    self.netclient = NetClient.new()
    -- 给 KOReader 的列表排序器装 nil 保护（真机闪退真凶，见 corefix.lua）
    local fixed, detail = CoreFix.install()
    if fixed then
        logger.info("ezvenera: hardened booklist sorters:", detail)
    else
        logger.warn("ezvenera: booklist hardening skipped:", detail)
    end
    -- 启动时对齐“全局代理同步”（若开启）
    if self.settings:isApplyGlobal() then
        ProxyConf.applyGlobal(self.settings)
    end
    self.ui.menu:registerToMainMenu(self)
    -- Dispatcher 注册（供手势/快捷键绑定，hello.koplugin 同款约定）
    Dispatcher:registerAction("ezvenera_open", {
        category = "none",
        event = "EzVeneraOpen",
        title = "EZVenera 漫画",
        general = true,
    })
    -- 续读单独一条：用户可把它绑到角点轻触/多指划（设置→轻点与手势），
    -- 这是平板上真正的高频区域。动态标题在菜单里给（addToMainMenu）。
    Dispatcher:registerAction("ezvenera_resume", {
        category = "none",
        event = "EzVeneraResume",
        title = "EZVenera: 继续上次阅读",
        general = true,
    })
    Dispatcher:registerAction("ezvenera_downloads", {
        category = "none",
        event = "EzVeneraDownloads",
        title = "EZVenera: 下载与缓存",
        general = true,
    })
    -- 【SimpleUI 的两个对接面】上游 v2.7.1 的 features/sui_quickactions.lua 会
    -- 扫 Dispatcher 动作（_scanDispatcherActions:2355 → execute:3125），所以上面
    -- 三条在 SimpleUI 的「自定义 QA → 系统动作」里直接能选到；_registerSimpleUIQA
    -- 再走它头部注释声明的公开插件接口 QA.register，做出带标签/图标的三个磁贴。
    -- 真机当前未装 SimpleUI：注册失败必须静默，不能让 init() 抛错。
    self:_registerSimpleUIQA()
    self:_startSettingsAutoflush()
    self:_selftestOnStartup()
end

--- 定期把 KOReader 的全局设置落盘。
--- 为什么插件要管这件事：G_reader_settings 只在干净退出（Device:exit → close）
--- 或系统挂起时才写盘，而安卓上「从最近任务划掉」和应用崩溃都不走这两条路；
--- 设置→键盘布局的勾选（menu_keyboard_layout.lua 的 callback）甚至是直接改内存里
--- 的 keyboard_layouts 表、连 saveSetting 都不调，所以整批改动会随着一次强杀蒸发
--- ——用户看到的就是「每次重开 KOReader 都要重新设键盘布局」。
--- settings.reader.lua 实测 9.8KB，30s 一次的写盘代价可忽略。
--- 全程 pcall：拿不到 G_reader_settings / UIManager 就静默不启用，绝不拖垮启动。
function EzVenera:_startSettingsAutoflush()
    if self._settings_autoflush then return end
    local G = G_reader_settings
    if type(G) ~= "table" or type(G.flush) ~= "function" then return end
    local ok_u, UIManager = pcall(require, "ui/uimanager")
    if not ok_u or type(UIManager) ~= "table"
        or type(UIManager.scheduleIn) ~= "function" then return end
    local tick
    tick = function()
        local ok, err = pcall(function() G:flush() end)
        if not ok then
            logger.warn("ezvenera: KOReader 设置自动落盘失败", tostring(err))
        end
        pcall(UIManager.scheduleIn, UIManager, 30, tick)
    end
    pcall(UIManager.scheduleIn, UIManager, 30, tick)
    self._settings_autoflush = true
end

--- 【临时排查件（任务 #16）】真机菜单要点好几层才能点到自检，触屏导航不可靠，
--- 改成启动时读标志文件自动跑：`adb shell "echo A60 > /sdcard/koreader/ezv_selftest"`
--- 后重启 KOReader 即可。诊断结束连同整个函数与 selftest.lua 一起删除。
function EzVenera:_selftestOnStartup()
    local ok, err = pcall(function()
        local path = "/sdcard/koreader/ezv_selftest"
        local f = io.open(path, "r")
        if not f then return end
        local mode = (f:read("*a") or ""):gsub("%s", "")
        f:close()
        os.remove(path)
        if mode == "" then return end
        logger.warn("ezveneraST flag", mode, "-> schedule")
        UIManager:scheduleIn(8, function()
            local ST = require("selftest")
            local head = mode:sub(1, 1)
            if head == "A" then
                ST.parseStress(tonumber(mode:sub(2)) or 60)
            elseif head == "C" then
                ST.imageStress(self:getBrowser(), "baozi",
                    "yinghuo-yinghuo", "0_17", tonumber(mode:sub(2)))
            elseif head == "D" then
                ST.pageStress(self:getBrowser(), "baozi",
                    "yinghuo-yinghuo", "0_17", "萤火", "0_17", tonumber(mode:sub(2)))
            elseif head == "E" then
                local okE, eng = self:initEngine()
                if not okE then
                    logger.warn("ezveneraST E 引擎不可用:", tostring(eng))
                else
                    ST.abiProbe(eng, tonumber(mode:sub(2)))
                end
            elseif head == "F" then
                ST.downloadFlow(self:getBrowser(), "baozi",
                    "yinghuo-yinghuo", "0_17", "萤火", "0_17")
            elseif head == "G" then
                ST.glyphProbe()
            elseif head == "H" then
                local b = self:getBrowser()
                local last = (b.library and b.library:listHistory() or {})[1]
                if not (last and last.epId) then
                    logger.warn("ezveneraST H 无历史记录可计时")
                else
                    ST.openTiming(b, last.key, last.comicId, last.epId,
                        tonumber(mode:sub(2)))
                end
            elseif head == "U" then
                ST.customSourceFlow(self:getSources(),
                    "https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json",
                    "https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/baozi.js")
            elseif head == "P" then
                ST.directProbe(self:getBrowser(), "baozi",
                    "tazhimigong-erpingmian", "0")
            elseif head == "O" then
                local b = self:getBrowser()
                -- 目标：`O|源key|漫画id|章节id`；`Ob` = ANR 复现那一章（baozi
                -- 的图床经代理不通）；其余走阅读历史第一条。
                local target
                if mode:sub(2, 2) == "|" then
                    local k, c, e = mode:match("^O|([^|]+)|([^|]+)|(.+)$")
                    target = { key = k, comicId = c, epId = e }
                elseif mode == "Ob" then
                    target = { key = "baozi", comicId = "tazhimigong-erpingmian",
                        epId = "0", title = "纸蜂蜜-二维", epTitle = "ep0" }
                else
                    target = (b.library and b.library:listHistory() or {})[1]
                end
                if not (target and target.epId) then
                    logger.warn("ezveneraST O 无历史记录可开")
                else
                    ST.openChapter(b, target)
                end
            else
                ST.readerPath(self:getBrowser(), "baozi",
                    "yinghuo-yinghuo", "0_17", "萤火", "0_17")
            end
        end)
    end)
    if not ok then logger.warn("ezveneraST startup hook failed:", err) end
end

function EzVenera:infoMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
end

--- 加密后端名称（R3-M3：状态页可见化，纯 Lua 回退不再静默）
function backendName()
    local Convert = require("runtime/convert")
    local okc, c = pcall(Convert.new)
    if okc and c and c.backend then
        return c.backend.name or "openssl"
    end
    return "纯 Lua 回退（AES/摘要不可用）"
end

--- 惰性 sources/browser 访问（crash 2026-09-22 18:56 修复：管理入口
--- 未走 initEngine 时 _sources 为 nil）。任一入口都经此 getter。
function EzVenera:getSources()
    if self._sources ~= nil then return self._sources end
    -- R-D2v5 解耦：源管理是纯 Lua（netclient+convert），不依赖 JS 引擎。
    -- Android 引擎不可用时源管理照常工作。
    local Convert = require("runtime/convert")
    self._sources = require("runtime/sources").new{
        netclient = self.netclient,
        convert = Convert.new(),
        settings = self.settings,
        datadir = self:_sourcesDataDir(),
    }
    return self._sources
end

--- 源数据目录（KOReader datastorage:getDataDir() = <koreader>/；
--- 测试环境无 datastorage 时回退相对路径）
function EzVenera:_sourcesDataDir()
    local okDs, DataStorage = pcall(require, "datastorage")
    if okDs and DataStorage and DataStorage.getDataDir then
        local okDir, dir = pcall(function() return DataStorage:getDataDir() end)
        if okDir and type(dir) == "string" and dir ~= "" then
            return dir .. "/ezvenera"
        end
    end
    return "ezvenera"
end

--- 惰性引擎访问（引擎初始化昂贵，浏览时才建）
function EzVenera:getEngine()
    if self._engine ~= nil then return self._engine end
    local JsHost = require("runtime/jshost")
    self._engine = JsHost.new{}
    return self._engine
end

--- 初始化引擎 + bridge + vendored init.js（getBrowser 时调用）。
--- Android（R-D2v5）引擎 dlopen 被禁 → 返回 false，浏览走纯 Lua 视图。
function EzVenera:initEngine()
    local engine = self:getEngine()
    if engine.initialized then return true, engine end
    if not engine:status().available then
        return false, engine.reason
    end
    local Convert = require("runtime/convert")
    local Cookies = require("runtime/cookies")
    local Bridge = require("runtime/bridge")
    local bridge = Bridge.new{
        settings = self.settings,
        netclient = self.netclient,
        convert = Convert.new(),
        cookies = Cookies.new(),
    }
    local init_js = self:readVendoredInitJS()
    if not init_js then
        return false, "vendored init.js missing"
    end
    local ok, err = engine:init(bridge, nil, init_js)
    if not ok then
        return false, err
    end
    return true, engine
end

--- 惰性 browser 访问（2026-09-22 双崩溃修复：此前 _browser 仅在引擎
--- 可用时创建，Android 引擎被禁（R-D2v5）后菜单点击 nil 索引崩溃）。
--- 引擎不可用时也创建——源列表是纯 Lua 视图；进入具体源内容时由
--- browser 提示引擎不可用。
function EzVenera:getBrowser()
    if self._browser ~= nil then return self._browser end
    local engine = nil
    local ok, eng = self:initEngine()
    if ok then engine = eng end
    local Convert = require("runtime/convert")
    local Cookies = require("runtime/cookies")
    self._browser = require("browser").new{
        engine = engine,
        sources = self:getSources(),
        netclient = self.netclient,
        convert = Convert.new(),
        cookies = Cookies.new(),
        settings = self.settings,
        library = self.library or Library.new(self.settings),
        infoMessage = function(text) self:infoMessage(text) end,
    }
    return self._browser
end

function EzVenera:readVendoredInitJS()
    -- <插件目录>/vendored/init.js（从 main.lua 自身定位，避免依赖 cwd）
    local dirname
    local info = debug.getinfo(1, "S")
    if info and info.source then
        dirname = info.source:match("@?(.-)main%.lua$")
    end
    local path = dirname and (dirname .. "vendored/init.js")
        or "vendored/init.js"
    -- 审查 L6：必须用 "rb"——Windows dev 下 "r" 的 CRLF 转换会使内容
    -- 与 sha256 校验（verify_vendored）的字节流不一致
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- 【R9】菜单 callback 由 KOReader 分发循环直接调用。这里的未捕获 Lua 错误会
--- 冒到主循环，用户看到的不是提示而是整应用闪退（真机实证）。所以入口统一
--- 收住错误；处理器只记消息不取栈（栈信息在这里没有诊断价值，且日志已经够长）。
local function guardCallback(label, fn)
    local ok, err = xpcall(fn, function(msg) return tostring(msg) end)
    if not ok then
        logger.warn("ezvenera: " .. label .. " 内部错误:", err)
        UIManager:show(InfoMessage:new{
            text = "操作失败：" .. label .. "\n" .. tostring(err),
        })
    end
end

--- 历史首条 → 一行「上次读到哪」。菜单和 Dispatcher 标题共用，两处不会说两套话。
local function resumeLabel(library)
    if not library then return nil end
    local ok, hist = pcall(function() return library:listHistory() end)
    if not ok or type(hist) ~= "table" then return nil end
    local h = hist[1]
    if not h then return nil end
    local label = (h.title and h.title ~= "" and h.title) or tostring(h.comicId)
    if h.epTitle or h.epId then
        label = label .. " · " .. tostring(h.epTitle or h.epId)
    end
    return "继续上次阅读：" .. label
end

--- 三个高频动作的唯一实现：菜单项、Dispatcher 事件、SimpleUI 磁贴都收敛到这里，
--- 三处不会各说一套话，也不会漏掉 R9 的错误收口（未捕获错误 = 整应用闪退）。
function EzVenera:openSources()
    guardCallback("浏览漫画源", function()
        -- R-D2v5：Android 无引擎也进列表（纯 Lua 已装源视图）；点具体源时由
        -- browser 提示引擎不可用。
        self:getBrowser():showSourceList()
    end)
end

function EzVenera:resumeLastRead()
    guardCallback("继续上次阅读", function()
        self:getBrowser():resumeLast()
    end)
end

function EzVenera:showDownloads()
    guardCallback("下载与缓存", function()
        self:getBrowser():showCacheManager()
    end)
end

--- SimpleUI 的 Quick Action 磁贴。上游契约见 features/sui_quickactions.lua 头部
--- 「EXTERNAL PLUGIN API」：descriptor = { id, label, icon, is_in_place,
--- is_async_in_place, execute }，同 id 重复 register 会替换旧条目，所以插件热
--- 更新不需要 unregister。没装 SimpleUI 时 require 必失败——init() 抛错会让
--- KOReader 把整个插件判为加载失败（菜单项直接消失），故逐条 pcall。
function EzVenera:_registerSimpleUIQA()
    local ok_qa, QA = pcall(require, "features/sui_quickactions")
    if not (ok_qa and type(QA) == "table" and type(QA.register) == "function") then
        return
    end
    local ok_c, Config = pcall(require, "infra/sui_config")
    local icons = (ok_c and Config and Config.ICON) or {}
    local plugin = self
    local descs = {
        { id = "ezvenera_open", label = _("EZVenera 漫画"),
          icon = icons.plugin, run = function() plugin:openSources() end },
        { id = "ezvenera_resume", label = _("EZVenera: 继续上次阅读"),
          icon = icons.continue_, run = function() plugin:resumeLastRead() end },
        { id = "ezvenera_downloads", label = _("EZVenera: 下载与缓存"),
          icon = icons.history, run = function() plugin:showDownloads() end },
    }
    for _, d in ipairs(descs) do
        -- 磁贴点开的是我们自己的全屏 Menu 浮层：execute() 返回后它还活着，
        -- 所以要声明 async（否则 SimpleUI 的底栏会替我们收放主页栈）。
        d.is_in_place = true
        d.is_async_in_place = true
        d.execute = d.run
        d.run = nil
        local ok, err = pcall(QA.register, d)
        if not ok then
            logger.warn("ezvenera: SimpleUI QA.register 失败", d.id, tostring(err))
        end
    end
end

function EzVenera:addToMainMenu(menu_items)
    local plugin = self
    -- 照抄 weread 范式（weread/ui/menu.lua:39-46）：
    -- sorting_hint="tools" + sub_item_table_func 延迟构建
    menu_items.ezvenera = {
        text = _("EZVenera 漫画"),
        sorting_hint = "tools",
        -- 【外部启动器对接面】KOReader 自己的菜单永远不会调它——touchmenu.lua:887
        -- 见有 sub_item_table(_func) 就先开子菜单，callback 分支在其后。它是给
        -- SimpleUI 的「自定义 QA → 插件」用的：那条分支反射调用
        -- addToMainMenu(probe) 后找 entry.callback（sui_quickactions.lua:3142-3152），
        -- 没有顶层 callback 的插件在它列表里就是打不开。语义 = 首项「浏览漫画源」。
        callback = function()
            plugin:openSources()
        end,
        sub_item_table_func = function()
            local okitems, items = pcall(function()
                return {
            {
                text = "浏览漫画源",
                callback = function()
                    plugin:openSources()
                end,
                keep_menu_open = false,
            },
            {
                text = "收藏夹",
                callback = function()
                    guardCallback("收藏夹", function()
                        plugin:getBrowser():showFavorites()
                    end)
                end,
                keep_menu_open = false,
            },
            {
                text = "阅读历史",
                callback = function()
                    guardCallback("阅读历史", function()
                        plugin:getBrowser():showHistory()
                    end)
                end,
                keep_menu_open = false,
            },
            {
                text = "下载与缓存",
                callback = function()
                    plugin:showDownloads()
                end,
                keep_menu_open = false,
            },
            {
                text = "管理漫画源",
                sub_item_table = {
                    {
                        text = "浏览索引并安装",
                        callback = function()
                            guardCallback("浏览索引并安装", function()
                                plugin:showIndexBrowser()
                            end)
                        end,
                    },
                    {
                        text = "从 URL 添加源（.js 直装）",
                        callback = function()
                            guardCallback("从 URL 添加源", function()
                                plugin:addSourceFromURL()
                            end)
                        end,
                    },
                    {
                        text = "添加自定义源索引（index.json）",
                        callback = function()
                            guardCallback("添加自定义源索引", function()
                                plugin:addSourceIndexFromURL()
                            end)
                        end,
                    },
                    {
                        text = "已添加的自定义索引",
                        callback = function()
                            guardCallback("自定义索引管理", function()
                                plugin:showCustomIndexes()
                            end)
                        end,
                    },
                    {
                        text = "从本地文件添加源",
                        callback = function()
                            guardCallback("从本地文件添加源", function()
                                plugin:addSourceFromLocal()
                            end)
                        end,
                    },
                    {
                        text = "已安装源（查看/删除）",
                        callback = function()
                            guardCallback("已安装源", function()
                                plugin:showInstalledBrowser()
                            end)
                        end,
                    },
                },
                keep_menu_open = true,
            },
            {
                text = "网络代理",
                sub_item_table = ProxyConf.buildMenu(self.settings, {
                    infoMessage = function(text)
                        plugin:infoMessage(text)
                    end,
                    scheduleIn = function(sec, fn)
                        UIManager:scheduleIn(sec, function()
                            guardCallback("代理设置", fn)
                        end)
                    end,
                    netclient = self.netclient,
                }),
                keep_menu_open = true,
            },
            {
                text = "引擎与状态",
                callback = function()
                    guardCallback("引擎与状态", function()
                        local st = plugin:getEngine():status()
                        local lines = {
                            "JS 引擎: " .. (st.available and "已安装"
                                or ("未安装")),
                            "库: " .. tostring(st.libname or "-"),
                            "原因: " .. tostring(st.reason or "-"),
                            "已初始化: " .. tostring(st.initialized) .. (st.available and not st.initialized and "（打开浏览/管理时自动初始化）" or ""),
                            "加密后端: " .. tostring(backendName()),
                            "代理: " .. (plugin.settings:isProxyEnabled()
                                and plugin.settings:getProxyURL() or "未启用"),
                            "版本: M1（骨架 + 代理）",
                        }
                        plugin:infoMessage(table.concat(lines, "\n"))
                    end)
                end,
                keep_menu_open = true,
            },
            -- 【临时排查件（任务 #16）】A/B 压力自测：判"章节阅读期同一 PC 崩
            -- 在 libluajit"是否需要 quickjs/FFI 回调参与。诊断完整块删除。
            {
                text = "自检(排查用)",
                sub_item_table = {
                    {
                        text = "A 纯 Lua 解析压力",
                        callback = function()
                            guardCallback("自检A", function()
                                local ST = require("selftest")
                                plugin:infoMessage(tostring(ST.parseStress(60)))
                            end)
                        end,
                        keep_menu_open = true,
                    },
                    {
                        text = "B 完整阅读路径",
                        callback = function()
                            guardCallback("自检B", function()
                                local ST = require("selftest")
                                ST.readerPath(plugin:getBrowser(), "baozi",
                                    "yinghuo-yinghuo", "0_17", "萤火", "0_17")
                            end)
                        end,
                        keep_menu_open = false,
                    },
                },
                keep_menu_open = true,
            },
                }
            end)
            if not okitems then
                return {
                    { text = "EZVenera internal error (diagnostic)",
                      keep_menu_open = true },
                    { text = tostring(items), info_only = true },
                }
            end
            -- 「继续上次阅读」置顶：真机反馈回看一本书要走 源→分类→结果→详情
            -- →章节 五层，同一条历史也绑到手势（onEzVeneraResume）。
            local last = resumeLabel(plugin.library)
            if last then
                table.insert(items, 1, {
                    text = "▶ " .. last,
                    callback = function()
                        plugin:resumeLastRead()
                    end,
                    keep_menu_open = false,
                })
            end
            return items
        end,
    }
end


--- 文本输入框（KOReader 虚拟键盘）。与代理地址同一套做法：普通菜单项 +
--- InputDialog，绝不用 hold_input（ADR-005）。KOReader 之外退化为提示。
function EzVenera:askText(title, hint, initial, on_ok)
    local okDlg, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not okDlg then
        self:infoMessage(title .. "\n（输入框仅在 KOReader 内可用）")
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        input_hint = hint or "",
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local v = dialog:getInputText()
                        if type(v) == "string" then
                            v = v:gsub("^%s+", ""):gsub("%s+$", "")
                        end
                        UIManager:close(dialog)
                        if type(v) == "string" and v ~= "" then on_ok(v) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 联网的添加动作统一走这里：先在菜单回调里返回（让「正在处理」这帧画出来），
--- 真正的下载放到 scheduleIn 的节拍里。安卓的输入派发只有 5s 预算，点击回调里
--- 直接联网就是「KOReader 无响应」（任务 #22 的同一教训）。
function EzVenera:runNetworkTask(label, fn)
    self:infoMessage("正在联网处理，请稍候…")
    UIManager:scheduleIn(0.2, function()
        guardCallback(label, fn)
    end)
end

--- 三条添加路径共用的收尾：让 browser 丢掉旧缓存，并把结果说清楚。
function EzVenera:reportSourceInstalled(ok, entry)
    if not ok then
        self:infoMessage("添加失败：" .. tostring(entry))
        return
    end
    if self._browser then
        pcall(function() self._browser:invalidateSource(entry.key) end)
    end
    self:infoMessage("已添加源：" .. tostring(entry.name or entry.key)
        .. "\n标识: " .. tostring(entry.key)
        .. "\n大小: " .. tostring(entry.size or "?") .. " 字节"
        .. "\n\n现在可以从「浏览漫画源」打开它。")
end

--- 从任意 URL 直装一个源 js（EZVenera/Venera 社区分享的单文件源）。
function EzVenera:addSourceFromURL()
    local plugin = self
    plugin:askText("源文件地址（.js）", "https://主机/目录/mysrc.js", "",
        function(url)
            if not url:match("^https?://") then
                plugin:infoMessage("地址需要以 http:// 或 https:// 开头")
                return
            end
            plugin:runNetworkTask("从 URL 添加源", function()
                plugin:reportSourceInstalled(
                    plugin:getSources():installFromURL(url))
            end)
        end)
end

--- 从本地文件装（把源 js 拷到 /sdcard/koreader/ 下再填路径，零网络）。
function EzVenera:addSourceFromLocal()
    local plugin = self
    plugin:askText("本地源文件路径", "/sdcard/koreader/ezvenera/mysrc.js",
        "/sdcard/koreader/", function(path)
            plugin:reportSourceInstalled(
                plugin:getSources():installLocalFile(path))
        end)
end

--- 添加一份自定义源索引（index.json）：之后「浏览索引并安装」里就能看到这些源。
function EzVenera:addSourceIndexFromURL()
    local plugin = self
    plugin:askText("自定义源索引地址（index.json）",
        "https://主机/目录/index.json", "", function(url)
            plugin:runNetworkTask("添加自定义源索引", function()
                local ok, res = plugin:getSources():addCustomIndex(url)
                if not ok then
                    plugin:infoMessage("添加失败：" .. tostring(res))
                    return
                end
                plugin:infoMessage("已加入自定义索引："
                    .. tostring(res.count) .. " 条源"
                    .. "\n基址: " .. tostring(res.base or "?")
                    .. "\n\n到「浏览索引并安装」里就能看到这些源。")
            end)
        end)
end

--- 已添加的自定义索引：点开可删除（装错地址时有出口，不用连电脑改文件）。
function EzVenera:showCustomIndexes()
    local list = self:getSources():listCustomIndexes()
    if #list == 0 then
        self:infoMessage("尚未添加自定义源索引\n\n用「添加自定义源索引」填一份"
            .. " index.json 地址即可。")
        return
    end
    local Menu = require("ui/widget/menu")
    local ConfirmBox = require("ui/widget/confirmbox")
    local plugin = self
    local item_table = {}
    for _, e in ipairs(list) do
        table.insert(item_table, {
            text = (e.base or e.file),
            mandatory = tostring(e.count) .. " 条",
            file = e.file,
        })
    end
    UIManager:show(Menu:new{
        title = "自定义源索引（" .. tostring(#list) .. "）",
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(menu_self, item)
            UIManager:show(ConfirmBox:new{
                text = "删除该自定义索引？\n" .. tostring(item.file)
                    .. "\n\n（已安装的源不受影响。）",
                ok_text = "删除",
                ok_callback = function()
                    local ok, err = plugin:getSources():removeCustomIndex(item.file)
                    plugin:infoMessage(ok and "已删除"
                        or ("删除失败：" .. tostring(err)))
                end,
            })
        end,
    })
end

--- 索引浏览 + 安装（M2 T16 交互）
function EzVenera:showIndexBrowser()
    local sources = self:getSources()
    local plugin = self
    self:runNetworkTask("拉取源索引", function()
    local list, err = sources:fetchIndex()
    if not list then
        plugin:infoMessage("索引拉取失败：\n" .. tostring(err)
            .. "\n\n提示：GitHub 直连可能超时，稍后重试或配置代理；"
            .. "也可以「添加自定义源索引」用别的地址。")
        return
    end
    local merged = sources:mergeLocal(list)
    if #merged == 0 then
        self:infoMessage("索引为空")
        return
    end
    local Menu = require("ui/widget/menu")
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local inst = sources:installed()
    local item_table = {}
    for _, e in ipairs(merged) do
        local mark = inst[e.key] and "◆ " or ""
        table.insert(item_table, {
            text = mark .. (e.name or e.key),
            mandatory = e.version and ("v" .. tostring(e.version)) or nil,
            entry = e,
        })
    end
    local menu = Menu:new{
        title = "源索引（" .. tostring(#merged) .. " 条）",
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(menu_self, item)
            local e = item.entry
            UIManager:show(ConfirmBox:new{
                text = "安装/更新源？\n" .. (e.name or e.key)
                    .. (e.version and ("  v" .. tostring(e.version)) or "")
                    .. (e._base and ("\n基址: " .. tostring(e._base)) or "")
                    .. (inst[e.key] and "\n（已安装，将覆盖更新）" or ""),
                ok_text = "安装",
                ok_callback = function()
                    -- 下载在 scheduleIn 节拍里跑：ConfirmBox 的 ok_callback 仍在
                    -- 输入派发路径上，直接联网就是安卓「无响应」（任务 #22）。
                    self:runNetworkTask("安装源", function()
                        self:reportSourceInstalled(sources:install(e))
                    end)
                end,
            })
        end,
    }
    UIManager:show(menu)
    end)
end

--- 已安装源列表 → 单源操作菜单（参数配置/登录/删除，见 browser.lua）
function EzVenera:showInstalledBrowser()
    local sources = self:getSources()
    local inst = sources:listInstalled()
    if #inst == 0 then
        self:infoMessage("尚未安装任何源\n用「浏览索引并安装」添加")
        return
    end
    local Menu = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local item_table = {}
    for _, e in ipairs(inst) do
        table.insert(item_table, {
            text = (e.name or e.key) .. "  v" .. tostring(e.version),
            mandatory = e.key,
            key = e.key,
            name = e.name or e.key,
            version = e.version,
        })
    end
    local menu = Menu:new{
        title = "已安装源（" .. tostring(#inst) .. "）",
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = function(menu_self, item)
            UIManager:close(menu_self)
            guardCallback("源管理", function()
                self:getBrowser():showSourceMenu(item.key, item.name,
                    item.version)
            end)
        end,
    }
    UIManager:show(menu)
end

--- 手势/快捷键与 SimpleUI 的「系统动作」分支（Dispatcher:execute）走这里。
--- 三条都转成受 guard 的方法： dispatcher 的调用栈同样在主循环上，未捕获错误
--- 一样是闪退（R9）。
function EzVenera:onEzVeneraOpen()
    self:openSources()
    return true
end

function EzVenera:onEzVeneraResume()
    self:resumeLastRead()
    return true
end

function EzVenera:onEzVeneraDownloads()
    self:showDownloads()
    return true
end

return EzVenera
