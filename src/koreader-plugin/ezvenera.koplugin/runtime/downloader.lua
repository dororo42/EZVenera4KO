--[[
EZVenera for KOReader — runtime/downloader.lua

章节离线下载：把一话的图片落到 <dataDir>/ezvenera/downloads/<key>__<comic>__<ep>/，
并写一份自描述 manifest，供离线阅读与"下载与缓存"界面统计/删除。

为什么必须自己写：Venera 契约里"下载"由宿主 App 实现（Flutter 侧 Downloader），
JS 源只负责给出 images URL 列表；本移植的 HTTP 通道是 netclient（ADR-003 插件自带
代理），所以取字节与落盘也只能我们自己做。

两条实现约束（都是真机踩出来的，见 R-D2v4）：
* 进程内禁 fork/exec：建目录/删除走 KOReader 内建 lfs（libs/libkoreader-lfs）。
* manifest 用行式纯文本而不是 JSON：这是插件自己的文件、没有互操作需求，省掉
  一个依赖，也让单测无需伪造 JSON 编码器（中文标题按字节原样存）。

文件系统通过 deps.fs 注入，真实实现见 Downloader.makeFs()；单测给内存表实现，
这样命名/续传/取消留半截/manifest 解析等逻辑都能在纯 LuaJIT 环境里验证。

取消与失败的处置是「留字节」而不是「删字节」：完整 manifest 只在最后一页之后才
写，中途停下的目录写一份 complete=0 的 manifest，下次 begin 校验 URL 逐位相同就
从那页继续（弱网/流量场景下，重下一整章的代价由用户承担）。
]]

local Downloader = {}
Downloader.__index = Downloader

Downloader.MAGIC = "EZV1"

--- 源给的 key / comicId / epId 全部压平成文件安全字符。
--- 与 runtime/sourcedata.lua 同规则，代价同上：不同 id 压平后可能碰撞。
local function safeId(s)
    return (tostring(s or ""):gsub("[^%w%-_]", "_"))
end

local function esc(s)
    return (tostring(s or ""):gsub("\\", "\\\\"):gsub("\t", "\\t")
        :gsub("\n", "\\n"):gsub("\r", "\\r"))
end

local function unesc(s)
    local out = (s:gsub("\\.", { ["\\"] = "\\", ["\t"] = "\t",
        ["\n"] = "\n", ["\r"] = "\r" }))
    return out
end

local EXT_BY_TYPE = {
    webp = "webp", jpeg = "jpg", jpg = "jpg", png = "png", gif = "gif",
    bmp = "bmp", avif = "avif", ["image/svg+xml"] = "svg",
}

--- 页文件名：优先 URL 后缀，其次响应头 content-type，最后兜底 img。
--- 后缀决定离线解码走哪条路（renderimage 按字节头认格式，但文件名给人看，
--- 也影响用户把目录拖进别的阅读器时的可用性）。
local function extOf(url, hdrs)
    local path = tostring(url or ""):gsub("[#?].*$", "")
    local ext = path:match("%.([%w]+)$")
    if ext then
        ext = ext:lower()
        if EXT_BY_TYPE[ext] then return ext == "jpeg" and "jpg" or ext end
    end
    local ct = hdrs and (hdrs["content-type"] or hdrs["Content-Type"])
    if ct then
        local sub = tostring(ct):match("image/([%w%.%+%-]+)")
        if sub and EXT_BY_TYPE[sub:lower()] then return EXT_BY_TYPE[sub:lower()] end
    end
    return "img"
end

-- 阅读器「另存本页」也按同一套后缀规则（browser.lua showReader）。
Downloader.extOf = extOf

-- ---------- 真实文件系统后端（KOReader 侧） ----------

