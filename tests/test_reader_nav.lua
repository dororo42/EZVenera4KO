-- unit test: browser.lua 阅读器内的章节导航（上一章 / 目录 / 下一章）
-- 关注点：导航条是叠在 ImageViewer 之上的独立窗口，所以①三键都是普通
-- callback（ADR-005 禁 hold）、②换章要先把上一章的阅读器与导航条收干净、
-- ③阅读器关闭时导航条不能留在屏幕上、④离线只下过两章时也能前后跳。
-- browser.lua 顶层 require KOReader 前端模块 → 测试环境先桩化。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = {
    shown = {}, closed = {}, scheduled = {}, pb = {}, viewer = nil,
    viewer_args = nil, bars = {}, button_tables = {},
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
-- Menu 的 switchItemTable 是关键语义之一：目录必须翻到当前章所在那一页，
-- 否则千话书永远开在第一页。
stub("ui/widget/menu", {
    new = function(_, args)
        return {
            __menu = true, args = args, switched = {},
            switchItemTable = function(self, _t, _it, num)
                table.insert(self.switched, num)
            end,
        }
    end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })
stub("ui/widget/confirmbox", {
    new = function(_, a) return { __confirm = true, args = a } end,
})
stub("ui/widget/imageviewer", {
    new = function(_, args)
        local w = { __viewer = true, free = noop, args = args, got = {} }
        -- ImageViewer 是 InputContainer：真机上所有触摸都以 onGesture 进来，
        -- 自己再按 ges_events 转成 onTap/onSwipe…。桩记录收到的事件即可。
        function w:handleEvent(event)
            table.insert(self.got, event)
            return true
        end
        fake.viewer, fake.viewer_args = w, args
        return w
    end,
})
-- 导航条三件套：真机是 BottomContainer(dimen=整屏) 套 FrameContainer 套
-- ButtonTable；桩只需留住 buttons 定义与窗口对象本身。
-- BottomContainer 继承 WidgetContainer:handleEvent —— 先问子控件（点在按钮上
-- 就返回 true），没人吃掉才轮到自己。这里用 hit_button 留住那个开关。
stub("ui/widget/container/bottomcontainer", {
    new = function(_, args)
        local w = { __bar = true, args = args, hit_button = false }
        function w:handleEvent(event) return self.hit_button and true or nil end
        table.insert(fake.bars, w)
        return w
    end,
})
stub("ui/widget/container/framecontainer", {
    new = function(_, args) return { __frame = true, args = args } end,
})
stub("ui/widget/buttontable", {
    new = function(_, args)
        table.insert(fake.button_tables, args)
        return { __bt = true, args = args }
    end,
})
stub("device", {
    screen = {
        w = 600, h = 800,
        getSize = function(s) return { w = s.w, h = s.h } end,
        getWidth = function(s) return s.w end,
        getHeight = function(s) return s.h end,
    },
})
stub("ui/renderimage", {
    renderImageData = function(_, data)
        return { __bb = true, data = data, free = noop, stride = 600, h = 800 }
    end,
})
stub("ffi/blitbuffer", {
    TYPE_BB8 = 1, COLOR_GRAY_E = 233, COLOR_WHITE = 255,
    new = function() return { __bb = true, fill = noop, free = noop } end,
})
-- 下载对话框：close 会走 dismiss_callback，与真机一致（离线用例要先下两章）
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

local CHAPTERS = { ["7"] = "第7话", ["8"] = "第8话", ["9"] = "第9话" }
local URLS = { "https://cdn.example.com/1.webp",
               "https://cdn.example.com/2.webp",
               "https://cdn.example.com/3.webp" }

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 造一套 browser：info_calls / ep_calls 分开数，才能验证「换章不再取详情」。
local function makeBrowser()
    local fs = memFs()
    local net = { total = 0 }
    net.request = function(_, o)
        net.total = net.total + 1
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
    fake.viewer, fake.viewer_args = nil, nil
    fake.bars, fake.button_tables = {}, {}
    b = Browser.new{ infoMessage = noop, netclient = net, downloader = dl }
    b.cookies = { headerFor = function() return nil end }
    b._hasMember = function() return false end
    b.info_calls, b.ep_calls, b.broken = 0, 0, false
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadEp" then
            b.ep_calls = b.ep_calls + 1
            return URLS
        end
        if path == "comic.loadInfo" then
            b.info_calls = b.info_calls + 1
            if b.broken then return nil, "Not logged in" end
            return { title = "航海王", chapters = CHAPTERS }
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

--- 下完整一话：逐拍推进，返回 on_done 的结果
local function downloadAll(b, ep)
    local out = {}
    b:downloadChapter("baozi", "c1", ep, "航海王", "第" .. ep .. "话",
        function(ok, info) out.ok, out.info = ok, info end)
    for _ = 1, 100 do
        if out.ok ~= nil or #fake.scheduled == 0 then break end
        runTick()
    end
    return out
end

--- 最近一条导航条上的三个按钮
local function navButtons()
    local args = fake.button_tables[#fake.button_tables]
    assert(args, "nav bar button table shown")
    return args.buttons[1]
end

local function lastShownText()
    for i = #fake.shown, 1, -1 do
        if fake.shown[i].text then return fake.shown[i].text end
    end
end

local function lastMenu()
    local out
    for _, w in ipairs(fake.shown) do if w.__menu then out = w end end
    return out
end

local function countClosed(w)
    local n = 0
    for _, x in ipairs(fake.closed) do if x == w then n = n + 1 end end
    return n
end

-- 导航条：三个普通 callback（无 hold 依赖），并且确实盖在阅读器之上
function tests.nav_bar_has_three_plain_callbacks()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local btns = navButtons()
    assert_eq("3 buttons", 3, #btns)
    assert_eq("prev label", "上一章", btns[1].text)
    assert_eq("toc label", "目录", btns[2].text)
    assert_eq("next label", "下一章", btns[3].text)
    for i, btn in ipairs(btns) do
        assert_eq("button " .. i .. " plain callback", "function",
            type(btn.callback))
        assert(btn.hold_callback == nil and btn.hold_gesture == nil,
            "button " .. i .. " must not depend on hold (ADR-005)")
    end
    assert_eq("one bar", 1, #fake.bars)
    local bar = fake.bars[1]
    assert_eq("bar spans the screen", 600, bar.args.dimen.w)
    -- show 顺序 = 窗口栈顺序：阅读器在下、导航条在上，阅读器的手势才会被
    -- 按钮区域之外的点击照常收到
    assert_eq("bar stacked above the reader", fake.viewer, fake.shown[#fake.shown - 1])
    assert_eq("nav handle published", "function", type(b._reader_nav.step))
    return true
end

-- 【真机踩到】导航条是盖在阅读器之上的顶层窗口。UIManager:sendEvent 只把
-- 「未被顶层窗口消费」的事件继续发给 is_always_active 的窗口，普通向下传播
-- 不存在——不转交的话点图片区域翻页彻底失效（真机上就是这么坏的）。
local function gesture_event()
    -- 真机 device/input.lua 的触摸事件全部是 Event:new("Gesture", ges)
    return { handler = "onGesture", args = { { ges = "tap", pos = { x = 500, y = 300 } } } }
end

function tests.strip_forwards_untouched_gestures_to_the_reader()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local bar, viewer = fake.bars[1], fake.viewer
    local ev = gesture_event()
    assert_eq("untouched tap reaches the reader", true, bar:handleEvent(ev))
    assert_eq("tap forwarded exactly once", 1, #viewer.got)
    assert_eq("forwarded the very same event object", ev, viewer.got[1])
    viewer.got = {}
    bar.hit_button = true
    assert_eq("button press is consumed by the strip", true, bar:handleEvent(ev))
    assert_eq("consumed tap does not also page the reader", 0, #viewer.got)
    bar.hit_button = false
    -- 生命周期事件不转交：Show/CloseWidget 由 UIManager 直接投递，
    -- 再喂给阅读器就是重复渲染 / 重复关闭。
    assert_eq("onShow not forwarded", nil, bar:handleEvent({ handler = "onShow", args = {} }))
    assert_eq("onCloseWidget not forwarded", nil,
        bar:handleEvent({ handler = "onCloseWidget", args = {} }))
    assert_eq("no lifecycle event leaked into the reader", 0, #viewer.got)
    return true
end

-- 换章后新建的导航条必须转交给新阅读器：viewer 是 upvalue，绑错就等于把
-- 手势喂给一个已经 free 掉的窗口
function tests.new_chapter_strip_forwards_to_the_new_reader()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    navButtons()[3].callback()
    assert_eq("a second strip was built", 2, #fake.bars)
    local new_bar, new_viewer = fake.bars[2], fake.viewer
    assert_eq("new strip hands over to the new reader", true,
        new_bar:handleEvent(gesture_event()))
    assert_eq("forwarded exactly once", 1, #new_viewer.got)
    return true
end

-- 下一章：先收掉上一章的阅读器与导航条，再按同一入口开下一章（页缓存、
-- 预取节拍、BB 所有权都随旧闭包回收，不留第二套生命周期）
function tests.next_chapter_reopens_on_the_next_one()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local old_viewer, old_bar = fake.viewer, fake.bars[1]
    fake.closed = {}
    navButtons()[3].callback()
    assert_eq("old reader closed", 1, countClosed(old_viewer))
    assert_eq("old nav bar closed", 1, countClosed(old_bar))
    assert_eq("next chapter opened", "第8话", fake.viewer_args.title_text)
    assert_eq("fresh bar for the new chapter", 2, #fake.bars)
    assert_eq("nav handle re-armed", "function", type(b._reader_nav.step))
    return true
end

-- 边界：第一章点【上一章】只给提示，不换章也不拆掉当前阅读器
function tests.prev_at_first_chapter_only_toasts()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local bars, viewer = #fake.bars, fake.viewer
    navButtons()[1].callback()
    assert_eq("toast at the edge", "已是第一章", lastShownText())
    assert_eq("reader untouched", viewer, fake.viewer)
    assert_eq("no extra bar", bars, #fake.bars)
    assert_eq("no extra chapter fetch", 1, b.ep_calls)
    return true
end

-- 目录：全章节 + 已下载标记 + 翻到当前章所在页，选中即跳章
function tests.toc_positions_on_current_chapter_and_jumps()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "8", "航海王", "第8话")
    navButtons()[2].callback()
    local menu = lastMenu()
    assert(menu, "toc menu shown")
    local it = menu.args.item_table
    assert_eq("all chapters listed", 3, #it)
    assert_eq("undownloaded chapter marker", "○ 第8话", it[2].text)
    assert_eq("scrolled to current chapter", 2, menu.switched[#menu.switched])
    menu.args.onMenuSelect(menu, it[3])
    assert_eq("jumped to chapter 9", "第9话", fake.viewer_args.title_text)
    return true
end

-- 阅读器关闭（标题栏 X、下滑）时导航条必须一起消失：否则三条按钮会留在
-- 上一层界面之上，点了没反应
function tests.closing_reader_disposes_nav_bar()
    local b = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local bar = fake.bars[1]
    fake.viewer_args.image.free()          -- ImageViewer 的 onCloseWidget
    assert_eq("bar closed with the reader", 1, countClosed(bar))
    assert_eq("nav handle dropped", nil, b._reader_nav)
    return true
end

-- 离线：源调不通（没网/未登录）时用本书已下载的话构造章节表；这一趟只失败
-- 一次，之后走缓存（否则每按一次导航就重跑一次阻塞调用 = 每次白屏几秒）
function tests.offline_nav_falls_back_to_downloaded_chapters()
    local b = makeBrowser()
    assert_eq("chapter 7 downloaded", true, downloadAll(b, "7").ok)
    assert_eq("chapter 8 downloaded", true, downloadAll(b, "8").ok)
    fake.shown, fake.closed, fake.viewer, fake.viewer_args = {}, {}, nil, nil
    fake.bars, fake.button_tables = {}, {}
    b.broken = true
    b.info_calls, b.ep_calls = 0, 0
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    assert_eq("offline open is silent", 0, b.info_calls + b.ep_calls)
    navButtons()[3].callback()
    assert_eq("switched to a downloaded chapter", "第8话",
        fake.viewer_args.title_text)
    assert_eq("first press tries the source once", 1, b.info_calls)
    assert_eq("no page traffic: both chapters are local", 0, b.ep_calls)
    navButtons()[1].callback()
    assert_eq("back to chapter 7", "第7话", fake.viewer_args.title_text)
    assert_eq("offline subset got cached", 1, b.info_calls)
    fake.shown = {}
    navButtons()[1].callback()
    assert_eq("edge hint admits it is the offline subset",
        "离线列表中已是第一章", lastShownText())
    return true
end

-- 进过详情 → 章节表已在缓存：换章不再发 comic.loadInfo
function tests.chapters_from_detail_are_reused()
    local b = makeBrowser()
    b:showDetail("baozi", { id = "c1", title = "航海王" })
    assert_eq("detail fetched chapters once", 1, b.info_calls)
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    navButtons()[3].callback()
    assert_eq("still no second loadInfo", 1, b.info_calls)
    assert_eq("one loadEp per chapter", 2, b.ep_calls)
    assert_eq("now on chapter 8", "第8话", fake.viewer_args.title_text)
    return true
end

return tests
