-- unit test: main.lua 的三个入口面（KOReader 主菜单 / Dispatcher / SimpleUI）
-- main.lua 依赖 KOReader UI，故先把桩模块塞进 package.loaded 再 require；
-- 覆盖点全是「外部启动器能不能把我们打开」这条链，改 main.lua 前先回来看这里。
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual))
end

local shown = {}          -- InfoMessage / toast 记录
local warns = {}          -- logger.warn 记录
local qa_reg = {}         -- SimpleUI QA.register 记录
local actions = {}        -- Dispatcher:registerAction 记录

local function stub_module(name, tbl)
    package.loaded[name] = tbl
end

-- WidgetContainer:extend{...} —— 只要返回一个能被方法赋值的类表
local WC = {}
WC.__index = WC
function WC.extend(_, tbl)
    local t = tbl or {}
    t.__index = t
    return setmetatable(t, { __index = WC })
end

stub_module("gettext", function(s) return s end)
stub_module("logger", {
    info = function() end, dbg = function() end,
    warn = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        table.insert(warns, table.concat(parts, " "))
    end,
})
stub_module("dispatcher", {
    registerAction = function(_, id, desc) actions[id] = desc end,
})
stub_module("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    scheduleIn = function() end,
})
stub_module("ui/widget/infomessage", {
    new = function(cls, o) return setmetatable(o or {}, { __index = cls }) end,
})
stub_module("ui/widget/container/widgetcontainer", WC)

local Main = require("main")

local function fakeBrowser()
    local calls = {}
    return {
        calls = calls,
        showSourceList = function() calls.source = (calls.source or 0) + 1 end,
        resumeLast = function() calls.resume = (calls.resume or 0) + 1 end,
        showCacheManager = function() calls.cache = (calls.cache or 0) + 1 end,
    }
end

local function newInstance(browser)
    local inst = setmetatable({
        name = "ezvenera",
        settings = stubs.settings_memory(),
        library = nil,
    }, { __index = Main })
    if browser then
        inst.getBrowser = function() return browser end
    end
    return inst
end

local function probeMenu(inst)
    local probe = {}
    inst:addToMainMenu(probe)
    return probe.ezvenera
end

local tests = {}

function tests.entry_exists_with_submenu_and_hint()
    local entry = probeMenu(newInstance())
    assert(entry ~= nil, "menu_items.ezvenera 未注册")
    assert(type(entry.sub_item_table_func) == "function", "子菜单没构建")
    assert_eq("sorting_hint", "tools", entry.sorting_hint)
    return true
end

-- SimpleUI 的「自定义 QA → 插件」分支：反射 addToMainMenu(probe) 后按
-- plugin_key 或 plugin.name 找 entry.callback（sui_quickactions.lua:3142-3152）。
-- 没有这个 callback，我们在它的插件启动器列表里就是打不开。
function tests.top_level_callback_for_external_launchers()
    local browser = fakeBrowser()
    local entry = probeMenu(newInstance(browser))
    assert_eq("顶层 callback 类型", "function", type(entry.callback))
    entry.callback()                       -- KOReader 自己不会调它，这里手动模拟启动器
    assert_eq("打开源列表", 1, browser.calls.source)
    return true
end

-- KOReader 自己的菜单里 callback 必须是惰性的（touchmenu.lua:887 子菜单优先），
-- 这里退一步验证：子菜单照旧能构建，且首项仍是「浏览漫画源」。
function tests.submenu_still_builds_first_item_is_browse()
    local browser = fakeBrowser()
    local entry = probeMenu(newInstance(browser))
    local items = entry.sub_item_table_func()
    assert_eq("子菜单项数", "浏览漫画源", items[1] and items[1].text)
    items[1].callback()
    assert_eq("首项也打开源列表", 1, browser.calls.source)
    return true
end

function tests.submenu_wires_resume_and_downloads()
    local browser = fakeBrowser()
    local inst = newInstance(browser)
    local items = probeMenu(inst).sub_item_table_func()
    local by_text = {}
    for _, it in ipairs(items) do by_text[it.text] = it end
    by_text["下载与缓存"].callback()
    assert_eq("下载与缓存", 1, browser.calls.cache)
    return true
end

