-- unit test: browser.lua 的跨拍 await 步进器（r10 M3）
-- 冻结的根因：源的 async 方法在**同一拍里**拿不到响应（桥开了 async_http
-- 只会先给一个 __pending），旧的 `_awaitSource` eval 一次就要值，于是只能
-- 报「异步任务未兑现」或者由 netclient 原地阻塞到超时。M3 把它改成
-- 「起一次 → 每拍泵一次 → 到值再回调」，这里钉住步进器自身的契约。
--
-- 假引擎只模拟三件事：AWAIT_SNIPPET 返回槽号、读槽、泵。真 socket / 真桥
-- 那条链在 tests/test_async_e2e.lua（tlsfake 全栈）里证，本地没有 luasocket。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = { sched = {}, shown = {}, warns = {} }

local function recWarn(msg, ...)
    local line = tostring(msg)
    for i = 1, select("#", ...) do
        line = line .. " " .. tostring((select(i, ...)))
    end
    table.insert(fake.warns, line)
end

stub("logger", { warn = recWarn, info = noop, err = noop, dbg = noop,
    verbose = noop, setLevel = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = noop,
    setDirty = noop,
    scheduleIn = function(_, sec, fn)
        table.insert(fake.sched, { sec = sec, fn = fn })
    end,
})
stub("ui/widget/menu", {
    new = function(_, args) return { __menu = true, args = args } end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })

-- 本地测试 VM 里没有 `json`（KOReader 侧是 C 模块），所以从 Browser 注入解码器
-- （`b.json`）。只登记本文件用到的夹具；收到没登记的字符串就 error —— 静默
-- 返回 nil 会把「解不出来」伪装成「还没兑现」，那正好是本次要改的那条判定。
local DECODED = {
    ['{"value":7}'] = { value = 7 },
    ['{"value":null}'] = {},
    ['{"__pending":true}'] = { __pending = true },
    ['{"__error":"boom"}'] = { __error = "boom" },
    ['{"value":"late-A"}'] = { value = "late-A" },
    ['{"value":"real-B"}'] = { value = "real-B" },
    ['{"value":{"chapters":{"1":"第1话"}}}'] = {
        value = { chapters = { ["1"] = "第1话" } },
    },
    -- showSourceHome 读的两条声明（Venera 的扁平 categories 形状）
    ['{"value":{"categories":["国漫","日漫"],"categoryParams":["gm","rm"]}}'] = {
        value = {
            categories = { "国漫", "日漫" },
            categoryParams = { "gm", "rm" },
        },
    },
    ['{"value":[{"title":"排行","type":"comicList"}]}'] = {
        value = { { title = "排行", type = "comicList" } },
    },
    -- 结果列表 / 详情 / 页表（调用点跨拍用例用）
    ['{"value":{"comics":[{"title":"甲","id":"c1"}],"maxPage":3}}'] = {
        value = { comics = { { title = "甲", id = "c1" } }, maxPage = 3 },
    },
    ['{"value":{"title":"书","chapters":{"1":"第1话","2":"第2话"}}}'] = {
        value = { title = "书", chapters = { ["1"] = "第1话", ["2"] = "第2话" } },
    },
    ['{"value":["u1","u2"]}'] = { value = { "u1", "u2" } },
}
local fakeJson = {
    decode = function(s)
        local v = DECODED[s]
        if not v then
            error("json 桩收到没登记的夹具: " .. tostring(s))
        end
        return v
    end,
}

package.loaded["browser"] = nil
local Browser = require("browser")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got "
        .. tostring(actual))
end

local function assert_true(label, v)
    assert(v, label .. ": 期望真值，得到 " .. tostring(v))
end

