-- unit test: runtime/bridge.lua 的 r10 M2 异步 http 通道。
-- 契约（三条，缺一条这个里程碑就不能算完成）：
--   ①开关打开时，http 消息**立刻**返回 {__pending=id}，桥内零阻塞调用；
--   ②完成回调把结果排进 takeHttpReady()，形状与同步路径**逐字段相同**
--     （包括「网络失败不是桥错误」这条源的判定依赖）；
--   ③异步通道不可用（requestAsync 返回 nil）→ 退回同步，请求不会凭空消失。
-- 全程假 netclient：只验桥的分派与形状，不碰真 socket。

local Bridge = require("runtime/bridge")
local stubs = require("tests.stubs")

local tests = {}

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 假 netclient：request 记账（用来证明异步路径没调它），
--- requestAsync 只存回调，由测试决定何时兑现。
local function makeNet(opts)
    opts = opts or {}
    local net = { calls = {}, jobs = {}, sync_calls = 0, cb = {} }
    function net:requestAsync(o, on_done)
        if opts.async_fails then return nil, "socket.select 不可用" end
        local idx = #self.cb + 1
        self.calls[idx] = o
        self.cb[idx] = on_done
        local job = {
            cancelled = false,
            cancel = function(j) j.cancelled = true end,
        }
        self.jobs[idx] = job
        return job
    end
    function net:request(o)
        self.sync_calls = self.sync_calls + 1
        self.calls[#self.calls + 1] = o
        return opts.sync_resp or { status = 200, headers = {}, body = "sync" }
    end
    --- 测试侧「这一拍网络完成了」
    function net:finish(i, ok, resp)
        self.cb[i](ok, resp)
    end
    return net
end

local function makeBridge(net, async)
    return Bridge.new({
        settings = stubs.settings_memory(),
        netclient = net,
        convert = require("runtime/convert").new(),
        storage = { load = function() return {} end, save = function() return true end },
        async_http = async,
    })
end

local function httpMsg(url)
    return { method = "http", url = url or "https://api.example.com/list",
             http_method = "GET", headers = { ["user-agent"] = "ezv" } }
end

function tests.async_returns_pending_without_any_blocking_call()
    local net = makeNet()
    local br = makeBridge(net, true)
    local v, iserr = br:handle(httpMsg())
    assert_eq("不是桥错误", false, iserr)
    assert_eq("回的是挂起标记", 1, v.__pending)
    assert_eq("响应只有这一个键", nil, next(v, "__pending"))
    assert_eq("同步 request 一次都没调", 0, net.sync_calls)
    assert_eq("请求参数已交给 netclient", "https://api.example.com/list",
        net.calls[1].url)
    assert_eq("自定义头带过去了", "ezv", net.calls[1].headers["user-agent"])
    return true
end

function tests.ids_increment_and_each_callback_matches_its_request()
    local net = makeNet()
    local br = makeBridge(net, true)
    assert_eq("第一条", 1, br:handle(httpMsg("https://a/1")).__pending)
    assert_eq("第二条", 2, br:handle(httpMsg("https://a/2")).__pending)
    net:finish(2, true, { status = 201, headers = {}, body = "two" })
    local ready = br:takeHttpReady()
    assert_eq("只完成了一条", 1, #ready)
    assert_eq("是第二条的 id", 2, ready[1].id)
    assert_eq("对应它自己的响应体", "two", ready[1].out.body)
    assert_eq("取走即清空", nil, br:takeHttpReady())
    return true
end

function tests.async_shape_equals_sync_shape_for_the_same_response()
    -- 关键回归：源里判的是 result.status / result.error，异步换了形状
    -- 就等于把所有源一次性打挂。两条路跑同一份响应，逐字段对拍。
    local resp = { status = 404, headers = { ["x-a"] = "1" }, body = "nope" }
    local net_a = makeNet{ sync_resp = resp }
    local sync = makeBridge(net_a, false):handle(httpMsg("https://a/x"))
    local net_b = makeNet()
    local br_b = makeBridge(net_b, true)
    br_b:handle(httpMsg("https://a/x"))
    net_b:finish(1, true, resp)
    local async = br_b:takeHttpReady()[1].out
    assert_eq("status 一致", sync.status, async.status)
    assert_eq("body 一致", sync.body, async.body)
    assert_eq("header 一致", sync.headers["x-a"], async.headers["x-a"])
    assert_eq("error 一致", sync.error, async.error)
    return true
end

function tests.network_failure_is_not_a_bridge_error()
    -- 同步路径：request 返回 {error=...} → 桥把它当**正常结果**交回，
    -- 源自己判 status!==200。异步路径必须同样：回调拿到字符串错因也要
    -- 包成 {error=...}，而不是 __error（那会让 glue 抛异常，语义变了）。
    local net = makeNet()
    local br = makeBridge(net, true)
    br:handle(httpMsg("https://a/fail"))
    net:finish(1, false, "timeout")
    local v = br:takeHttpReady()[1].out
    assert_eq("错因进 error 字段", "timeout", v.error)
    assert_eq("状态码为空（与同步一致）", nil, v.status)
    assert_eq("没有 __error 键", nil, v.__error)
    return true
end

function tests.falls_back_to_sync_when_async_channel_is_unavailable()
    local net = makeNet{ async_fails = true }
    local br = makeBridge(net, true)
    local v, iserr = br:handle(httpMsg("https://a/fb"))
    assert_eq("不是桥错误", false, iserr)
    assert_eq("没有挂起标记", nil, v.__pending)
    assert_eq("退回同步一次", 1, net.sync_calls)
    assert_eq("拿到同步响应", 200, v.status)
    return true
end

function tests.stays_synchronous_when_switch_is_off()
    local net = makeNet()
    local br = makeBridge(net, false)
    local v = br:handle(httpMsg("https://a/off"))
    assert_eq("默认关：直接给结果", 200, v.status)
    assert_eq("没调 requestAsync", 0, #net.cb)
    return true
end

function tests.abort_cancels_in_flight_and_drops_results()
    local net = makeNet()
    local br = makeBridge(net, true)
    br:handle(httpMsg("https://a/1"))
    br:handle(httpMsg("https://a/2"))
    net:finish(1, true, { status = 200, headers = {}, body = "one" })
    assert_eq("在飞计数含已排队结果", 2, br:httpInflight())
    assert_eq("只取消还没完成的那条", 1, br:abortHttp())
    assert_eq("已完成的 job 不再被 cancel", false, net.jobs[1].cancelled)
    assert_eq("第二条 job 被 cancel", true, net.jobs[2].cancelled)
    assert_eq("取消后计数归零", 0, br:httpInflight())
    assert_eq("已排好的结果一起丢弃（没人再兑现）", nil, br:takeHttpReady())
    -- 取消后再来的回调不得把结果塞回队列（协程是在下一拍才 unwound 的）
    net:finish(2, false, "cancelled")
    assert_eq("迟到回调不产生悬空 resolve", nil, br:takeHttpReady())
    return true
end

function tests.bytes_body_is_wrapped_on_both_paths()
    -- 图片走 msg.bytes：二进制必须以 {__bytes_b64=...} 过桥，异步支路
    -- 共用同一个格式化函数，不能漏。
    local bin = string.char(0, 1, 255, 128, 10)
    local net = makeNet()
    local br = makeBridge(net, true)
    local msg = httpMsg("https://a/img")
    msg.bytes = true
    br:handle(msg)
    net:finish(1, true, { status = 200, headers = {}, body = bin })
    local out = br:takeHttpReady()[1].out
    assert_eq("标记存在", true, type(out.body) == "table"
        and out.body.__bytes_b64 ~= nil)
    local Convert = require("runtime/convert")
    assert_eq("解回来是原字节", bin, Convert.base64Decode(out.body.__bytes_b64))
    return true
end

return tests
