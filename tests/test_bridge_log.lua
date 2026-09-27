-- unit test: runtime/jshost.lua 桥流水账的日志级别
-- 背景（真机 2026-09-26）：读一话 127 张图 → 几百条
-- `ezvenera bridge <- load_setting k=imageHost` 以 warn 落 logcat，把真正的
-- 故障行淹掉了。契约：
--   ①逐条进出（任意 method）只落 dbg —— logger 默认级别 info，dbg 是 noop，
--     正常跑一行都不出；开「开发者选项 → 启用调试日志」原样回来。
--   ②唯一例外：http 的桥错误必须留在 warn（联网失败是真故障）。
-- jshost 在【模块加载期】捕获 logger，所以桩必须先于 require：走 stubs 的共享
-- 入口（它会强制重载 jshost）。手搓 stub 会在多个文件之间抢同一次 require，
-- 后写的那个拿到的是别人捕获的 logger，断言就变成假通过。

local stubs = require("tests.stubs")
local JsHost, fake = stubs.reload_jshost_with_logger()

local Bridge = require("runtime/bridge")
local NetClient = require("netclient")
local Convert = require("runtime/convert")
local Cookies = require("runtime.cookies")

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function reset()
    fake.reset()
end

local function makeBridge()
    return Bridge.new({
        settings = stubs.settings_memory(),
        netclient = NetClient.new({
            transport = function()
                return { status = 200, headers = {}, body = "", error = nil }
            end,
        }),
        convert = Convert.new(stubs.fake_convert_impl()),
        cookies = Cookies.new({
            json = { encode = function() return "x" end,
                     decode = function() return nil end },
            store = { load = function() return nil end, save = function() end },
        }),
        storage = { load = function() return {} end, save = function() return true end },
    })
end

-- _bridgeHandler 只用 self.json 与 self.bridge，无需真引擎：直接拼裸实例。
-- json 桩把入参消息按引用传入（pending），绕开编解码。
local pending
local fakejson = {
    decode = function() return pending end,
    encode = function() return "enc" end,
}
local function post(msg)
    pending = msg
    local host = setmetatable({ json = fakejson, bridge = makeBridge() }, JsHost)
    return host:_bridgeHandler("{}")
end

local tests = {}

function tests.normal_traffic_never_reaches_warn()
    reset()
    -- 复刻真机场景：一话图片的 imageHost 查询被反复读上百次
    for _ = 1, 127 do
        post({ method = "load_setting", key = "src1", setting_key = "imageHost" })
    end
    assert_eq("warn 零条", 0, #fake.warns)
    assert_true("进出两条 dbg", #fake.dbgs >= 254)
    assert_true("<- 带 method 与 setting_key",
        fake.dbgs[1]:find("bridge <- load_setting", 1, true) ~= nil
        and fake.dbgs[1]:find("k=imageHost", 1, true) ~= nil)
    assert_true("-> 记录未设置值",
        fake.dbgs[2]:find("bridge -> load_setting <unset>", 1, true) ~= nil)
    return true
end

function tests.other_methods_log_nothing_at_warn()
    reset()
    assert_true("uuid 调用成功", post({ method = "uuid" }) ~= nil)
    assert_eq("warn 零条", 0, #fake.warns)
    assert_true("仍有 dbg 流水", #fake.dbgs == 1
        and fake.dbgs[1]:find("bridge <- uuid", 1, true) ~= nil)
    return true
end

function tests.http_bridge_error_stays_warn()
    reset()
    -- 缺 url → bridge 返回 { __error = "http: missing url" }（单键 = 桥错误）
    post({ method = "http", key = "src1" })
    assert_eq("warn 恰好一条", 1, #fake.warns)
    assert_true("是 http 出口行",
        fake.warns[1]:find("bridge -> http", 1, true) ~= nil
        and fake.warns[1]:find("missing url", 1, true) ~= nil)
    return true
end

function tests.http_success_is_dbg_only()
    reset()
    post({ method = "http", key = "src1", http_method = "GET",
           url = "https://example.com/a?token=secret" })
    assert_eq("成功请求不产 warn", 0, #fake.warns)
    local joined = table.concat(fake.dbgs, "\n")
    assert_true("入站锚带 url 与状态码",
        joined:find("url=https://example.com/a", 1, true) ~= nil
        and joined:find("status=200", 1, true) ~= nil)
    -- L7：查询串（token/session）绝不落日志，两个方向都要剥
    assert_true("查询串被剥掉", joined:find("secret", 1, true) == nil)
    return true
end

function tests.http_pending_is_logged_as_pending_not_status()
    -- r10 M2：异步受理行此时**还没有**状态码。留 `status=nil` 会让排查的人
    -- 以为站点回了空状态；出口必须写 pending=<id>，且照旧只是 dbg。
    -- 注意 netclient 要换成带 requestAsync 的假对象：真 NetClient 在单测里
    -- 没有 socket.select，异步支路会静默退回同步（那就测不到 pending）。
    reset()
    local host = setmetatable({ json = fakejson, bridge = makeBridge() }, JsHost)
    host.bridge.netclient = {
        requestAsync = function() return {} end,
        request = function() return { status = 200, headers = {}, body = "" } end,
    }
    host.bridge.async_http = true
    pending = { method = "http", url = "https://example.com/p" }
    local out = host:_bridgeHandler("{}")
    assert_eq("编码结果原样交回桥的挂起标记", "enc", out)
    assert_eq("受理阶段不产 warn", 0, #fake.warns)
    local joined = table.concat(fake.dbgs, "\n")
    assert_true("出口写 pending=1",
        joined:find("bridge -> http pending=1", 1, true) ~= nil)
    assert_true("不再谎报 status", joined:find("status=nil", 1, true) == nil)
    return true
end

return tests
