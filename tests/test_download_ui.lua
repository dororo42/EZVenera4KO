-- unit test: browser.lua 的章节下载 / 离线打开 / 缓存管理接线
-- 关注点：UI 不冻结（每拍一页）、取消清干净、已下载章节零网络打开、
-- 菜单全是普通 callback（ADR-005 禁 hold）。
-- browser.lua 顶层 require KOReader 前端模块 → 测试环境先桩化。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = {
    shown = {}, closed = {}, scheduled = {}, pb = {}, viewer_args = nil,
}

stub("logger", { warn = noop, info = noop, err = noop, dbg = noop, verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = function(_, w) table.insert(fake.closed, w) end,
    scheduleIn = function(_, sec, fn)
        table.insert(fake.scheduled, { sec = sec, fn = fn })
    end,
    setDirty = noop,
})
stub("ui/widget/menu", {
    new = function(_, args) return { __menu = true, args = args } end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })
stub("ui/widget/confirmbox", {
    new = function(_, a) return { __confirm = true, args = a } end,
})
stub("ui/widget/imageviewer", {
    new = function(_, args)
        fake.viewer_args = args
        return { __viewer = true, free = noop }
    end,
})
stub("ui/renderimage", {
    renderImageData = function(_, data)
        return { __bb = true, data = data, free = noop, stride = 600, h = 800 }
    end,
})
stub("ffi/blitbuffer", {
    TYPE_BB8 = 1, COLOR_GRAY_E = 233,
    new = function() return { __bb = true, fill = noop, free = noop } end,
})
-- 真机 ProgressbarDialog 的两个关键语义：show/close 由对话框自己管，且 close
-- 会走 onCloseWidget → dismiss_callback。不还原这条，"下载完成时误判成用户
-- 取消"这类 bug 在测试里看不见。
stub("ui/widget/progressbardialog", {
    new = function(_, args)
        local d = { args = args, shown = false, closed = false, progress = 0 }
        function d:show() self.shown = true end
        function d:close()
            self.closed = true
            if args.dismiss_callback then args.dismiss_callback() end
        end
        function d:reportProgress(v) self.progress = v end
        table.insert(fake.pb, d)
        return d
    end,
})

package.loaded["browser"] = nil
local Browser = require("browser")
local Downloader = require("runtime.downloader")
local memFs = require("memfs")

local tests = {}

local URLS = {
    "https://cdn.example.com/1.webp",
    "https://cdn.example.com/2.webp",
    "https://cdn.example.com/3.webp",
}

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 造一套 browser + 下载器。下载器只注入内存 fs，取字节仍走
--- Browser:fetchImageBytes（与真机 getDownloader 的 request 闭包同构），
--- 这样"下载与阅读共用同一条代理/cookie 通道"也被覆盖。
local function makeBrowser(images)
    local fs = memFs()
    local net = { total = 0, hits = {} }
    net.request = function(_, o)
        net.total = net.total + 1
        net.hits[o.url] = (net.hits[o.url] or 0) + 1
        return { status = 200, headers = { ["content-type"] = "image/webp" },
                 body = "IMG:" .. o.url }
    end
    local b
    local dl = Downloader.new{
        fs = fs, basedir = "/data/ezvenera/downloads",
        request = function(url, headers)
            local data, hdrs, err = b:fetchImageBytes(url, nil, headers)
            if not data then return { status = 0, error = err or hdrs } end
            return { status = 200, body = data, headers = hdrs }
        end,
    }
    fake.shown, fake.closed, fake.scheduled, fake.pb = {}, {}, {}, {}
    fake.viewer_args = nil
    b = Browser.new{ infoMessage = noop, netclient = net, downloader = dl }
    b.cookies = {
        headerFor = function() return nil end,
        purge = function() b.purged = (b.purged or 0) + 1 end,
    }
    b._hasMember = function() return false end
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadEp" then return images or URLS end
        if path == "comic.loadInfo" then
            return { title = "航海王", chapters = { ["7"] = "第7话", ["8"] = "第8话" } }
        end
        return nil
    end
    return b, dl, fs, net
end

--- 跑一个已排队的节拍（模拟 UIManager 的事件循环）
local function runTick()
    local e = table.remove(fake.scheduled, 1)
    if e and e.fn then e.fn() end
    return e ~= nil
end

--- 跑一个预取节拍的回调（0.2s 那类），跳过 2s 延时的内存探针
local function runPrefetchTick()
    for i, e in ipairs(fake.scheduled) do
        if e.sec < 1 then return table.remove(fake.scheduled, i).fn() end
    end
