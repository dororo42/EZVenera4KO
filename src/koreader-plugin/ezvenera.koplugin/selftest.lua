--[[
EZVenera for KOReader — selftest.lua
【临时排查件（任务 #16），诊断完连同 browser.lua 的 diag 探针一起删除】

真机三次同签名 SIGSEGV（libluajit 同一 PC，向野指针 STR）需要用 A/B 实验定性：
  A 纯 Lua 解析压力 —— 直接驱动 runtime/htmlparse 引擎 + JSON 编码，
    **不经过 quickjs / FFI 回调 / 网络 / 图片解码**。若 A 复现同一 PC，
    根因在 Lua 侧数据结构churn（分配器/GC/表），与 JS 引擎无关。
  B 完整阅读路径 —— browser:showReader(...)，即用户实际会崩的那条链
    （JS_Eval → __ezv_post 回调 → 解析 → 网络 → ImageViewer 解码）。
每个采样点打印 VmRSS/VmHWM/VmPeak + Lua 占用，崩溃时看曲线末段即可判
"分配耗尽" 还是 "指针破坏"。语料 = 真机崩溃那一章的原始 HTML
（/sdcard/koreader/ezv_probe.html，101648 B，baozi 0_17）。
]]

local oklog, logger = pcall(require, "logger")
if not oklog or not logger then logger = nil end
local function log(...)
    if logger and logger.warn then logger.warn(...) end
end

local SelfTest = {}

local CORPUS = "/sdcard/koreader/ezv_probe.html"

--- 进程内存 + Lua 占用采样（Android: /proc/self/status）
local function sample(tag)
    local rss, hwm, peak = "?", "?", "?"
    local f = io.open and io.open("/proc/self/status", "r")
    if f then
        local t = f:read("*a")
        f:close()
        rss = t:match("VmRSS:%s+(%d+)") or "?"
        hwm = t:match("VmHWM:%s+(%d+)") or "?"
        peak = t:match("VmPeak:%s+(%d+)") or "?"
    end
    local okl, kb = pcall(collectgarbage, "count")
    log("ezveneraST", tag, " rss_kb=", rss, " hwm_kb=", hwm, " peak_kb=", peak,
        " lua_kb=", (okl and math.floor(kb)) or "?")
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- 复刻 baozi 章节页在真机 logcat 里出现的操作序列（热路径形状）
local function exerciseChapter(eng)
    -- 页面结构：div#viewer > ul.bar.QB > li > p > amp-img
    local page = eng:handle({ ["function"] = "querySelectorAll", key = "d",
                              query = "div#viewer ul.bar.QB li p amp-img" })
    local n = (type(page) == "table" and page[1] ~= nil) and #page or 0
    for i = 1, n do
        eng:handle({ ["function"] = "getAttributes", doc = "d", key = page[i] })
    end
    local box = eng:handle({ ["function"] = "querySelector", key = "d",
                             query = "div.header" })
    if type(box) == "number" then
        local kids = eng:handle({ ["function"] = "dom_querySelectorAll",
                                  doc = "d", key = box, query = "span" })
        for _, k in ipairs(type(kids) == "table" and kids or {}) do
            eng:handle({ ["function"] = "getText", doc = "d", key = k })
        end
    end
    -- 章节列表块（详情/章节页同款churn）
    local lst = eng:handle({ ["function"] = "dom_querySelectorAll", doc = "d",
                             key = 1, query = "a" })
    for _, k in ipairs(type(lst) == "table" and lst or {}) do
        eng:handle({ ["function"] = "getAttributes", doc = "d", key = k })
    end
    return n
end

--- 模式 A：纯 Lua，不碰 quickjs/网络/解码
function SelfTest.parseStress(rounds)
    rounds = rounds or 60
    local html = readAll(CORPUS)
    if not html then
        return "语料缺失：" .. CORPUS .. "（先 adb push 一份章节 HTML）"
    end
    local okHP, HtmlParse = pcall(require, "runtime/htmlparse")
    if not okHP or not HtmlParse then
        return "htmlparse 加载失败：" .. tostring(HtmlParse)
    end
    local okj, J = pcall(require, "json")
    log("ezveneraST A begin bytes=", #html, " rounds=", rounds,
        " json=", tostring(okj))
    sample("A start")
    for r = 1, rounds do
        local eng = HtmlParse.newEngine()
        eng:handle({ ["function"] = "parse", key = "d", data = html })
        local npages = exerciseChapter(eng)
        if okj then
            -- 桥回包形状：几百个字符串/数字的表 → JSON 编码（真实分配压力）
            local payload = { pages = {}, title = html:sub(1, 200) }
            for i = 1, npages do payload.pages[i] = "https://img.example/" .. i end
            pcall(function() return J.encode(payload) end)
        end
        eng:handle({ ["function"] = "dispose", key = "d" })
        sample(("A r=%d/%d pages=%d"):format(r, rounds, npages))
    end
    log("ezveneraST A done")
    return "A 完成：" .. rounds .. " 轮（未崩溃 = 纯 Lua 路径不是充分条件）"
