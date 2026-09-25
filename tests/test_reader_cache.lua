-- unit test: 章节阅读器的返回栈 + 图片字节缓存/预取（真机反馈
-- "只有关闭，无返回按钮" 与 "加载慢、内存要管"）
-- browser.lua 顶层 require KOReader 前端模块，测试环境没有 → preload 桩。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = {
    shown = {},
    closed = {},
    scheduled = {},        -- 待执行的 scheduleIn 任务
    viewer_args = nil,
}

stub("logger", { warn = noop, info = noop, err = noop, dbg = noop, verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = function(_, w) table.insert(fake.closed, w) end,
    -- 带 delay 记录：scheduleIn 同时被预取（0.2s）和阅读器的诊断内存探针
    -- （2s 自续节拍）使用，断言只针对预取队列，互不干扰。
    scheduleIn = function(_, sec, fn)
        table.insert(fake.scheduled, { sec = sec, fn = fn })
    end,
})
stub("ui/widget/menu", {
    new = function(_, args) return { __menu = true, args = args } end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })
stub("ui/widget/imageviewer", {
    new = function(_, args)
        fake.viewer_args = args
        -- 真机 ImageViewer:init 在取第一页的同时把 _images_list_cur 置 1
        -- （imageviewer.lua:145-149），延迟首屏的补画要拿它比对当前页。
        local v = { __viewer = true, free = noop, _images_list_cur = 1,
                    updates = 0 }
        function v:update()
            self.updates = self.updates + 1
            fake.viewer_updates = self.updates
        end
        return v
    end,
})
local decoded = 0
-- 真机 BB 是 FFI cdata，带 stride/h（browser.lua 按 stride*h 记解码内存预算）
stub("ui/renderimage", {
    renderImageData = function(_, data)
        decoded = decoded + 1
        return { __bb = true, data = data, free = noop, stride = 600, h = 800 }
    end,
})
stub("ffi/blitbuffer", {
    TYPE_BB8 = 1, COLOR_GRAY_E = 233, COLOR_WHITE = 255,
    new = function() return { __bb = true, fill = noop, free = noop } end,
})
-- KOReader 的 json 模块在测试环境不存在；浏览器只用它解 eval 结果，
-- 本测试全部走 _awaitSource 桩，不会触及。
package.loaded["browser"] = nil
local Browser = require("browser")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 造一个只关心阅读器的 Browser：netclient 记录每个 URL 被取了几次
local function makeReader(images, opts)
    opts = opts or {}
    local net = { hits = {}, opts = {}, total = 0 }
    net.request = function(_, o)
        net.total = net.total + 1
        net.hits[o.url] = (net.hits[o.url] or 0) + 1
        net.opts[o.url] = o
        if opts.fail_urls and opts.fail_urls[o.url] then
            return { status = 500, headers = {}, body = nil }
        end
        return { status = 200,
                 headers = { ["content-length"] = "12" },
                 body = "IMG:" .. o.url }
    end
    fake.shown, fake.closed, fake.scheduled = {}, {}, {}
    fake.viewer_args = nil
    local b = Browser.new{ infoMessage = noop, netclient = net,
                           page_cache_bytes = opts.cache_budget,
                           page_bb_bytes = opts.bb_budget }
    b._hasMember = function() return false end
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadEp" then return images end
        return nil
    end
    return b, net
end

local function urls(n)
    local t = {}
    for i = 1, n do t[i] = "https://cdn.example.com/" .. i .. ".webp" end
    return t
end

--- 索引一页（触发 __index：下载 + 排预取）
local function touch(pt, pn) return pt[pn] end

--- 预取队列：排除诊断探针的长延时节拍（见 ui/uimanager 桩注释）
local function prefetchCount()
    local n = 0
    for _, e in ipairs(fake.scheduled) do
        if e.sec < 1 then n = n + 1 end
    end
    return n
end

--- 跑掉当前排队的预取任务（每次只取一张，跑完会再排一个）
local function runScheduled(times)
    for _ = 1, times do
        local fn
        for i, e in ipairs(fake.scheduled) do
            if e.sec < 1 then
                fn = table.remove(fake.scheduled, i).fn
                break
            end
        end
        if fn then fn() end
    end
