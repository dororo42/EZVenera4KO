-- unit test: runtime/jshost.lua S2/T19 桥接 C shim（lib/libezvbridge.so）
-- 验证点：Lua 侧纯指针回调（const char* (*)(void*, const char*)）经真实
-- LuaJIT ffi.cast 往返；shim 缺失/安装失败优雅降级；回调绝不向 C 栈抛错。
local JsHost = require("runtime.jshost")
local Bridge = require("runtime.bridge")
local NetClient = require("netclient")
local Convert = require("runtime.convert")
local Cookies = require("runtime.cookies")
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_true(label, v)
    assert(v == true, label .. ": expected true, got " .. tostring(v))
end

-- shim 回调返回值统一转 Lua string（cdata 指针 → ffi.string）
local ffi = require("ffi")
local function respStr(resp)
    if type(resp) == "string" then return resp end
    return ffi.string(resp)
end

-- ---- 测试内迷你 JSON（扁平对象/数组/字符串/数字/布尔；仅 \" \\ \n 转义）----

local function jsonEncode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return string.format("%.14g", v) end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' end
            if c == "\\" then return "\\\\" end
            if c == "\n" then return "\\n" end
            if c == "\t" then return "\\t" end
            return string.format("\\x%02x", c:byte())
        end) .. '"'
    end
    if t == "table" then
        if #v > 0 then
            local parts = {}
            for i = 1, #v do parts[i] = jsonEncode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("jsonEncode: unsupported type " .. t)
end

