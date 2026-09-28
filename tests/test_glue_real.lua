--- unit test: QUICKJS_GLUE 行为（真 quickjs 执行，非字符串模式断言）
--
-- 核实报告 §3 测试缺口 #1：glue 此前只有 `src:find('…')` 式断言，thenable/
-- 不同步 resolve/单拍上限/异常计数/超龄丢弃全部从未被执行过。
--
-- 环境约定（与 test_convert_real 同一形状：不可用就整文件 SKIP，
-- 靠 chunk 返回 nil，run_tests.py 打印 SKIP 且不影响退出码）：
--   QUICKJS_LIB_PATH=<宿主 libquickjs 路径> 或系统路径里有 libquickjs
--   （`./scripts/fetch-quickjs.sh && ./scripts/build-quickjs.sh --target x86_64`
--   产出）。
--   **CI 已经真跑本文件**（.github/workflows/ci.yml 的 "Build host libquickjs"
--   步把 QUICKJS_LIB_PATH 指向构建目录产物，另有 "Glue suite really executed"
--   反向闸门：一旦重新 SKIP 就红）。2026-09-28 在 x86_64 Linux + 真 LuaJIT 2.1
--   + quickjs-ng v0.17.0 上 8/8 通过；本机（Windows，无宿主 quickjs）仍是
--   SKIP——**别把本机绿读成 CI 绿**，反过来也别把本机 SKIP 读成 CI SKIP。
--   glue 的 JS 语义另有 node 执行同一批字节的点验（脚本在仓库外
--   `ezv_scratch/glue_node/`）；本文件补的是"真 quickjs 也吃这套"那一层。
--
-- 探测**不得**回落到插件目录 `lib/*.so`：那是 2026-09-25 真机 SIGSEGV 的
-- 同名遮蔽向量（RCA），且本机那份 857KB 残留是 ARM 产物，在 x86_64 上只会
-- 让 ffi.load 报错或加载到错版本 ABI。

local ffi = require("ffi")
local JsHost = require("runtime.jshost")

local JS_TAG_EXCEPTION = 6   -- 与 runtime/jshost.lua:42 同一常量

local tests = {}
local LIB

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_true(label, v)
    assert(v, label .. ": expected truthy, got " .. tostring(v))
end

local function probeLib()
    local path = os.getenv("QUICKJS_LIB_PATH")
    if path and path ~= "" then
        local ok, lib = pcall(ffi.load, path)
        if ok then return lib end
    end
    for _, name in ipairs({ "libquickjs", "quickjs", "qjs" }) do
        local ok, lib = pcall(ffi.load, name)
        if ok then return lib end
    end
    return nil
end

local function declare()
    local function cdef(decl) pcall(ffi.cdef, decl) end
    cdef[[ typedef struct JSRuntime JSRuntime; ]]
    cdef[[ typedef struct JSContext JSContext; ]]
    cdef[[ typedef union JSValueUnion {
            int32_t int32;
            double float64;
            void *ptr;
            int32_t short_big_int;
        } JSValueUnion; ]]
    cdef[[ typedef struct JSValue {
            JSValueUnion u;
            int64_t tag;
        } JSValue; ]]
    cdef[[ typedef JSValue JSValueConst; ]]
    cdef[[ JSRuntime *JS_NewRuntime(void); ]]
    cdef[[ void JS_FreeRuntime(JSRuntime *rt); ]]
    cdef[[ JSContext *JS_NewContext(JSRuntime *rt); ]]
    cdef[[ void JS_FreeContext(JSContext *ctx); ]]
    cdef[[ void JS_SetMemoryLimit(JSRuntime *rt, size_t limit); ]]
    cdef[[ JSValue JS_Eval(JSContext *ctx, const char *source, size_t len,
                    const char *filename, int flags); ]]
    cdef[[ JSValue JS_GetException(JSContext *ctx); ]]
    cdef[[ const char *JS_ToCStringLen2(JSContext *ctx, size_t *plen,
                    JSValueConst val, bool cesu8); ]]
    cdef[[ void JS_FreeCString(JSContext *ctx, const char *ptr); ]]
    cdef[[ void JS_FreeValue(JSContext *ctx, JSValue val); ]]
end

