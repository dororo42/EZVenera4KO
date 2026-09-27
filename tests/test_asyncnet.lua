-- unit test: runtime/asyncnet.lua — 非阻塞调度骨架（一拍一 resume / 排队 /
-- 取消 / 切片预算 / retry 包装）。全程用假 select 与假时钟，不碰真 socket。
--
-- 任务体约定（与 asyncnet 的 on_done 形状绑死，改一边必须改另一边）：
--   return value        → on_done(true, value)
--   return nil, err     → on_done(false, err)

local AsyncNet = require("runtime.asyncnet")

local tests = {}

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 假环境：now 由外部推进；select 按脚本决定「这一拍就绪吗」
--- ready[1] = 下一次 select 是否就绪（弹出）；脚本用完后落到 default_ready
--- （默认 true，只测形状时用；要测「真的等」就设 false，否则脚本等于没生效）
local function makeNet(opts)
    opts = opts or {}
    local env = { t = 1000, polls = 0, ready = opts.ready or {} }
    env.default_ready = opts.default_ready
    if env.default_ready == nil then env.default_ready = true end
    local net = AsyncNet.new{
        now = function() return env.t end,
        select = function(rs, ws, timeout)
            env.polls = env.polls + 1
            env.last_timeout = timeout
            local nxt = table.remove(env.ready, 1)
            if nxt == nil then nxt = env.default_ready end
            if nxt then
                return rs or {}, ws or {}, nil
            end
            return {}, {}, nil
        end,
        max_inflight = opts.max_inflight,
        slice_sec = opts.slice_sec,
    }
    env.net = net
    --- 推进 n 拍，每拍把时钟推 step 秒
    function env.run(times, step)
        for _ = 1, times or 1 do
            env.t = env.t + (step or 0.05)
            net:tick()
        end
    end
    return net, env
end

-- 任务体一次跑完（无等待）：第一拍就结束并回调 on_done
function tests.completes_without_waiting()
    local net, env = makeNet()
    local out = {}
    net:submit(function(io) return "ok-value" end,
        function(ok, res) out.ok, out.res = ok, res end)
    local r = net:tick()
    assert_eq("one finished", 1, r.finished)
    assert_eq("none active", 0, r.active)
    assert_eq("on_done ok", true, out.ok)
    assert_eq("result passed", "ok-value", out.res)
    return true
end