--- 假引擎。opts.start(seq, code) 决定这次 await 开局写进槽里的字符串
--- （省略即 `{"__pending":true}`，也就是当拍没结果）；opts.resolve_at[pump 序号]
--- = {槽号 = 字符串} 表示「第 N 次泵之后这些槽变成这个值」。
local function makeEngine(opts)
    opts = opts or {}
    local e = {
        pumps = 0, slots = {}, cleared = {}, evals = {}, seq = 0,
        bridge = { async_http = opts.async_http ~= false },
    }
    function e:eval(code)
        table.insert(self.evals, code)
        local n = tonumber(code:match("^globalThis%.__ezv_ret%[(%d+)%]$"))
        if n then return true, self.slots[n] end
        if code:find("delete", 1, true) then
            local d = tonumber(code:match("%[(%d+)%]"))
            self.cleared[d] = true
            self.slots[d] = nil
            return true, "true"
        end
        if code:sub(1, 2) == "((" then          -- AWAIT_SNIPPET 的 IIFE
            self.seq = self.seq + 1
            local s = self.seq
            self.slots[s] = (opts.start and opts.start(self.seq, code))
                or '{"__pending":true}'
            return true, tostring(s)
        end
        return true, "undefined"
    end
    function e:pump()
        self.pumps = self.pumps + 1
        local set = opts.resolve_at and opts.resolve_at[self.pumps]
        if set then
            for k, v in pairs(set) do self.slots[k] = v end
        end
        return 0, true
    end
    return e
end

local function makeBrowser(e)
    local b = setmetatable({}, { __index = Browser })
    b.engine = e
    b.json = fakeJson
    b._registered = setmetatable({}, { __index = function() return "jsk" end })
    b.messages = {}
    b.infoMessage = function(text) table.insert(b.messages, text) end
    return b
end

--- 跑 n 拍；每拍取最早排入的回调，步进器自己会再排下一拍
local function runTicks(n)
    for _ = 1, n do
        local t = table.remove(fake.sched, 1)
        if not t then return false end
        t.fn()
    end
    return true
end