local function jsonDecode(s)
    local pos = 1
    local function skipWS()
        while pos <= #s and s:find("^%s", pos) do pos = pos + 1 end
    end
    local parseValue
    local function parseString()
        assert(s:sub(pos, pos) == '"', "jsonDecode: bad string")
        pos = pos + 1
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            assert(c ~= "", "jsonDecode: unterminated string")
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local n = s:sub(pos + 1, pos + 1)
                if n == "n" then buf[#buf + 1] = "\n"
                elseif n == "t" then buf[#buf + 1] = "\t"
                elseif n == '"' then buf[#buf + 1] = '"'
                elseif n == "\\" then buf[#buf + 1] = "\\"
                elseif n == "/" then buf[#buf + 1] = "/"
                else error("jsonDecode: unsupported escape \\" .. n) end
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end
    local function parseLiteral(word, value)
        if s:sub(pos, pos + #word - 1) == word then
            pos = pos + #word
            return value
        end
        error("jsonDecode: bad literal at " .. pos)
    end
    local function parseNumber()
        local a, b, num = s:find("^(-?%d+%.?%d*[eE]?[-+]?%d*)", pos)
        assert(a, "jsonDecode: bad number at " .. pos)
        pos = b + 1
        return tonumber(num)
    end
    parseValue = function()
        skipWS()
        local c = s:sub(pos, pos)
        if c == '"' then return parseString() end
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skipWS()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skipWS()
                local k = parseString()
                skipWS()
                assert(s:sub(pos, pos) == ":", "jsonDecode: expected :")
                pos = pos + 1
                obj[k] = parseValue()
                skipWS()
                local d = s:sub(pos, pos)
                if d == "," then pos = pos + 1
                elseif d == "}" then pos = pos + 1; return obj
                else error("jsonDecode: expected , or } at " .. pos) end
            end
        end
        if c == "[" then
            pos = pos + 1
            local arr = {}
            skipWS()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skipWS()
                local d = s:sub(pos, pos)
                if d == "," then pos = pos + 1
                elseif d == "]" then pos = pos + 1; return arr
                else error("jsonDecode: expected , or ] at " .. pos) end
            end
        end
        if c == "t" then return parseLiteral("true", true) end
        if c == "f" then return parseLiteral("false", false) end
        if c == "n" then return parseLiteral("null", nil) end
        return parseNumber()
    end
    local v = parseValue()
    skipWS()
    assert(pos > #s, "jsonDecode: trailing garbage at " .. pos)
    return v
end

local minijson = { encode = jsonEncode, decode = jsonDecode }

-- ---- 假 quickjs 库（table 桩，绕过 FFI；cdef 仍为真实声明）----

local function makeFakeQuickjs()
    return {
        JS_NewRuntime = function() return { tag = "rt" } end,
        JS_FreeRuntime = function() end,
        JS_NewContext = function() return { tag = "ctx" } end,
        JS_FreeContext = function() end,
        JS_SetMemoryLimit = function() end,
        JS_Eval = function() return { tag = 2 } end,   -- 非 EXCEPTION
        JS_GetException = function() return { tag = 6 } end,
        JS_ExecutePendingJob = function() return 0 end,
        JS_ToCStringLen2 = function() return nil end,
        JS_FreeCString = function() end,
        JS_FreeValue = function() end,
        JS_NewCFunction2 = function() return { tag = 2 } end,
        JS_GetGlobalObject = function() return { tag = 2 } end,
        JS_SetPropertyStr = function() return 0 end,
        JS_NewStringLen = function() return { tag = 2 } end,
    }
end

-- ---- 全内存 bridge（对齐 test_bridge.makeBridge）----

local function makeBridge(extra)
    extra = extra or {}
    local data_store = extra.data_store or {}
    local storage = {
        load = function(key) return data_store[key] or {} end,
        save = function(key, map) data_store[key] = map; return true end,
    }
    local nc = extra.netclient or NetClient.new({
        transport = function()
            return { status = 200, headers = {}, body = "", error = nil }
        end,
    })
    local cookiejar = extra.cookies or Cookies.new({
        json = { encode = function() return "x" end,
                 decode = function() return nil end },
        store = { load = function() return nil end, save = function() end },
    })
    return Bridge.new({
        settings = extra.settings or stubs.settings_memory(),
        netclient = nc,
        convert = Convert.new(stubs.fake_convert_impl()),
        cookies = cookiejar,
        storage = storage,
    }), data_store
end

-- 组装一个走真实 init 流程的 JsHost（shim 可注入）
local function makeHost(opts)
    opts = opts or {}
    local host = JsHost.new({
        lib = opts.lib or makeFakeQuickjs(),
        shim = opts.shim,
    })
    return host
end

local tests = {}

-- ---- S2/T19：shim 注册与纯指针回调往返 ----

function tests.shim_roundtrip_via_ffi_pointer_callback()
    local captured = {}
    local fake_ctx = { tag = "ctx" }
    local fakeshim = {
        ezv_install_bridge = function(ctx, fn)
            captured.ctx = ctx
            captured.fn = fn
            return 0
        end,
    }
    local host = makeHost({ shim = fakeshim })
    local bridge, store = makeBridge()
    local ok = host:init(bridge, minijson, nil)
    assert_true("init ok", ok)
    assert_eq("installed ctx is host ctx", host.ctx, captured.ctx)
    assert(captured.fn ~= nil, "callback fn not captured")

    -- 经真实 LuaJIT cdata 函数指针调用（string → char* → Lua string → char*）
    local s1 = respStr(captured.fn(nil, '{"method":"save_data","key":"src1",'
        .. '"data_key":"token","data":"abc123"}'))
    assert(s1 and not s1:find("__error", 1, true),
        "save_data should not error, got " .. tostring(s1))

    local s2 = respStr(captured.fn(nil, '{"method":"load_data","key":"src1",'
        .. '"data_key":"token"}'))
    assert(s2 and s2:find("abc123", 1, true),
        "load_data should return saved value, got " .. tostring(s2))

    -- dispose 释放回调
    host:dispose()
    assert_eq("callback freed", nil, host._shim_cb)
    assert_eq("store written", "abc123", store.src1 and store.src1.token)
    return true
end

function tests.shim_callback_swallows_errors()
    local captured = {}
    local fakeshim = {
        ezv_install_bridge = function(_, fn) captured.fn = fn; return 0 end,
    }
    local host = makeHost({ shim = fakeshim })
    -- bridge.handle 抛错 → 回调内 pcall 吞掉，返回 __error JSON（不跨 C 栈）
    local booby = { handle = function() error("boom") end }
    local ok = host:init(booby, minijson, nil)
    assert_true("init ok", ok)
    local s = respStr(captured.fn(nil, '{"method":"anything"}'))
    assert(s:find("__error", 1, true),
        "callback must encode error as __error, got " .. tostring(s))

    -- 非 JSON 入参 → bad JSON 错误形状
    local s2 = respStr(captured.fn(nil, 'not-json'))
    assert(s2:find("__error", 1, true),
        "bad JSON must return __error, got " .. tostring(s2))
    host:dispose()
    return true
end

function tests.shim_missing_reports_clear_reason()
    -- 不注入 shim：探测走真实 ffi.load，测试环境无 libezvbridge → 明确降级
    local host = makeHost({})
    local bridge = makeBridge()
    local ok, err = host:init(bridge, minijson, nil)
    assert(ok ~= true, "init must fail without shim")
    assert(err and err:find("libezvbridge", 1, true),
        "reason should mention libezvbridge, got " .. tostring(err))
    assert(err and err:find("build-shim", 1, true),
        "reason should point to scripts/build-shim.sh, got " .. tostring(err))
    host:dispose()
    return true
end

function tests.shim_install_failure_degrades()
    local fakeshim = {
        ezv_install_bridge = function() return -1 end,
    }
    local host = makeHost({ shim = fakeshim })
    local bridge = makeBridge()
    local ok, err = host:init(bridge, minijson, nil)
    assert(ok ~= true, "init must fail when shim rejects install")
    assert(err and err:find("ezv_install_bridge failed", 1, true),
        "unexpected reason: " .. tostring(err))
    assert_eq("callback freed on failure", nil, host._shim_cb)
    host:dispose()
    return true
end

function tests.shim_callback_anchored_against_gc()
    local fakeshim = {
        ezv_install_bridge = function(_, fn) return 0 end,
    }
    local host = makeHost({ shim = fakeshim })
    local bridge = makeBridge()
    local ok = host:init(bridge, minijson, nil)
    assert_true("init ok", ok)
    assert(host._shim_cb ~= nil,
        "cast callback must be anchored on host (GC safety)")
    collectgarbage("collect")
    collectgarbage("collect")
    assert(host._shim_cb ~= nil, "anchor must survive GC")
    host:dispose()
    return true
end

-- ---- R1 回归锚（2026-09-23 独立评估 + 真机 tombstone 修正）：pump ABI ----
-- 两条硬约束（quickjs-ng v0.17.0 quickjs.c:2526）：
--   1. 双参签名 JS_ExecutePendingJob(JSRuntime*, JSContext**)——旧单参 cdef 在
--      arm64 上把垃圾寄存器值当 pctx 传入，函数写 *pctx → 野指针 SIGSEGV；
--   2. pctx **不得为 NULL**——连"无 job"分支都无条件 `*pctx = NULL`，
--      真机 tombstone：fault addr 0x0 / #00 libquickjs.so+0xe3f8 ← libluajit.so。
-- 桩强制断言双参 + 可解引用的合法出参指针，任何回归在单测层拦截。

local function makePumpFakeLib(get_rc)
    local fake = makeFakeQuickjs()
    local calls = 0
    fake.JS_ExecutePendingJob = function(rt, pctx)
        assert(rt ~= nil, "pump: rt must be passed")
        assert(type(pctx) == "cdata",
            "pump: pctx must be a writable JSContext** out-param, got "
            .. tostring(pctx))
        local _ = pctx[0]     -- 解引用哨兵：NULL 传进来在这里（等同 C 侧）炸
        calls = calls + 1
        return get_rc(calls)
    end
    return fake
end

local function makePumpHost(get_rc)
    local fake = makePumpFakeLib(get_rc)
    local fakeshim = {
        ezv_install_bridge = function() return 0 end,
    }
    local host = makeHost({ lib = fake, shim = fakeshim })
    local bridge = makeBridge()
    assert_true("init ok", host:init(bridge, minijson, nil))
    return host
end

function tests.pump_drains_jobs_until_empty()
    local host = makePumpHost(function(i) return i <= 3 and 1 or 0 end)
    local executed, drained = host:pump()
    assert_eq("3 jobs executed", 3, executed)
    assert_eq("queue drained", true, drained)
    host:dispose()
    return true
end

function tests.pump_respects_job_cap()
    -- 永不排空（模拟 setInterval 自续链）：必须止步于上限
    local host = makePumpHost(function() return 1 end)
    local executed, drained = host:pump(50)
    assert_eq("capped at 50", 50, executed)
    assert_eq("reports not drained", false, drained)
    host:dispose()
    return true
end

function tests.pump_job_error_consumes_exception()
    local consumed = false
    local host = makePumpHost(function(i) return i == 1 and 1 or -1 end)
    host.lib.JS_GetException = function() consumed = true; return { tag = 3 } end
    local executed, drained = host:pump()
    assert_eq("first job ok", 1, executed)
    assert_eq("not drained on job error", false, drained)
    assert_true("pending exception consumed", consumed)
    host:dispose()
    return true
end

-- ---- R5 回归锚（真机 2026-09-23："详情加载失败：not a function"）----
-- Lua→JS wire 形状是唯一体面：Lua 空表在 luaJSON 1.3.5
-- （KOReader 随包 common/json/util.lua:91-100 IsArray）下必然编成 {}，
-- 而 init.js 拿到 querySelectorAll 结果直接 ks.map(...)（init.js:702）→
-- quickjs "not a function"。故空数组走显式标记 {"__empty_array":true}，
-- 由 glue 的 __ezv_untag_bytes 还原为 []。此处在真实 _bridgeHandler +
-- 真实 htmlparse 上锁住出口字节。

local function post(handler, msg)
    return respStr(handler:_bridgeHandler(minijson.encode(msg)))
end

function tests.wire_empty_html_array_is_marked_and_nonempty_stays_array()
    local host = makeHost({ shim = {
        ezv_install_bridge = function() return 0 end } })
    assert_true("init ok", host:init(makeBridge(), minijson, nil))
    post(host, { method = "html", ["function"] = "parse", key = 7,
        data = '<div class="a"><span>x</span><i></i></div>' })

    local empty = post(host, { method = "html", ["function"] = "querySelectorAll",
        key = 7, query = "li.nope" })
    assert_eq("empty querySelectorAll wire", '{"__empty_array":true}', empty)

    local hit = minijson.decode(post(host, { method = "html",
        ["function"] = "querySelectorAll", key = 7, query = "div > span" }))
    assert_eq("non-empty stays a JSON array", 1, #hit)

    -- map 型结果（attributes）空值必须保持 {}，否则 JS 侧 .attributes[k] 失真
    local ikey = minijson.decode(post(host, { method = "html",
        ["function"] = "querySelector", key = 7, query = "i" }))
    local attrs = post(host, { method = "html", ["function"] = "getAttributes",
        key = ikey, doc = 7 })
    assert_eq("empty attributes stay object", "{}", attrs)
    host:dispose()
    return true
end

function tests.wire_empty_cookie_list_is_marked()
    local host = makeHost({ shim = {
        ezv_install_bridge = function() return 0 end } })
    assert_true("init ok", host:init(makeBridge(), minijson, nil))
    local r = post(host, { method = "cookie", ["function"] = "get",
        url = "https://example.com/" })
    assert_eq("empty cookie list wire", '{"__empty_array":true}', r)
    host:dispose()
    return true
end

function tests.glue_restores_empty_array_marker()
    -- glue 是 JS 字符串，Lua 侧不执行；此处锁住还原规则不被误删
    -- （行为验证：node 载入 QUICKJS_GLUE 跑 __ezv_untag_bytes，见
    --   reports/2026-09-23-independent-review-r4.md §2d 记录）
    local path = package.searchpath("runtime.jshost", package.path)
    assert(path, "runtime/jshost.lua not found on package.path")
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    assert(src:find("v.__empty_array === true", 1, true),
        "QUICKJS_GLUE must restore {__empty_array:true} to []")
    assert(src:find("return __ezv_b64decode", 1, true),
        "binary untag must stay ahead of the array marker (order matters)")
    return true
end

function tests.glue_delay_is_thenable_queued_not_sync()
    -- H1（审查报告 §2-H1，2026-09-25）：init.js:26-31 setTimeout 契约 =
    -- sendMessage({delay}).then(cb)。锁三个要点：① delay 分支返回带
    -- then 的对象；② 回调注册进 __ezv_timers 队列（**不得**同步 resolve
    -- ——setInterval 自续链会忙等冻结主循环）；③ pump 侧有 __ezv_poll_timers
    -- 排空入口（Lua _pollTimers 调用）。
    local path = package.searchpath("runtime.jshost", package.path)
    assert(path, "runtime/jshost.lua not found on package.path")
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    assert(src:find('typeof out.__delay_ms === "number"', 1, true),
        "glue must branch on delay marker")
    assert(src:find("then: function(fn) { t.fn = fn; }", 1, true),
        "delay result must be a thenable registering the callback")
    assert(src:find("__ezv_timers.push(t)", 1, true),
        "delay must queue into __ezv_timers (no synchronous resolve)")
    assert(src:find("function __ezv_poll_timers(", 1, true),
        "glue must expose timer poll entry for jshost:pump")
    assert(src:find("__ezv_poll_timers(Date.now())", 1, true),
        "Lua pump must drain JS timers")
    return true
end

function tests.register_source_patches_load_setting_defaults()
    -- R7：源用 `loadSetting(k) === ""` 判"用默认域名"，宿主返回 null 会让
    -- 图片 URL 拼成 https://nullnull/…（真机 logcat 实证）。注册处必须包装
    -- loadSetting，把 undefined/null 换成源声明的 default，再退到 ""。
    local path = package.searchpath("runtime.jshost", package.path)
    assert(path, "runtime/jshost.lua not found on package.path")
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    assert(src:find("s.loadSetting = function", 1, true),
        "registerSource must wrap loadSetting with host-side defaults")
    assert(src:find("d.default !== undefined", 1, true)
        and src:find("d.defaultValue !== undefined", 1, true),
        "wrapper must read both `default` and `defaultValue` declarations")
    assert(src:find('s.settings || {}', 1, true),
        "wrapper must tolerate sources without a settings block")
    assert(src:find('return "";', 1, true),
        "wrapper must fall back to empty string, never null")
    return true
end

return tests
