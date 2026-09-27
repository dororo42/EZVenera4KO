-- unit test: r10 M3 的**全栈**端到端——真 Browser 步进器 + 真 JsHost:pump
--   + 真 Bridge(async_http) + 真 NetClient/AsyncNet，socket 层来自 tests/tlsfake.lua。
-- 为什么还要第三个 e2e：M1 证的是传输层「一拍只推进一件事」，M2 证的是桥与泵
-- 「按顺序兑现」，而 M3 改的是**再上面那一层**——界面在续体里建。三层各自用桩都绿，
-- 中间那道缝（槽号从 eval 返回值里取、resolve 打进的是哪一格、跨拍期间到底排了几拍、
-- 假 socket 的响应字节最后有没有变成菜单上那行标题）仍然没人覆盖。
-- 本地 LuaJIT 里没有 luasocket/LuaSec（M0 真机实测才有 3.1.0/1.3.2），也没有 JS 引擎，
-- 所以 JS 那一半由下面的「假源」按 AWAIT_SNIPPET 的契约模拟（槽号 / {"__pending":true}
-- / {"value":…}）。Promise 兑现语义本身不在这里证，由 node 点验（AGENTS.md 的 M2 条目）。

local stubs = require("tests.stubs")
local TlsFake = require("tests.tlsfake")
local JsHost, sink = stubs.reload_jshost_with_logger()

-- bridge / netclient / asyncnet 跟着一起重载：它们在模块加载期捕获 logger，
-- 不重绑就写进**别的**测试文件的 sink，本文件的「零 warn」断言会假绿。
for _, m in ipairs({ "runtime.bridge", "netclient", "runtime/asyncnet" }) do
    package.loaded[m] = nil
end
local Bridge = require("runtime.bridge")
local NetClient = require("netclient")
local Convert = require("runtime.convert")

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local ui = { sched = {}, shown = {} }

stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(ui.shown, w) end,
    close = noop,
    setDirty = noop,
    scheduleIn = function(_, sec, fn)
        table.insert(ui.sched, { sec = sec, fn = fn })
    end,
})
stub("ui/widget/menu", {
    new = function(_, args) return { __menu = true, args = args } end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })

package.loaded["browser"] = nil
local Browser = require("browser")

local BODY = TlsFake.BODY
local enc = TlsFake.jsonEnc

--- 严格 JSON 解析（本地 VM 没有 json/cjson；真机上是 KOReader 的 C 模块）。
--- 这里**必须**是真解析器而不是「登记夹具」：槽里的文本要由假 socket 的响应
--- 字节一路算出来，写成预置字符串就等于把「字节穿过四层」换成「字符串相等」，
--- 而本次要证的正是前者。形状只覆盖本用例（整数、ASCII \u）。
local ESCMAP = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f",
    ["\\"] = "\\", ['"'] = '"', ["/"] = "/" }