--- 打开一个干净的 runtime + context，装入 glue 和 __ezv_post 桩。
--- 桩必须回 `__delay_ms` 标记——delay 分支的入口是桥响应里的这个字段
--- （runtime/bridge.lua:381），回空对象会让整条 timer 路径根本不被触发。
local function open()
    local rt = LIB.JS_NewRuntime()
    assert(rt ~= nil, "JS_NewRuntime failed")
    LIB.JS_SetMemoryLimit(rt, 8 * 1024 * 1024)
    local ctx = LIB.JS_NewContext(rt)
    assert(ctx ~= nil, "JS_NewContext failed")

    local function eval(code)
        local val = LIB.JS_Eval(ctx, code, #code, "<glue-test>", 0)
        if val.tag == JS_TAG_EXCEPTION then
            local exc = LIB.JS_GetException(ctx)
            local s = LIB.JS_ToCStringLen2(ctx, nil, exc, false)
            local msg = s ~= nil and ffi.string(s) or "?"
            if s ~= nil then LIB.JS_FreeCString(ctx, s) end
            LIB.JS_FreeValue(ctx, exc)
            LIB.JS_FreeValue(ctx, val)
            error("glue eval failed: " .. msg)
        end
        local s = LIB.JS_ToCStringLen2(ctx, nil, val, false)
        local out = s ~= nil and ffi.string(s) or nil
        if s ~= nil then LIB.JS_FreeCString(ctx, s) end
        LIB.JS_FreeValue(ctx, val)
        return out
    end

    eval(JsHost.QUICKJS_GLUE)
    eval([[
        globalThis.__ezv_post = function (s) {
            var m = JSON.parse(s);
            if (m && m.method === 'delay') {
                return JSON.stringify({ __delay_ms: m.time });
            }
            return JSON.stringify({});
        };
    ]])
    return rt, ctx, eval
end

--- 每个用例用**自己的** runtime：`__ezv_timers` 是 glue 的模块级数组，
--- 共用 context 时上一条用例残留的定时器会落进下一条的 fired/dropped 计数
--- （run_tests.py 按字母序跑，"never_thened…" 排在 "timer_cap…" 之后必然串味）。
local function with_host(fn)
    local rt, ctx, eval = open()
    local ok, err = pcall(fn, eval)
    LIB.JS_FreeContext(ctx)
    LIB.JS_FreeRuntime(rt)
    if not ok then error(err) end
    return true
end

--- Date.now 可用（glue 的 at 计算依赖它）
function tests.date_now_available()
    return with_host(function(eval)
        assert_eq("Date.now", "function", eval("typeof Date.now"))
    end)
end

--- delay 返回 thenable，且**没有**同步 resolve（H1 契约本体）
function tests.delay_returns_thenable_without_resolving()
    return with_host(function(eval)
        local t = eval([[
            var d = sendMessage({ method: 'delay', time: 5 });
            JSON.stringify({ then: typeof d.then, ms: d.__delay_ms });
        ]])
        assert_eq("thenable + 延迟值", '{"then":"function","ms":5}', t)
    end)
end

--- 到点前不触发、到点后触发一次——setInterval 忙等冻结的防线
function tests.delay_fires_only_when_due()
    return with_host(function(eval)
        eval([[
            var fired = 0;
            var d = sendMessage({ method: 'delay', time: 5 });
            d.then(function () { fired++; });
        ]])
        assert_eq("到点前 poll 未触发", "0",
            eval("__ezv_poll_timers(Date.now()).split('|')[0]"))
        assert_eq("回调未同步执行", 0, tonumber(eval("fired")))
        assert_eq("到点后 poll 计数", "1",
            eval("__ezv_poll_timers(Date.now() + 100).split('|')[0]"))
        assert_eq("回调已执行", 1, tonumber(eval("fired")))
    end)
end

--- 同一 timer 只触发一次（双发排除）
function tests.timer_fires_exactly_once()
    return with_host(function(eval)
        eval([[
            var fires = 0;
            var d = sendMessage({ method: 'delay', time: 1 });
            d.then(function () { fires++; });
            __ezv_poll_timers(Date.now() + 10);
            __ezv_poll_timers(Date.now() + 10);
        ]])
        assert_eq("恰好一次", 1, tonumber(eval("fires")))
    end)
end

--- 单拍上限 64，剩余留到下一拍（风暴防线）
function tests.timer_cap_is_64_per_poll()
    return with_host(function(eval)
        eval([[
            for (var i = 0; i < 70; i++) {
                var d = sendMessage({ method: 'delay', time: 1 });
                d.then(function () {});
            }
        ]])
        assert_eq("首拍 64", "64",
            eval("__ezv_poll_timers(Date.now() + 10).split('|')[0]"))
        assert_eq("次拍 6", "6",
            eval("__ezv_poll_timers(Date.now() + 10).split('|')[0]"))
    end)
end

--- 回调抛错在**当拍**计数、且不串到下一拍（Y3 留痕的本体）
function tests.timer_callback_exception_is_counted()
    return with_host(function(eval)
        eval([[
            var d = sendMessage({ method: 'delay', time: 1 });
            d.then(function () { throw new Error('boom'); });
        ]])
        assert_eq("fired|errors|dropped", "1|1|0",
            eval("__ezv_poll_timers(Date.now() + 10)"))
        assert_eq("计数不跨拍串味", "0|0|0",
            eval("__ezv_poll_timers(Date.now() + 20)"))
    end)
end

--- 从未 .then 的条目 60s 后丢弃（Y3 泄漏上界）
function tests.never_thened_timer_dropped_after_age()
    return with_host(function(eval)
        eval([[
            var d = sendMessage({ method: 'delay', time: 1 });   // 故意不 .then
        ]])
        assert_eq("未到龄：保留", "0|0|0",
            eval("__ezv_poll_timers(Date.now() + 10)"))
        assert_eq("61s 后丢弃", "0|0|1",
            eval("__ezv_poll_timers(Date.now() + 61000)"))
        assert_eq("丢弃后队列已空", "0|0|0",
            eval("__ezv_poll_timers(Date.now() + 122000)"))
    end)
end

--- Lua 侧解析契约：poll 恒为三段数字串（_pollTimers 按 `^(%d+)|(%d+)|(%d+)$` 匹配）
function tests.poll_returns_packed_three_fields()
    return with_host(function(eval)
        local packed = eval("__ezv_poll_timers(Date.now())")
        assert_true("三段数字形状",
            packed ~= nil and packed:match("^%d+|%d+|%d+$") ~= nil)
    end)
end

-- 引擎不可用 ⇒ 整文件 SKIP（chunk 返回 nil 是 run_tests.py 的约定）
LIB = probeLib()
if not LIB then return nil end
declare()
return tests
