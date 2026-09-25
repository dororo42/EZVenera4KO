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
这样命名/续传/取消清理/manifest 解析等逻辑都能在纯 LuaJIT 环境里验证。
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
        "saved\t" .. esc(m.saved), "pages\t" .. esc(#m.pages) }
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

--- 读 manifest 并校验页文件是否都在（缺文件 = 不完整，不能当离线章用）。
function Downloader:manifestOf(key, comicId, epId)
    local dir = self:dirOf(key, comicId, epId)
    local m = Downloader.decodeManifest(self.fs.read(Downloader.manifestPath(dir)))
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
    -- 上一轮中断的残留（含坏 manifest）先清干净：manifest 最后才写，所以
    -- 此刻目录里的任何东西都不能给离线阅读当"已下载"用。
    local stale = self.fs.list(dir)
    if stale then
        for _, name in ipairs(stale) do self.fs.remove(dir .. "/" .. name) end
    end
    return {
        o = o, key = key, comicId = comicId, epId = epId, dir = dir,
        images = images, total = #images, done = 0, pages = {}, bytes = 0,
    }
end

--- 取一页并落盘。返回 ("run", done) 还有页要下 / ("done", manifest) /
--- ("error", err)。取消在这里生效：调用方置 job.stopped，或 on_progress 返回 false。
function Downloader:step(job)
    if job.skipped then return "done", job.manifest end
    local o = job.o
    if job.stopped then
        self:remove(job.key, job.comicId, job.epId)
        return "error", "已取消"
    end
    local fail = function(msg)
        self:remove(job.key, job.comicId, job.epId)
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
        self:remove(job.key, job.comicId, job.epId)
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

--- 已下载章节列表（按 manifest 的 saved 倒序）。dir 里没有 manifest 的一律
--- 跳过（中断的残留），并顺手删掉，避免占着空间又读不出来。
function Downloader:list()
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
            if ok then
                m.dir = dir
                rows[#rows + 1] = m
            else
                self:_prune(dir)
            end
        elseif self.fs.list(dir) then
            self:_prune(dir)
        end
    end
    table.sort(rows, function(a, b) return (a.saved or 0) > (b.saved or 0) end)
    return rows
end

function Downloader:_prune(dir)
    local names = self.fs.list(dir) or {}
    for _, name in ipairs(names) do self.fs.remove(dir .. "/" .. name) end
    self.fs.remove(dir)
end

function Downloader:clearAll()
    local rows = self:list()
    for _, m in ipairs(rows) do self:_prune(m.dir) end
    return #rows
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
