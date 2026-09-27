-- unit test: runtime/downloader.lua — 章节离线下载 / manifest / 缓存清理
-- 依赖注入：内存文件系统 + 可编程 request，全程不碰真机磁盘。

local Downloader = require("runtime.downloader")

local tests = {}

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

--- 内存 fs：见 tests/memfs.lua（与 makeFs()（lfs+io）语义一致）
local memFs = require("memfs")

local URLS = {
    "https://cdn.example.com/p1.webp",
    "https://cdn.example.com/p2.jpg?sign=abc",
    "/local/p3.png",
}

--- 造一个下载器：body 前缀 IMG:，opts.bad_urls 里的 URL 恒返 500（可运行时改）
local function makeDL(opts)
    opts = opts or {}
    local fs = memFs()
    local reqs = {}
    local env = { bad = opts.bad_urls or {}, reqs = reqs }
    local dl = Downloader.new{
        fs = fs, basedir = "/data/ezvenera/downloads",
        request = function(url, headers)
            reqs[#reqs + 1] = { url = url, headers = headers }
            if env.bad[url] then
                return { status = 500, headers = {}, body = nil, error = "boom" }
            end
            return { status = 200,
                     headers = { ["content-type"] = opts.ctype or "image/webp" },
                     body = "IMG:" .. url }
        end,
    }
    return dl, fs, env
end

local CHAPTER = {
    key = "baozi", comicId = "c1", epId = "0_17",
    comicTitle = "航海王", chapterTitle = "第 17 话",
}

local function withImages(dl, urls, extra)
    local o = { images = urls or URLS }
    for k, v in pairs(CHAPTER) do o[k] = v end
    if extra then for k, v in pairs(extra) do o[k] = v end end
    return dl:download(o)
end

-- 主路径：3 页落盘 + manifest + 进度回调 + 按 URL 后缀命名
function tests.download_writes_pages_and_manifest()
    local dl, fs = makeDL()
    local seen = {}
    local ok, man = withImages(dl, nil, {
        on_progress = function(done, total) seen[#seen + 1] = done .. "/" .. total end })
    assert_eq("ok", true, ok)
    assert_eq("pages", 3, #man.pages)
    assert_eq("progress", "1/3,2/3,3/3", table.concat(seen, ","))
    local dir = dl:dirOf("baozi", "c1", "0_17")
    assert_eq("dir", "/data/ezvenera/downloads/baozi__c1__0_17", dir)
    assert_eq("page 1 name", "0001.webp", man.pages[1].file)
    assert_eq("page 2 name (query stripped)", "0002.jpg", man.pages[2].file)
    assert_eq("page 3 name", "0003.png", man.pages[3].file)
    assert_eq("page 1 on disk", "IMG:" .. URLS[1], fs.state.files[dir .. "/0001.webp"])
    local want = 0
    for _, u in ipairs(URLS) do want = want + #("IMG:" .. u) end
    assert_eq("bytes summed", want, man.bytes)
    assert(fs.state.files[dir .. "/manifest.txt"], "manifest written last")
    return true
end

-- 重复下载直接复用（列表里再点一次不该重下一遍流量）
function tests.repeat_download_is_skipped()
    local dl, _, env = makeDL()
    withImages(dl)
    local n0 = #env.reqs
    local ok, man = withImages(dl)
    assert_eq("ok", true, ok)
    assert_eq("skipped", true, man.skipped)
    assert_eq("no extra requests", n0, #env.reqs)
    return true
end

-- 中途失败：已下页留着（complete=0），恢复后只补剩下的页，不重下整章
function tests.failed_download_keeps_pages_and_resumes()
    local dl, fs, env = makeDL({ bad_urls = { [URLS[2]] = true } })
    local ok, err = withImages(dl)
    assert_eq("not ok", false, ok)
    assert(tostring(err):find("第 2 页", 1, true), "page-scoped error: " .. tostring(err))
    assert_eq("not offered as downloaded", nil, dl:manifestOf("baozi", "c1", "0_17"))
    local part = dl:partialOf("baozi", "c1", "0_17")
    assert(part, "partial manifest kept")
    assert_eq("1 page kept", 1, #part.pages)
    local dir = dl:dirOf("baozi", "c1", "0_17")
    assert_eq("page 1 bytes on disk", "IMG:" .. URLS[1], fs.state.files[dir .. "/0001.webp"])
    env.bad = {}
    local n0 = #env.reqs
    local ok2, man2 = withImages(dl)
    assert_eq("resume succeeds", true, ok2)
    assert_eq("only missing pages fetched", 2, #env.reqs - n0)
    assert_eq("all pages now", 3, #man2.pages)
    assert_eq("complete after resume", true, man2.complete ~= false)
    assert_eq("no partial left", nil, dl:partialOf("baozi", "c1", "0_17"))
    return true
end

-- 取消：on_progress 返回 false 即中止，字节留着等下次续
function tests.cancel_keeps_pages_for_resume()
    local dl, fs = makeDL()
    local ok, err = withImages(dl, nil, {
        on_progress = function() return false end })
    assert_eq("not ok", false, ok)
    assert_eq("reason", "已取消", err)
    assert_eq("nothing offered as downloaded", nil, dl:manifestOf("baozi", "c1", "0_17"))
    local part = dl:partialOf("baozi", "c1", "0_17")
    assert(part, "partial kept")
    assert_eq("page 1 survives", "IMG:" .. URLS[1],
        fs.state.files[dl:dirOf("baozi", "c1", "0_17") .. "/0001.webp"])
    return true
end

-- 逐页步进（UI 不冻结的形态）：每 step 只发一个请求，中途置 stopped 也留字节
function tests.step_advances_one_page_at_a_time()
    local dl, fs, env = makeDL()
    local job, err = dl:begin({ key = "baozi", comicId = "c1", epId = "0_17",
                                comicTitle = "T", chapterTitle = "U", images = URLS })
    assert(job, "begin: " .. tostring(err))
    assert_eq("fresh start", 0, job.resumed)
    local s1, d1 = dl:step(job)
    assert_eq("first step runs", "run", s1)
    assert_eq("one page per step", 1, d1)
    assert_eq("one request per step", 1, #env.reqs)
    assert_eq("nothing downloaded yet", nil, dl:manifestOf("baozi", "c1", "0_17"))
    job.stopped = true
    local s3, info = dl:step(job)
    assert_eq("stopped step errors", "error", s3)
    assert_eq("reason", "已取消", info)
    assert_eq("page 1 still on disk", "IMG:" .. URLS[1],
        fs.state.files[dl:dirOf("baozi", "c1", "0_17") .. "/0001.webp"])
    -- 下一次 begin 从第 2 页续：resumed 计数 + 只补 2 页
    local job2 = dl:begin({ key = "baozi", comicId = "c1", epId = "0_17",
                            comicTitle = "T", chapterTitle = "U", images = URLS })
    assert_eq("resumes from page 2", 1, job2.resumed)
    dl:step(job2)
    dl:step(job2)
    assert_eq("only the 2 missing pages re-fetched", 3, #env.reqs)
    assert_eq("chapter complete after resume", 3, #dl:manifestOf("baozi", "c1", "0_17").pages)
    return true
end

-- 续传的硬条件：URL 逐位相同。签名图床重取列表会换 token，这时必须重下
function tests.resume_requires_identical_page_urls()
    local dl, _, env = makeDL()
    withImages(dl, nil, { on_progress = function() return false end })
    assert_eq("partial exists", 1, #dl:partialOf("baozi", "c1", "0_17").pages)
    local moved = { "https://cdn.example.com/p1.webp?sig=NEW", URLS[2], URLS[3] }
    local n0 = #env.reqs
    local job = dl:begin({ key = "baozi", comicId = "c1", epId = "0_17",
                           comicTitle = "T", chapterTitle = "U", images = moved })
    assert_eq("url changed → no reuse", 0, job.resumed)
    local ok = dl:download({ key = "baozi", comicId = "c1", epId = "0_17",
                             comicTitle = "T", chapterTitle = "U", images = moved })
    assert_eq("fresh download ok", true, ok)
    assert_eq("all 3 pages re-fetched", 3, #env.reqs - n0)
    return true
end

-- 未完成章不进「已下载」表、不计体积，但能被列出来单独删；clearAll 一起清
function tests.partials_are_listed_separately_and_cleared()
    local dl = makeDL()
    withImages(dl)                                   -- 完整 1 章
    withImages(dl, nil, { key = "baozi2", comicId = "c1", epId = "0_17",
                          on_progress = function() return false end })  -- 未完成 1 章
    assert_eq("complete chapters", 1, #dl:list())
    local parts = dl:listPartials()
    assert_eq("partials", 1, #parts)
    assert_eq("partial has 1 page", 1, #parts[1].pages)
    local want_bytes = #("IMG:" .. URLS[1]) + #("IMG:" .. URLS[2]) + #("IMG:" .. URLS[3])
    assert_eq("usage counts complete only", want_bytes, dl:usage())
    assert_eq("clearAll removes both", 2, dl:clearAll())
    assert_eq("nothing complete left", 0, #dl:list())
    assert_eq("nothing partial left", 0, #dl:listPartials())
    return true
end

-- 向后兼容：本次改动之前写的 manifest 没有 complete 行，必须仍算完整可离线
function tests.legacy_manifest_without_complete_is_downloaded()
    local dl, fs = makeDL()
    withImages(dl)
    local path = Downloader.manifestPath(dl:dirOf("baozi", "c1", "0_17"))
    local text = fs.state.files[path]
    assert(text, "manifest exists")
    fs.state.files[path] = (text:gsub("complete\t1\n", ""))
    assert_eq("legacy line dropped", nil,
        fs.state.files[path]:match("complete"))
    local m = dl:manifestOf("baozi", "c1", "0_17")
    assert_eq("still offered", 3, #m.pages)
    assert_eq("still in list()", 1, #dl:list())
    return true
end

-- 已下过的章节：begin 直接给 skipped job，一个请求都不发
function tests.begin_reuses_completed_chapter()
    local dl, _, env = makeDL()
    withImages(dl)
    local n0 = #env.reqs
    local job = dl:begin({ key = "baozi", comicId = "c1", epId = "0_17", images = URLS })
    assert_eq("skipped job", true, job.skipped)
    local state, man = dl:step(job)
    assert_eq("done at once", "done", state)
    assert_eq("manifest handed back", 3, #man.pages)
    assert_eq("no extra requests", n0, #env.reqs)
    return true
end

-- manifest 往返：中文标题 / 带签名的 URL 原样还原
function tests.manifest_roundtrip_keeps_cjk_and_urls()
    local dl = makeDL()
    withImages(dl)
    local m = dl:manifestOf("baozi", "c1", "0_17")
    assert_eq("comic title", "航海王", m.comicTitle)
    assert_eq("chapter title", "第 17 话", m.chapterTitle)
    assert_eq("url kept", URLS[2], m.pages[2].url)
    assert_eq("key", "baozi", m.key)
    assert_eq("pages readable offline", 3, #Downloader.localImages(m))
    return true
end

-- 缺页 = 不完整：manifest 在但文件被删，就不能当已下载用
function tests.incomplete_chapter_is_not_offered()
    local dl, fs = makeDL()
    withImages(dl)
    local dir = dl:dirOf("baozi", "c1", "0_17")
    fs.state.files[dir .. "/0002.jpg"] = nil
    assert_eq("not downloadable", nil, dl:manifestOf("baozi", "c1", "0_17"))
    assert_eq("list drops it", 0, #dl:list())
    return true
end

-- 多章：列表按保存时间倒序、usage 求和、clearAll 清空
function tests.list_usage_and_clear()
    local dl = makeDL()
    withImages(dl)
    local o2 = { key = "copy", comicId = "c2", epId = "5",
                 comicTitle = "A", chapterTitle = "B", images = { URLS[1] } }
    o2.saved = nil
    local ok = dl:download(o2)
    assert_eq("second chapter ok", true, ok)
    local rows = dl:list()
    assert_eq("two chapters", 2, #rows)
    local sum = dl:usage()
    assert(sum > rows[1].bytes, "usage covers both chapters")
    assert_eq("clearAll count", 2, dl:clearAll())
    assert_eq("usage after clear", 0, dl:usage())
    assert_eq("nothing downloadable left", nil, dl:manifestOf("baozi", "c1", "0_17"))
    return true
end

-- 源给的 id 不可信：路径必须压平，不能逃出 downloads 目录
function tests.ids_are_sanitized_into_safe_paths()
    local dl = makeDL()
    local ok = dl:download({ key = "../evil", comicId = "a/b", epId = "c\\d",
                             comicTitle = "t", chapterTitle = "u",
                             images = { URLS[1] } })
    assert_eq("ok", true, ok)
    local dir = dl:dirOf("../evil", "a/b", "c\\d")
    assert_eq("flattened", "/data/ezvenera/downloads/___evil__a_b__c_d", dir)
    assert(not dir:find("/%.%./"), "no parent traversal")
    return true
end

-- 头信息透传：源 onImageLoad 的 headers 与单页 headers 都要进请求
function tests.request_headers_are_merged()
    local dl, _, env = makeDL()
    withImages(dl, { { url = URLS[1], headers = { Referer = "r1" } } },
        { base_headers = { Cookie = "c=1", Referer = "base" } })
    assert_eq("one request", 1, #env.reqs)
    assert_eq("per-page wins", "r1", env.reqs[1].headers.Referer)
    assert_eq("base kept", "c=1", env.reqs[1].headers.Cookie)
    return true
end

return tests