-- 没数据时每一拍只推进一次轮询并让出（UI 因此在拍间拿得到事件）
function tests.yields_once_per_tick_when_not_ready()
    local net, env = makeNet{ ready = { false, false, false, true } }
    local out = {}
    net:submit(function(io)
        local ok = AsyncNet.pause(io, { getfd = function() return 7 end }, "read")
        if ok then return "got-data" end
        return nil, "not-ready"
    end, function(ok, res) out.ok, out.res = ok, res end)
    env.run(3)
    assert_eq("still running after 3 ticks", 1, #net._order)
    assert_eq("no callback yet", nil, out.ok)
    env.run(1)
    assert_eq("finished on 4th tick", true, out.ok)
    assert_eq("result", "got-data", out.res)
    assert_eq("4 polls total", 4, env.polls)
    return true
end

-- 非阻塞 select 必须传 0（数字 fd / 阻塞等待都被真机拒，见文件头约束）
function tests.poll_uses_zero_timeout_and_object_sets()
    local net, env = makeNet{ ready = { true } }
    local objSeen
    net:submit(function(io)
        local obj = { getfd = function() return 41 end, tag = "sock" }
        AsyncNet.pause(io, obj, "read")
        objSeen = obj
        return 1
    end)
    net:tick()
    assert_eq("select timeout = 0", 0, env.last_timeout)
    assert_eq("passed the object itself", "sock", objSeen and objSeen.tag)
    return true
end

-- 超过在飞上限的任务排队，前面的收尾后自动补位（补位在下一拍才被推进）
function tests.over_cap_queues_then_starts()
    local net, env = makeNet{ max_inflight = 2, default_ready = false }
    local order = {}
    local function slow(tag)
        net:submit(function(io)
            if not AsyncNet.pause(io, { getfd = function() return 1 end }, "read") then
                return nil, "not-ready"
            end
            order[#order + 1] = tag
            return tag
        end)
    end
    slow("a"); slow("b"); slow("c")
    assert_eq("two in flight", 2, #net._order)
    assert_eq("one queued", 1, net._waiting and #net._waiting or 0)
    env.run(2)
    assert_eq("nothing done while blocked", 0, #order)
    assert_eq("queue untouched", 1, #net._waiting)
    env.default_ready = true
    env.run(1)                      -- a、b 结束，c 补位进在飞
    assert_eq("two done", 2, #order)
    assert_eq("c moved into flight", 1, #net._order)
    assert_eq("c not resumed this tick", 2, #order)
    env.run(1)
    assert_eq("c finished", 3, #order)
    assert_eq("c last", "c", order[3])
    return true
end

-- 取消：pause 立刻返回 false，任务体自行收尾，字节/句柄由持有方处理
function tests.cancel_stops_pause_and_reports()
    local net, env = makeNet{ ready = { false, false, false } }
    local out = {}
    local job = net:submit(function(io)
        local ok, why = AsyncNet.pause(io, { getfd = function() return 9 end }, "both")
        if ok then return "should-not-happen" end
        return nil, why
    end, function(ok, res) out.ok, out.res = ok, res end)
    env.run(1)
    assert_eq("still running", true, net._order[1] ~= nil)
    job:cancel()
    env.run(1)
    assert_eq("job finished", true, job.done)
    assert_eq("reported failure", false, out.ok)
    assert_eq("reason = cancelled", "cancelled", out.res)
    assert_eq("nothing active", 0, #net._order)
    return true
end

-- 排队中的任务被取消：补位时直接丢弃，不占在飞槽位
function tests.cancelled_queued_job_never_starts()
    local net, env = makeNet{ max_inflight = 1, ready = { false } }
    local ran = {}
    net:submit(function(io)
        if not AsyncNet.pause(io, { getfd = function() return 1 end }, "read") then
            return nil, "not-ready"
        end
        ran[#ran + 1] = "a"
        return "a"
    end)
    local j2 = net:submit(function(io) ran[#ran + 1] = "b"; return "b" end)
    j2:cancel()
    env.ready = { true }
    env.run(2)
    assert_eq("only a ran", 1, #ran)
    assert_eq("a", "a", ran[1])
    assert_eq("queue emptied", 0, #net._waiting)
    return true
end

-- 切片预算：一拍里推进到预算用尽就停，剩下的下一拍继续（ANR 预算判据）
function tests.tick_stops_at_budget()
    local net, env = makeNet{ max_inflight = 4 }
    for _ = 1, 4 do
        net:submit(function(io)
            AsyncNet.pause(io, { getfd = function() return 1 end }, "read")
            return 1
        end)
    end
    -- 每 resume 让时钟走 0.01s：预算 0.025 ⇒ 一拍最多 3 个任务
    local realResume = net._resume
    function net:_resume(job)
        env.t = env.t + 0.01
        return realResume(self, job)
    end
    local start = env.t
    local r = net:tick(0.025)
    assert_eq("budgeted resumes", 3, r.started)
    assert_eq("one left for next tick", 1, r.active)
    assert_eq("clock advanced", true, env.t > start)
    env.run(1)
    assert_eq("last one drains next tick", 0, #net._order)
    return true
end

-- retry：wantread/wantwrite 走「等一拍再来」，非阻塞类错误原样上抛
function tests.retry_handles_want_and_propagates_real_errors()
    local net, env = makeNet{ ready = { false, false, true } }
    local out = { attempts = 0 }
    net:submit(function(io)
        local obj = { getfd = function() return 3 end }
        local v, e = AsyncNet.retry(io, obj, "both", function()
            out.attempts = out.attempts + 1
            if out.attempts == 1 then return nil, "wantwrite" end
            if out.attempts == 2 then return nil, "wantread" end
            return nil, "connection refused"
        end)
        return v, e
    end, function(ok, res) out.ok, out.res = ok, res end)
    env.run(1)
    assert_eq("still retrying", nil, out.ok)
    assert_eq("one attempt per data-arrival", 1, out.attempts)
    assert_eq("一拍一次非阻塞轮询", 1, env.polls)
    env.run(2)
    assert_eq("third attempt returns as failure", false, out.ok)
    assert_eq("attempts", 3, out.attempts)
    assert_eq("error string kept", "connection refused", out.res)
    -- 一拍一次轮询：3 拍走到第三次尝试，第 4 次 poll 是 wantread 那一等
    assert_eq("polls per tick", 4, env.polls)
    return true
end

-- retry 的等待总超时：对端一直不给数据不能无限挂着
function tests.retry_gives_up_after_wait_deadline()
    local net, env = makeNet{ ready = { false, false, false, false, false } }
    net.wait_sec = 0.2
    local out = {}
    net:submit(function(io)
        local v, e = AsyncNet.retry(io, { getfd = function() return 1 end },
            "read", function() return nil, "timeout" end)
        return v, e
    end, function(ok, res) out.ok, out.res = ok, res end)
    for _ = 1, 8 do
        env.run(1, 0.1)
        if out.ok ~= nil then break end
    end
    assert_eq("gave up", false, out.ok)
    assert_eq("last blocking error surfaced", "timeout", out.res)
    assert_eq("bounded polls", true, env.polls >= 3 and env.polls <= 4)
    return true
end

-- select 抛错（例如塞了数字 fd）必须变成任务失败，而不是把整拍炸掉
function tests.poll_error_becomes_job_failure_not_crash()
    local net = AsyncNet.new{
        now = (function() local t = 0 return function() t = t + 1 return t end end)(),
        select = function() error("attempt to index a number value") end,
    }
    local out = {}
    net:submit(function(io)
        local ok, why = AsyncNet.pause(io, 41, "read")   -- 数字 fd：真机上就是这个形状
        if ok then return "should-not-happen" end
        return nil, why
    end, function(ok, res) out.ok, out.res = ok, res end)
    local r = net:tick()
    assert_eq("job finished", 1, r.finished)
    assert_eq("reported failure", false, out.ok)
    assert(type(out.res) == "string" and out.res:find("poll-error", 1, true),
        "poll error surfaced, got: " .. tostring(out.res))
    return true
end

-- 任务体自己抛错：pcall 兜住并作为失败上报（不能哑成 nil 成功）
function tests.body_error_becomes_job_failure()
    local net, env = makeNet()
    local out = {}
    net:submit(function(io) error("boom in body") end,
        function(ok, res) out.ok, out.res = ok, res end)
    local r = net:tick()
    assert_eq("finished", 1, r.finished)
    assert_eq("failure", false, out.ok)
    assert_eq("message kept", true, tostring(out.res):find("boom in body") ~= nil)
    return true
end

-- on_done 抛错不能把调度器带崩（真机上回调常是 UI 代码）
function tests.on_done_error_is_recorded()
    local net, env = makeNet()
    net:submit(function(io) return "v" end,
        function() error("widget gone") end)
    local r = net:tick()
    assert_eq("still finished", 1, r.finished)
    assert_eq("error counted", 1, net.errors or 0)
    assert_eq("error kept", true, tostring(net.last_error):find("widget gone") ~= nil)
    assert_eq("slot released", 0, #net._order)
    return true
end

-- abortAll：只标记取消，不丢在飞表（下一拍自然收尾）
function tests.abort_all_marks_pending_jobs()
    local net, env = makeNet{ ready = { false, false, false, false } }
    local out = {}
    net:submit(function(io)
        while true do
            if not AsyncNet.pause(io, { getfd = function() return 1 end }, "read") then
                return nil, "stopped"
            end
        end
    end, function(ok, res) out.ok, out.res = ok, res end)
    env.run(1)
    assert_eq("one active", 1, net:pending())
    assert_eq("abortAll count", 1, net:abortAll())
    env.run(1)
    assert_eq("drained next tick", 0, net:pending())
    assert_eq("reported failure", false, out.ok)
    assert_eq("reason", "stopped", out.res)
    assert_eq("stats tracked resumes", true, net:stats().resumes >= 2)
    return true
end

-- 取消时同步跑 cleanup（fd 必须当场释放，不能等下一拍）；重复 cancel 只跑一次
function tests.cancel_runs_cleanup_once_synchronously()
    local net, env = makeNet{ ready = { false, false } }
    local closed = 0
    local job                                  -- 必须先声明：闭包里的 job 要
    job = net:submit(function(io)              -- 拿到的是 upvalue 而不是全局
        while true do
            if not AsyncNet.pause(io, { getfd = function() return 1 end }, "read") then
                return nil, "cancelled"
            end
        end
    end, function(ok, res) job.ok, job.res = ok, res end)
    job.cleanup = function() closed = closed + 1 end
    env.run(1)
    job:cancel()
    assert_eq("cleanup ran at cancel time, not next tick", 1, closed)
    job:cancel()
    assert_eq("idempotent", 1, closed)
    env.run(1)                               -- 下一拍只负责 unwind
    assert_eq("unwound as cancelled", "cancelled", job.res)
    assert_eq("reported failure", false, job.ok)
    assert_eq("slot released", 0, #net._order)
    return true
end

-- new() 必须把 wait_sec 存下来：否则 submit 里的 `self.wait_sec or 4`
-- 永远退回 4，上层（netclient 用 default_timeout_block）配的等于没配
function tests.new_keeps_wait_sec()
    local net = AsyncNet.new{ wait_sec = 7, max_inflight = 3 }
    assert_eq("wait_sec kept", 7, net.wait_sec)
    assert_eq("max_inflight kept", 3, net.max_inflight)
    local kept
    net:submit(function(io) kept = io._wait_sec; return 1 end)
    net:tick()
    assert_eq("job inherits it", 7, kept)
    return true
end

return tests
