-- unit test: r10 M2 的**全栈**端到端——真 NetClient(含 AsyncNet) + 真 Bridge + 真 JsHost:pump
-- 为什么单独一个文件：M1 测的是传输层「一拍只推进一件事」，M2 测的是泵「按顺序兑现」，
-- 两边各用各的桩，于是**中间那道缝**（bridge 的 on_done 签名、opts 形状、body 字节如何
-- 穿过 json.encode + jsLiteral）谁都没覆盖。这里三件真代码串起来跑一整轮。
-- 本地 LuaJIT 没有 luasocket/luasec（M0 真机实测才有 3.1.0/1.3.2），所以 socket 层
-- 只能由 tests/tlsfake.lua 提供——那份桩照真机形状钉死：方法挂 metatable、select 只吃
-- 带 getfd 的对象、非阻塞恒 timeout 0、"要等" 与 "说就绪" 必须隔一拍。
-- JS 那一半（Promise 兑现语义）不在这里验，由 node 直接跑 QUICKJS_GLUE 点验。

local stubs = require("tests.stubs")
local TlsFake = require("tests.tlsfake")
local JsHost, sink = stubs.reload_jshost_with_logger()
local Bridge = require("runtime.bridge")
local NetClient = require("netclient")
local Convert = require("runtime.convert")

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- 响应体与「JSON 编码 / JS 字面量还原」两个助手都在 tests/tlsfake.lua：端到端
-- 现在有两个文件（桥+泵、桥+泵+浏览器步进器），各写一份必然漂移。
local BODY = TlsFake.BODY
local enc = TlsFake.jsonEnc
local jsUnescape = TlsFake.jsUnescape

