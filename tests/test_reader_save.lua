-- unit test: browser.lua 章节阅读器的「另存本页」（长按 + 导航条【存图】键）
-- 关注点（每条都对应真机/规范约束）：
--   ①存的是图床原图字节，不是截屏：落点 <dataDir>/ezvenera/saved/<书名>/<章节>_pNNN.ext；
--   ②书名的中文必须留在路径里（Lua 的 %w 只认 ASCII，套 safeId 会压成一串下划线），
--     截断必须停在 UTF-8 码点边界，否则产生非法路径名；
--   ③这一页还没有字节时**绝不在手势回调里联网**：只排进预取队列 + 一句提示
--     （一次同步取图最坏 6s，正踩安卓 5s 输入超时，见 browser.lua 的 IMG_OPTS）；
--   ④长按只接管上游「按住不动 → 墨水屏全刷」那一支（v2026.07.1
--     imageviewer.lua:637-652），带位移的一支必须照常平移；
--   ⑤位移判定用我们自己记的起点：上游 onPan 会把 _pan_relative_* 改写成
--     增量（:654-659），拿它判断会把「拖完抬起」误认成长按。
-- browser.lua 顶层 require KOReader 前端模块 → 测试环境先桩化。

local noop = function() end
local function stub(name, mod)
    package.preload[name] = function() return mod end
    package.loaded[name] = nil
end

local fake = {
    shown = {}, closed = {}, scheduled = {}, infos = {}, warns = {}, pb = {},
    viewer = nil, viewer_args = nil, bars = {}, button_tables = {},
}

stub("logger", {
    warn = function(msg, ...)
        local line = tostring(msg)
        for i = 1, select("#", ...) do
            line = line .. " " .. tostring((select(i, ...)))
        end
        table.insert(fake.warns, line)
    end,
    info = noop, err = noop, dbg = noop, verbose = noop,
})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/uimanager", {
    show = function(_, w) table.insert(fake.shown, w) end,
    close = function(_, w) table.insert(fake.closed, w) end,
    scheduleIn = function(_, sec, fn)
        table.insert(fake.scheduled, { sec = sec, fn = fn })
    end,
    setDirty = noop,
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
-- 真机 <dataDir> 就是 /sdcard/koreader；这里同时钉住「saved 与 downloads 并列」
stub("datastorage", { getDataDir = function() return "/sdcard/koreader" end })

-- ---------- 阅读器 ----------
-- 类方法照抄上游 v2026.07.1（devsrc 实档 :629-659），实例方法留空 ——
-- _hookLongPressSave 要盖的正是实例，且 base 必须还能通过 __index 取到。
local ViewerClass = {}
function ViewerClass:onHold(_, ges)
    self._panning = true
    self._pan_relative_x = ges.pos.x
    self._pan_relative_y = ges.pos.y
    return true
end
function ViewerClass:onHoldRelease(_, ges)
    if self._panning then
        self._panning = false
        self._pan_relative_x = ges.pos.x - self._pan_relative_x
        self._pan_relative_y = ges.pos.y - self._pan_relative_y
        if math.abs(self._pan_relative_x) < self.pan_threshold
            and math.abs(self._pan_relative_y) < self.pan_threshold then
            self.full_refresh = (self.full_refresh or 0) + 1
        else
            self.panned = (self.panned or 0) + 1
        end
    end
    return true
end
-- 上游 onPan 写的是**增量**（imageviewer.lua:654-659），不是坐标差
function ViewerClass:onPan(_, ges)
    self._panning = true
    self._pan_relative_x = ges.relative.x
    self._pan_relative_y = ges.relative.y
    return true
end

