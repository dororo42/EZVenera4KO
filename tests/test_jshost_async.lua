-- unit test: runtime/jshost.lua 的 r10 M2 泵侧兑现（_tickNet / _deliverHttp / busy）。
-- 引擎在单测里不可用（无 quickjs .so），所以用裸实例 + _evalRaw 桩：
-- 验的是「泵每一拍做了什么、拼出的 JS 长什么样」，不是 JS 执行结果
-- （glue 那半边用 node 直接跑 QUICKJS_GLUE 点验，见 AGENTS.md 的 M2 条）。
-- 契约：
--   ①顺序 = 先推网络一拍 → 再投递已完成响应 → 然后排 promise 队列 → 定时器；
--     反了每个网络结果都要多等一拍（0.5s）。
--   ②投递的 JSON 必须以**合法 JS 字符串字面量**进 eval：引号、反斜杠、
--     换行、控制字符全转义。漏一个裸换行 = 那条 eval 变 SyntaxError = 结果丢失。
--   ③编码失败也必须兑现（否则 Promise 永挂，界面表现为无解释的等待）。

local stubs = require("tests.stubs")
local JsHost, fake = stubs.reload_jshost_with_logger()

local tests = {}

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 反解 JS 字符串字面量内容（只认 \" \\ \n \r \t \uXXXX），
--- 用来做「拼出去再剥回来逐字节相同」的往返断言。
local ESCAPES = { n = "\n", r = "\r", t = "\t", ["\\"] = "\\", ['"'] = '"' }
local function jsUnescape(s)
    local out = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c ~= "\\" then
            out[#out + 1] = c
            i = i + 1
        else
            local n = s:sub(i + 1, i + 1)
            if n == "u" then
                local b = tonumber(s:sub(i + 2, i + 5), 16)
                assert_true("合法的 \\u 转义", b ~= nil and b < 256)
                out[#out + 1] = string.char(b)
                i = i + 6
            else
                assert_true("合法的转义序列: " .. tostring(n), ESCAPES[n] ~= nil)
                out[#out + 1] = ESCAPES[n]
                i = i + 2
            end
        end
    end
    return table.concat(out)
end

--- 假桥：netclient 的 tickAsync 记一拍；ready 由测试塞；
--- takeHttpReady 取走即清空（真桥同语义）。
local function makeHost(opts)
    opts = opts or {}
    local order = {}
    local ready = opts.ready or {}
    local nc = { pending = opts.pending or 0, ticks = 0 }
    function nc:tickAsync(budget)
        self.ticks = self.ticks + 1
        self.last_budget = budget
        order[#order + 1] = "tick"
        if opts.tick_fails then error("select blew up") end
        return { active = self.pending, started = 0, finished = 0, queued = 0 }
    end
    function nc:asyncPending() return self.pending end
    local br = { netclient = nc, aborted = 0, inflight = opts.inflight or 0 }
    function br:takeHttpReady()
        order[#order + 1] = "take"
        if #ready == 0 then return nil end
        local out = ready
        ready = {}
        return out
    end
    function br:httpInflight() return self.inflight end
    function br:abortHttp() self.aborted = self.aborted + 1; return 1 end
    local host = setmetatable({
        initialized = opts.initialized ~= false,
        ctx = opts.ctx == nil and {} or opts.ctx,
        rt = nil,                       -- _drainJobs 走「无引擎」早退支路
        bridge = br,
        json = opts.json or { encode = function(v) return v.__json or "{}" end },
    }, JsHost)
    local codes = {}
    function host._evalRaw(_, code)
        codes[#codes + 1] = code
        order[#order + 1] = "eval"
        return true, "1"
    end
    host._codes = codes
    host._order = order
    host._nc = nc
    host._br = br
    return host
end

local tests_ = tests

function tests_.pump_order_is_net_then_resolve_then_timers()
    local host = makeHost{ ready = { { id = 1, out = { __json = '{"status":200}' } } } }
    host:pump()
    assert_eq("第一拍先推网络", "tick", host._order[1])
    assert_eq("第二件事是取结果", "take", host._order[2])
    assert_eq("两次 eval 封顶", 2, #host._codes)
    assert_true("先兑现再排定时器",
        host._codes[1]:find("__ezv_resolve", 1, true) == 1
        and host._codes[2]:find("__ezv_poll_timers", 1, true) == 1)
    return true
end

function tests_.tick_gets_the_slice_budget()
    local host = makeHost()
    host:pump()
    assert_eq("预算就是泵里那个常量", host.PUMP_NET_SLICE_SEC, host._nc.last_budget)
    assert_eq("单位是秒（数字）", "number", type(host._nc.last_budget))
    return true
end

function tests_.resolve_payload_round_trips_byte_exact()
    -- 引号、反斜杠、裸换行、裸制表符、NUL 一起上
    local payload = '{"a":"he said \\"hi\\" c:\\x","b":1}\n\t'
        .. string.char(0) .. "tail"
    local host = makeHost{ ready = { { id = 7, out = { __json = payload } } } }
    host:pump()
    local code = host._codes[1]
    assert_true("带 id", code:find("__ezv_resolve(7,", 1, true) ~= nil)
    local inner = code:match('^__ezv_resolve%(%d+, "(.*)", null%)$')
    assert_true("字面量形状成立", inner ~= nil)
    assert_true("串里没有裸引号",
        not inner:gsub('\\"', ""):find('"', 1, true))
    assert_true("串里没有裸控制字符", not inner:find("%c"))
    assert_eq("剥回来逐字节等于原 JSON", payload, jsUnescape(inner))
    return true
end

function tests_.encode_failure_still_resolves_the_promise()
    local host = makeHost{
        ready = { { id = 3, out = {} } },
        json = { encode = function() error("bad utf8") end },
    }
    host:pump()
    assert_eq("以错误串兑现", '__ezv_resolve(3, null, "bridge: async encode failed")',
        host._codes[1])
    return true
end

function tests_.empty_queue_touches_nothing_but_the_clock()
    local host = makeHost{ ready = {} }
    host:pump()
    assert_eq("网络照旧推一拍", 1, host._nc.ticks)
    assert_eq("没有结果就不 eval resolve", 1, #host._codes)
    assert_true("只剩定时器 eval",
        host._codes[1]:find("__ezv_poll_timers", 1, true) ~= nil)
    return true
end

function tests_.delivery_skipped_when_engine_is_gone()
    local host = makeHost{ ready = { { id = 1, out = { __json = "{}" } } },
                           initialized = false }
    host:pump()
    assert_eq("没 eval", 0, #host._codes)
    return true
end

function tests_.tick_error_warns_once_and_pump_keeps_running()
    fake.reset()
    local host = makeHost{ tick_fails = true,
                           ready = { { id = 1, out = { __json = '{"status":500}' } } } }
    local executed, drained = host:pump()
    assert_eq("泵没被炸停", true, drained)
    assert_eq("job 计数照走", 0, executed)
    assert_eq("网络失败留 warn", 1, #fake.warns)
    assert_true("warn 内容可定位", fake.warns[1]:find("net tick failed", 1, true) ~= nil)
    assert_true("同拍仍把已完成的结果投出去",
        host._codes[1]:find("__ezv_resolve", 1, true) == 1)
    return true
end

function tests_.busy_follows_net_and_bridge_counts()
    local host = makeHost{ pending = 0, inflight = 0 }
    assert_eq("空闲 = false", false, host:busy())
    host._nc.pending = 2
    assert_eq("netclient 有在飞 = true", true, host:busy())
    host._nc.pending = 0
    host._br.inflight = 1
    assert_eq("桥里还有排队结果 = true", true, host:busy())
    local bare = setmetatable({ bridge = nil }, JsHost)
    assert_eq("没桥也不炸", false, bare:busy())
    return true
end

function tests_.dispose_aborts_in_flight_requests()
    local host = makeHost()
    host.lib = { JS_FreeContext = function() end, JS_FreeRuntime = function() end }
    host:dispose()
    assert_eq("先取消在飞请求", 1, host._br.aborted)
    assert_eq("引擎标记为未初始化", false, host.initialized)
    return true
end

return tests_