--- 只数菜单，忽略 `progressMessage` 的自消失 toast（两者都走 UIManager:show）
local function shownMenus()
    local out = {}
    for _, w in ipairs(fake.shown) do
        if w.__menu then out[#out + 1] = w end
    end
    return out
end

local function reset()
    fake.sched, fake.shown, fake.warns = {}, {}, {}
end

local tests = {}

-- ---------- 开关关闭：与今天逐字节一致 ----------

--- 桥没开 async_http ⇒ 必须整个走同步 `_awaitSource`，一拍都不排。
--- 这是 M3 的「零用户可见变化」保证：默认配置下步进器根本不参与。
function tests.switch_off_delegates_to_sync_api()
    reset()
    local e = makeEngine{ async_http = false }
    local b = makeBrowser(e)
    local hits, got
    b._awaitSource = function(_, key, path)
        hits = hits and hits + 1 or 1
        assert_eq("委托 path 原样", "comic.loadInfo", path)
        assert_eq("委托 key 原样", "src", key)
        return { ok = true }
    end
    b:_awaitSourceAsync("src", "comic.loadInfo", nil,
        function(v) got = v end)
    assert_eq("同步实现恰被调一次", 1, hits)
    assert_true("结果同步就位", got and got.ok)
    assert_eq("开关关闭不排节拍", 0, #fake.sched)
    assert_eq("开关关闭不泵", 0, e.pumps)
    return true
end

--- 引擎根本没有 bridge（老桩、纯 Lua 环境、单测替身）也一样走同步。
function tests.engine_without_bridge_stays_sync()
    reset()
    local b = makeBrowser({ eval = noop })
    local called
    b._awaitSource = function() called = true return "V" end
    local got
    b:_awaitSourceAsync("src", "category", nil, function(v) got = v end)
    assert_eq("走的是同步 API", "V", got)
    assert_true("同步实现被调用", called)
    return true
end

--- 同步 API 遇到未兑现仍然是**原来那句**错误（老调用点、未转换的路径靠它）
function tests.sync_pending_keeps_the_original_message()
    reset()
    local e = makeEngine{}
    local b = makeBrowser(e)
    local v, err = b:_awaitSource("src", "search.load", "[]")
    assert_eq("未兑现没有值", nil, v)
    assert_eq("文案与 r10 M2 之前一致",
        "异步任务未兑现（源内 promise 悬挂或泵上限截断）", err)
    assert_eq("同步路径一拍不排", 0, #fake.sched)
    return true
end

-- ---------- 跨拍步进本体 ----------

--- 值当拍就在槽里（声明属性、同步源方法）⇒ on_done 在同一个栈帧跑完，
--- 不排节拍、不泵。所有调用点因此可以在不改行为的前提下换成 CPS。
function tests.ready_value_callbacks_inline_without_a_tick()
    reset()
    local e = makeEngine{ start = function() return '{"value":7}' end }
    local b = makeBrowser(e)
    local done, val
    b:_awaitSourceAsync("src", "category", nil, function(v, err)
        done = true
        val = v
        assert_eq("就绪时没有错误", nil, err)
    end)
    assert_true("同帧回调", done)
    assert_eq("值已解出", 7, val)
    assert_eq("就绪不排节拍", 0, #fake.sched)
    assert_eq("用完清槽", true, e.cleared[1])
    return true
end

--- 未兑现：排一拍、每拍恰好泵一次，第三拍出值就立刻收尾并清槽。
--- 「一拍一次泵」是 ANR 预算的落点（M0：一次等待 = 一个周期）。
function tests.pending_resolves_after_three_ticks_with_one_pump_each()
    reset()
    local e = makeEngine{
        resolve_at = { [3] = { [1] = '{"value":7}' } },
    }
    local b = makeBrowser(e)
    local hits, val
    b:_awaitSourceAsync("src", "comic.loadInfo", '["id"]', function(v)
        hits = (hits or 0) + 1
        val = v
    end)
    assert_eq("开局没结果不回调", nil, hits)
    assert_eq("只排了一拍", 1, #fake.sched)
    assert_eq("节拍 = 0.05s", 0.05, fake.sched[1].sec)
    runTicks(2)
    assert_eq("两拍后仍未兑现", nil, hits)
    assert_eq("每拍一次泵", 2, e.pumps)
    assert_eq("还在排下一拍", 1, #fake.sched)
    runTicks(1)
    assert_eq("第三拍兑现", 1, hits)
    assert_eq("兑现的值", 7, val)
    assert_eq("泵次数 = 步进次数", 3, e.pumps)
    assert_eq("兑现后不再排队", 0, #fake.sched)
    assert_eq("兑现后清槽", true, e.cleared[1])
    return true
end

--- 【本次修的缺陷】迟到结果不许踩掉下一次 await：旧实现是单槽全局，A 超时
--- 放弃后 A 的源继续跑完并把结果写进全局，正好落在 B 正在读的那一格 ⇒ B 拿到
--- A 的数据（而且形状完全合法，日志里看不出来）。槽位化之后各写各的格子。
function tests.late_result_cannot_poison_the_next_await()
    reset()
    local e = makeEngine{
        resolve_at = { [2] = {
            [1] = '{"value":"late-A"}',      -- A 早已超时放弃
            [2] = '{"value":"real-B"}',      -- B 的正主
        } },
    }
    local b = makeBrowser(e)
    local a_val, a_err, b_val, b_err
    b.AWAIT_TIMEOUT_SEC = 0                   -- A 第一拍就放弃
    b:_awaitSourceAsync("src", "search.load", '["a"]',
        function(v, err) a_val, a_err = v, err end)
    runTicks(1)
    assert_eq("A 没有值", nil, a_val)
    assert_true("A 报超时", a_err and a_err:find("超时", 1, true) ~= nil)
    assert_eq("A 的槽被清", true, e.cleared[1])
    assert_eq("A 超时后不再排队", 0, #fake.sched)
    assert_eq("A 超时有 warn（降级要留痕）", 1, #fake.warns)

    b.AWAIT_TIMEOUT_SEC = 60
    b:_awaitSourceAsync("src", "categoryComics.load", '["b"]',
        function(v, err) b_val, b_err = v, err end)
    runTicks(1)
    assert_eq("B 拿到自己那一格", "real-B", b_val)
    assert_eq("B 没有错误", nil, b_err)
    assert_eq("A 的回调没被迟到结果再叫一次", 1, #fake.warns)
    -- B 读的必须是 [2]，不是 [1]
    local saw_own_slot = false
    for _, code in ipairs(e.evals) do
        if code == "globalThis.__ezv_ret[2]" then saw_own_slot = true end
    end
    assert_true("B 只读自己的槽", saw_own_slot)
    return true
end

--- 源自己抛错（__error）是**终值**，不许被当成「还没好」而一直等。
function tests.source_error_is_final_not_retried()
    reset()
    local e = makeEngine{ start = function() return '{"__error":"boom"}' end }
    local b = makeBrowser(e)
    local val, err, hits
    b:_awaitSourceAsync("src", "comic.loadEp", "[]", function(v, v2)
        hits = 1
        val, err = v, v2
    end)
    assert_eq("错误也当场回调", 1, hits)
    assert_eq("没有值", nil, val)
    assert_eq("源原文照抄", "boom", err)
    assert_eq("终值不排节拍", 0, #fake.sched)
    assert_eq("终值不泵", 0, e.pumps)
    return true
end

--- 合法的空结果（源 return undefined ⇒ `{"value":null}`）必须是 **ok**，
--- 不能掉进错误分支：调用方靠 err==nil 区分「没有内容」和「读取失败」。
function tests.null_value_is_ok_with_no_error()
    reset()
    local e = makeEngine{ start = function() return '{"value":null}' end }
    local b = makeBrowser(e)
    local val, err, hits
    b:_awaitSourceAsync("src", "category", nil, function(v, e2)
        hits = 1
        val, err = v, e2
    end)
    assert_eq("回调一次", 1, hits)
    assert_eq("值为 nil", nil, val)
    assert_eq("没有错误", nil, err)
    return true
end

--- 泵中途死掉（main.lua 的错误分支会置 _pump_running=false，桥也会被拆）：
--- 步进器当场说清楚，不能空转到 60 秒。
function tests.engine_lost_mid_flight_stops_waiting()
    reset()
    local e = makeEngine{}
    local b = makeBrowser(e)
    local err
    b:_awaitSourceAsync("src", "comic.loadInfo", "[]",
        function(_, e2) err = e2 end)
    e.bridge.async_http = false
    runTicks(1)
    assert_eq("明确报引擎已停", "引擎已停止，等待中断", err)
    assert_eq("停等后不再排队", 0, #fake.sched)
    return true
end

--- 排不进节拍（没有调度器的环境）⇒ 立刻按未兑现报错，别留下永挂的等待。
function tests.scheduler_failure_aborts_the_wait()
    reset()
    local UM = package.loaded["ui/uimanager"]
    local old = UM.scheduleIn
    UM.scheduleIn = function() error("no scheduler") end
    local e = makeEngine{}
    local b = makeBrowser(e)
    local val, err
    b:_awaitSourceAsync("src", "search.load", "[]", function(v, e2)
        val, err = v, e2
    end)
    UM.scheduleIn = old
    assert_eq("没有值", nil, val)
    assert_eq("报无法排队", "无法排入节拍，异步等待中止", err)
    assert_eq("失败也要清槽", true, e.cleared[1])
    return true
end

--- 续体里的 Lua 错误绝不能冒到 KOReader 主循环（= 整应用闪退，R9 的教训）。
function tests.continuation_error_is_guarded()
    reset()
    local e = makeEngine{ start = function() return '{"value":7}' end }
    local b = makeBrowser(e)
    local ok = pcall(function()
        b:_awaitSourceAsync("src", "category", nil,
            function() error("续体里的 bug") end)
    end)
    assert_true("步进器没有把错误抛出去", ok)
    assert_eq("用户可见提示 1 条", 1, #b.messages)
    assert_true("提示里带原因",
        b.messages[1]:find("续体里的 bug", 1, true) ~= nil)
    assert_eq("错误落了 warn", 1, #fake.warns)
    return true
end

-- ---------- 声明读取落到菜单（CPS 调用点） ----------

--- 分类/发现各自 await、菜单只建一次，所以两条计数必须落在**同一个作用域**。
--- 搬进闭包时若顺手写个 `local n_exp = 0`，计数就长在闭包里：发现项照常进
--- 菜单，但 `n_cat==0 and n_exp==0` 仍然成立 → 明明有内容却多出一行「该源未
--- 声明分类/发现项」。这里用「只有 explore 的源」把那条占位行钉死。
function tests.explore_only_source_gets_no_placeholder()
    reset()
    local e = makeEngine{ start = function(seq)
        if seq == 1 then return '{"value":null}' end   -- 无 category 声明
        return '{"value":[{"title":"排行","type":"comicList"}]}'
    end }
    local b = makeBrowser(e)
    b:showSourceHome("src")
    assert_eq("同步声明不跨拍", 0, #fake.sched)
    assert_eq("菜单恰好建一次", 1, #fake.shown)
    local it = fake.shown[1].args.item_table
    assert_eq("只有搜索 + 1 个发现项", 2, #it)
    assert_eq("没有占位行", nil, it[2].info_only)
    assert_true("发现项能下钻", it[2].explore_path ~= nil)
    return true
end

--- 分类计数同样要在续体里累加（顺带钉住 params 平铺形状没在搬动中丢掉）。
function tests.category_items_are_counted_inside_the_continuation()
    reset()
    local e = makeEngine{ start = function(seq)
        if seq == 1 then
            return '{"value":{"categories":["国漫","日漫"],"categoryParams":["gm","rm"]}}'
        end
        return '{"value":null}'
    end }
    local b = makeBrowser(e)
    b:showSourceHome("src")
    local it = fake.shown[1].args.item_table
    assert_eq("搜索 + 2 个分类", 3, #it)
    assert_eq("首个分类标题", "国漫", it[2].text)
    assert_eq("分类带 param", "gm", it[2].param)
    assert_eq("分类走 category 而非搜索", false, it[2].is_search_item)
    return true
end

--- 两条声明都当拍没兑现：菜单必须等两条**都到齐**才建、且只建一次。
--- （建两遍 = 真机上盖栈，返回箭头要按两次。）
function tests.home_waits_for_both_declarations_and_builds_once()
    reset()
    local e = makeEngine{
        resolve_at = {
            [2] = { [1] = '{"value":{"categories":["国漫","日漫"],"categoryParams":["gm","rm"]}}' },
            [4] = { [2] = '{"value":[{"title":"排行","type":"comicList"}]}' },
        },
    }
    local b = makeBrowser(e)
    b:showSourceHome("src")
    assert_eq("开局不建菜单", 0, #fake.shown)
    runTicks(3)
    assert_eq("只到一条时不建菜单", 0, #fake.shown)
    runTicks(1)
    assert_eq("到齐后只建一次", 1, #fake.shown)
    local it = fake.shown[1].args.item_table
    assert_eq("搜索 + 2 分类 + 1 发现", 4, #it)
    assert_eq("泵次数 = 步进次数", 4, e.pumps)
    assert_eq("收尾后不再排队", 0, #fake.sched)
    assert_eq("两个槽都清掉", 2, (e.cleared[1] and 1 or 0) + (e.cleared[2] and 1 or 0))
    return true
end

-- ---------- 调用点跨拍：界面晚一拍出现，而且只出现一次 ----------

--- 结果列表：`showResults` 签名不变（调用方都不取返回值），所以跨拍只允许
--- 表现在「菜单晚一拍、且只有一次」。多一次就是菜单盖菜单，返回键要点两下。
function tests.results_menu_appears_one_tick_after_the_load_resolves()
    reset()
    local e = makeEngine{
        resolve_at = { [2] = { [1] =
            '{"value":{"comics":[{"title":"甲","id":"c1"}],"maxPage":3}}' } },
    }
    local b = makeBrowser(e)
    b:showResults("src", "search.load", { "kw", {} }, 1, "搜索")
    assert_eq("未兑现前不建菜单", 0, #shownMenus())
    runTicks(1)
    assert_eq("第一拍还没有", 0, #shownMenus())
    runTicks(1)
    assert_eq("兑现后只建一次", 1, #shownMenus())
    local it = shownMenus()[1].args.item_table
    assert_eq("1 条结果 + 下一页", 2, #it)
    assert_eq("下一页在最后一页之前", true, it[2].nextPage)
    return true
end

--- 详情：章节表、下载入口、收藏行都必须等同一次 loadInfo。
function tests.detail_menu_waits_for_loadinfo()
    reset()
    local e = makeEngine{
        resolve_at = { [1] = { [1] =
            '{"value":{"title":"书","chapters":{"1":"第1话","2":"第2话"}}}' } },
    }
    local b = makeBrowser(e)
    b:showDetail("src", { id = "c1", title = "书" })
    assert_eq("开局不建菜单", 0, #shownMenus())
    runTicks(1)
    local it = shownMenus()[1].args.item_table
    assert_eq("只建一次", 1, #shownMenus())
    -- 下载 + 2 章 + 书名行（library 未注入 ⇒ 没有收藏行）
    assert_eq("行数", 4, #it)
    assert_true("章节已排序", it[2].text ~= it[3].text)
    return true
end

--- 阅读器：600 行阅读器闭包与页表来源无关，所以按参数交接给 `_openReader`。
--- 页表没到手之前**绝不能**开阅读器（开了就是空 images 表 → 真机白屏）。
function tests.reader_opens_only_after_the_page_table_lands()
    reset()
    local e = makeEngine{
        resolve_at = { [2] = { [1] = '{"value":["u1","u2"]}' } },
    }
    local b = makeBrowser(e)
    b._hasMember = function() return false end      -- 该源无 onImageLoad
    b.getDownloader = function()
        return { manifestOf = function() return nil end }
    end
    local opened = {}
    -- 位置与 Browser:_openReader(key, comicId, epId, title, chapterTitle,
    -- dl, man, images, base) 对齐（本地 LuaJIT 没有 table.pack）
    b._openReader = function(_, _k, _c, _e, _t, _ct, _dl, man, images)
        opened[#opened + 1] = { images = images, man = man }
    end
    b:showReader("src", "c1", "7", "书", "第7话")
    assert_eq("页表没到就不开", 0, #opened)
    runTicks(1)
    assert_eq("还在等就不开", 0, #opened)
    runTicks(1)
    assert_eq("到齐后只开一次", 1, #opened)
    assert_eq("交进去的是页表", 2, #(opened[1].images or {}))
    assert_eq("联网取的不是离线清单", nil, opened[1].man)
    return true
end

--- 已下载的章节必须仍然**当场**打开：离线路径一个节拍都不许排
--- （排了就等于把「秒开」变成「等一下」，是回归不是改进）。
function tests.offline_chapter_opens_without_a_single_tick()
    reset()
    local e = makeEngine{}
    local b = makeBrowser(e)
    b._hasMember = function() return false end
    b.getDownloader = function()
        return { manifestOf = function()
            return { dir = "/d", pages = { { file = "1.jpg" } }, bytes = 10 }
        end }
    end
    local opened = {}
    b._openReader = function(_, _k, _c, _e, _t, _ct, _dl, man, images)
        opened[#opened + 1] = { images = images, man = man }
    end
    b:showReader("src", "c1", "7", "书", "第7话")
    assert_eq("当场开一次", 1, #opened)
    assert_eq("没有源调用", 0, e.seq)
    assert_eq("一拍都不排", 0, #fake.sched)
    assert_eq("离线清单传进去了", "/d", (opened[1].man or {}).dir)
    assert_eq("页表来自本地文件", "/d/1.jpg", (opened[1].images or {})[1].local_file)
    return true
end

--- 下载：页表跨拍时 `_startChapterDownload` 也只能被叫一次。
function tests.chapter_download_starts_once_when_pages_land()
    reset()
    local e = makeEngine{
        resolve_at = { [1] = { [1] = '{"value":["u1","u2"]}' } },
    }
    local b = makeBrowser(e)
    b._hasMember = function() return false end
    b.getDownloader = function()
        return { manifestOf = function() return nil end }
    end
    local started = {}
    b._startChapterDownload = function(_, dl, key, comicId, epId,
            bookTitle, chapterTitle, images, base, err)
        started[#started + 1] = { images = images, err = err, key = key }
        return true, { pages = images }
    end
    local ok, info = b:downloadChapter("src", "c1", "7", "书", "第7话")
    assert_eq("页表没到就不开工", 0, #started)
    assert_eq("跨拍时同步返回 nil", nil, ok)
    assert_eq("也没有第二返回值", nil, info)
    runTicks(1)
    assert_eq("到齐后开工一次", 1, #started)
    assert_eq("交进去的是页表", 2, #(started[1].images or {}))
    return true
end

-- ---------- JS 侧契约（Lua 能检的那一半） ----------

--- snippet 必须①按槽写、②把槽号 return 出来，否则 Lua 侧只会拿到 nil ⇒
--- "no result"，所有源调用一起哑掉，而错误在 JS 里、Lua 看不见。
function tests.snippet_allocates_and_returns_its_own_slot()
    reset()
    local e = makeEngine{}
    local b = makeBrowser(e)
    b:_awaitSource("src", "category")
    local code = e.evals[1]
    assert_true("写的是自己那一格",
        code:find("__ezv_ret[slot] = j", 1, true) ~= nil)
    assert_true("把槽号返回给 Lua", code:find("return slot;", 1, true) ~= nil)
    assert_true("槽号单调递增（每次 await 换一格）",
        code:find("__ezv_seq", 1, true) ~= nil)
    assert_true("未兑现标记仍是同一个形状",
        code:find('{"__pending":true}', 1, true) ~= nil)
    -- 两次 await 用两个槽，读的是各自的格子
    b:_awaitSource("src", "explore")
    assert_eq("第二次读到自己的槽",
        "globalThis.__ezv_ret[2]", e.evals[#e.evals - 1])
    return true
end

return tests