end

--- 下完一整话（逐拍推进），返回 on_done 收到的结果
local function downloadAll(b, epId)
    local out = {}
    b:downloadChapter("baozi", "c1", epId or "7", "航海王",
        "第 " .. (epId or "7") .. " 话",
        function(ok, info) out.ok, out.info = ok, info end)
    for _ = 1, 100 do
        if out.ok ~= nil or #fake.scheduled == 0 then break end
        runTick()
    end
    return out
end

local function shownMenus()
    local out = {}
    for _, w in ipairs(fake.shown) do
        if w.__menu then out[#out + 1] = w end
    end
    return out
end

local function fileCount(fs)
    local n = 0
    for _ in pairs(fs.state.files) do n = n + 1 end
    return n
end

-- 主路径：每拍只下一页（界面不冻结），进度回写对话框，完成后 on_done 给 manifest
function tests.download_steps_one_page_per_tick()
    local b, dl, fs, net = makeBrowser()
    local out = {}
    b:downloadChapter("baozi", "c1", "7", "航海王", "第7话",
        function(ok, info) out.ok, out.info = ok, info end)
    local d = fake.pb[1]
    assert(d and d.shown, "progress dialog shown")
    assert_eq("max = page count", 3, d.args.progress_max)
    assert_eq("one page per tick", 1, net.total)
    assert_eq("progress bar updated", 1, d.progress)
    assert_eq("not finished yet", nil, out.ok)
    runTick()
    assert_eq("dialog still open mid-download", false, d.closed)
    assert_eq("progress advanced", 2, d.progress)
    runTick()
    assert_eq("done after last page", true, out.ok)
    assert_eq("3 pages", 3, #out.info.pages)
    assert_eq("dialog closed at end", true, d.closed)
    assert_eq("offline readable", true, dl:isDownloaded("baozi", "c1", "7"))
    assert_eq("pages + manifest", 4, fileCount(fs))
    return true
end

-- 取消：点对话框关闭即中止，半截文件清干净（否则占空间又读不出来）
function tests.dismissing_dialog_cancels_and_prunes()
    local b, dl, fs, net = makeBrowser()
    local out = {}
    b:downloadChapter("baozi", "c1", "7", "航海王", "第7话",
        function(ok, info) out.ok, out.info = ok, info end)
    assert_eq("first page in flight", 1, net.total)
    fake.pb[1].args.dismiss_callback()
    runTick()
    assert_eq("stops at the page boundary", 1, net.total)
    assert_eq("cancelled", false, out.ok)
    assert_eq("reason", "已取消", out.info)
    assert_eq("partials cleaned", 0, fileCount(fs))
    assert_eq("nothing offered as offline", nil, dl:manifestOf("baozi", "c1", "7"))
    return true
end

-- 已下过的章节：不再请求网络、也不弹进度对话框
function tests.already_downloaded_returns_immediately()
    local b, _, _, net = makeBrowser()
    downloadAll(b)
    local before = net.total
    fake.shown, fake.pb = {}, {}
    local out = downloadAll(b)
    assert_eq("no extra traffic", before, net.total)
    assert_eq("ok", true, out.ok)
    assert_eq("manifest handed back", 3, #out.info.pages)
    assert_eq("no dialog", 0, #fake.pb)
    return true
end

-- 离线打开：已下载章节零网络、零源方法调用（loadEp 都不发）
function tests.downloaded_chapter_opens_offline()
    local b, _, _, net = makeBrowser()
    downloadAll(b)
    local before = net.total
    fake.shown, fake.viewer_args = {}, nil
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local a = fake.viewer_args
    assert(a, "viewer opened")
    assert_eq("page count from manifest", 3, a.images_list_nb)
    assert_eq("no network at all", before, net.total)
    assert_eq("page decoded from local file", "IMG:" .. URLS[1], a.image[1].data)
    assert_eq("still no network", before, net.total)
    for _, w in ipairs(fake.shown) do
        assert(w.text ~= "章节加载中…", "offline open must not toast 章节加载中")
    end
    return true
end

-- 在线打开仍然走 fetchImageBytes（页字节缓存没被重构改坏）；首屏例外：
-- 点章节那一次回调不许联网（安卓 5s 输入超时会弹「无响应」），由节拍补。
function tests.online_reader_still_fetches_and_caches()
    local b, _, _, net = makeBrowser()
    b:showReader("baozi", "c1", "9", "航海王", "第9话")
    local pt = fake.viewer_args.image
    local pg = pt[1]
    assert_eq("first paint is a placeholder", true, pg ~= nil and pg.data == nil)
    assert_eq("no download in the paint path", 0, net.total)
    runPrefetchTick()
    assert_eq("page decoded from bytes", "IMG:" .. URLS[1], pt[1].data)
    assert_eq("first page fetched once", 1, net.total)
    assert_eq("repeat read served from cache", "IMG:" .. URLS[1], pt[1].data)
    assert_eq("no re-download", 1, net.total)
    return true
end

-- 详情菜单必须给一个"下载章节"入口，点它是第二个菜单（不是 hold）
function tests.detail_menu_exposes_download_picker()
    local b = makeBrowser()
    fake.shown = {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    local menus = shownMenus()
    assert_eq("detail menu shown", 1, #menus)
    local found
    for _, it in ipairs(menus[1].args.item_table) do
        if it.downloadMgr then found = it end
    end
    assert(found, "download entry present")
    assert_eq("entry carries no hold dependency", nil, found.hold_callback)
    menus[1].args.onMenuSelect(menus[1], found)
    menus = shownMenus()
    assert_eq("picker opens above detail (栈不拆)", 2, #menus)
    local rows = menus[2].args.item_table
    assert_eq("one row per chapter", 2, #rows)
    assert_eq("not downloaded yet", "○ 第7话", rows[1].text)
    assert_eq("ep id shown", "7", rows[1].mandatory)
    return true
end

-- 章节顺序必须确定：扁平章节表落在 Lua 表的 hash 部分，pairs() 顺序不保证，
-- 真机上同一本书会排成乱序（第10话 夹在第2话 前面）。
function tests.detail_chapters_sorted_numerically()
    local b = makeBrowser()
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadInfo" then
            return { title = "航海王", chapters = {
                ["10"] = "第10话", ["2"] = "第2话", ["9"] = "第9话", ["1"] = "第1话",
            } }
        end
        return nil
    end
    fake.shown = {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    local ids = {}
    for _, it in ipairs(shownMenus()[1].args.item_table) do
        if it.epId then ids[#ids + 1] = tostring(it.epId) end
    end
    assert_eq("four chapter rows", 4, #ids)
    assert_eq("1 first", "1", ids[1])
    assert_eq("then 2", "2", ids[2])
    assert_eq("then 9", "9", ids[3])
    assert_eq("10 sorts after 9, not after 1", "10", ids[4])
    return true
end

-- 移植源的章节 id 常是不透明 URL（A漫 v2.0.0：尾部随机串），按 id 排就是
-- 按随机串字典序排 → 真机目录乱序（21,14,4,7,12,…）。标题里的话数才是顺序。
function tests.detail_chapters_with_url_ids_sort_by_title_number()
    local b = makeBrowser()
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadInfo" then
            return { title = "恋爱版本更新中", chapters = {
                ["https://aman8.org/c/zZq.html"] = "第3話-要來我房間喝一杯嗎?",
                ["https://aman8.org/c/aBc.html"] = "第21話-在你這裡留下「愛的印記」",
                ["https://aman8.org/c/xYw.html"] = "第4話-不合時宜的正裝打扮",
                ["https://aman8.org/c/epA.html"] = "番外-作者的話",
            } }
        end
        return nil
    end
    fake.shown = {}
    b:showDetail("aman", { id = "c1", title = "恋爱版本更新中" })
    local titles = {}
    for _, it in ipairs(shownMenus()[1].args.item_table) do
        if it.epId then titles[#titles + 1] = it.text end
    end
    assert_eq("四行章节", 4, #titles)
    assert_eq("按标题话数排", "第3話-要來我房間喝一杯嗎?", titles[1])
    assert_eq("4 在 3 之后", "第4話-不合時宜的正裝打扮", titles[2])
    assert_eq("21 不在 2 前面", "第21話-在你這裡留下「愛的印記」", titles[3])
    assert_eq("没号的排最后", "番外-作者的話", titles[4])
    return true
end

-- 下载完成后回到清单：该行就地变成 ◆ + 体积
function tests.picker_row_updates_after_download()
    local b, dl = makeBrowser()
    fake.shown = {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    local detail = shownMenus()[1]
    local entry
    for _, it in ipairs(detail.args.item_table) do
        if it.downloadMgr then entry = it end
    end
    detail.args.onMenuSelect(detail, entry)
    local menu = shownMenus()[2]
    local row = menu.args.item_table[1]
    menu.args.onMenuSelect(menu, row)
    for _ = 1, 50 do
        if row.text:sub(1, 3) == "◆" then break end
        if not runTick() then break end
    end
    assert_eq("row marked downloaded", "◆ 第7话", row.text)
    assert(row.mandatory:find("已下载", 1, true),
        "size + 已下载 shown: " .. row.mandatory)
    assert_eq("chapter stored", true, dl:isDownloaded("baozi", "c1", "7"))
    return true
end

-- 缓存管理：列体积 + 逐章「读或删」+ 清 Cookie；删除要两步再二次确认
function tests.cache_manager_lists_and_deletes()
    local b, dl = makeBrowser()
    downloadAll(b)
    fake.shown = {}
    b:showCacheManager()
    local menu = shownMenus()[1]
    local rows = menu.args.item_table
    assert_eq("head + chapter + 清空全部 + cookies + note", 5, #rows)
    assert(rows[1].text:find("已下载 1 话", 1, true), "usage header: " .. rows[1].text)
    -- 体积必须带单位（真机曾经显示成裸字节 "1,683,200"）
    assert(rows[2].mandatory:match("%d+ [KMGT]?B$"),
        "size carries a unit: " .. rows[2].mandatory)
    assert(not rows[2].mandatory:find(",", 1, true),
        "no raw byte grouping: " .. rows[2].mandatory)
    local chapter = rows[2]
    assert(chapter.cachedChapter, "chapter row carries its manifest")
    assert(rows[3].clearAll, "clear-all offered when something is on disk")
    fake.shown = {}
    menu.args.onMenuSelect(menu, chapter)
    local sub = shownMenus()[1]
    assert(sub, "tapping a chapter opens its action menu, not a delete prompt")
    assert_eq("read + delete offered", 2, #sub.args.item_table)
    assert_eq("first action is reading", true, sub.args.item_table[1].read)
    fake.shown = {}
    sub.args.onMenuSelect(sub, sub.args.item_table[2])
    local box = fake.shown[1]
    assert(box and box.__confirm, "delete asks for confirmation")
    fake.shown = {}
    box.args.ok_callback()
    local again = shownMenus()[1]
    assert(again, "cache screen reopened")
    for _, it in ipairs(again.args.item_table) do
        assert(it.cachedChapter == nil, "no chapter rows left")
        assert(it.clearAll == nil, "clear-all row drops with the last chapter")
    end
    assert_eq("space reclaimed", 0, dl:usage())
    return true
end

function tests.cache_manager_purges_cookies()
    local b = makeBrowser()
    fake.shown = {}
    b:showCacheManager()
    local menu = shownMenus()[1]
    local row
    for _, it in ipairs(menu.args.item_table) do
        if it.clearCookies then row = it end
    end
    assert(row, "cookie row present")
    fake.shown = {}
    menu.args.onMenuSelect(menu, row)
    fake.shown[1].args.ok_callback()
    assert_eq("jar purged", 1, b.purged)
    return true
end

-- 点「阅读」= 离线打开已下载章节：一个请求都不发（用户反馈：点章节不该直接删）
function tests.cached_chapter_menu_reads_offline()
    local b, _, _, net = makeBrowser()
    downloadAll(b)
    local before = net.total
    fake.shown = {}
    b:showCacheManager()
    local menu = shownMenus()[1]
    fake.shown = {}
    menu.args.onMenuSelect(menu, menu.args.item_table[2])
    local sub = shownMenus()[1]
    assert(sub, "chapter action menu shown")
    fake.viewer_args = nil
    sub.args.onMenuSelect(sub, sub.args.item_table[1])
    local a = fake.viewer_args
    assert(a, "reader opened from the cache screen")
    assert_eq("page count from manifest", 3, a.images_list_nb)
    assert_eq("reading a cached chapter costs no network", before, net.total)
    return true
end

-- 菜单回调里出错不许冒到主循环（R9：错误逃出 = 整应用闪退）
function tests.download_error_does_not_escape()
    local b = makeBrowser()
    b._loadEpImages = function() error("boom in ep load") end
    fake.shown = {}
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    local detail = shownMenus()[1]
    local entry
    for _, it in ipairs(detail.args.item_table) do
        if it.downloadMgr then entry = it end
    end
    detail.args.onMenuSelect(detail, entry)
    local menu = shownMenus()[2]
    local ok = pcall(function()
        menu.args.onMenuSelect(menu, menu.args.item_table[1])
    end)
    assert_eq("callback did not raise", true, ok)
    return true
end

return tests
