-- M2 T16: sources.lua —— 源文件仓库（R3.4）
-- 契约（design §3.7，2026-09-20 用户确认）：
--   索引 = 数组 [{name, fileName, key, version, description?}]
--   默认基址 = https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/
--   CDN 备选 = https://cdn.jsdelivr.net/gh/WEP-56/EZvenera-config@main/
--   本地源目录 <data>/ezvenera/index/*.json（同 schema），同 key 本地优先
--   已安装清单：key/version/来源/文件 sha256（json 存 <data>/ezvenera/installed.json）
--   源 js 文件存 <data>/ezvenera/sources/<key>.js
-- netclient 依赖注入（http 请求经 per-request 代理）；sha256 用 convert。

local Json = nil  -- 惰性：KOReader 内建 json / 测试注入

local Sources = {}
Sources.__index = Sources

Sources.DEFAULT_INDEX_URL =
    "https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json"
Sources.DEFAULT_BASE_URL =
    "https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/"
Sources.CDN_INDEX_URL =
    "https://cdn.jsdelivr.net/gh/WEP-56/EZvenera-config@main/index.json"
Sources.CDN_BASE_URL =
    "https://cdn.jsdelivr.net/gh/WEP-56/EZvenera-config@main/"
-- 真机实测（M2, 2026-09-22）：https+proxy 走 LuaSec CONNECT 随包不可用，
-- https 直连证书链也易失败。http 变体走 socket.http 原生 proxy=（最稳）。
Sources.HTTP_INDEX_URL =
    "http://cdn.jsdelivr.net/gh/WEP-56/EZvenera-config@main/index.json"
Sources.HTTP_BASE_URL =
    "http://cdn.jsdelivr.net/gh/WEP-56/EZvenera-config@main/"

--- 纯 Lua ensureDir：io.open 探针（r+ 存在即返回；否则逐级 mkdir 兜底）。
--- os.execute 的 mkdir -p 在 Windows 不可用，且不同平台命令各异——探针方案
--- 零平台差异。datadir 本体在 install/manifest 写入时自动创建。
local function ensureDirFor(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function ensureDir(dir)
    if ensureDirFor(dir) then return true end
    -- R-D2v4：KOReader 进程内禁 fork/exec（LuaJIT+FFI SIGSEGV 实测），
    -- 用 lfs.mkdir（KOReader 内建）；非 KOReader 测试环境无 lfs 时
    -- 退化 os.execute（测试进程无 FFI 引擎加载，安全）。
    local oklfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if oklfs and lfs and lfs.mkdir then
        pcall(lfs.mkdir, dir)
    else
        pcall(os.execute, 'mkdir "' .. dir .. '" 2>nul')
        pcall(os.execute, 'mkdir -p "' .. dir .. '" 2>/dev/null')
    end
    return ensureDirFor(dir)
end

--- 读自定义索引的 .base 边车文件（没有则 nil）。
local function readSidecarBase(pdir, stem)
    local f = io.open(pdir .. "/" .. stem .. ".base", "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    s = (s or ""):gsub("%s+$", ""):gsub("^%s+", "")
    if s == "" then return nil end
    return s
end

--- 统一 GET：netclient:request(opts) 适配（返回 {status, body}）
function Sources:fetchUrl(url)
    local opts = { url = url, method = "GET" }
    -- per-request 代理（R2 契约）：读用户设置
    local st = self.settings
    if st then
        local enabled, purl
        if type(st.readSetting) == "function" then
            enabled = st:readSetting("proxy_enabled")
            purl = st:readSetting("proxy_url")
        elseif type(st.data) == "table" then
            enabled = st.data.proxy_enabled
            purl = st.data.proxy_url
        end
        if enabled and purl and purl ~= "" then
            opts.proxy = purl
        end
    end
    local ok, resp = pcall(function()
        return self.netclient:request(opts)
    end)
    if not ok then return nil, tostring(resp) end
    if type(resp) ~= "table" then return nil, "bad response" end
    return resp
end

function Sources.new(deps)
    deps = deps or {}
    local o = setmetatable({}, Sources)
    o.netclient = deps.netclient      -- 需含 request(opts) → {status, body}
    o.settings = deps.settings        -- proxy_enabled/proxy_url（可选）
    o.convert = deps.convert          -- 需含 sha256hex(bytes)（convert 提供）
    o.json = deps.json                -- 可注入（测试）；运行时回退内建
    o.datadir = deps.datadir or "ezvenera"
    -- 已安装清单内存缓存（load 时读盘）
    o._installed = nil
    return o
end

local function jdecode(self, s)
    if not s or s == "" then return nil end
    if self.json then
        local ok, v = pcall(function() return self.json.decode(s) end)
        if ok then return v end
        return nil
    end
    local ok, J = pcall(require, "json")
    if not ok or not J then return nil end
    local okd, v = pcall(function() return J.decode(s) end)
    return okd and v or nil
end

local function jencode(self, v)
    if self.json then
        local ok, s = pcall(function() return self.json.encode(v) end)
        if ok then return s end
        return nil
    end
    local ok, J = pcall(require, "json")
    if not ok or not J then return nil end
    local oke, s = pcall(function() return J.encode(v) end)
    return oke and s or nil
end

local function joinPath(base, fileName)
    if base:sub(-1) ~= "/" then base = base .. "/" end
    return base .. fileName
end

--- URL → (基址目录, 末段文件名)。查询串/锚点先剥掉，否则文件名带 ?x=y 存不成文件。
local function splitURL(url)
    local clean = tostring(url):gsub("[?#].*$", "")
    return clean:match("^(.-/)([^/]+)$")
end

--- lfs 在 KOReader 里叫 libs/libkoreader-lfs，测试进程里叫 lfs，都没有时退化
--- 到 io.open 探测（只能读已知文件名，列目录的能力就没有）。
local function openLfs()
    for _, name in ipairs({ "libs/libkoreader-lfs", "lfs" }) do
        local ok, m = pcall(require, name)
        if ok and type(m) == "table" and m.dir then return m end
    end
    return nil
end

-- ---------- 已安装清单 ----------

function Sources:installedFile()
    return self.datadir .. "/installed.json"
end

function Sources:installed()
    if self._installed then return self._installed end
    local f = io.open(self:installedFile(), "r")
    if not f then self._installed = {} return self._installed end
    local s = f:read("*a")
    f:close()
    local v = jdecode(self, s)
    self._installed = (type(v) == "table") and v or {}
    return self._installed
end

function Sources:saveInstalled()
    local s = jencode(self, self:installed())
    if not s then return false end
    ensureDir(self.datadir)
    local path = self:installedFile()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(s)
    f:close()
    if os.rename(tmp, path) then return true end
    local f2 = io.open(path, "w")
    if not f2 then return false end
    f2:write(s)
    f2:close()
    pcall(function() os.remove(tmp) end)
    return true
end

-- ---------- 路径 ----------


function Sources:sourcePath(key)
    local safe = tostring(key):gsub("[^%w%-_]", "_")
    local dir = self.datadir .. "/sources"
    ensureDir(dir)
    return dir .. "/" .. safe .. ".js"
end

function Sources:localIndexDir()
    local dir = self.datadir .. "/index"
    ensureDir(dir)
    return dir
end

-- ---------- 索引抓取 ----------

--- 拉取远端索引。返回 (list|nil, err)
--- 策略：先默认基址，失败（非 200/网络错）自动切 jsdelivr CDN。
function Sources:fetchIndex(indexUrl)
    local urls = {}
    if indexUrl and indexUrl ~= "" then
        table.insert(urls, indexUrl)
    else
        table.insert(urls, self.DEFAULT_INDEX_URL)
        table.insert(urls, self.CDN_INDEX_URL)
        table.insert(urls, self.HTTP_INDEX_URL)  -- http 兜底（proxy 原生）
    end
    local lastErr
    for _, url in ipairs(urls) do
        local resp, ferr = self:fetchUrl(url)
        if resp then
            if resp.status == 200 and type(resp.body) == "string"
                    and resp.body ~= "" then
                local list = jdecode(self, resp.body)
                if type(list) == "table" then
                    return list
                end
                lastErr = "index JSON invalid"
            else
                lastErr = ("HTTP %s from %s"):format(tostring(resp.status),
                    url)
            end
        else
            lastErr = tostring(ferr)
        end
    end
    return nil, lastErr or "index fetch failed"
end

--- 本地索引合并：读取 localIndexDir/*.json，同 key 本地优先
--- 返回 {list=合并后数组, localKeys={key=true}}
function Sources:mergeLocal(remoteList)
    local localEntries = {}
    local seenLocal = {}
    local pdir = self:localIndexDir()
    local lfs = openLfs()
    if lfs then
        for entry in lfs.dir(pdir) do
            if entry:sub(-5) == ".json" then
                local f = io.open(pdir .. "/" .. entry, "r")
                if f then
                    local s = f:read("*a")
                    f:close()
                    local list = jdecode(self, s)
                    if type(list) == "table" then
                        -- 自定义索引的基址记在同名 .base 边车文件里
                        -- （见 addCustomIndex）；官方/手工放的本地索引没有它就照旧走默认基址。
                        local base = readSidecarBase(pdir, entry:sub(1, -6))
                        for _, e in ipairs(list) do
                            if type(e) == "table" and e.key then
                                if base and not e._base then e._base = base end
                                table.insert(localEntries, e)
                                seenLocal[e.key] = true
                            end
                        end
                    end
                end
            end
        end
    end
    local merged = {}
    if type(remoteList) == "table" then
        for _, e in ipairs(remoteList) do
            if type(e) == "table" and e.key and not seenLocal[e.key] then
                table.insert(merged, e)
            end
        end
    end
    for _, e in ipairs(localEntries) do
        table.insert(merged, e)
    end
    return merged, seenLocal
end

-- ---------- 安装 / 更新 / 删除 ----------

--- 下载并安装/更新一个源。返回 (ok, err|installedEntry)
function Sources:install(entry, baseUrl)
    if type(entry) ~= "table" or not entry.key or not entry.fileName then
        return false, "invalid entry (need key + fileName)"
    end
    local bases = {}
    if baseUrl and baseUrl ~= "" then
        table.insert(bases, baseUrl)
    elseif entry._base and entry._base ~= "" then
        -- 自定义索引自带基址（addCustomIndex 记下的），官方基址对它没意义
        table.insert(bases, entry._base)
    else
        table.insert(bases, self.DEFAULT_BASE_URL)
        table.insert(bases, self.CDN_BASE_URL)
        table.insert(bases, self.HTTP_BASE_URL)  -- http 兜底（proxy 原生）
    end
    local body
    local usedBase
    local lastErr
    for _, b in ipairs(bases) do
        local url = joinPath(b, entry.fileName)
        local resp, ferr = self:fetchUrl(url)
        if resp and resp.status == 200
                and type(resp.body) == "string" and resp.body ~= "" then
            body = resp.body
            usedBase = b
            break
        end
        lastErr = ("fetch %s failed: HTTP %s"):format(url,
            tostring(resp and resp.status or ferr))
    end
    if not body then return false, lastErr or "download failed" end

    -- sha256（convert.sha256hex 或退化为长度指纹——CI 桩可注入）
    local sha
    if self.convert and self.convert.sha256hex then
        sha = self.convert.sha256hex(body)
    elseif self.convert and self.convert.sha256 then
        sha = self.convert.sha256(body)
    else
        sha = ("len:%d"):format(#body)
    end

    local path = self:sourcePath(entry.key)
    local f = io.open(path, "w")
    if not f then return false, "cannot write " .. path end
    f:write(body)
    f:close()

    local inst = self:installed()
    inst[entry.key] = {
        -- key 也存一份：install() 把这个表直接回给调用方（UI 要拿它提示/失效
        -- 缓存），只靠清单的键取不到。
        key = entry.key,
        name = entry.name,
        version = entry.version,
        source = usedBase or baseUrl or self.DEFAULT_BASE_URL,
        file = path,
        sha256 = sha,
        size = #body,
        installed_at = os.time(),
    }
    self:saveInstalled()
    return true, inst[entry.key]
end

--- 删除已安装源。返回 (ok, err)
function Sources:remove(key)
    local inst = self:installed()
    local e = inst[key]
    if not e then return false, "not installed: " .. tostring(key) end
    if e.file then
        -- 原来整段 pcall 吞错：文件删不掉（只读挂载、被占用）时清单条目
        -- 已经没了，磁盘上留一个 UI 里看不见、也永远清不掉的孤儿 .js。
        -- 现在删不动就报错，条目保留，用户可以重试。
        if not os.remove(e.file) then
            local probe = io.open(e.file, "r")
            if probe then
                probe:close()
                return false, "源文件删除失败（只读或被占用）：" .. e.file
            end
        end
    end
    inst[key] = nil
    if not self:saveInstalled() then
        -- 内存清单和磁盘必须同步：写盘失败就把条目放回去（磁盘上本来就在）
        inst[key] = e
        return false, "清单写入失败：installed.json"
            .. "（源文件已删，列表里的这条重启后仍在）"
    end
    return true
end

--- 已安装源 js 内容读取（供 jshost eval）
function Sources:readSource(key)
    local inst = self:installed()
    local e = inst[key]
    if not e or not e.file then return nil end
    local f = io.open(e.file, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- 已安装 key 列表（稳定排序）
function Sources:listInstalled()
    local out = {}
    for key, e in pairs(self:installed()) do
        table.insert(out, { key = key, name = e.name, version = e.version })
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- 本地 .js 直装（design §3.7：选择本地文件安装）
--- 返回 (ok, err|installedEntry)。key 缺省取文件名去扩展。
--- meta（可选）= {name=…, version=…}：整包导入时索引里带着显示名和版本，
--- 传进来才不会把清单写成 key/"local"（UI 列表与更新比较都依赖这两项）。
function Sources:installLocalFile(path, key, meta)
    local f = io.open(path, "r")
    if not f then return false, "cannot open " .. tostring(path) end
    local body = f:read("*a")
    f:close()
    if body == "" then return false, "empty file" end
    key = key or (path:match("([^/\\]+)%.js$")) or ("local_" .. os.time())
    local sha
    if self.convert and self.convert.sha256hex then
        sha = self.convert.sha256hex(body)
    else
        sha = ("len:%d"):format(#body)
    end
    local dest = self:sourcePath(key)
    local g = io.open(dest, "w")
    if not g then return false, "cannot write " .. dest end
    g:write(body)
    g:close()
    local inst = self:installed()
    inst[key] = {
        key = key,
        name = (meta and meta.name) or key,
        version = (meta and meta.version) or "local",
        source = "local:" .. path,
        file = dest,
        sha256 = sha,
        size = #body,
        installed_at = os.time(),
    }
    self:saveInstalled()
    return true, inst[key]
end

--- 本地整包导入：`<dir>/manifest.json`（与官方 index.json 同 schema）
--- + 同目录里的 .js。返回 (results, err)，results = {n_ok, n_fail, list=}，
--- list 每项 {key, name, ok, err}。
--- 为什么不顺手写进 index/：自定义索引（addCustomIndex）走的是「记下基址、
--- 之后按 fileName 联网下载」；离线整包没有可下载的基址，落进 index/ 反而让
--- 「浏览索引并安装」拿默认基址去下一个 404。所以只落 sources/ +
--- installed.json，装完直接在「已安装源」里可见可用。
function Sources:installLocalBundle(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil, "需要本地目录路径"
    end
    dir = dir:gsub("[/\\]+$", "")
    local manifest = dir .. "/manifest.json"
    local f = io.open(manifest, "r")
    if not f then
        -- 兼容官方索引的命名
        manifest = dir .. "/index.json"
        f = io.open(manifest, "r")
    end
    if not f then
        return nil, "目录里没有 manifest.json / index.json: " .. dir
    end
    local raw = f:read("*a")
    f:close()
    local list = jdecode(self, raw)
    if type(list) ~= "table" or #list == 0 then
        return nil, "索引解析失败或为空（需要 JSON 数组）"
    end
    local out = { list = {}, n_ok = 0, n_fail = 0, n_over = 0 }
    for _, e in ipairs(list) do
        local res = {}
        if type(e) ~= "table" or not e.key or not e.fileName then
            res.key = type(e) == "table" and e.key or "?"
            res.ok, res.err = false, "条目缺 key/fileName"
        else
            res.key, res.name = e.key, e.name or e.key
            -- 同名 key 已在装机上：整包会**静默覆盖**用户自己装的版本
            -- （真机教训：包里带了个 zaimanhua，把用户 v1.0.2 换成了 v1.0.0）。
            -- 覆盖本身是想要的行为（整包就是批量装），但必须报出来。
            local prev = self:installed()[e.key]
            if type(prev) == "table" then
                res.overwrite = true
                res.prev_version = prev.version
            end
            local ok, r = self:installLocalFile(dir .. "/" .. e.fileName,
                e.key, { name = e.name, version = e.version })
            if ok and res.overwrite then out.n_over = out.n_over + 1 end
            res.ok = ok and true or false
            if ok then
                res.version = r.version
                out.n_ok = out.n_ok + 1
            else
                res.err = tostring(r)
                out.n_fail = out.n_fail + 1
            end
        end
        table.insert(out.list, res)
    end
    return out
end

-- ---------- 添加自定义漫画源 ----------

local function writeFile(path, body)
    local f = io.open(path, "w")
    if not f then return false, "无法写入 " .. path end
    f:write(body)
    f:close()
    return true
end

--- 从任意 http(s) 地址直装一个源 js（「添加自定义漫画源」最快的一条路）。
--- 地址拆成 基址 + 文件名 后复用 install() 的下载/落盘/清单链路。
--- 返回 (ok, err|installedEntry)
function Sources:installFromURL(url, name)
    if type(url) ~= "string" or not url:match("^https?://") then
        return false, "地址需要以 http:// 或 https:// 开头"
    end
    local base, fileName = splitURL(url)
    if not base or not fileName or fileName == "" then
        return false, "地址里取不出源文件名（应形如 https://主机/目录/xxx.js）"
    end
    local key = fileName:gsub("%.js$", ""):gsub("[^%w%-_]", "_")
    if key == "" then return false, "文件名不合法，生不出本地标识" end
    local nm = (type(name) == "string" and name ~= "") and name or key
    return self:install({ key = key, fileName = fileName, name = nm,
        version = "custom" }, base)
end

--- 添加自定义源索引（一份 index.json）：原文落进本地索引目录，之后
--- 「浏览索引并安装」直接能看到并安装这些源。
--- 为什么不重新编码：本地索引目录的约定是与官方同 schema 的 JSON 数组，
--- 原文落盘最无损（也绕开对 json 编码器的依赖）；基址单独记在同名 .base
--- 边车文件里，源 js 一般与索引同目录，安装时要靠它取文件（mergeLocal 读回）。
--- 返回 (ok, err|{ file=标识, count=条数, base=基址 })
function Sources:addCustomIndex(url)
    if type(url) ~= "string" or not url:match("^https?://") then
        return false, "地址需要以 http:// 或 https:// 开头"
    end
    local resp, ferr = self:fetchUrl(url)
    if not resp then return false, "索引拉取失败：" .. tostring(ferr) end
    if resp.status ~= 200 or type(resp.body) ~= "string" or resp.body == "" then
        return false, "索引拉取失败：HTTP " .. tostring(resp.status or ferr)
    end
    local list = jdecode(self, resp.body)
    if type(list) ~= "table" then
        return false, "索引不是合法的 JSON（应为条目数组）"
    end
    local n = 0
    for _, e in ipairs(list) do
        if type(e) == "table" and e.key and e.fileName then n = n + 1 end
    end
    if n == 0 then
        return false, "索引里没有可用条目（每条需要 key + fileName）"
    end
    local stem = "custom_" .. tostring(url:gsub("[?#].*$", "")
        :gsub("[^%w%-_]", "_")):sub(-56)
    local pdir = self:localIndexDir()
    local ok, err = writeFile(pdir .. "/" .. stem .. ".json", resp.body)
    if not ok then return false, err end
    local base = splitURL(url)
    if base then
        local okb, errb = writeFile(pdir .. "/" .. stem .. ".base", base)
        if not okb then return false, errb end
    end
    return true, { file = stem, count = n, base = base }
end

--- 已添加的自定义索引（供查看/删除）。返回 [{file, base, count}]，按 file 排序。
function Sources:listCustomIndexes()
    local out = {}
    local pdir = self:localIndexDir()
    local lfs = openLfs()
    if not lfs then return out end
    for name in lfs.dir(pdir) do
        local stem = name:match("^(custom_[%w%-_]+)%.json$")
        if stem then
            local f = io.open(pdir .. "/" .. name, "r")
            local count = 0
            if f then
                local list = jdecode(self, f:read("*a"))
                f:close()
                if type(list) == "table" then
                    for _, e in ipairs(list) do
                        if type(e) == "table" and e.key and e.fileName then
                            count = count + 1
                        end
                    end
                end
            end
            table.insert(out, {
                file = stem, base = readSidecarBase(pdir, stem), count = count,
            })
        end
    end
    table.sort(out, function(a, b) return a.file < b.file end)
    return out
end

--- 删除一份自定义索引（只认 custom_ 前缀，官方/手工本地索引文件不动）。
--- 返回 (ok, err)
function Sources:removeCustomIndex(stem)
    if type(stem) ~= "string" or not stem:match("^custom_[%w%-_]+$") then
        return false, "索引标识不合法"
    end
    local pdir = self:localIndexDir()
    local removed = false
    for _, suffix in ipairs({ ".json", ".base" }) do
        local path = pdir .. "/" .. stem .. suffix
        local f = io.open(path, "r")
        if f then f:close() end
        if os.remove(path) then removed = true end
    end
    if not removed then return false, "找不到索引：" .. stem end
    return true
end

return Sources