end

local tests = {}

--- 在 UIManager:show 记录里找 Menu（进度 toast 会先占掉 shown[1]）
local function shownMenu()
    for _, w in ipairs(fake.shown) do
        if w.__menu then return w end
    end
end

-- 返回出口 1：章节菜单不许被拆（阅读器盖在其上，关阅读器即回列表）
function tests.chapter_menu_stays_open_under_reader()
    local shown_reader = 0
    local b = Browser.new{ infoMessage = noop }
    b.showReader = function() shown_reader = shown_reader + 1 end
    b._awaitSource = function() return { chapters = { ["7"] = "第7话" } } end
    local menu
    fake.shown, fake.closed = {}, {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    menu = shownMenu()
    assert_eq("menu shown", true, menu ~= nil and menu.__menu)
    menu.args.onMenuSelect(menu, { comicId = "c1", epId = "7", text = "第7话" })
    assert_eq("reader opened", 1, shown_reader)
    assert_eq("chapter menu NOT closed (返回可用)", 0, #fake.closed)
    return true
end

-- 返回出口 2：阅读器必须带标题栏（X 退出）与章节名
function tests.reader_opens_with_title_bar()
    local b = makeReader({ "https://cdn.example.com/1.webp" })
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local a = fake.viewer_args
    assert_eq("viewer opened", true, a ~= nil)
    assert_eq("title bar on", true, a.with_title_bar)
    assert_eq("title shows chapter", "第7话", a.title_text)
    assert_eq("fullscreen", true, a.fullscreen)
    -- 列表级 image_disposable=true 才会触发 page_table:free()（回收缓存）
    assert_eq("list disposable", true, a.image_disposable)
    -- 页级必须 false：BB 归我们所有（viewer 换页时先 free 再销毁持有者，
    -- 而我们对同一页复用同一 BB → true 会造出 free 后仍被引用的悬垂读）
    assert_eq("page disposable off", false, a.image.image_disposable)
    assert_eq("page count", 1, a.images_list_nb)
    return true
end

-- 同一页重复取零成本：ImageViewer 往回翻页会重新索引 _images_list[pn]，
-- 字节与解码 BB 都在缓存里，直接复用同一个 BB 对象（不再下载、不再解码、
-- 不再新分配内存）。页级 image_disposable=false 保证 viewer 不会 free 它。
function tests.repeat_page_hit_is_served_from_cache()
    local b, net = makeReader(urls(3))
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    -- 首屏只排队不联网（ANR 修法，见 browser.lua 的 IMG_OPTS 注释）
    local d0 = decoded
    touch(pt, 1)
    assert_eq("first paint does not touch the net", 0, net.total)
    runScheduled(1)
    assert_eq("tick fetched the deferred first page", 1, net.total)
    local bb1 = pt[1]
    assert_eq("page decoded (not placeholder)", true, bb1 ~= nil and bb1.__bb and bb1.data ~= nil)
    local bb2 = pt[1]
    assert_eq("no second download", 1, net.total)
    assert_eq("decoded once for two reads", 1, decoded - d0)
    assert_eq("same BB reused", true, bb1 == bb2)
    assert_eq("url fetched once", 1, net.hits["https://cdn.example.com/1.webp"])
    return true
end

-- 预取：读到第 N 页后排一页，跑一次任务把 N+1 拉进缓存
function tests.prefetch_warms_next_page()
    local b, net = makeReader(urls(5))
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    touch(pt, 1)
    assert_eq("schedule requested", 1, prefetchCount())
    runScheduled(1)
    assert_eq("deferred first page warmed", 1, net.total)
    assert_eq("repainted the visible page", 1, fake.viewer_updates)
    assert_eq("re-armed", 1, prefetchCount())
    runScheduled(1)
    assert_eq("prefetched page 2", 2, net.total)
    runScheduled(1)
    assert_eq("prefetched page 3", 3, net.total)
    -- 预热过的页翻到时不再下载
    local d0 = decoded
    touch(pt, 2)
    assert_eq("page 2 already warm", 3, net.total)
    assert_eq("but still decoded", 1, decoded - d0)
    return true
end

-- 关闭阅读器后预取必须彻底停手（否则后台无限下载用户已经不要的页）
function tests.free_stops_prefetch_and_cache()
    local b, net = makeReader(urls(6))
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    touch(pt, 1)
    runScheduled(1)
    local before = net.total
    pt:free()
    for _ = 1, 6 do
        runScheduled(2)
    end
    assert_eq("no traffic after close", before, net.total)
    return true
end

-- 内存闸门：超预算按插入序逐出，页缓存不会无限涨
function tests.cache_evicts_over_byte_budget()
    local imgs = urls(4)
    local b, net = makeReader(imgs, { cache_budget = 80 })
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    touch(pt, 1)
    runScheduled(1)          -- 首屏由节拍取回
    touch(pt,2); touch(pt,3); touch(pt,4)
    assert_eq("each url once", 1, net.hits[imgs[1]])
    -- 每页 body ≈34B，预算 80B → 只留得下 2 页，最先插入的按序逐出
    touch(pt, 1)
    assert_eq("evicted page re-fetched", 2, net.hits[imgs[1]])
    touch(pt, 4)
    assert_eq("recent page still cached", 1, net.hits[imgs[4]])
    return true
end

-- 解码 BB 独立预算：BB 是内存大头（一页 600x800 BB8 ≈ 0.45MB），逐出时
-- 正在显示的那一页绝不能被逐（否则交出无引用的 BB 会被终值器回收）。
function tests.bb_evicts_over_bb_budget_keeps_current_page()
    local imgs = urls(4)
    -- 每页 BB = 600*800 = 480000B；预算 1MB → 最多留 2 页
    local b, net = makeReader(imgs, { bb_budget = 1024 * 1024 })
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    local bb1 = pt[1]
    runScheduled(1)          -- 首屏由节拍取回，页 1 进缓存/解码预算
    bb1 = pt[1]
    local d0 = decoded
    assert(pt[2] ~= nil and pt[3] ~= nil, "later pages decode")
    assert(decoded - d0 >= 2, "pages 2,3 decoded")
    -- 页 1 的 BB 已被预算逐出 → 翻回去重新解码（字节仍在缓存，不再下载）
    local bb1b = pt[1]
    assert_eq("evicted page re-decoded", true, bb1b ~= bb1)
    assert_eq("bytes still cached, no re-download", 1, net.hits[imgs[1]])
    assert_eq("current page still a BB", true, pt[3].__bb)
    return true
end

-- 坏图不进缓存：否则一次 500 会被当成页内容反复复用。
-- 【ANR】一次调用只撞一次超时（原来在同一次回调里连撞 2×10s → 主循环冻结
-- 20s），重试挪到预取节拍，且总次数封顶，够不着的页不再无限重排。
function tests.failed_page_is_not_cached()
    local imgs = urls(2)
    local b, net = makeReader(imgs, { fail_urls = { [imgs[1]] = true } })
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    assert(pt[1] ~= nil, "failed page must still yield a placeholder BB")
    assert_eq("first paint does not touch the net", 0, net.hits[imgs[1]] or 0)
    runScheduled(1)
    assert_eq("single attempt per turn", 1, net.hits[imgs[1]])
    runScheduled(2)
    assert_eq("retry moved to the next tick", 2, net.hits[imgs[1]])
    runScheduled(3)
    assert_eq("gives up after the try budget", 2, net.hits[imgs[1]])
    return true
end

-- 整章都取不到时预取自已熔断：真机 baozi 的图床经代理每页要 2.2s 才失败，
-- 95 页 × 重试会把用户已经放弃的东西撞几分钟。
function tests.prefetch_breaks_after_a_run_of_failures()
    local imgs = urls(6)
    local fails = {}
    for _, u in ipairs(imgs) do fails[u] = true end
    local b, net = makeReader(imgs, { fail_urls = fails })
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    touch(pt, 1)
    runScheduled(8)
    assert_eq("prefetch gives up after 3 straight failures", 3, net.total)
    assert_eq("and never re-arms", 0, prefetchCount())
    return true
end

-- 【ANR】阅读器发出的每个图片请求都必须自带紧超时：缺了它就退回 netclient
-- 默认，经代理不通的 CDN（baozicdn 实测）一次握手就吃掉整个超时窗口，
-- 主循环冻到 5s 以上安卓即弹「KOReader 无响应」。
function tests.image_requests_carry_a_bounded_timeout()
    local imgs = urls(1)
    local b, net = makeReader(imgs)
    b:showReader("baozi", "c1", "7", "t", "第7话")
    local pt = fake.viewer_args.image
    touch(pt, 1)
    runScheduled(1)
    local o = net.opts[imgs[1]]
    assert(o, "image request went out")
    assert_eq("block timeout bounded", true,
        type(o.timeout_block) == "number" and o.timeout_block <= 3)
    assert_eq("total timeout bounded", true,
        type(o.timeout_total) == "number" and o.timeout_total <= 6)
    return true
end

-- 代理对某台主机整体不通（CONNECT 后无 TLS 字节 → status=nil）时，该主机
-- 后续图片请求降级为直连；代理本身仍是 per-request 显式指定（ADR-003）。
function tests.broken_proxy_host_falls_back_to_direct()
    local imgs = urls(1)
    local seen = {}
    local net = { total = 0 }
    net.request = function(_, o)
        net.total = net.total + 1
        seen[net.total] = o.proxy
        if o.proxy == "" then
            return { status = 200, headers = {}, body = "IMG:" .. o.url }
        end
        return { status = nil, headers = {}, body = nil,
                 error = "TLS 握手失败: wantread" }
    end
    local b = Browser.new{ infoMessage = noop, netclient = net,
        settings = { isProxyEnabled = function() return true end,
                     getProxyURL = function() return "http://10.0.0.1:8080" end } }
    assert_eq("proxied attempt fails", nil,
        b:fetchImageBytes(imgs[1], nil, nil, { attempts = 1 }))
    assert_eq("first went through the proxy", "http://10.0.0.1:8080", seen[1])
    assert_eq("same host now direct", "IMG:" .. imgs[1],
        b:fetchImageBytes(imgs[1], nil, nil, { attempts = 1 }))
    assert_eq("second request forced direct", "", seen[2])
    return true
end

-- 【R9 真机闪退】菜单回调由 KOReader 分发循环直接调用；错误冒到主循环后，
-- 主循环用 luaL_traceback 生成崩溃报告时自己崩在 libluajit 里（tombstone 02/03
-- 同一签名）。所以回调入口必须收住错误并转成用户可见提示。
function tests.menu_callback_error_does_not_escape()
    local reported = nil
    local b = Browser.new{ infoMessage = function(t) reported = t end }
    b.showReader = function() error("boom in reader") end
    b._awaitSource = function() return { chapters = { ["7"] = "第7话" } } end
    fake.shown, fake.closed = {}, {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    local menu = shownMenu()
    local okcall = pcall(function()
        menu.args.onMenuSelect(menu, { comicId = "c1", epId = "7", text = "第7话" })
    end)
    assert_eq("callback did not raise", true, okcall)
    assert(reported and reported:find("boom in reader", 1, true),
        "error surfaced to user: " .. tostring(reported))
    return true
end

-- 进度提示必须自消失（真机 R8：模态"章节加载中…"永远压在阅读器上面）；
-- 错误提示必须保持模态（用户必须看到）。
function tests.progress_toast_dismisses_but_errors_stay_modal()
    local modal = {}
    local b = Browser.new{ infoMessage = function(t) table.insert(modal, t) end }
    b._awaitSource = function() return { chapters = { ["7"] = "第7话" } } end
    fake.shown = {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    local toast = fake.shown[1]
    assert_eq("progress toast shown first", "加载详情…", toast.text)
    assert(type(toast.timeout) == "number" and toast.timeout > 0,
        "progress toast must auto-dismiss, got " .. tostring(toast.timeout))
    b._awaitSource = function() return nil, "network down" end
    b:showResults("baozi", "search.load", { "kw", {} }, 1, "t")
    assert_eq("error routed to modal infoMessage", 1, #modal)
    assert(modal[1]:find("network down", 1, true),
        "error text surfaced: " .. tostring(modal[1]))
    return true
end

return tests
