-- unit test: browser.lua 章节阅读器底部的「第 N / M 页」+ 可拉进度条
-- 关注点（都是真机/规范约束，不是口味问题）：
--   ①比例→页码必须钳制：上游 HorizontalScrollBar 的 ratio 完全不钳
--     （v2026.07.1 horizontalscrollbar.lua:78），手指拖出轨道就是负数/大于 1；
--   ②拖动途中（pan / hold_pan）只改显示不跳页，按下/抬起才跳：一次同步取图
--     最坏 6s，跟着手指连跳几下必踩安卓 5s ANR（见 IMG_OPTS 注释）；
--   ③六个手势名都要盖上我们的处理函数——上游把它们别名成同一个方法，
--     只改 onTapScroll 的话另外五个仍走原实现（原实现要 scroll_callback，
--     我们没给 → 点了没反应）；
--   ④点图片翻页时条子也得跟着动（paint 挂在取页路径上，不只挂在拖动上）；
--   ⑤页码文本格按最宽版本预留：HorizontalGroup 的子控件偏移只在第一次
--     getSize() 时算（horizontalgroup.lua:15-38），页码变长会把条挤位；
--   ⑥装不上进度条模块时导航条必须照常工作（降级成三键）。
-- browser.lua 顶层 require KOReader 前端模块 → 测试环境先桩化。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = {
    shown = {}, closed = {}, scheduled = {}, dirty = {}, pb = {}, warns = {},
    viewer = nil, viewer_args = nil, bars = {}, button_tables = {}, vgs = {},
    groups = {}, spans = {}, centers = {}, texts = {}, sb = nil,
    break_scrollbar = false,
}