local function dec(s)
    local function ws(j)
        while true do
            local c = s:sub(j, j)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then j = j + 1
            else return j end
        end
    end
    local function value(j)
        j = ws(j)
        local c = s:sub(j, j)
        if c == "{" then
            local t = {}
            j = ws(j + 1)
            if s:sub(j, j) == "}" then return t, j + 1 end
            while true do
                local k
                k, j = value(j)
                assert(type(k) == "string", "键必须是字符串，位置 " .. j)
                j = ws(j)
                assert(s:sub(j, j) == ":", "缺冒号，位置 " .. j)
                local v
                v, j = value(j + 1)
                if v ~= nil then t[k] = v end
                j = ws(j)
                local d = s:sub(j, j)
                if d == "," then j = j + 1
                elseif d == "}" then return t, j + 1
                else error("缺 , 或 }，位置 " .. j .. " 处是 " .. tostring(d)) end
            end
        elseif c == "[" then
            local t = {}
            j = ws(j + 1)
            if s:sub(j, j) == "]" then return t, j + 1 end
            while true do
                local v
                v, j = value(j)
                t[#t + 1] = v
                j = ws(j)
                local d = s:sub(j, j)
                if d == "," then j = j + 1
                elseif d == "]" then return t, j + 1
                else error("缺 , 或 ]，位置 " .. j .. " 处是 " .. tostring(d)) end
            end
        elseif c == '"' then
            local out = {}
            j = j + 1
            while true do
                local ch = s:sub(j, j)
                if ch == "" then error("字符串未闭合") end
                if ch == '"' then return table.concat(out), j + 1 end
                if ch == "\\" then
                    local n = s:sub(j + 1, j + 1)
                    if n == "u" then
                        local b = tonumber(s:sub(j + 2, j + 5), 16)
                        assert(b and b < 128, "只认 ASCII \\u")
                        out[#out + 1] = string.char(b)
                        j = j + 6
                    else
                        assert(ESCMAP[n], "未知转义: \\" .. tostring(n))
                        out[#out + 1] = ESCMAP[n]
                        j = j + 2
                    end
                else
                    out[#out + 1] = ch
                    j = j + 1
                end
            end
        elseif c == "t" then
            assert(s:sub(j, j + 3) == "true", "bad true")
            return true, j + 4
        elseif c == "f" then
            assert(s:sub(j, j + 4) == "false", "bad false")
            return false, j + 5
        elseif c == "n" then
            assert(s:sub(j, j + 3) == "null", "bad null")
            return nil, j + 4
        end
        local numstr = s:match("^-?%d+", j)
        assert(numstr, "不是值: " .. tostring(s:sub(j, j + 8)))
        return tonumber(numstr), j + #numstr
    end
    return value(1)
end

local json = { encode = enc, decode = dec }

-- 「假源」的形状：成员 → 这次 await 在 JS 侧实际发生的事。
-- 典型搜索源 = 发一笔 http、把响应体再 JSON.parse 成列表；声明类成员 = 普通
-- 属性，当拍就有值、**绝不**联网（真实源正是这样，所以源主页不该因为开异步
-- 而跨拍）。标题取自响应体，于是「菜单上那行字」就是假 socket 字节的指纹。
local SOURCES = {
    ["search.load"] = {
        http = { method = "http", key = "src1", http_method = "GET",
                 url = "https://api.example.com/list" },
        then_body = function(b)
            return { comics = { { title = b.title, id = "c1" } }, maxPage = 2 }
        end,
    },
    category = { decl = { categories = { "国漫" }, categoryParams = { "gm" } } },
    explore = { decl = { { title = "排行", type = "comicList" } } },
}

--- 一整轮真栈。用例主体整个跑在假模块窗口里：netclient 是到请求那一刻才
--- require("socket"/"ltn12")，窗口一关就变成回落分支（test_async_e2e 的教训）。
--- `async_on=false` 复刻今天的默认配置：桥不开异步 ⇒ 步进器根本不参与。
local function withCase(async_on, fn)
    ui.sched, ui.shown = {}, {}
    sink.reset()
    local fake = TlsFake.makeFakeHttp{}
    local one = { code = 200,
                  headers = { ["content-length"] = tostring(#BODY) },
                  body = BODY }
    -- 只有异步路径需要「等一拍」。同步路径必须一次成功：takeBlocked 会把第一次
    -- connect 变成 nil,"timeout"，那就测的是失败分支而不是 M3 之前的旧行为。
    local log, env = TlsFake.withTlsStack(fake, {
        blocked = async_on and { connect = 1, handshake = 1, receive = 1 } or {},
        responses = { one, one, one },
    })
    local js = { seq = 0, slots = {}, id2slot = {}, cleared = {}, codes = {},
                 resolved = 0 }
    local box = { log = log, env = env, js = js, fake = fake }

    TlsFake.withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        box.nc = nc
        box.br = Bridge.new{
            settings = stubs.settings_memory(), netclient = nc,
            convert = Convert.new(stubs.fake_convert_impl()),
            cookies = stubs.fake_cookies(),
            storage = { load = function() return {} end,
                        save = function() return true end },
            async_http = async_on,
        }
        local host = setmetatable({ initialized = true, ctx = {},
                                    bridge = box.br, json = json }, JsHost)
        box.host = host

        --- 假 JS 引擎：只认四条形迹——AWAIT_SNIPPET 的 IIFE、读槽、清槽、泵投递
        --- 的 __ezv_resolve。其余（__ezv_poll_timers）回 0。
        function host._evalRaw(_, code)
            js.codes[#js.codes + 1] = code
            local path = code:match('"missing ([^"]+)"')
            if code:sub(1, 2) == "((" and path then
                js.seq = js.seq + 1
                local slot = js.seq
                local src = assert(SOURCES[path], "假源没这条成员: " .. path)
                local function fill(v) js.slots[slot] = enc({ value = v }) end
                js.slots[slot] = '{"__pending":true}'
                if src.decl then
                    fill(src.decl)
                    return true, tostring(slot)
                end
                -- 源里那一句 await sendMessage(...)：真桥 + 真 netclient
                local ret = host:_bridgeHandler(enc(src.http))
                local id = tonumber(ret:match('"__pending"%s*:%s*(%d+)'))
                if id then
                    js.id2slot[id] = slot              -- 当拍没结果 → 交给泵
                else
                    fill(src.then_body(dec(dec(ret).body)))   -- 同步：当场有值
                end
                return true, tostring(slot)
            end
            local n = tonumber(code:match("^globalThis%.__ezv_ret%[(%d+)%]$"))
            if n then return true, js.slots[n] end
            if code:find("delete", 1, true) then
                local d = tonumber(code:match("%[(%d+)%]"))
                js.cleared[d] = true
                js.slots[d] = nil
                return true, "true"
            end
            local id, lit = code:match('^__ezv_resolve%((%d+), "(.*)", null%)$')
            if id then
                local slot = js.id2slot[tonumber(id)]
                -- 迟到的兑现：那一格早就没人等了（槽位化的意义，这里只证不炸）
                if not slot then return true, "undefined" end
                local resp = dec(TlsFake.jsUnescape(lit))
                js.slots[slot] = enc({
                    value = SOURCES["search.load"].then_body(dec(resp.body)) })
                js.resolved = js.resolved + 1
                return true, "undefined"
            end
            return true, "0"
        end

        local b = setmetatable({}, { __index = Browser })
        b.engine = host
        b.json = json
        b._registered = setmetatable({}, { __index = function() return "jsk" end })
        b.messages = {}
        b.infoMessage = function(text) table.insert(b.messages, text) end
        box.b = b

        --- 一拍：推进时钟（假 socket 的 gettime 就是 env.t），再跑最早排入的回调
        box.tick = function()
            env.t = env.t + 0.05
            local t = table.remove(ui.sched, 1)
            if not t then return nil end
            t.fn()
            return true
        end
        box.menus = function()
            local out = {}
            for _, w in ipairs(ui.shown) do
                if w.__menu then out[#out + 1] = w end
            end
            return out
        end
        --- 等到**新增**的菜单出现为止；返回跑掉的拍数（没等到返回用尽的 max）
        box.wait = function(max_ticks)
            local base = #box.menus()
            local n = 0
            while #box.menus() == base and n < max_ticks and box.tick() do
                n = n + 1
            end
            return n
        end
        fn(box)
    end)
    return box
end

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_true(label, v)
    assert(v, label .. ": 期望真值，得到 " .. tostring(v))
end

local tests = {}

--- 搜索：菜单必须等假 socket 的响应字节到齐才出现，且只出现一次。
--- 这一条同时是 M3 的存在理由——点下搜索的那个栈帧里没有一次阻塞网络调用。
function tests.search_menu_appears_only_when_the_response_bytes_land()
    local box = withCase(true, function(b)
        b.b:showResults("src", "search.load", { "kw" }, 1, "搜索")
        b.frame = { menus = #b.menus(), sched = #ui.sched,
            slice = ui.sched[1] and ui.sched[1].sec,
            inflight = b.br:httpInflight(), calls = #b.fake._calls,
            polls = b.env.polls, poll_timeout = b.env.poll_timeout }
        b.ticks = b.wait(20)
        local m = b.menus()
        local it = m[1] and m[1].args.item_table
        b.after = { menus = #m, it = it, inflight = b.br:httpInflight(),
            cleared = b.js.cleared[1], slot = b.js.slots[1], warns = #sink.warns }
        b.tick()
        b.extra = #b.menus()
    end)
    assert_eq("开局一个菜单都不建", 0, box.frame.menus)
    assert_eq("开局排了一拍（剩下的交给节拍）", 1, box.frame.sched)
    assert_eq("节拍 = 0.05s（与忙时泵周期同值）", 0.05, box.frame.slice)
    assert_eq("请求已交给桥", 1, box.frame.calls)
    assert_eq("在飞 = 1", 1, box.frame.inflight)
    -- 非阻塞的证据：那一拍确实轮询过 socket，但 timeout 恒为 0（M0 钉死的形状）
    assert_true("开局就把连接挂起（polls>=1）", box.frame.polls >= 1)
    assert_eq("轮询超时 = 0，绝不原地等", 0, box.frame.poll_timeout)
    assert_true("跨拍了才出界面: ticks=" .. tostring(box.ticks), box.ticks >= 1)
    assert_true("而且不是无限等: ticks=" .. tostring(box.ticks), box.ticks <= 12)
    assert_eq("兑现恰好一次", 1, box.js.resolved)
    assert_eq("菜单只建一次", 1, box.after.menus)
    assert_eq("兑现后不再排队", 0, #ui.sched)
    assert_eq("多跑一拍不会盖第二个菜单", 1, box.extra)
    local it = box.after.it
    assert_true("菜单项建出来了", it ~= nil)
    assert_eq("1 条结果 + 下一页", 2, #it)
    -- 关键证据：标题来自假 socket 的响应体（bridge→resolve→槽→解码 一路过来）
    assert_eq("标题来自响应字节", "你好", it[1].text)
    assert_eq("下一页在最后一页之前", true, it[2].nextPage)
    assert_eq("兑现之后不再在飞", 0, box.after.inflight)
    assert_eq("用完清槽", true, box.after.cleared)
    assert_eq("槽里不留东西", nil, box.after.slot)
    assert_eq("全程零 warn", 0, box.after.warns)
    return true
end

--- 开关关着（= 今天的默认配置）：步进器根本不参与，菜单在**同一个栈帧**里出现，
--- 内容与时钟无关。这就是「零用户可见变化」的证据，不是口头承诺。
function tests.switch_off_shows_the_menu_in_the_same_frame()
    local box = withCase(false, function(b)
        b.b:showResults("src", "search.load", { "kw" }, 1, "搜索")
        local m = b.menus()
        b.seen = { menus = #m, sched = #ui.sched, polls = b.env.polls,
            it = m[1] and m[1].args.item_table, warns = #sink.warns }
    end)
    assert_eq("当场就建菜单", 1, box.seen.menus)
    assert_eq("一拍都不排", 0, box.seen.sched)
    assert_eq("同步路径不轮询（一问一答阻塞式）", 0, box.seen.polls)
    local it = box.seen.it
    assert_true("菜单项建出来了", it ~= nil)
    assert_eq("内容与异步路径同形", "你好", it[1].text)
    assert_eq("下一页照常", true, it[2].nextPage)
    assert_eq("零 warn", 0, box.seen.warns)
    return true
end

--- 声明类成员（category / explore 是普通属性）不该因为「开了异步」就跨拍：
--- 源主页必须当场建好。这条挡住「把所有 await 一律改异步等待」的过度改造。
function tests.declaration_reads_never_cross_a_tick()
    local box = withCase(true, function(b)
        b.b:showSourceHome("src")
        local m = b.menus()
        b.seen = { menus = #m, sched = #ui.sched, calls = #b.fake._calls,
            it = m[1] and m[1].args.item_table, seq = b.js.seq,
            warns = #sink.warns }
    end)
    assert_eq("两次 await（category + explore）", 2, box.seen.seq)
    assert_eq("菜单当场建好", 1, box.seen.menus)
    assert_eq("一拍都不排", 0, box.seen.sched)
    assert_eq("声明读取不联网", 0, box.seen.calls)
    local it = box.seen.it
    assert_true("菜单建出来了", it ~= nil)
    assert_eq("搜索 + 1 分类 + 1 发现", 3, #it)
    assert_eq("分类文字来自声明", "国漫", it[2].text)
    assert_eq("零 warn", 0, box.seen.warns)
    return true
end

--- 桥 abort（泵死掉 / 引擎拆桥）之后：socket 当场释放、等待侧不会凭空拿到结果，
--- 并且必须在下一拍自己说清楚「引擎已停止」——不能空转到 60 秒超时。
function tests.abort_releases_the_socket_and_the_wait_reports_itself()
    local box = withCase(true, function(b)
        b.b:showResults("src", "search.load", { "kw" }, 1, "搜索")
        -- 引擎拆桥就发生在这一拍（真机是 main.lua 的错误分支 / JsHost:dispose）：
        -- 此刻请求一定还在飞，取消要当场把 fd 收回来
        b.cancelled = b.br:abortHttp()
        b.closed = TlsFake.logFind(b.log, "%.close") ~= nil
        b.host.bridge.async_http = false       -- 复刻 main.lua 泵死掉时的拆桥
        b.tick()
        b.seen = { menus = #b.menus(), sched = #ui.sched, msg = b.b.messages[1],
            cleared = b.js.cleared[1], resolved = b.js.resolved,
            inflight = b.br:httpInflight() }
    end)
    assert_eq("取消掉一条在飞请求", 1, box.cancelled)
    assert_true("fd 当场关掉，不等对端超时", box.closed)
    assert_eq("取消之后没有投递过任何东西", 0, box.seen.resolved)
    assert_eq("取消之后不在飞", 0, box.seen.inflight)
    assert_eq("没结果就不建菜单", 0, box.seen.menus)
    assert_true("用户看到的是停等说明: " .. tostring(box.seen.msg),
        box.seen.msg ~= nil and box.seen.msg:find("引擎已停止", 1, true) ~= nil)
    assert_eq("停等后不再排队", 0, box.seen.sched)
    assert_eq("放弃也要清槽", true, box.seen.cleared)
    return true
end

--- 连跑两笔搜索（搜索→翻页、失败后重试的真机形态）：各占一格、各自兑现，
--- 后一笔不必重走前面那笔的等待。假栈每次事务结束都 close 连接（tlsfake 的
--- `open_with` 形状），所以这里**不**断言隧道复用——复用是 test_netclient 里
--- 「异步建隧同步复用」那条钉的，别把桩的简化当成被测对象。
function tests.two_searches_each_get_their_own_slot()
    local box = withCase(true, function(b)
        b.ticks = {}
        for round = 1, 2 do
            b.b:showResults("src", "search.load", { "kw" .. round }, 1, "搜索")
            b.ticks[round] = b.wait(20)
        end
        local m = b.menus()
        b.seen = { menus = #m, seq = b.js.seq, resolved = b.js.resolved,
            titles = { m[1].args.item_table[1].text, m[2].args.item_table[1].text },
            sched = #ui.sched, warns = #sink.warns, slots = {} }
        for k, v in pairs(b.js.slots) do b.seen.slots[#b.seen.slots + 1] = k .. v end
    end)
    assert_eq("两笔 = 两个槽", 2, box.seen.seq)
    assert_eq("两笔都兑现", 2, box.seen.resolved)
    assert_eq("菜单两个（翻页是压栈，各一次）", 2, box.seen.menus)
    assert_eq("第一笔的标题来自响应体", "你好", box.seen.titles[1])
    assert_eq("第二笔同样（各自的字节各自的槽）", "你好", box.seen.titles[2])
    assert_true("第二笔更快: " .. tostring(box.ticks[2]) .. " < "
        .. tostring(box.ticks[1]), box.ticks[2] < box.ticks[1])
    assert_eq("两个槽都被清掉，不留常驻垃圾", 0, #box.seen.slots)
    assert_eq("收尾不再排队", 0, box.seen.sched)
    assert_eq("零 warn", 0, box.seen.warns)
    return true
end

return tests