--- deps.fs 未注入时用它。lfs 只做目录操作（进程内禁 os.execute），
--- 读写走 io.open 二进制。
function Downloader.makeFs()
    local lfs
    local okl, m = pcall(require, "libs/libkoreader-lfs")
    if okl and m then lfs = m end
    local function hasFs() return lfs ~= nil end

    local function split(path)
        local parts, lead = {}, path:sub(1, 1) == "/" and "/" or ""
        for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
        return parts, lead
    end

    local fs = {}
    function fs.exists(p)
        if hasFs() then return lfs.attributes(p, "mode") ~= nil end
        local f = io.open(p, "rb")
        if f then f:close() return true end
        return false
    end
    function fs.mkdir(path)
        if not hasFs() then return false end
        local parts, lead = split(path)
        local acc = lead
        for _, seg in ipairs(parts) do
            acc = (acc == "" and seg or acc .. "/" .. seg)
            local mode = lfs.attributes(acc, "mode")
            if mode == nil then
                local ok = pcall(lfs.mkdir, acc)
                if not ok then return false end
            elseif mode ~= "directory" then
                return false
            end
        end
        return true
    end
    function fs.write(path, bytes)
        local f = io.open(path, "wb")
        if not f then return false end
        f:write(bytes)
        f:close()
        return true
    end
    function fs.read(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end
    function fs.list(dir)
        if not hasFs() then return nil end
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return nil end
        local names = {}
        for name in iter, obj do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        return names
    end
    function fs.remove(path)
        if hasFs() and lfs.attributes(path, "mode") == "directory" then
            return pcall(lfs.rmdir, path)
        end
        return os.remove(path) and true or false
    end
    return fs
end

-- ---------- 模块实例 ----------

--- deps: { fs = see makeFs(), basedir = "<...>/ezvenera/downloads",
---           request = fn(url, headers) → {status=,body=,headers=} | nil,err }
function Downloader.new(deps)
    deps = deps or {}
    local o = setmetatable({}, Downloader)
    o.fs = deps.fs or Downloader.makeFs()
    o.basedir = deps.basedir or "ezvenera/downloads"
    o.request = deps.request
    return o
end

function Downloader:chapterId(key, comicId, epId)
    return ("%s__%s__%s"):format(safeId(key), safeId(comicId), safeId(epId))
end

function Downloader:dirOf(key, comicId, epId)
    return self.basedir .. "/" .. self:chapterId(key, comicId, epId)
end

function Downloader.manifestPath(dir) return dir .. "/manifest.txt" end

function Downloader:pagePath(key, comicId, epId, file)
    return self:dirOf(key, comicId, epId) .. "/" .. file
end

-- ---------- manifest 编解码 ----------

function Downloader.encodeManifest(m)
    local lines = { Downloader.MAGIC,
        "key\t" .. esc(m.key), "comic\t" .. esc(m.comicId),
        "ep\t" .. esc(m.epId), "comic_title\t" .. esc(m.comicTitle),
        "chapter_title\t" .. esc(m.chapterTitle),
        "saved\t" .. esc(m.saved),
        -- 未完成的章留着字节等续传，靠这一行和「已下载」区分开。
        -- 缺行 = 完整（本次改动之前写下的 manifest 都没有这行）。
        "complete\t" .. (m.complete == false and "0" or "1"),
        "pages\t" .. esc(#m.pages) }
    for i, p in ipairs(m.pages) do
        lines[#lines + 1] = ("page\t%s\t%s\t%s"):format(
            esc(p.file), esc(p.bytes), esc(p.url))
    end
    return table.concat(lines, "\n") .. "\n"
end

function Downloader.decodeManifest(text)
    if type(text) ~= "string" or text:sub(1, #Downloader.MAGIC) ~= Downloader.MAGIC then
        return nil
    end
    local m = { pages = {} }
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local k, rest = line:match("^([^\t]+)\t(.*)$")
        if k == "key" then m.key = unesc(rest)
        elseif k == "comic" then m.comicId = unesc(rest)
        elseif k == "ep" then m.epId = unesc(rest)
        elseif k == "comic_title" then m.comicTitle = unesc(rest)
        elseif k == "chapter_title" then m.chapterTitle = unesc(rest)
        elseif k == "saved" then m.saved = tonumber(rest)
        elseif k == "complete" then m.complete = rest ~= "0"
        elseif k == "page" then
            local file, bytes, url = rest:match("^([^\t]*)\t([^\t]*)\t(.*)$")
            if file then
                m.pages[#m.pages + 1] = {
                    file = unesc(file), bytes = tonumber(bytes) or 0,
                    url = unesc(url) }
            end
        end
    end
    if #m.pages == 0 then return nil end
    return m
end

--- 目录里的 manifest（完整与未完成都返回）。
function Downloader:_manifestIn(key, comicId, epId)
    local dir = self:dirOf(key, comicId, epId)
    local m = Downloader.decodeManifest(
        self.fs.read(Downloader.manifestPath(dir)))
    if not m then return nil end
    local bytes = 0
    for _, p in ipairs(m.pages) do
        if not self.fs.exists(dir .. "/" .. p.file) then return nil end
        bytes = bytes + (p.bytes or 0)
    end
    m.dir = dir
    m.bytes = bytes
    m.key = m.key or key
    m.comicId = m.comicId or comicId
    m.epId = m.epId or epId
    return m
end

--- 读 manifest 并校验页文件是否都在（缺文件 = 不完整，不能当离线章用）。
--- 未完成（complete=0）的目录**不算已下载**：离线阅读与「已下载」标记只认完整章。
function Downloader:manifestOf(key, comicId, epId)
    local m = self:_manifestIn(key, comicId, epId)
    if not m or m.complete == false then return nil end
    return m
end

--- 未完成的下载（取消或某页失败留下的前半截），页文件齐才返回。
function Downloader:partialOf(key, comicId, epId)
    local m = self:_manifestIn(key, comicId, epId)
    if not m or m.complete ~= false then return nil end
    return m
end

function Downloader:isDownloaded(key, comicId, epId)
    return self:manifestOf(key, comicId, epId) ~= nil
end

--- 开始下载一话（不取页，只做校验 + 建目录 + 清残留）。
--- 拆成 begin/step 是因为 KOReader 是单线程 UI：一次性下完一话会冻结界面
--- 几十秒，所以浏览器侧要「每拍一页」（UIManager:scheduleIn）。
--- 返回 job（交给 step），或 (nil, err)。job.skipped 表示已下过、无需下载。
--- o:
---   key / comicId / epId / comicTitle / chapterTitle
---   images = { "url" | {url=, headers=} , ... }（Venera 两种形态都吃）
---   base_headers = 源 onImageLoad 给的公共头
---   on_progress = fn(done, total)；返回 false 即请求取消
--- 续传的硬条件：前半截每页的 URL 与本轮 images 逐位相同。签名型图床（URL 带
--- token）重取列表后必然变串，这时不复用——宁可重下，也不能把第 3 页的文件
--- 配到第 5 页的地址上。
function Downloader:_pagesResumable(part, images)
    for i, p in ipairs(part.pages) do
        local url = (type(images[i]) == "table") and images[i].url or images[i]
        if url ~= p.url then return false end
    end
    return true
end

function Downloader:begin(o)
    if not self.request then return nil, "no request channel" end
    local key, comicId, epId = o.key, o.comicId, o.epId
    local have = self:manifestOf(key, comicId, epId)
    if have then
        have.skipped = true
        return { skipped = true, manifest = have, key = key, comicId = comicId,
            epId = epId }
    end
    local images = o.images
    if type(images) ~= "table" or images[1] == nil then
        return nil, "没有可下载的页"
    end
    local dir = self:dirOf(key, comicId, epId)
    if not self.fs.mkdir(dir) then return nil, "无法创建目录: " .. dir end
    local pages, done, bytes = {}, 0, 0
    local part = self:partialOf(key, comicId, epId)
    if part and self:_pagesResumable(part, images) then
        pages, done = part.pages, #part.pages
        for _, p in ipairs(pages) do bytes = bytes + (p.bytes or 0) end
    else
        -- 不能续就把目录清干净（含坏 manifest）：完整 manifest 最后才写，
        -- 目录里来路不明的文件不能让离线阅读当成"已下载"。
        local stale = self.fs.list(dir)
        if stale then
            for _, name in ipairs(stale) do self.fs.remove(dir .. "/" .. name) end
        end
    end
    return {
        o = o, key = key, comicId = comicId, epId = epId, dir = dir,
        images = images, total = #images, done = done, pages = pages,
        bytes = bytes, resumed = done,
    }
end

--- 落一份「未完成」manifest：已下页的字节留着，下次 begin 从这里续。
--- 一页都没落成就没有留的价值，直接清目录。
function Downloader:_leavePartial(job)
    if #job.pages == 0 then
        self:remove(job.key, job.comicId, job.epId)
        return
    end
    self.fs.write(Downloader.manifestPath(job.dir), Downloader.encodeManifest{
        key = job.key, comicId = job.comicId, epId = job.epId,
        comicTitle = job.o.comicTitle, chapterTitle = job.o.chapterTitle,
        saved = os.time(), pages = job.pages, complete = false,
    })
end

--- 取一页并落盘。返回 ("run", done) 还有页要下 / ("done", manifest) /
--- ("error", err)。取消在这里生效：调用方置 job.stopped，或 on_progress 返回 false。
--- 取消与失败都保留已下页（complete=0），不删字节。
function Downloader:step(job)
    if job.skipped then return "done", job.manifest end
    local o = job.o
    if job.stopped then
        self:_leavePartial(job)
        return "error", "已取消"
    end
    local fail = function(msg)
        self:_leavePartial(job)
        return "error", msg
    end

    local i = job.done + 1
    local item = job.images[i]
    local url, headers = item, nil
    if type(item) == "table" then
        url = item.url
        headers = item.headers
    end
    if type(url) ~= "string" or url == "" then
        return fail("第 " .. i .. " 页没有 URL")
    end
    local h = {}
    if type(o.base_headers) == "table" then
        for k, v in pairs(o.base_headers) do h[k] = v end
    end
    if type(headers) == "table" then
        for k, v in pairs(headers) do h[k] = v end
    end
    local data, hdrs, err
    for _ = 1, 2 do
        local ok, resp, e = pcall(self.request, url, h)
        if ok and type(resp) == "table" and resp.status == 200
                and type(resp.body) == "string" and resp.body ~= "" then
            data, hdrs = resp.body, resp.headers
            break
        end
        data = nil
        if not ok then
            err = tostring(resp)
        elseif type(resp) == "table" then
            err = tostring(resp.error or resp.status)
        else
            err = e ~= nil and tostring(e) or tostring(resp)
        end
    end
    if not data then
        return fail("第 " .. i .. " 页下载失败: " .. tostring(err))
    end
    local file = ("%04d.%s"):format(i, extOf(url, hdrs))
    if not self.fs.write(job.dir .. "/" .. file, data) then
        return fail("第 " .. i .. " 页写盘失败")
    end
    job.pages[i] = { file = file, bytes = #data, url = url }
    job.bytes = job.bytes + #data
    job.done = i
    if o.on_progress and o.on_progress(i, job.total) == false then
        job.stopped = true
    end
    if job.stopped then
        self:_leavePartial(job)
        return "error", "已取消"
    end
    if i < job.total then return "run", i end

    local man = {
        key = job.key, comicId = job.comicId, epId = job.epId,
        comicTitle = o.comicTitle, chapterTitle = o.chapterTitle,
        saved = os.time(), pages = job.pages,
    }
    if not self.fs.write(Downloader.manifestPath(job.dir),
            Downloader.encodeManifest(man)) then
        return fail("manifest 写盘失败")
    end
    man.dir = job.dir
    man.bytes = job.bytes
    return "done", man
end

--- 同步下载一话（单拍到底）。真机 UI 请用 begin/step，见 Downloader:begin。
function Downloader:download(o)
    local job, err = self:begin(o)
    if not job then return false, err end
    if job.skipped then return true, job.manifest end
    while true do
        local state, info = self:step(job)
        if state == "run" then
        elseif state == "done" then return true, info
        else return false, info end
    end
end

function Downloader:remove(key, comicId, epId)
    local dir = self:dirOf(key, comicId, epId)
    if not self.fs.list(dir) then return false end
    self:_prune(dir)
    return true
end

--- 按 manifest 的 complete 位扫描下载目录。want_complete=true 取完整章（可离线
--- 阅读、计入体积），false 取未完成章（只能续传或删除）。
--- 页文件缺失的一律清掉：完整章缺页 = 损坏，未完成缺页 = 没法续，留着只会占空间。
function Downloader:_scan(want_complete)
    local dirs = self.fs.list(self.basedir) or {}
    local rows = {}
    for _, name in ipairs(dirs) do
        local dir = self.basedir .. "/" .. name
        local m = Downloader.decodeManifest(
            self.fs.read(Downloader.manifestPath(dir)))
        if m then
            local ok = true
            m.bytes = 0
            for _, p in ipairs(m.pages) do
                if not self.fs.exists(dir .. "/" .. p.file) then ok = false break end
                m.bytes = m.bytes + (p.bytes or 0)
            end
            if not ok then
                self:_prune(dir)
            elseif (m.complete ~= false) == want_complete then
                m.dir = dir
                rows[#rows + 1] = m
            end
        elseif self.fs.list(dir) then
            self:_prune(dir)
        end
    end
    table.sort(rows, function(a, b) return (a.saved or 0) > (b.saved or 0) end)
    return rows
end

--- 已下载（完整）章节列表，按 saved 倒序。未完成的不在这里出现，也不能当离线章。
function Downloader:list()
    return self:_scan(true)
end

--- 未完成（取消或失败中断）的章节：留着字节等续传，界面里给单独的删除入口。
function Downloader:listPartials()
    return self:_scan(false)
end

function Downloader:_prune(dir)
    local names = self.fs.list(dir) or {}
    for _, name in ipairs(names) do self.fs.remove(dir .. "/" .. name) end
    self.fs.remove(dir)
end

--- 清空全部下载：完整章与未完成章（留着等续传的半截）一起走，返回删除条数。
function Downloader:clearAll()
    local rows = self:list()
    for _, m in ipairs(rows) do self:_prune(m.dir) end
    local parts = self:listPartials()
    for _, m in ipairs(parts) do self:_prune(m.dir) end
    return #rows + #parts
end

--- 已下载章节占用的字节数（按 manifest 记录的页字节求和）。
function Downloader:usage()
    local total = 0
    for _, m in ipairs(self:list()) do total = total + (m.bytes or 0) end
    return total
end

--- 离线阅读用的页表：交给 browser 的取页路径按本地文件读。
function Downloader.localImages(manifest)
    local out = {}
    for i, p in ipairs(manifest.pages) do
        out[i] = { local_file = manifest.dir .. "/" .. p.file }
    end
    return out
end

return Downloader
