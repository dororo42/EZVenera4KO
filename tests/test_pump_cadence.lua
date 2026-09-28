-- unit test: main.lua 的引擎泵节拍（r10 M2）。
-- 为什么要钉住这条：非阻塞传输的收益**完全**取决于泵周期——一次「等数据」
-- 正好是一个周期的墙钟时间，0.5s 的周期会把一次 TLS 握手拖成好几拍；
-- 反过来，空闲时还按 0.05s 跑就是白耗电。判据来自 eng:busy()。
-- 另外一条硬要求：泵炸掉时必须顺手取消在飞请求，否则那些 socket
-- 只能等对端超时才归还。

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

-- main.lua 依赖的 UI 桩：只补到能 require 的程度（与 test_main_entry 同一套）
package.loaded["gettext"] = package.loaded["gettext"] or function(s) return s end
package.loaded["logger"] = package.loaded["logger"] or
    { info = function() end, dbg = function() end, err = function() end,
      warn = function() end }
local UM = package.loaded["ui/uimanager"] or {}
UM.show = UM.show or function() end
UM.scheduleIn = UM.scheduleIn or function() end
package.loaded["ui/uimanager"] = UM
package.loaded["ui/widget/infomessage"] = package.loaded["ui/widget/infomessage"]
    or { new = function(cls, o) return setmetatable(o or {}, { __index = cls }) end }
package.loaded["ui/widget/container/widgetcontainer"] =
    package.loaded["ui/widget/container/widgetcontainer"] or
    (function()
        local WC = {}
        WC.__index = WC
        function WC.extend(_, tbl)
            local t = tbl or {}
            t.__index = t
            return setmetatable(t, { __index = WC })
        end
        return WC
    end)()
package.loaded["dispatcher"] = package.loaded["dispatcher"]
    or { registerAction = function() end }

local Main = require("main")
local tests = {}

--- 造一个能跑的插件实例 + 假引擎；sched 收 scheduleIn 的 (delay, cb)。
local function withPump(engine, body)
    local sched = {}
    local old = UM.scheduleIn
    UM.scheduleIn = function(_, delay, cb)
        table.insert(sched, { delay = delay, cb = cb })
    end
    local warns = {}
    local oldlog = package.loaded["logger"]
    package.loaded["logger"] = {
        info = function() end, dbg = function() end, err = function() end,
        warn = function(msg, ...)
            local line = tostring(msg)
            for i = 1, select("#", ...) do
                line = line .. " " .. tostring(select(i, ...))
            end
            table.insert(warns, line)
        end,
    }
    local inst = setmetatable({ name = "ezvenera", _pump_running = false },
        { __index = Main })
    inst._engine = engine
    local ok, err = pcall(body, inst, sched, warns)
    UM.scheduleIn = old
    package.loaded["logger"] = oldlog
    assert(ok, "pump case broke: " .. tostring(err))
    return sched, warns
end

local function makeEngine(opts)
    opts = opts or {}
    local eng = { initialized = true, pumps = 0, busy_flag = opts.busy,
                  aborted = 0, capped = opts.capped }
    function eng:pump()
        self.pumps = self.pumps + 1
        if opts.throws then error("js host died") end
        -- 注意 or 陷阱：capped 时必须显式 false（and-or 链会恒 true）
        -- 读 self.capped：测试中改 eng.capped 才能生效（opts 是另一张表）
        return 0, not self.capped
    end
    function eng:busy() return self.busy_flag == true end
    -- 注意是闭包捕获 eng，不是 self：abortHttp 被 : 调用时多带一个自变量
    eng.bridge = { abortHttp = function() eng.aborted = eng.aborted + 1 end }
    return eng
end