-- 降级必须留痕：真机第一次「看不到进度条」就是被静默 pcall 吃掉的
-- （logger.warn 是普通函数、变参，不是方法 → 别写成 self 冒号形状）
stub("logger", { warn = function(msg, ...)
    local line = tostring(msg)
    for i = 1, select("#", ...) do line = line .. " " .. tostring((select(i, ...))) end
    table.insert(fake.warns, line)
end, info = noop, err = noop, dbg = noop, verbose = noop })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = function(_, w) table.insert(fake.closed, w) end,
    scheduleIn = function(_, sec, fn)
        table.insert(fake.scheduled, { sec = sec, fn = fn })
    end,
    -- 独立浮层改完子控件必须自己标脏，否则页码翻了条子不动
    setDirty = function(_, w, region) table.insert(fake.dirty, w) end,
})
stub("ui/widget/infomessage", { new = function(_, a) return a end })
stub("ui/widget/confirmbox", {
    new = function(_, a) return { __confirm = true, args = a } end,
})
stub("ui/widget/menu", {
    new = function(_, args)
        return { __menu = true, args = args, switched = {},
            switchItemTable = function() end }
    end,
})
stub("ui/widget/progressbardialog", {
    new = function(_, args)
        local d = { args = args, progress = 0 }
        function d:show() end
        function d:close()
            if args.dismiss_callback then args.dismiss_callback() end
        end
        function d:reportProgress(v) self.progress = v end
        table.insert(fake.pb, d)
        return d
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

-- ---------- 阅读器 + 导航条 ----------
stub("ui/widget/imageviewer", {
    new = function(_, args)
        local w = { __viewer = true, free = noop, args = args, got = {},
                    switches = {}, _images_list_cur = 1 }
        function w:handleEvent(event)
            table.insert(self.got, event)
            return true
        end
        -- 真机 imageviewer.lua:472-491：换页先取 _images_list[n]（→ 我们的
        -- page_table.__index → servePage），再记下当前页。
        function w:switchToImageNum(num)
            if num == self._images_list_cur then return end
            local page = self.args.image[num]
            table.insert(self.switches, { num = num, page = page })
            self._images_list_cur = num
        end
        fake.viewer, fake.viewer_args = w, args
        return w
    end,
})
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
-- 布局容器：只留住「子控件列表」，坐标计算交给真机。
-- 注意形状：上游 Widget:new(o) 就是「把入参表变成实例」（widget.lua:40-41 →
-- :extend() 在 :26-31 直接给 o 挂元表并返回 o），
-- 所以 browser.lua 的 table.insert(rows, 1, page_bar.group) 插的就是这张表。
-- 桩要照抄这个语义，否则「页码条排在三键之上」这条断言测的是桩不是代码。
local function containerStub(marker, key)
    return {
        new = function(_, args)
            args[marker] = true
            table.insert(fake[key], args)
            return args
        end,
    }
end
stub("ui/widget/verticalgroup", containerStub("__vg", "vgs"))
stub("ui/widget/horizontalgroup", containerStub("__hg", "groups"))
stub("ui/widget/horizontalspan", containerStub("__span", "spans"))
stub("ui/widget/container/centercontainer", containerStub("__cc", "centers"))
stub("ui/geometry", {
    new = function(_, args)
        local g = {}
        for k, v in pairs(args) do g[k] = v end
        return g
    end,
})
-- ui/font：字名表取自上游 font.lua:40-84（fontmap）与 :85-105（sizemap）。
-- 桩里校验字名，用错名字必须当场炸出来——真机上它的表现只是「进度条不见了」。
local FONTMAP = {
    cfont = "NotoSans-Regular.ttf", tfont = "NotoSans-Bold.ttf",
    smalltfont = "NotoSans-Bold.ttf", x_smalltfont = "NotoSans-Bold.ttf",
    ffont = "NotoSans-Regular.ttf", smallffont = "NotoSans-Regular.ttf",
    largeffont = "NotoSans-Regular.ttf", rifont = "NotoSans-Regular.ttf",
    pgfont = "NotoSans-Regular.ttf", scfont = "DroidSansMono.ttf",
    hpkfont = "DroidSansMono.ttf", hfont = "NotoSans-Regular.ttf",
    infont = "DroidSansMono.ttf", smallinfont = "DroidSansMono.ttf",
    infofont = "NotoSans-Regular.ttf", smallinfofont = "NotoSans-Regular.ttf",
    smallinfofontbold = "NotoSans-Bold.ttf",
    x_smallinfofont = "NotoSans-Regular.ttf",
    xx_smallinfofont = "NotoSans-Regular.ttf",
}
local SIZEMAP = {
    cfont = 24, tfont = 26, smalltfont = 24, x_smalltfont = 22,
    ffont = 20, smallffont = 15, largeffont = 25, pgfont = 20,
    scfont = 20, rifont = 16, hpkfont = 20, hfont = 24, infont = 22,
    smallinfont = 16, infofont = 24, smallinfofont = 22,
    smallinfofontbold = 22, x_smallinfofont = 20, xx_smallinfofont = 18,
}
stub("ui/font", {
    getFace = function(_, name, size)
        assert(FONTMAP[name], "no such UI font name: " .. tostring(name))
        fake.fonts = fake.fonts or {}
        table.insert(fake.fonts, name)
        return { index = name, idx = name, face = name,
                 size = size or SIZEMAP[name], file = FONTMAP[name] }
    end,
})
-- TextWidget：宽度按字符数*6 造，够验证「按最宽版本预留格子」。
-- args.face 必给：上游 face=nil 时 updateSize 会把它送进
-- Font:getAdjustedFace(face) 并直接取 face.is_real_bold
-- （v2026.07.1 textwidget.lua:102 + font.lua:385-386）→ 报错。真机上这条
-- 报错被 showNavBar 的 pcall 吞掉 = 整页码条静默消失（2026-09-26 实证）。
stub("ui/widget/textwidget", {
    new = function(_, args)
        assert(args.face, "TextWidget:new without face crashes upstream")
        assert(type(args.face.size) == "number", "face must carry a size")
        local w = { __tw = true, text = args.text, sets = {}, freed = false,
                    face = args.face }
        function w:getSize() return { w = #self.text * 6, h = 20 } end
        function w:setText(t)
            table.insert(self.sets, t)
            self.text = t
        end
        function w:free() self.freed = true end
        table.insert(fake.texts, w)
        return w
    end,
})
-- 上游 HorizontalScrollBar 的外部形状：set(low, high) 画滑块，
-- touch_dimen 只在 paintTo 里写（v2026.07.1 :106-110），首帧前是 nil。
stub("ui/widget/horizontalscrollbar", {
    new = function(_, args)
        assert(not fake.break_scrollbar, "horizontal scrollbar unavailable")
        local w = { __sb = true, args = args, width = args.width,
                    height = args.height, sets = {} }
        function w:paintTo(_bb, x, y)
            self.touch_dimen = { x = x, y = y - 16, w = self.width,
                                 h = self.height + 32 }
        end
        function w:set(low, high)
            table.insert(self.sets, { low = low, high = high })
        end
        fake.sb = w
        return w
    end,
})

package.loaded["browser"] = nil
local Browser = require("browser")
local Downloader = require("runtime.downloader")
local memFs = require("memfs")

local tests = {}

local URLS = { "https://cdn.example.com/1.webp",
               "https://cdn.example.com/2.webp",
               "https://cdn.example.com/3.webp" }

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function assert_close(label, expected, actual)
    assert(type(actual) == "number" and math.abs(actual - expected) < 1e-9,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

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
    fake.shown, fake.closed, fake.scheduled, fake.dirty, fake.pb = {}, {}, {}, {}, {}
    fake.viewer, fake.viewer_args = nil, nil
    fake.bars, fake.button_tables, fake.vgs = {}, {}, {}
    fake.groups, fake.spans, fake.centers, fake.texts = {}, {}, {}, {}
    fake.sb, fake.break_scrollbar, fake.fonts, fake.warns = nil, false, {}, {}
    b = Browser.new{ infoMessage = noop, netclient = net, downloader = dl }
    b.cookies = { headerFor = function() return nil end }
    b._hasMember = function() return false end
    b.info_calls, b.ep_calls = 0, 0
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadEp" then
            b.ep_calls = b.ep_calls + 1
            return URLS
        end
        if path == "comic.loadInfo" then
            b.info_calls = b.info_calls + 1
            return { title = "航海王", chapters = { ["7"] = "第7话" } }
        end
        return nil
    end
    return b, dl, fs, net
end

--- 开一章并把进度条「画」出来（paintTo 之后 touch_dimen 才存在）
local function openChapter(b)
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    assert(fake.sb, "progress bar created")
    fake.sb:paintTo(nil, 0, 760)
    return fake.sb
end

local function ges(kind, sb, x)
    return { ges = kind, pos = { x = x, y = 770 } }
end

--- 落在第 pn 页区间中间的比例位置（轨道从 0 开始，宽 sb.width）
local function xOfPage(sb, pn, total)
    return (sb.width * ((pn - 0.5) / total))
end

local function runTicks(n)
    for _ = 1, n do
        local e = table.remove(fake.scheduled, 1)
        if e and e.fn then pcall(e.fn) end
    end
end

-- ①比例→页码：钳制 + 分段映射，且与滑块的画法严格互逆
function tests.ratio_maps_to_pages_and_clamps()
    local b = Browser.new{ infoMessage = noop }
    assert_eq("left edge is page 1", 1, b:_pageFromRatio(0, 5))
    assert_eq("middle of 6 is page 4", 4, b:_pageFromRatio(0.5, 6))
    assert_eq("negative ratio clamps to 1", 1, b:_pageFromRatio(-0.4, 5))
    assert_eq("ratio above 1 clamps to the last page", 5, b:_pageFromRatio(1.9, 5))
    assert_eq("exactly 1 clamps to the last page", 5, b:_pageFromRatio(1, 5))
    assert_eq("no ratio", nil, b:_pageFromRatio(nil, 5))
    assert_eq("garbage ratio", nil, b:_pageFromRatio("x", 5))
    assert_eq("empty chapter", nil, b:_pageFromRatio(0.5, 0))
    assert_eq("no total", nil, b:_pageFromRatio(0.5, nil))
    -- 互逆：每一页滑块的左边缘都必须读回该页
    for total = 1, 9 do
        for pn = 1, total do
            local low = b:_pageThumb(pn, total)
            assert_eq("thumb left edge reads back page " .. pn .. "/" .. total,
                pn, b:_pageFromRatio(low, total))
        end
    end
    return true
end

function tests.thumb_window_is_one_page_wide_and_clamped()
    local b = Browser.new{ infoMessage = noop }
    local l1, h1 = b:_pageThumb(1, 4)
    assert_eq("page 1 low", 0, l1)
    assert_close("page 1 high", 0.25, h1)
    local l4, h4 = b:_pageThumb(4, 4)
    assert_close("last page low", 0.75, l4)
    assert_eq("last page high", 1, h4)
    assert_eq("below range clamps to page 1", 0, (b:_pageThumb(0, 4)))
    assert_close("above range clamps to the last thumb", 0.75,
        (select(1, b:_pageThumb(99, 4))))
    local l0, h0 = b:_pageThumb(1, 0)
    assert_eq("no pages → whole track", 0, l0)
    assert_eq("no pages → whole track high", 1, h0)
    return true
end

function tests.label_reads_current_over_total()
    local b = Browser.new{ infoMessage = noop }
    assert_eq("label text", "第 3 / 12 页", b:_pageLabel(3, 12))
    return true
end

-- ③⑤结构：页码条排在三键之上；文本格按最宽版本（"第 M / M 页"）预留，
-- 否则 HorizontalGroup 的偏移算一次就不再更新，页码变长会把条挤位
function tests.bar_sits_above_the_buttons_with_a_reserved_label()
    local b, dl, fs, net = makeBrowser()
    openChapter(b)
    local sb = fake.sb
    assert_eq("one page bar", 1, #fake.groups)
    local group = fake.groups[1]
    assert_eq("group children: span/label/span/bar/span", 5, #group)
    assert(group[1].__span and group[3].__span and group[5].__span,
        "spans separate the parts")
    assert_eq("the bar itself is in the group", sb, group[4])
    assert_eq("label cell is a CenterContainer", true, group[2].__cc)
    -- 格子必须在构造时就带上 dimen：WidgetContainer:getSize 只在 self.dimen
    -- 存在时返回固定尺寸（v2026.07.1 widgetcontainer.lua:21-24），否则退回
    -- 「第一个子控件的当前尺寸」——那等于第 1 页的窄文本，页码变长就压到轨道上
    assert_eq("cell pinned to the widest label", #("第 3 / 3 页") * 6,
        fake.centers[1].dimen.w)
    -- 两次 TextWidget：先探最宽（3/3），再建初始页码（1/3），探针要 free
    assert_eq("probe + label", 2, #fake.texts)
    assert_eq("probe text is the widest one", "第 3 / 3 页", fake.texts[1].text)
    assert_eq("probe released", true, fake.texts[1].freed)
    -- 字体：上游「分页显示」专用字面 pgfont，且两个 TextWidget 共用同一个 face
    -- （getFace 每次新建对象，共用才能共享字形缓存）
    assert_eq("uses the pagination font", "pgfont", fake.fonts[1])
    assert_eq("face looked up once", 1, #fake.fonts)
    assert_eq("label reuses that face", fake.texts[1].face, fake.texts[2].face)
    assert_eq("label starts at page 1", "第 1 / 3 页", fake.texts[2].text)
    assert_eq("track gives the screen the label plus 3 spans",
        600 - 3 * 8 - #("第 3 / 3 页") * 6, sb.width)
    assert_eq("thumb starts on page 1", 0, sb.sets[1].low)
    assert_close("thumb is one page wide", 1 / 3, sb.sets[1].high)
    -- 四键照常在工作
    local btns = fake.button_tables[#fake.button_tables].buttons[1]
    assert_eq("still four nav buttons", 4, #btns)
    local vg = fake.vgs[#fake.vgs]
    assert_eq("nav strip has two rows", 2, #vg)
    assert_eq("row 1 is the page bar", fake.groups[1], vg[1])
    assert_eq("row 2 is the button table", true, vg[2].__bt)
    return true
end

-- ②点轨道：跳到那一页，但取图走延迟——手势回调里一个网络请求都不能发
-- （单页最坏 6s，正踩安卓 5s 输入超时）
function tests.tap_jumps_but_defers_the_fetch()
    local b, dl, fs, net = makeBrowser()
    local sb = openChapter(b)
    local label = fake.texts[2]
    fake.dirty = {}
    local before = net.total
    assert_eq("tap handled", true,
        sb.onTapScroll(sb, nil, ges("tap", sb, xOfPage(sb, 3, 3))))
    assert_eq("no synchronous fetch inside the gesture", before, net.total)
    assert_eq("reader moved to page 3", 3, fake.viewer._images_list_cur)
    assert_eq("label previewed page 3", "第 3 / 3 页", label.text)
    assert(#fake.scheduled > 0, "the fetch is left to the prefetch tick")
    assert(#fake.dirty > 0, "the jump repaints the strip")
    runTicks(20)
    assert(net.total > before, "the queued page eventually gets fetched")
    return true
end

-- ②拖动：pan / hold_pan 只改显示，抬起才翻页。跟手指一路跳页 =
-- 一长串同步取图，必炸 ANR
function tests.drag_previews_and_only_releases_jump()
    local b, dl, fs, net = makeBrowser()
    local sb = openChapter(b)
    local label = fake.texts[2]
    local before = net.total
    for _, kind in ipairs({ "pan", "hold_pan", "pan", "hold_pan" }) do
        local pn = kind == "pan" and 2 or 3
        sb.onPanScroll(sb, nil, ges(kind, sb, xOfPage(sb, pn, 3)))
    end
    assert_eq("dragging turns no page", 1, fake.viewer._images_list_cur)
    assert_eq("dragging fetches nothing", before, net.total)
    assert_eq("but the label follows the finger", "第 3 / 3 页", label.text)
    assert_eq("and so does the thumb", 2 / 3, sb.sets[#sb.sets].low)
    -- 松手：停在第 3 页 → 真跳
    sb.onPanScrollRelease(sb, nil, ges("pan_release", sb, xOfPage(sb, 3, 3)))
    assert_eq("release jumps to the previewed page", 3,
        fake.viewer._images_list_cur)
    assert_eq("still no synchronous fetch", before, net.total)
    return true
end

-- ③上游把六个手势别名成同一个方法（horizontalscrollbar.lua:86-90）。
-- 只盖 onTapScroll 的话另外五个仍走原实现 → 原实现读 scroll_callback（我们
-- 没给）→ 拖动/长按彻底没反应。六个必须全是指向同一个函数的实例字段。
tests.every_drag_gesture_reaches_our_handler = function()
    local b = makeBrowser()
    local sb = openChapter(b)
    local names = { "onTapScroll", "onHoldScroll", "onHoldPanScroll",
                    "onHoldReleaseScroll", "onPanScroll",
                    "onPanScrollRelease" }
    for _, n in ipairs(names) do
        assert_eq(n .. " is ours", "function", type(sb[n]))
        assert_eq(n .. " shares the one handler", sb.onTapScroll, sb[n])
    end
    -- 每个入口都得认（这里挑最要紧的两种：hold 跳页、hold_pan 只预览）
    sb:paintTo(nil, 0, 760)
    sb.onHoldScroll(sb, nil, ges("hold", sb, xOfPage(sb, 2, 3)))
    assert_eq("hold jumps", 2, fake.viewer._images_list_cur)
    local cur = fake.viewer._images_list_cur
    sb.onHoldPanScroll(sb, nil, ges("hold_pan", sb, xOfPage(sb, 3, 3)))
    assert_eq("hold_pan only previews", cur, fake.viewer._images_list_cur)
    sb.onHoldReleaseScroll(sb, nil, ges("hold_release", sb, xOfPage(sb, 3, 3)))
    assert_eq("hold_release jumps", 3, fake.viewer._images_list_cur)
    return true
end

-- ④条子是叠在阅读器上的独立浮层：点图片翻页（根本碰不到条子）时也必须跟着动
function tests.page_flips_from_anywhere_repaint_the_bar()
    local b, dl, fs, net = makeBrowser()
    local sb = openChapter(b)
    local label = fake.texts[2]
    -- 真机换页路径：ImageViewer 取 _images_list[n] → page_table.__index → servePage
    local page = fake.viewer_args.image[2]
    assert(page, "page 2 served")
    assert_eq("label followed the reader", "第 2 / 3 页", label.text)
    assert_close("thumb followed the reader", 1 / 3, sb.sets[#sb.sets].low)
    assert_eq("the strip asked to be repainted", 1, #fake.dirty)
    -- 同一页重复取（ImageViewer 回翻也会重取）不再刷一遍脏区
    fake.dirty = {}
    assert(fake.viewer_args.image[2])
    assert_eq("repainting only happens on a real change", 0, #fake.dirty)
    return true
end

-- 首帧之前没有 touch_dimen（上游在 paintTo 里才写），此时来的手势只能忽略：
-- 拿 nil 去算比例就是报错，报错冒到主循环就是闪退
function tests.gestures_before_the_first_paint_are_ignored()
    local b, dl, fs, net = makeBrowser()
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local sb = fake.sb
    assert_eq("no touch zone before painting", nil, sb.touch_dimen)
    local before = net.total
    assert_eq("tap is swallowed harmlessly", true,
        sb.onTapScroll(sb, nil, ges("tap", sb, 100)))
    assert_eq("no page change", 1, fake.viewer._images_list_cur)
    assert_eq("no traffic", before, net.total)
    assert_eq("no thumb move", 1, #sb.sets)
    -- 缺 ges / 缺 pos 的事件形状也不能炸
    assert_eq("gesture without coordinates", true, sb.onTapScroll(sb, nil, {}))
    assert_eq("nil gesture", true, sb.onTapScroll(sb, nil, nil))
    return true
end

-- ⑥降级：进度条那套模块装不上（别的设备/别的版本）时，只留三键导航条，
-- 阅读器和翻页完全照常
function tests.nav_bar_survives_without_the_scrollbar()
    local b, dl, fs, net = makeBrowser()
    fake.break_scrollbar = true
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    assert_eq("no page bar built", nil, fake.sb)
    assert_eq("but the reader opened", true, fake.viewer ~= nil)
    local bar = fake.bars[1]
    assert(bar, "nav bar still shown")
    local vg = fake.vgs[#fake.vgs]
    assert_eq("buttons-only strip", 1, #vg)
    assert_eq("row 1 is the button table", true, vg[1].__bt)
    -- 降级必须留痕：静默 pcall 是这次真机排查最大的障碍（什么日志都没有）
    local said = false
    for _, w in ipairs(fake.warns) do
        if w:find("page bar unavailable", 1, true) then said = w end
    end
    assert(said, "the degradation must be logged, warns were: "
        .. table.concat(fake.warns, " | "))
    local btns = fake.button_tables[#fake.button_tables].buttons[1]
    assert_eq("four buttons", 4, #btns)
    btns[2].callback()
    local menu
    for _, w in ipairs(fake.shown) do if w.__menu then menu = w end end
    assert(menu, "toc opens without the progress bar")
    -- 取页路径上的 paint 钩子不能留悬空引用
    assert(fake.viewer_args.image[2], "page 2 still served")
    return true
end

return tests