end

--- 模式 B：完整阅读路径（与用户崩溃时同一条链）
function SelfTest.readerPath(browser, sourceKey, comicId, epId, comicTitle, chapTitle)
    log("ezveneraST B begin", tostring(sourceKey), tostring(comicId), tostring(epId))
    sample("B before showReader")
    browser:showReader(sourceKey, comicId, epId, comicTitle, chapTitle)
    sample("B after showReader")
    return "B 完成：阅读器已打开，停在页内 90s 采样（看 ezveneraDIAG tick）"
end

--- 模式 C：逐页「下载 + 解码 + 释放」，不建 ImageViewer。
--- A/B 已排除纯 Lua 与静置阅读页；剩下的差异变量就是**每页图片本身**
--- （尺寸/格式 → C 侧解码 → BB 生命周期），所以把整章图片按翻页顺序过一遍，
--- 打印每页字节数与解码后的 w/h/stride。崩在哪一页 = 那一页的形状有问题。
function SelfTest.imageStress(browser, sourceKey, comicId, epId, limit)
    local args = '["' .. tostring(comicId) .. '","' .. tostring(epId) .. '"]'
    local ep = browser:_awaitSource(sourceKey, "comic.loadEp", args)
    if type(ep) ~= "table" then return "C 取章节失败" end
    local images = type(ep.images) == "table" and ep.images or ep
    if images[1] == nil then return "C 章节无图" end
    local n = math.min(#images, limit or #images)
    local netclient = browser.netclient
    local proxy = ""
    if browser.settings and browser.settings:isProxyEnabled() then
        proxy = browser.settings:getProxyURL() or ""
    end
    local okri, RenderImage = pcall(require, "ui/renderimage")
    log("ezveneraST C begin pages=", #images, " stress=", n,
        " renderimage=", tostring(okri))
    sample("C start")
    for i = 1, n do
        local item = images[i]
        local url = type(item) == "table" and item.url or item
        local ok, resp = pcall(function()
            return netclient:request{ url = url, method = "GET", proxy = proxy }
        end)
        local data = ok and type(resp) == "table" and resp.body or nil
        if type(data) ~= "string" then data = nil end
        log("ezveneraST C i=" .. i .. " bytes=" .. (data and #data or "nil")
            .. " status=" .. tostring(ok and type(resp) == "table" and resp.status or resp))
        if data then
            local okd, bb = pcall(function()
                return RenderImage:renderImageData(data, #data, false)
            end)
            if okd and bb then
                log("ezveneraST C i=" .. i .. " decoded " .. tonumber(bb.w) .. "x"
                    .. tonumber(bb.h) .. " stride=" .. tonumber(bb.stride)
                    .. " alloc=" .. tostring(bb.config))
                pcall(function() bb:free() end)
            else
                log("ezveneraST C i=" .. i .. " DECODE FAIL", tostring(bb))
            end
        end
        sample("C i=" .. i)
    end
    log("ezveneraST C done")
    return "C 完成：" .. n .. " 页解码（未崩 = 解码链不是充分条件）"
end

--- 模式 D：真实翻页 + 重绘（ImageViewer:switchToImageNum + UIManager:widgetRepaint）。
--- A/B/C 都不崩，剩下的唯一变量就是**翻页时的 BB 释放/重绘链**：我们的
--- page_table.__index 每次返回**新** BB，viewer 在换页时 free 旧 BB，
--- ImageWidget 又可能持有已被 free 的悬垂 data 指针。逐页翻 + 逐页重绘 = 用户
--- 手工做的事，只是快得多；崩在第几页即定位。
function SelfTest.pageStress(browser, sourceKey, comicId, epId, comicTitle, chapTitle, pages)
    browser:showReader(sourceKey, comicId, epId, comicTitle, chapTitle)
    local UIManager = require("ui/uimanager")
    local stack = UIManager._window_stack or {}
    local viewer
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w.switchToImageNum then viewer = w break end
    end
    if not viewer then
        return "D 窗口栈里没有 ImageViewer（层数=" .. tostring(#stack) .. "）"
    end
    local nb = tonumber(viewer._images_list_nb) or 0
    local n = math.min(nb, pages or nb)
    log("ezveneraST D begin nb=", nb, " stress=", n,
        " widget=", tostring(viewer.name))
    for i = 1, n do
        sample("D i=" .. i)
        local ok, err = pcall(function() return viewer:switchToImageNum(i) end)
        log("ezveneraST D switch i=" .. i .. " ok=" .. tostring(ok) .. " " .. tostring(err))
        local okr, errr = pcall(function() return UIManager:widgetRepaint(viewer, 0, 0) end)
        log("ezveneraST D repaint i=" .. i .. " ok=" .. tostring(okr) .. " " .. tostring(errr))
    end
    -- 回翻：BB 归插件所有并复用，这条路径正是"viewer 先 free 再重绘"的
    -- 原崩溃窗口（R-D2 所有权修复后必须无崩、无黑页）
    for i = n, 1, -1 do
        sample("D rev i=" .. i)
        local ok, err = pcall(function() return viewer:switchToImageNum(i) end)
        log("ezveneraST D rev switch i=" .. i .. " ok=" .. tostring(ok) .. " " .. tostring(err))
        local okr, errr = pcall(function() return UIManager:widgetRepaint(viewer, 0, 0) end)
        log("ezveneraST D rev repaint i=" .. i .. " ok=" .. tostring(okr) .. " " .. tostring(errr))
    end
    pcall(function() return UIManager:close(viewer) end)
    log("ezveneraST D done")
    return "D 完成：" .. n .. " 页正+反翻页重绘（未崩 = 翻页链不是充分条件）"
end

--- 模式 E：JSValue 跨 LuaJIT FFI 的 ABI / 堆破坏探针。
--- 崩溃现场是 LuaJIT 往一个"表指针"写指针而该指针是垃圾（x10=0x0000dc08_00000402，
--- 两个小整数拼出来的形状），而 quickjs 侧唯一能造成"任意地址写"的就是
--- **按值传递 16 字节聚合体**：JS_Eval 返回 JSValue、JS_ToCStringLen2/JS_FreeValue
--- 接收 JSValue。若某个 tag/union 半字解码错位，JS_FreeValue 会对**错误对象**
--- 做引用计数递减 = 往随机地址写一个"减一后的值"，正好能造出上述形状。
--- 探针做法：反复 eval 各 tag 的结果（含 object → 必走 decref），每轮校验
--- 一块长期存活的 Lua 表金丝雀 + 校验返回值形状，破坏即可见、无需等崩。
function SelfTest.abiProbe(engine, rounds)
    rounds = rounds or 120
    if not engine or not engine.initialized then
        return "E 引擎未初始化（先跑一次浏览）"
    end
    local canary = {}
    for i = 1, 4096 do canary[i] = (i * 7) % 65536 end
    local function canaryBroken(tag)
        for i = 1, 4096 do
            if canary[i] ~= (i * 7) % 65536 then
                log("ezveneraST E CANARY BROKEN at", tag, "i=", i,
                    " got=", canary[i], " want=", (i * 7) % 65536)
                return i
            end
        end
        return 0
    end
    -- {脚本, 期望 ok, 期望返回值}
    local cases = {
        { "'str'", true, "str" },
        { "42", true, "42" },
        { "undefined", true, "undefined" },
        { "true", true, "true" },
        { "({a:1,b:'x'})", true, "[object Object]" },     -- OBJECT → decref
        { "([1,2,3,4,5])", true, "1,2,3,4,5" },           -- ARRAY → decref
        { "new String('w')", true, "w" },                 -- 包装对象 → decref
        { "'x'.repeat(5000)", true, nil },                -- 长字符串
        { "(function(){throw new Error('boom')})()", false, nil }, -- 异常
    }
    local bad = 0
    log("ezveneraST E begin rounds=", rounds, " cases=", #cases)
    sample("E start")
    for r = 1, rounds do
        for ci = 1, #cases do
            local c = cases[ci]
            local ok, res = engine:eval(c[1])
            local wantOk, want = c[2], c[3]
            local shape = (ok ~= wantOk)
                or (want ~= nil and res ~= want)
                or (want == nil and wantOk and type(res) ~= "string")
            if shape then
                bad = bad + 1
                log("ezveneraST E shape drift r=" .. r .. " case=" .. ci ..
                    " ok=" .. tostring(ok) .. " res=" .. tostring(res):sub(1, 40))
            end
        end
        local cb = canaryBroken("r=" .. r)
        if cb > 0 then
            return "E 金丝雀被破坏：r=" .. r .. " i=" .. cb ..
                " → quickjs/FFI 侧存在越界写，崩溃根因即此"
        end
        if r % 20 == 0 then sample("E r=" .. r) end
        collectgarbage("step", 300)
    end
    log("ezveneraST E done bad=", bad)
    return "E 完成：" .. rounds .. " 轮 × " .. #cases .. " 例，形状偏差 " .. bad ..
        " 次，金丝雀完好"
end

--- F：离线下载全链（真机验证用，排查完随本文件一起删除）
--- 走的是用户同一条路：getDownloader → downloadChapter（ProgressbarDialog +
--- scheduleIn 逐页）→ manifest 离线读 → 缓存管理界面留在屏上。
function SelfTest.downloadFlow(browser, sourceKey, comicId, epId,
        comicTitle, chapTitle)
    local UIManager = require("ui/uimanager")
    local Downloader = require("runtime.downloader")
    local dl = browser:getDownloader()
    log("ezveneraST F basedir=" .. tostring(dl.basedir))
    local t0 = os.time()
    browser:downloadChapter(sourceKey, comicId, epId, comicTitle, chapTitle,
        function(ok, info)
            log("ezveneraST F step ok=" .. tostring(ok)
                .. " secs=" .. tostring(os.time() - t0)
                .. " pages=" .. tostring(ok and info and #info.pages or "-")
                .. " bytes=" .. tostring(ok and info and info.bytes or "-")
                .. " err=" .. tostring(not ok and info or "-"))
            UIManager:scheduleIn(3, function()
                local man = dl:manifestOf(sourceKey, comicId, epId)
                local imgs = man and Downloader.localImages(man) or {}
                local head = imgs[1] and dl.fs.read(imgs[1].local_file) or ""
                log("ezveneraST F offline pages=" .. tostring(#imgs)
                    .. " first_head=" .. head:sub(1, 4):gsub("%c", "?")
                    .. " list=" .. tostring(#dl:list())
                    .. " usage=" .. tostring(dl:usage()))
                browser:showCacheManager()
            end)
        end)
    return "F 已启动（进度见 F step / F offline 两行）"
end

--- G：字形探针（真机验证用，排查完随本文件一起删除）。
--- 设备字体缺字形时菜单里会显示成 "?" 方框，一次截图定全部候选字符。
function SelfTest.glyphProbe()
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    UIManager:show(InfoMessage:new{
        text = table.concat({
            "◆ U+25C6   ○ U+25CB",
            "★ U+2605   ☆ U+2606",
            "▶ U+25B6   ■ U+25A0",
            "✓ U+2713   ✗ U+2717",
            "⬇ U+2B07   ↧ U+21A7",
            "🗑 U+1F5D1  ℹ U+2139",
        }, "\n"),
    })
    return "G 字形探针已显示"
end

--- H：章节打开链路分段计时（ANR 定位·任务 #22）。
--- 真机 10:08/10:09 两次 InputDispatcher「Application is not responding」
--- （head age 8.5s / 10.3s），最后一条日志都是 `ezveneraDIAG page n=1 pn=1`
--- ——即卡在 servePage(1) 里（取图 + 解码），而 diag tick 2s 节拍整段静默。
--- 这里把 loadEp / 逐页取图 / 解码分开计时，定出吃掉主循环的是哪一段。
function SelfTest.openTiming(browser, key, comicId, epId, pages)
    local oku, ffiUtil = pcall(require, "ffi/util")
    local now = (oku and ffiUtil and ffiUtil.gettime)
        and function() return ffiUtil.gettime() end or os.clock
    local function ms(t0)
        return string.format("%.0fms", (now() - t0) * 1000)
    end
    log("ezveneraST H begin", tostring(key), tostring(comicId), tostring(epId))
    local t0 = now()
    local images, base = browser:_loadEpImages(key, comicId, epId)
    log("ezveneraST H loadEp", ms(t0),
        " pages=", images and tostring(#images) or "FAIL")
    if not images or #images == 0 then return "H 取章节失败" end
    local okri, RenderImage = pcall(require, "ui/renderimage")
    if not okri then return "H renderimage 不可用" end
    for pn = 1, math.min(pages or 4, #images) do
        local item = images[pn]
        local url = type(item) == "table" and item.url or item
        local hdrs = type(item) == "table" and item.headers or nil
        local tf = now()
        local data = browser:fetchImageBytes(url, base, hdrs)
        local fetched = now()
        local dec, bbw, bbh = nil, "?", "?"
        if data then
            local okd, bb = pcall(function()
                return RenderImage:renderImageData(data, #data, false)
            end)
            if okd and bb then
                bbw, bbh = tonumber(bb.w), tonumber(bb.h)
                pcall(function() bb:free() end)
            end
            dec = now()
        end
        local host = (type(url) == "string" and url:match("^[%a]+://([^/]+)"))
            or "?"
        log("ezveneraST H p" .. pn,
            " fetch=" .. (data and ms(tf) or ("FAIL " .. ms(tf))),
            " bytes=" .. (data and tostring(#data) or "0"),
            " decode=" .. (dec and string.format("%.0fms", (dec - fetched) * 1000) or "-"),
            " size=" .. bbw .. "x" .. bbh,
            " host=" .. tostring(host))
    end
    return "H 完成：分段耗时见 logcat（ezveneraST H）"
end

--- 【临时探针】ANR 复现/回归：走**真实**打开路径 browser:showReader(...)，
--- 只打印这一次调用的同步耗时（= 主循环被占住的长度，点章节的回调同量级）。
--- 修法生效时首页不再在这里下载，sync_ms 应当只是 loadEp 的千把毫秒；
--- 之后每 2s 一条 ezveneraDIAG tick 说明循环已换手，logcat 里不该再出 am_anr。
function SelfTest.openChapter(browser, last)
    local oku, ffiUtil = pcall(require, "ffi/util")
    local now = (oku and ffiUtil and ffiUtil.gettime)
        and function() return ffiUtil.gettime() end or os.clock
    log("ezveneraST O begin", tostring(last.key), tostring(last.comicId),
        tostring(last.epId))
    local t0 = now()
    local ok, err = pcall(function()
        browser:showReader(last.key, last.comicId, last.epId, last.title,
            last.epTitle)
    end)
    log("ezveneraST O open", ok and "ok" or ("FAIL " .. tostring(err)),
        " sync_ms=", string.format("%.0f", (now() - t0) * 1000))
    return "O 完成：sync_ms 见 logcat（ezveneraST O）"
end

--- 【临时探针】同一张图的 A/B 对照：直连 vs 走插件代理（proxy="" 是 netclient
--- 的强制直连哨兵）。用于判定"图床经代理不通"是代理侧的问题还是设备本身不
--- 通，决定要不要做直连回退。
function SelfTest.directProbe(browser, key, comicId, epId)
    local images = browser:_loadEpImages(key, comicId, epId)
    local item = images and images[1]
    local url = type(item) == "table" and item.url or item
    if type(url) ~= "string" then return "P 无图片 URL" end
    log("ezveneraST P url", tostring(url:match("^[%a]+://[^/]+")))
    for _, p in ipairs({ { tag = "direct", v = "" },
                         { tag = "proxy",
                           v = (browser.settings and browser.settings:isProxyEnabled())
                               and browser.settings:getProxyURL() or "" } }) do
        local t0 = os.time()
        local resp = browser.netclient:request{ url = url, method = "GET",
            proxy = p.v, timeout_block = 6, timeout_total = 12 }
        log("ezveneraST P", p.tag, " status=", tostring(resp and resp.status),
            " bytes=", tostring(resp and resp.body and #resp.body or 0),
            " secs=", os.time() - t0,
            " err=", tostring(resp and resp.error))
    end
    return "P 完成：A/B 见 logcat（ezveneraST P）"
end

--- 【临时排查件（任务 #24）】真机跑一遍「添加自定义漫画源」三条路径：
--- 自定义索引 → 边车基址 → 索引条目安装 → 删除；再从任意 URL 直装一个源。
--- 用法：`echo U > ezv_selftest` 后 push + 重启，看 logcat 的 `ezveneraST U`。
function SelfTest.customSourceFlow(sources, indexUrl, jsUrl)
    local oku, ffiUtil = pcall(require, "ffi/util")
    local now = (oku and ffiUtil and ffiUtil.gettime)
        and function() return ffiUtil.gettime() end or os.clock
    local function ms(t0) return string.format("%.0fms", (now() - t0) * 1000) end
    local t0 = now()
    log("ezveneraST U begin", tostring(indexUrl))

    local ok, res = sources:addCustomIndex(indexUrl)
    log("ezveneraST U addCustomIndex", ms(t0),
        " ok=", tostring(ok), " count=", ok and tostring(res.count) or "-",
        " base=", ok and tostring(res.base) or "-",
        " err=", ok and "-" or tostring(res))
    if ok then
        local list = sources:listCustomIndexes()
        log("ezveneraST U listCustomIndexes n=", tostring(#list))
        local merged = sources:mergeLocal({})
        local first = merged[1]
        log("ezveneraST U mergeLocal n=", tostring(#merged),
            " first._base=", first and tostring(first._base))
        local rok, rerr = sources:removeCustomIndex(res.file)
        log("ezveneraST U removeCustomIndex", tostring(rok), tostring(rerr))
    end

    if jsUrl then
        t0 = now()
        local iok, ientry = sources:installFromURL(jsUrl)
        log("ezveneraST U installFromURL", ms(t0), " ok=", tostring(iok),
            " key=", iok and tostring(ientry.key) or "-",
            " size=", iok and tostring(ientry.size) or "-",
            " err=", iok and "-" or tostring(ientry))
        if iok then
            local body = sources:readSource(ientry.key)
            log("ezveneraST U readSource bytes=", tostring(body and #body))
            sources:remove(ientry.key)
            log("ezveneraST U cleaned up", tostring(ientry.key))
        end
    end
    return "U 完成：自定义源三条路径见 logcat（ezveneraST U）"
end

--- 把 Lua 字符串编成 JS 字符串字面量（只处理源文件里真会出现的转义）
local function jsStrLiteral(s)
    local out = s:gsub(bs .. bs, bs .. bs .. bs .. bs)
    out = out:gsub(bs .. '"', bs .. bs .. '"')
    out = out:gsub(bs .. 'n', bs .. bs .. 'n')
    out = out:gsub(bs .. 'r', bs .. bs .. 'r')
    out = out:gsub(bs .. 't', bs .. bs .. 't')
    out = out:gsub(bs .. '/', bs .. bs .. '/')
    return '"' .. out .. '"'
end

--- 用引擎自己报出「第几行」：源文本走 JS 侧 eval()（运行期解析），
--- 语法错被 catch 后读 e.stack 里的 :LINE:COL。
function SelfTest.locateJsError(engine, code)
    if not engine then return "no engine" end
    if type(code) ~= "string" or code == "" then return "no code" end
    local js = '(() => { try { eval(' .. jsStrLiteral(code) .. ') '
            .. 'return "syntax-ok" } catch (e) '
            .. '{ return "ERR " + String((e && (e.stack || e.message)) || e) } })()'
    local ok, res = engine:eval(js)
    if not ok then return "eval失败 " .. tostring(res) end
    return tostring(res)
end

--- 【临时诊断件，与任务 #17 一起删除】本地整包导入 + 全量注册的真机加载测试。
--- 1) installLocalBundle 落盘（离线包没有可下载基址，全程不联网）；
--- 2) 逐源走 browser:_ensureSourceLoaded —— 这条路上依次发生 readSource、
---    ESM 剥壳、类名扫描、new + meta 求值，是唯一能一次验证「这 31 个源
---    到底能不能被 quickjs 装载」的地方；
--- 3) 汇总 n_ok/n_fail，并把前 maxShow 条失败原因打进 logcat（ezveneraST V）。
function SelfTest.bundleLoad(sources, browser, dir, maxShow)
    local oku, ffiUtil = pcall(require, "ffi/util")
    local now = (oku and ffiUtil and ffiUtil.gettime)
        and function() return ffiUtil.gettime() end or os.clock
    local function ms(t0) return string.format("%.0fms", (now() - t0) * 1000) end
    maxShow = maxShow or 10
    local t0 = now()
    log("ezveneraST V begin dir=", tostring(dir))

    local res, err = sources:installLocalBundle(dir)
    if not res then
        log("ezveneraST V installLocalBundle FAIL", ms(t0), tostring(err))
        return "V 导入失败: " .. tostring(err)
    end
    log("ezveneraST V installLocalBundle ok=", tostring(res.n_ok),
        " fail=", tostring(res.n_fail), " total=", tostring(#res.list),
        " ", ms(t0))
    for _, r in ipairs(res.list) do
        if not r.ok then
            log("ezveneraST V import FAIL", tostring(r.key), tostring(r.err))
        end
    end

    local eng_ok, eng_fail, shown = 0, 0, 0
    for _, r in ipairs(res.list) do
        if r.ok then
            local st = now()
            local jsKey, eerr = browser:_ensureSourceLoaded(r.key)
            if jsKey then
                eng_ok = eng_ok + 1
                log("ezveneraST V register OK", tostring(r.key),
                    "-> jsKey=" .. tostring(jsKey), " ", ms(st))
            else
                eng_fail = eng_fail + 1
                if shown < maxShow then
                    shown = shown + 1
                    log("ezveneraST V register FAIL", tostring(r.key),
                        tostring(eerr))
                    -- 让引擎自己报行号（e.stack 里带 :LINE:COL），生成器好改
                    local loc = SelfTest.locateJsError(browser.engine,
                        sources:readSource(r.key))
                    log("ezveneraST V   locate", tostring(r.key),
                        tostring(loc):gsub("[\r\n]+", " | "):sub(1, 240))
                end
            end
        end
    end
    log("ezveneraST V 注册汇总 ok=", tostring(eng_ok),
        " fail=", tostring(eng_fail),
        " (fail 详情只打前 " .. tostring(maxShow) .. " 条)")
    return "V 完成：导入 " .. tostring(res.n_ok) .. "/" ..
        tostring(#res.list) .. "，注册 " .. tostring(eng_ok) .. "/" ..
        tostring(eng_ok + eng_fail)
end
--- 【临时诊断件（移植包网络排查），与 #17 一起删除】URL 网络 A/B 探针。
--- 每条 URL 跑两趟：强制直连（proxy="" 是 netclient 的直连哨兵）与走插件
--- 代理，各打 status / 耗时 / 错误。每个节拍只发一次请求，别把整段探测压
--- 在主循环上（安卓 5s ANR 门槛，同 #22 的教训）。
--- 用法：`W|url1,url2` → logcat 关键字 `ezveneraST W`
function SelfTest.urlProbe(browser, urls)
    local UIManager = require("ui/uimanager")
    local oku, ffiUtil = pcall(require, "ffi/util")
    local now = (oku and ffiUtil and ffiUtil.gettime)
        and function() return ffiUtil.gettime() end or os.clock
    local proxy = (browser.settings and browser.settings:isProxyEnabled())
        and (browser.settings:getProxyURL() or "") or ""
    local jobs = {}
    for _, u in ipairs(urls or {}) do
        table.insert(jobs, { u = u, tag = "direct", p = "" })
        if proxy ~= "" then
            table.insert(jobs, { u = u, tag = "proxy", p = proxy })
        end
    end
    log("ezveneraST W begin n=", tostring(#jobs),
        " proxy=", proxy ~= "" and proxy or "(未启用)")
    local function step()
        local j = table.remove(jobs, 1)
        if not j then
            log("ezveneraST W done")
            return
        end
        local t0 = now()
        local ok, resp = pcall(function()
            return browser.netclient:request{ url = j.u, method = "GET",
                proxy = j.p, timeout_block = 6, timeout_total = 12 }
        end)
        log("ezveneraST W", j.tag,
            " status=", tostring(ok and resp and resp.status or "-"),
            " bytes=", tostring(ok and resp and resp.body and #resp.body or 0),
            " secs=", string.format("%.1f", (now() - t0)),
            " err=", tostring(ok and resp and resp.error or resp),
            " host=", tostring(j.u:match("^[%a]+://[^/]+")))
        pcall(UIManager.scheduleIn, UIManager, 2, step)
    end
    pcall(UIManager.scheduleIn, UIManager, 1, step)
    return "W 已排入 " .. tostring(#jobs) .. " 次探测，看 logcat ezveneraST W"
end
return SelfTest