function tests.idle_pump_keeps_the_slow_period()
    local eng = makeEngine{ busy = false }
    local sched = withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        assert_eq("启动时排一拍", 1, #s)
        assert_eq("空闲周期 0.5s", 0.5, s[1].delay)
        s[1].cb()                       -- 跑一次 tick
        assert_eq("续拍", 2, #s)
        assert_eq("仍然 0.5s", 0.5, s[2].delay)
        assert_eq("泵跑过一次", 1, eng.pumps)
    end)
    assert_true("harness ok", sched ~= nil)
    return true
end

function tests.in_flight_network_speeds_the_pump_up()
    local eng = makeEngine{ busy = true }
    withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        s[1].cb()
        assert_eq("在飞时收到 0.05s", 0.05, s[2].delay)
        -- 网络收尾后必须自己回到慢周期，不能一路 0.05s 跑到断电
        eng.busy_flag = false
        s[2].cb()
        assert_eq("空闲后回到 0.5s", 0.5, s[3].delay)
    end)
    return true
end

function tests.explicit_interval_stays_fixed()
    -- 调用方指定 interval（单测/探针要可预期）时不做自适应
    local eng = makeEngine{ busy = true }
    withPump(eng, function(inst, s)
        inst:_startEnginePump(eng, 0.2)
        s[1].cb()
        assert_eq("第二拍仍按指定值", 0.2, s[2].delay)
    end)
    return true
end

function tests.pump_is_started_only_once()
    local eng = makeEngine()
    withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        inst:_startEnginePump(eng)
        assert_eq("不叠第二条定时链", 1, #s)
    end)
    return true
end

function tests.pump_failure_aborts_in_flight_and_stops()
    local eng = makeEngine{ throws = true }
    local sched, warns = withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        s[1].cb()                       -- 这一拍里 pump 抛错
        assert_eq("不再续拍（停摆）", 1, #s)
        assert_eq("运行标记关掉", false, inst._pump_running)
    end)
    assert_eq("在飞请求被取消", 1, eng.aborted)
    assert_eq("停摆留一条 warn", 1, #warns)
    assert_true("warn 里能看出原因",
        warns[1]:find("js host died", 1, true) ~= nil)
    assert_true("harness ok", sched ~= nil)
    return true
end

function tests.pump_stops_when_engine_is_gone()
    local eng = makeEngine()
    withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        inst._engine = nil              -- 引擎被释放/换掉
        s[1].cb()
        assert_eq("自然停摆，不续拍", 1, #s)
        assert_eq("运行标记关掉", false, inst._pump_running)
    end)
    return true
end

--- Y1（核实报告 §2）：job/timer 触顶（drained=false）加速节拍
function tests.pump_backpressure_speeds_the_pump_up()
    local eng = makeEngine{ capped = true }   -- pump 返回 (0, false)
    local sched, warns = withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        s[1].cb()
        assert_eq("触顶时收到 0.05s", 0.05, s[2].delay)
        eng.capped = false                   -- 积压排完，回慢周期
        s[2].cb()
        assert_eq("排空后回到 0.5s", 0.5, s[3].delay)
    end)
    return true
end

--- Y4（核实报告 §2）：换引擎世代守卫——旧链静默消亡，新链接管
function tests.pump_restarts_with_new_engine_generation()
    local eng1 = makeEngine{ busy = false }
    local eng2 = makeEngine{ busy = false }
    local sched = withPump(eng1, function(inst, s)
        inst:_startEnginePump(eng1)
        s[1].cb()                            -- eng1 第一拍（已排 s[2]）
        inst._engine = eng2
        inst:_startEnginePump(eng2)          -- 世代 +1，新链 s[2]→s[3]
        local before = #s
        s[2].cb()                            -- 旧链已排队 tick：静默消亡
        assert_eq("旧链世代过期不续拍", before, #s)
        assert_eq("旧引擎没被再泵", 1, eng1.pumps)
        s[3].cb()                            -- 新链 tick：正常续拍
        assert_eq("新链接管续拍", before + 1, #s)
        assert_eq("新引擎被泵", 1, eng2.pumps)
    end)
    return true
end

function tests.stop_plugin_stops_the_pump()
    local eng = makeEngine()
    local sched = withPump(eng, function(inst, s)
        inst:_startEnginePump(eng)
        inst:stopPlugin()
        s[1].cb()
        assert_eq("停用后不续拍", 1, #s)
        assert_eq("运行标记关掉", false, inst._pump_running)
    end)
    return true
end

return tests