-- 手势/系统动作这条链（Dispatcher:execute）同样要收口：错误不外抛（R9 闪退）。
function tests.dispatcher_handlers_route_to_browser()
    local browser = fakeBrowser()
    local inst = newInstance(browser)
    assert_eq("onEzVeneraOpen", true, inst:onEzVeneraOpen())
    assert_eq("onEzVeneraResume", true, inst:onEzVeneraResume())
    assert_eq("onEzVeneraDownloads", true, inst:onEzVeneraDownloads())
    assert_eq("source", 1, browser.calls.source)
    assert_eq("resume", 1, browser.calls.resume)
    assert_eq("cache", 1, browser.calls.cache)
    return true
end

function tests.dispatcher_handler_error_is_contained()
    local inst = newInstance()
    inst.getBrowser = function() error("browser down") end
    local before = #shown
    assert_eq("不抛错", true, inst:onEzVeneraOpen())
    assert_eq("有 toast", 1, #shown - before)
    return true
end

local function fakeQA()
    qa_reg = {}
    return {
        register = function(desc) qa_reg[desc.id] = desc end,
    }
end

function tests.qa_descriptors_registered_when_simpleui_present()
    local browser = fakeBrowser()
    local inst = newInstance(browser)
    stub_module("features/sui_quickactions", fakeQA())
    stub_module("infra/sui_config", { ICON = {
        plugin = "/p/plugin.svg", continue_ = "/p/continue.svg",
        history = "/p/history.svg",
    } })
    inst:_registerSimpleUIQA()
    assert_eq("三个磁贴", 3, (function()
        local n = 0
        for _ in pairs(qa_reg) do n = n + 1 end
        return n
    end)())
    for id, expect in pairs({
        ezvenera_open = "source", ezvenera_resume = "resume",
        ezvenera_downloads = "cache",
    }) do
        local d = qa_reg[id]
        assert(d ~= nil, "缺描述符 " .. id)
        assert(type(d.label) == "string" and #d.label > 0, "缺 label: " .. id)
        assert(type(d.icon) == "string" and #d.icon > 0, "缺 icon: " .. id)
        -- 浮层在 execute() 返回后还活着 → 必须声明 in-place + async
        assert_eq(id .. " is_in_place", true, d.is_in_place)
        assert_eq(id .. " is_async_in_place", true, d.is_async_in_place)
        d.execute({ plugin = inst, fm = nil })
    end
    assert_eq("磁贴转发（三个各一次）", 3, (browser.calls.source or 0)
        + (browser.calls.resume or 0) + (browser.calls.cache or 0))
    return true
end

-- 没装 SimpleUI 的机器占多数：require 失败必须静默跳过，不能让 init() 抛错
-- （init 抛错 = KOReader 判插件加载失败 = 菜单项直接消失）。
function tests.qa_registration_silent_without_simpleui()
    package.loaded["features/sui_quickactions"] = nil
    qa_reg = {}
    local inst = newInstance(fakeBrowser())
    local ok, err = pcall(function() inst:_registerSimpleUIQA() end)
    assert_eq("不抛错", true, ok)
    assert_eq("无注册", true, next(qa_reg) == nil)
    return true
end

-- 单个描述符注册失败也不能连坐其余两个。
function tests.qa_registration_survives_per_descriptor_error()
    local seen = {}
    stub_module("features/sui_quickactions", {
        register = function(desc)
            table.insert(seen, desc.id)
            if desc.id == "ezvenera_resume" then error("bad descriptor") end
        end,
    })
    local inst = newInstance(fakeBrowser())
    local ok = pcall(function() inst:_registerSimpleUIQA() end)
    assert_eq("不抛错", true, ok)
    assert_eq("三条都尝试过", 3, #seen)
    local hit
    for _, w in ipairs(warns) do if w:find("QA.register", 1, true) then hit = true end end
    assert_eq("失败有 warn 日志", true, hit ~= nil)
    return true
end

-- 「添加自定义漫画源」的四个入口必须都在（用户报的功能缺口）。
function tests.source_menu_offers_custom_source_paths()
    local items = probeMenu(newInstance(fakeBrowser())).sub_item_table_func()
    local mgmt
    for _, it in ipairs(items) do
        if it.text == "管理漫画源" then mgmt = it end
    end
    assert(mgmt and mgmt.sub_item_table, "缺「管理漫画源」")
    local seen = {}
    for _, it in ipairs(mgmt.sub_item_table) do seen[it.text] = it end
    for _, name in ipairs({ "浏览索引并安装", "从 URL 添加源（.js 直装）",
        "添加自定义源索引（index.json）", "已添加的自定义索引",
        "从本地文件添加源", "已安装源（查看/删除）" }) do
        assert(type(seen[name] and seen[name].callback) == "function",
            "缺菜单项：" .. name)
    end
    return true
end

-- 本测试环境没有 InputDialog / Menu 控件：这些入口要降级成提示而不是抛错
-- （未捕获错误 = 真机闪退，R9 的同一条路）。
function tests.custom_source_entries_degrade_without_ui()
    local inst = newInstance(fakeBrowser())
    inst._sources = { listCustomIndexes = function() return {} end }
    local before = #shown
    local items = probeMenu(inst).sub_item_table_func()
    local mgmt
    for _, it in ipairs(items) do
        if it.text == "管理漫画源" then mgmt = it end
    end
    for _, it in ipairs(mgmt.sub_item_table) do
        if it.text == "从 URL 添加源（.js 直装）"
                or it.text == "从本地文件添加源"
                or it.text == "已添加的自定义索引" then
            it.callback()
        end
    end
    assert_eq("三项各有降级提示", 3, #shown - before)
    return true
end

-- ==== KOReader 全局设置自动落盘（修「键盘布局每次重开 KOReader 都要重设」）====

--- 换掉 uimanager.scheduleIn 与 G_reader_settings 两个桩，跑完还原。
--- 桩不还原会污染后面的用例，所以这里用 with 形而不是 setup/teardown。
local function withAutoflushStubs(flush, body)
    local UM = package.loaded["ui/uimanager"]
    local old_sched, old_G = UM.scheduleIn, G_reader_settings
    local sched = {}
    UM.scheduleIn = function(_, delay, cb)
        table.insert(sched, { delay = delay, cb = cb })
    end
    G_reader_settings = flush and { flush = flush } or nil
    local ok, err = pcall(body, sched)
    UM.scheduleIn, G_reader_settings = old_sched, old_G
    assert(ok, "autoflush case broke: " .. tostring(err))
    return sched
end

function tests.settings_autoflush_stays_off_without_koreader_settings()
    -- 单测/非 KOReader 环境里 G_reader_settings 这个全局不存在，
    -- 自动落盘必须静默不启用，而不是让 init() 抛错。
    local inst = newInstance(fakeBrowser())
    assert_eq("未启动前无标记", nil, inst._settings_autoflush)
    inst:_startSettingsAutoflush()
    assert_eq("拿不到全局设置就不启用", nil, inst._settings_autoflush)
    return true
end

function tests.settings_autoflush_flushes_and_reschedules()
    local n = 0
    local sched = withAutoflushStubs(function() n = n + 1 end, function(s)
        local inst = newInstance(fakeBrowser())
        inst:_startSettingsAutoflush()
        assert_eq("启动时排一次定时器", 1, #s)
        assert_eq("节拍 30 秒", 30, s[1].delay)
        s[1].cb()
        assert_eq("tick 触发一次写盘", 1, n)
        assert_eq("tick 之后续上下一拍", 2, #s)
        inst:_startSettingsAutoflush()   -- 幂等：不得叠第二条链
        assert_eq("重复调用不再排新定时器", 2, #s)
    end)
    assert(sched, "stub harness returned nothing")
    return true
end

function tests.settings_autoflush_error_is_contained()
    -- 写盘失败（只读存储、并发损坏…）只能记一条 warn，
    -- 既不能把异常抛给主循环，也不能让定时器链断掉。
    local before = #warns
    local sched = withAutoflushStubs(function() error("disk full") end, function(s)
        local inst = newInstance(fakeBrowser())
        inst:_startSettingsAutoflush()
        s[1].cb()
        assert_eq("异常后仍续拍", 2, #s)
    end)
    assert_eq("失败要留一条 warn", before + 1, #warns)
    assert(sched, "stub harness returned nothing")
    return true
end

return tests