--- 一整轮的真栈。**用例主体必须整个跑在假模块窗口里**：netclient 是到请求
--- 那一刻才 require("socket"/"ltn12") 的（不是建实例时），窗口一关就变成
--- "ltn12 unavailable"，测出来的全是回落分支。
local function withCase(tls_opts, fn)
    local fake = TlsFake.makeFakeHttp{}
    local one = { code = 200, headers = { ["content-length"] = tostring(#BODY) },
                  body = BODY }
    local log, env = TlsFake.withTlsStack(fake, {
        blocked = { connect = 1, handshake = 1, receive = 1 },
        -- 两笔：连跑两轮用例时第二笔也得有自己的响应体（否则测的是空 body）
        responses = { one, one },
        connect_fails = tls_opts and tls_opts.connect_fails,
    })
    local cur = nil
    local json = { encode = enc, decode = function() return cur end }
    local box = { codes = {}, log = log, env = env }
    TlsFake.withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        box.nc = nc
        box.br = Bridge.new{
            settings = stubs.settings_memory(), netclient = nc,
            convert = Convert.new(stubs.fake_convert_impl()),
            cookies = stubs.fake_cookies(),
            storage = { load = function() return {} end,
                        save = function() return true end },
            async_http = true,
        }
        box.host = setmetatable({
            initialized = true, ctx = {}, bridge = box.br, json = json,
        }, JsHost)
        function box.host._evalRaw(_, code)
            box.codes[#box.codes + 1] = code
            return true, "1"
        end
        box.post = function(msg)
            cur = msg
            return box.host:_bridgeHandler("ignored")
        end
        box.pump = function()
            env.t = env.t + 0.05
            return box.host:pump()
        end
        fn(box)
    end)
    return box
end

local HTTP_MSG = { method = "http", key = "src1", http_method = "GET",
                   url = "https://api.example.com/list" }

--- 取出那条 __ezv_resolve 里的 JS 字面量（并还原成 JSON 文本）
local function resolveOf(box)
    for _, code in ipairs(box.codes) do
        local id, lit = code:match('^__ezv_resolve%((%d+), "(.*)", null%)$')
        if id then return tonumber(id), jsUnescape(lit), code end
    end
    return nil
end

local tests = {}

function tests.handler_returns_a_promise_marker_without_touching_the_socket()
    withCase(nil, function(box)
        sink.reset()
        local ret = box.post(HTTP_MSG)
        -- _bridgeHandler 出口是**编码后的字符串**（真机上由 C 层原样交给 JS），
        -- 所以这里看到的是 {"__pending":N}
        assert_true("返回的是 pending 标记: " .. tostring(ret),
            type(ret) == "string" and ret:find('"__pending"', 1, true) ~= nil)
        assert_true("没有 status 字段（还没发生的事不能谎报）",
            ret:find("status", 1, true) == nil)
        assert_eq("一次系统轮询都还没跑", 0, box.env.polls)
        assert_eq("在飞 = 1", 1, box.br:httpInflight())
        assert_eq("已完成的响应 = 0", 0, #(box.br:takeHttpReady() or {}))
        assert_eq("桥日志零 warn", 0, #sink.warns)
    end)
    return true
end

function tests.response_reaches_js_byte_exact_after_pump_ticks()
    local seen = {}
    withCase(nil, function(box)
        box.post(HTTP_MSG)
        local ticks = 0
        while box.br:httpInflight() > 0 and ticks < 10 do
            box.pump()
            ticks = ticks + 1
        end
        seen.ticks = ticks
        seen.id, seen.payload, seen.code = resolveOf(box)
        seen.inflight = box.br:httpInflight()
        seen.warns = #sink.warns
    end)
    assert_true("响应不是一拍就变出来（每次都真的等过一拍）: ticks="
        .. tostring(seen.ticks), (seen.ticks or 0) >= 3)
    assert_true("泵兑现了那条 Promise", seen.id ~= nil)
    assert_eq("id 与桥登记的一致", 1, seen.id)
    assert_true("兑现语句里没有裸换行", not seen.code:find("\n"))
    -- 逐字节回到桥格式化后的 JSON：body 里的引号/反斜杠/裸换行/UTF-8 全须全尾
    assert_eq("穿过四层之后仍是同一段 JSON",
        enc({ status = 200, headers = { ["content-length"] = tostring(#BODY) },
              body = BODY }), seen.payload)
    assert_true("响应体里的裸换行以 JSON 转义活下来",
        seen.payload:find("x\\ny", 1, true) ~= nil)
    assert_eq("兑现之后不再在飞", 0, seen.inflight)
    assert_eq("零 warn（全程没有故障）", 0, seen.warns)
    return true
end

function tests.busy_follows_the_flight_so_the_cadence_can_drop_and_recover()
    withCase(nil, function(box)
        assert_eq("空载时不忙", false, box.host:busy())
        box.post(HTTP_MSG)
        assert_eq("在飞时忙（泵因此切到 0.05s）", true, box.host:busy())
        box.pump()
        assert_eq("还没跑完仍然忙", true, box.host:busy())
        for _ = 1, 8 do box.pump() end
        assert_eq("跑完回到空闲（泵退回 0.5s）", false, box.host:busy())
    end)
    return true
end

function tests.abort_mid_flight_releases_the_socket_and_delivers_nothing()
    withCase(nil, function(box)
        box.post(HTTP_MSG)
        box.pump()                              -- 正挂在一次等待上
        assert_eq("取消前在飞 1", 1, box.br:httpInflight())
        assert_eq("取消掉一条", 1, box.br:abortHttp())
        assert_eq("取消后在飞 0", 0, box.br:httpInflight())
        for _ = 1, 6 do box.pump() end
        assert_true("没兑现（Promise 由 JS 侧随引擎一起丢弃）",
            resolveOf(box) == nil)
        assert_true("fd 当场关掉，不等对端超时",
            TlsFake.logFind(box.log, "%.close") ~= nil)
    end)
    return true
end

function tests.network_failure_travels_as_a_value_not_a_bridge_error()
    withCase({ connect_fails = true }, function(box)
        box.post(HTTP_MSG)
        for _ = 1, 8 do box.pump() end
        local _, payload = resolveOf(box)
        assert_true("仍然兑现（源判的是 status，不是异常）", payload ~= nil)
        assert_true("带 error 字段", payload:find('"error":', 1, true) ~= nil)
        assert_true("绝不是桥错误/reject", payload:find("__error", 1, true) == nil)
    end)
    return true
end

function tests.two_sequential_requests_each_get_their_own_delivery()
    -- 源的典型形态：await 完一笔紧接着发下一笔（分类→列表、列表→详情）。
    -- 这里连跑两轮，验 id 不复用、隧道复用之后第二笔的字节照样完整落到 JS。
    local rounds = {}
    withCase(nil, function(box)
        for round = 1, 2 do
            box.post(HTTP_MSG)
            local ticks = 0
            while box.br:httpInflight() > 0 and ticks < 10 do
                box.pump()
                ticks = ticks + 1
            end
            rounds[round] = { ticks = ticks, payload = ({ resolveOf(box) })[2] }
            box.codes = {}                        -- 只看本轮新吐出的语句
        end
    end)
    local expected = enc({ status = 200,
                           headers = { ["content-length"] = tostring(#BODY) },
                           body = BODY })
    assert_eq("第一笔兑现", expected, rounds[1].payload)
    assert_eq("第二笔兑现（与第一笔逐字节相同）", expected, rounds[2].payload)
    assert_true("第二笔不再重做 TLS 握手（隧道复用）", rounds[2].ticks < rounds[1].ticks)
    return true
end

return tests