stub("ui/widget/imageviewer", {
    new = function(_, args)
        local w = setmetatable({
            __viewer = true, free = noop, args = args, got = {},
            _images_list_cur = 1, _panning = false, pan_threshold = 5,
        }, { __index = ViewerClass })
        function w:handleEvent(event)
            table.insert(self.got, event)
            return true
        end
        function w:switchToImageNum(num)
            if num == self._images_list_cur then return end
            local page = self.args.image[num]
            self.last_page = page
            self._images_list_cur = num
        end
        -- 上游构造函数里就把列表的第 1 页取成 self.image（v2026.07.1
        -- imageviewer.lua:145-150），这一取正是我们首屏延迟 + 排预取的入口。
        -- 不照做的话测试里根本不会触发取页路径。
        w.image = args.image[1]
        fake.viewer, fake.viewer_args = w, args
        return w
    end,
})
stub("ui/widget/container/bottomcontainer", {
    new = function(_, args)
        local w = { __bar = true, args = args }
        function w:handleEvent() return nil end
        function w:contentRange() return { w = 600, h = 60 } end
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
stub("ui/widget/verticalgroup", {
    new = function(_, args)
        args.__vg = true
        return args
    end,
})

package.loaded["browser"] = nil
local Browser = require("browser")
local Downloader = require("runtime.downloader")
local memFs = require("memfs")

local tests = {}

local URLS = { "https://cdn.example.com/1.webp",
               "https://cdn.example.com/2.jpg",
               "https://cdn.example.com/3.png" }

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function makeBrowser(overrides)
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
    fake.shown, fake.closed, fake.scheduled, fake.infos, fake.warns =
        {}, {}, {}, {}, {}
    fake.pb, fake.viewer, fake.viewer_args = {}, nil, nil
    fake.bars, fake.button_tables = {}, {}
    b = Browser.new{
        infoMessage = function(text) table.insert(fake.infos, tostring(text)) end,
        netclient = net, downloader = dl,
        saved_dir = overrides and overrides.saved_dir,
    }
    b.cookies = { headerFor = function() return nil end }
    b._hasMember = function() return false end
    b._awaitSource = function(_, _k, path)
        if path == "comic.loadEp" then return URLS end
        if path == "comic.loadInfo" then
            return { title = "航海王", chapters = { ["7"] = "第7话" } }
        end
        return nil
    end
    return b, dl, fs, net
end

local function runTick()
    local e = table.remove(fake.scheduled, 1)
    if e and e.fn then e.fn() end
    return e ~= nil
end

--- 开一章并把首页补画出来（首屏不联网，取页走预取节拍）
local function openChapter(b)
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    assert(fake.viewer, "reader opened")
    for _ = 1, 4 do
        if not runTick() then break end
    end
    return fake.viewer
end

local function toastText()
    for i = #fake.shown, 1, -1 do
        if fake.shown[i].text then return fake.shown[i].text end
    end
end

local function navButtons()
    local args = fake.button_tables[#fake.button_tables]
    assert(args, "nav bar button table shown")
    return args.buttons[1]
end

--- 存图目录里的文件名（排序后）
local function savedFiles(fs, dir)
    local names = fs.list(dir)
    return names or {}
end

-- ① 缓存命中 → 原图字节直接落盘，路径带中文书名，后缀跟 URL
function tests.saves_the_cached_bytes_under_the_book_title()
    local b, _dl, fs = makeBrowser{ saved_dir = "/sdcard/koreader/ezvenera/saved" }
    openChapter(b)
    navButtons()[3].callback()          -- 【存图】
    local dir = "/sdcard/koreader/ezvenera/saved/航海王"
    local names = savedFiles(fs, dir)
    assert_eq("one file saved", 1, #names)
    assert_eq("name carries chapter and page", "第7话_p001.webp", names[1])
    assert_eq("bytes are the source image, not a screenshot",
        "IMG:https://cdn.example.com/1.webp", fs.state.files[dir .. "/" .. names[1]])
    assert(toastText():find("已保存第 1 页", 1, true),
        "the toast names the page: " .. tostring(toastText()))
    return true
end

-- 后缀来自 URL（.jpg / .png），不是凭空写死 .img
function tests.extension_follows_the_source_url()
    local b, _dl, fs = makeBrowser{ saved_dir = "/S" }
    local v = openChapter(b)
    v:switchToImageNum(2)               -- 取第 2 页进缓存
    for _ = 1, 4 do
        if not runTick() then break end
    end
    navButtons()[3].callback()
    local names = savedFiles(fs, "/S/航海王")
    assert_eq("page 2 saved", 1, #names)
    assert_eq("jpg suffix kept", "第7话_p002.jpg", names[1])
    return true
end

-- ② 中文书名 / 章节名留在路径里；非法字符换成 _
function tests.title_keeps_chinese_and_drops_path_separators()
    local b = makeBrowser()
    assert_eq("chinese kept", "航海王 第7话", b:_safeName("航海王 第7话"))
    assert_eq("separators replaced", "a_b_c_d", b:_safeName('a/b\\c:d'))
    assert_eq("control bytes replaced", "a_b", b:_safeName("a\1b"))
    assert_eq("empty name falls back", "ezvenera", b:_safeName("///"))
    return true
end

-- 截断停在码点边界：按字节切会把三字的汉字切成非法序列
function tests.truncation_lands_on_a_codepoint_boundary()
    local b = makeBrowser()
    local name = b:_safeName("航海王航海王航海王", 10)
    assert(#name <= 10, "respects the byte budget, got " .. #name)
    assert_eq("whole characters kept", 9, #name)
    assert_eq("no half codepoint at the tail", "航海王", name)
    return true
end

-- 真机落点：未注入 saved_dir 时走 DataStorage，与 downloads 目录并列
function tests.saved_dir_sits_next_to_downloads()
    local b = makeBrowser()
    assert_eq("dataDir based", "/sdcard/koreader/ezvenera/saved", b:savedBasedir())
    local b2 = makeBrowser{ saved_dir = "/tmp/saved" }
    assert_eq("injected dir wins", "/tmp/saved", b2:savedBasedir())
    return true
end

-- ③ 这一页还没有字节：不联网、只排进队列 + 一句提示（ANR 红线）
function tests.missing_bytes_queue_the_fetch_instead_of_blocking()
    local b, _dl, fs, net = makeBrowser{ saved_dir = "/S" }
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    assert(fake.viewer, "reader opened")
    assert_eq("首屏不在点击回调里联网", 0, net.total)
    local before = net.total
    navButtons()[3].callback()          -- 【存图】：第 1 页还没有字节
    assert_eq("存图不在手势回调里下载", before, net.total)
    assert_eq("nothing written", 0, #savedFiles(fs, "/S/航海王"))
    assert(toastText():find("还没取到图", 1, true),
        "told the user why: " .. tostring(toastText()))
    assert(#fake.scheduled > 0, "prefetch tick scheduled")
    runTick()                            -- 事件循环跑到下一拍
    assert_eq("the tick fetched the page", before + 1, net.total)
    navButtons()[3].callback()
    local names = savedFiles(fs, "/S/航海王")
    assert_eq("saved on the second press", 1, #names)
    assert_eq("file name is deterministic", "第7话_p001.webp", names[1])
    return true
end

-- 离线章节：字节在本地文件里，直接复制，一个网络请求都不发
function tests.offline_chapter_copies_the_local_file()
    local b, dl, fs = makeBrowser{ saved_dir = "/S" }
    -- 先把整章下到本地（逐拍）
    local done = {}
    b:downloadChapter("baozi", "c1", "7", "航海王", "第7话",
        function(ok) done.ok = ok end)
    for _ = 1, 60 do
        if done.ok ~= nil or #fake.scheduled == 0 then break end
        runTick()
    end
    assert_eq("chapter downloaded", true, done.ok)
    fake.shown, fake.scheduled = {}, {}
    b:showReader("baozi", "c1", "7", "航海王", "第7话")
    local v = fake.viewer
    local man = dl:manifestOf("baozi", "c1", "7")
    assert(man, "manifest present")
    v._images_list_cur = 2
    local before = (function()
        local n = 0
        for _ in pairs(fs.state.files) do n = n + 1 end
        return n
    end)()
    navButtons()[3].callback()
    local names = savedFiles(fs, "/S/航海王")
    assert_eq("page 2 copied", 1, #names)
    assert_eq("copied bytes match the downloaded page",
        fs.state.files[man.dir .. "/" .. man.pages[2].file],
        fs.state.files["/S/航海王/" .. names[1]])
    assert_eq("no extra file anywhere else", before + 1,
        (function()
            local n = 0
            for _ in pairs(fs.state.files) do n = n + 1 end
            return n
        end)())
    return true
end

-- ④ 长按（按住不动抬起）→ 存当前显示的那一页，且不再触发上游全刷
function tests.hold_without_move_saves_instead_of_refreshing()
    local b, _dl, fs = makeBrowser{ saved_dir = "/S" }
    local v = openChapter(b)
    assert(v.onHold ~= ViewerClass.onHold, "hold handler got wrapped")
    v:onHold(nil, { ges = "hold", pos = { x = 100, y = 400 } })
    assert_eq("upstream hold state still set", true, v._panning)
    v:onHoldRelease(nil, { ges = "hold_release", pos = { x = 102, y = 401 } })
    assert_eq("no full refresh stolen from the reader", nil, v.full_refresh)
    assert_eq("panning cleared like upstream does", false, v._panning)
    local names = savedFiles(fs, "/S/航海王")
    assert_eq("page saved by the hold", 1, #names)
    assert_eq("saved the page on screen", "第7话_p001.webp", names[1])
    return true
end

-- ④' 长按带位移 → 仍是平移（缩放后看图靠这一支），不存图
function tests.hold_with_move_still_pans()
    local b, _dl, fs = makeBrowser{ saved_dir = "/S" }
    local v = openChapter(b)
    v:onHold(nil, { ges = "hold", pos = { x = 100, y = 400 } })
    v:onHoldRelease(nil, { ges = "hold_release", pos = { x = 300, y = 420 } })
    assert_eq("panned once", 1, v.panned)
    assert_eq("no full refresh either", nil, v.full_refresh)
    assert_eq("nothing saved", 0, #savedFiles(fs, "/S/航海王"))
    return true
end

-- ⑤ 位移判定用我们自己记的起点：onPan 把 _pan_relative_* 写成增量之后，
-- 抬手仍在按住点上 → 判成「没动」（照上游那两个字段算会差出一屏）
function tests.drag_then_release_on_the_hold_point_saves()
    local b, _dl, fs = makeBrowser{ saved_dir = "/S" }
    local v = openChapter(b)
    v:onHold(nil, { ges = "hold", pos = { x = 100, y = 400 } })
    v:onPan(nil, { ges = "pan", relative = { x = 240, y = 0 } })
    assert_eq("upstream pan fields rewritten as increments", 240, v._pan_relative_x)
    v:onHoldRelease(nil, { ges = "hold_release", pos = { x = 101, y = 400 } })
    assert_eq("judged as no movement", nil, v.panned)
    assert_eq("saved", 1, #savedFiles(fs, "/S/航海王"))
    return true
end

-- 前端没有这两个 handler（老版本 / 非触屏）时不盖：长按保持上游行为
function tests.hook_refuses_when_upstream_handlers_are_missing()
    local b = makeBrowser()
    local v = { _images_list_cur = 1, pan_threshold = 5 }
    assert_eq("nothing to wrap", false, b:_hookLongPressSave(v, noop))
    assert_eq("no hold override written", nil, rawget(v, "onHold"))
    return true
end

return tests
