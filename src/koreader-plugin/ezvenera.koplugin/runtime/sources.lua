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
    -- 已安装清单内存缓存（load 时读盘，指纹变了才重读）
    o._installed = nil
    o._installed_stamp = nil
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

--- 清单指纹：有 lfs 时用 mtime+size，没有时只剩字节数。
--- 只用来判断"盘上这份是不是我内存里这份"，不参与业务语义。
function Sources:_manifestStamp()
    local path = self:installedFile()
    local lfs = openLfs()
    local mtime = (lfs and lfs.attributes) and lfs.attributes(path, "modification") or nil
    local size
    local f = io.open(path, "rb")
    if f then size = f:seek("end"); f:close() end
    if mtime == nil and size == nil then return nil end
    return tostring(mtime) .. ":" .. tostring(size)
end

--- 内存缓存要在盘上清单被别人改动后失效：整包导入/adb 直接推 installed.json
--- 是这里最常见的操作，旧版本只在进程启动时读一次，推完不重启就永远看不到新源
--- （2026-09-25 真机"13 个源只显示 4 个"即此，见 reports §10.9）。
function Sources:installed()
    local stamp = self:_manifestStamp()
    if self._installed and (stamp == nil or stamp == self._installed_stamp) then
        return self._installed
    end
    local f = io.open(self:installedFile(), "r")
    if not f then
        self._installed = {}
        self._installed_stamp = stamp
        return self._installed
    end
    local s = f:read("*a")
    f:close()
    local v = jdecode(self, s)
    self._installed = (type(v) == "table") and v or {}
    self._installed_stamp = stamp
    return self._installed
end

--- 写盘。inst = 调用方正在改的那份清单表：外部改动可能让 installed() 中途换表，
--- 传进来才能保证"我改的就是我写出去的、也是缓存里的那一份"。
function Sources:saveInstalled(inst)
    inst = inst or self:installed()
    local s = jencode(self, inst)
    if not s then return false end
    ensureDir(self.datadir)
    local path = self:installedFile()
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(s)
    f:close()
    if os.rename(tmp, path) then
        self._installed = inst
        self._installed_stamp = self:_manifestStamp()
        return true
    end
    local f2 = io.open(path, "w")
    if not f2 then return false end
    f2:write(s)
    f2:close()
    pcall(function() os.remove(tmp) end)
    self._installed = inst
    self._installed_stamp = self:_manifestStamp()
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

-- ---------- 版本护栏（同名 key 不同版本导入时的裁决） ----------

--- 点分数字版本解析：'1.0.2' / 'v1.0.2' / '1.0.2-beta' → {1,0,2}；
--- 'local' / 'custom' / nil → nil（不可比较）。
local function versionParts(v)
    if type(v) ~= "string" then return nil end
    local s = v:match("^%s*(.-)%s*$"):gsub("^[vV]", ""):gsub("[%-+].*$", "")
    if s == "" or not s:match("^%d") or not s:match("^[%d%.]+$") then
        return nil
    end
    local out = {}
    for tok in s:gmatch("[^%.]+") do
        local n = tonumber(tok)
        if not n then return nil end
        table.insert(out, n)
    end
    return out
end

--- 返回 -1 / 0 / 1，任一侧不可解析返回 nil。
local function compareVersions(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    if not pa or not pb then return nil end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y and 1 or -1 end
    end
    return 0
end

--- 内容指纹：优先真 sha256（加密后端在位时），其次测试桩注入的 sha256hex，
--- 后端缺失才退回长度指纹（清单里长得像 'len:15063'，一眼可辨不是哈希）。
local function fingerprint(convert, body)
    if convert then
        -- 测试桩按普通函数注入（sha256hex/sha256），真 Convert 按方法注入 digest
        if convert.sha256hex then return convert.sha256hex(body) end
        if convert.digest and convert.hexEncode then
            local raw = convert:digest("sha256", body)
            if raw then return convert.hexEncode(raw) end
        end
        if convert.sha256 then return convert.sha256(body) end
    end
    return ("len:%d"):format(#body)
end

--- 备份文件名：`<源文件>.bak-<旧版本>`。同一旧版本重复导入只留一份（覆盖它），
--- 不会每次安装都堆一个新文件。
local function backupPath(file, version)
    return tostring(file) .. ".bak-" .. tostring(version or "0")
        :gsub("[^%w%.%-]", "_")
end

--- 覆盖前把旧文件留一份，返回备份路径（无旧文件/写不动则 nil）。
--- 备份失败绝不阻断安装：装不上比少一份退路更糟。
function Sources:_backupPrevious(key)
    local e = self:installed()[key]
    if type(e) ~= "table" or not e.file then return nil end
    local src = io.open(e.file, "r")
    if not src then return nil end
    local body = src:read("*a")
    src:close()
    if body == "" then return nil end
    local dest = backupPath(e.file, e.version)
    local g = io.open(dest, "w")
    if not g then return nil end
    g:write(body)
    g:close()
    return dest
end

--- 该源可用的备份（按版本号字符串降序，最新在前）。没有列目录能力时返回空表。
function Sources:listBackups(key)
    local e = self:installed()[key]
    if not e or not e.file then return {} end
    local lfs = openLfs()
    if not lfs then return {} end
    local dir, stem = e.file:match("^(.-)/([^/]+)%.js$")
    if not dir then return {} end
    local prefix = stem .. ".js.bak-"
    local out = {}
    for name in lfs.dir(dir) do
        if type(name) == "string" and name:sub(1, #prefix) == prefix then
            table.insert(out, {
                version = name:sub(#prefix + 1),
                file = dir .. "/" .. name,
            })
        end
    end
    table.sort(out, function(a, b) return a.version > b.version end)
    return out
end

--- 回退到某个备份：当前版本先备份掉，再把备份内容写回正式文件并改清单。
--- 返回 (ok, err|entry)
function Sources:restoreBackup(key, version)
    local inst = self:installed()
    local e = inst[key]
    if type(e) ~= "table" then return false, "未安装该源: " .. tostring(key) end
    local found
    for _, b in ipairs(self:listBackups(key)) do
        if b.version == tostring(version) then found = b.file end
    end
    if not found then return false, "找不到备份 v" .. tostring(version) end
    local src = io.open(found, "r")
    if not src then return false, "备份读不动: " .. found end
    local body = src:read("*a")
    src:close()
    if body == "" then return false, "备份为空文件" end
    self:_backupPrevious(key)
    local from_version = e.version
    local g = io.open(e.file, "w")
    if not g then return false, "无法写入 " .. tostring(e.file) end
    g:write(body)
    g:close()
    e.version = tostring(version)
    e.sha256 = fingerprint(self.convert, body)
    e.size = #body
    e.installed_at = os.time()
    e.verdict = "restore"
    e.prev_version = from_version
    e.backup = backupPath(e.file, from_version)
    self:saveInstalled(inst)
    return true, e
end

--- 覆盖护栏（只裁决，不碰磁盘；备份留到内容到手、马上要落盘时再做，
--- 免得一次失败的网络安装留下没用的 .bak）。返回 (allowed, verdict, reason)：
---   new/upgrade/same/unknown → 放行（unknown = 版本串不可解析，如 'custom'）
---   downgrade → 默认拦下，只有调用方显式 allow_downgrade（用户在确认框里
---   选了「仍然覆盖」）才放行
function Sources:_checkOverwrite(key, next_version, allow_downgrade)
    local prev = self:installed()[key]
    if type(prev) ~= "table" then return true, "new" end
    local c = compareVersions(prev.version, next_version)
    local verdict = c == nil and "unknown" or (c < 0 and "upgrade"
        or (c == 0 and "same" or "downgrade"))
    if verdict == "downgrade" and not allow_downgrade then
        return false, verdict,
            ("低版本不覆盖：本机已装 v%s，来的是 v%s"):format(
                tostring(prev.version), tostring(next_version))
    end
    return true, verdict, prev.version
end

-- ---------- 安装 / 更新 / 删除 ----------

--- 下载并安装/更新一个源。返回 (ok, err|installedEntry[, verdict])；
--- 被版本护栏拦下时第三个返回值是 "downgrade"，UI 靠它给出「仍然覆盖」。
--- opts = { allow_downgrade = bool }：降级需要调用方（用户确认框）显式放行。
function Sources:install(entry, baseUrl, opts)
    if type(entry) ~= "table" or not entry.key or not entry.fileName then
        return false, "invalid entry (need key + fileName)"
    end
    local allowed, verdict, note = self:_checkOverwrite(entry.key, entry.version,
        opts and opts.allow_downgrade)
    if not allowed then return false, note, verdict end

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

    local path = self:sourcePath(entry.key)
    -- 落盘前留一份旧文件：覆盖之后还能退回（见 restoreBackup / listBackups）
    local backup = self:_backupPrevious(entry.key)
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
        sha256 = fingerprint(self.convert, body),
        size = #body,
        installed_at = os.time(),
        verdict = verdict,
        prev_version = note,
        backup = backup,
    }
    self:saveInstalled(inst)
    return true, inst[entry.key], verdict
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
    if not self:saveInstalled(inst) then
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

--- 列表显示名：同名不同 key 在 Venera 生态里是常态（三家都做过「鸟鸟韩漫」），
--- 只给名字用户根本分不清点进去的是哪个源 → 重名的补 [key]，唯一的原样。
--- 入参 = {{key=, name=}, …}，返回等长数组。纯函数，不碰清单。
function Sources.uniqueLabels(list)
    local count = {}
    for _, e in ipairs(list) do
        local nm = e.name or e.key
        count[nm] = (count[nm] or 0) + 1
    end
    local out = {}
    for _, e in ipairs(list) do
        local nm = e.name or e.key
        out[#out + 1] = nm .. (count[nm] > 1
            and (" [" .. tostring(e.key) .. "]") or "")
    end
    return out
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
--- 返回 (ok, err|installedEntry[, verdict])。key 缺省取文件名去扩展。
--- meta（可选）= {name=…, version=…}：整包导入时索引里带着显示名和版本，
--- 传进来才不会把清单写成 key/"local"（UI 列表与更新比较都依赖这两项）。
--- opts = { allow_downgrade = bool }：同 install()。
function Sources:installLocalFile(path, key, meta, opts)
    local f = io.open(path, "r")
    if not f then return false, "cannot open " .. tostring(path) end
    local body = f:read("*a")
    f:close()
    if body == "" then return false, "empty file" end
    key = key or (path:match("([^/\\]+)%.js$")) or ("local_" .. os.time())
    local allowed, verdict, note = self:_checkOverwrite(key,
        meta and meta.version, opts and opts.allow_downgrade)
    if not allowed then return false, note, verdict end
    local dest = self:sourcePath(key)
    local backup = self:_backupPrevious(key)
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
        sha256 = fingerprint(self.convert, body),
        size = #body,
        installed_at = os.time(),
        verdict = verdict,
        prev_version = note,
        backup = backup,
    }
    self:saveInstalled(inst)
    return true, inst[key], verdict
end

--- 本地整包导入：`<dir>/manifest.json`（与官方 index.json 同 schema）
--- + 同目录里的 .js。返回 (results, err)，results = {n_ok, n_fail, n_skip, list=}，
--- list 每项 {key, name, ok, err, verdict[, skipped]}。
--- opts = { allow_downgrade = bool }：包内版本低于本机已装时，默认这条只报
--- 跳过不写盘；用户在确认框里选「仍然覆盖」后才传 true 重跑一遍。
--- 为什么不顺手写进 index/：自定义索引（addCustomIndex）走的是「记下基址、
--- 之后按 fileName 联网下载」；离线整包没有可下载的基址，落进 index/ 反而让
--- 「浏览索引并安装」拿默认基址去下一个 404。所以只落 sources/ +
--- installed.json，装完直接在「已安装源」里可见可用。
function Sources:installLocalBundle(dir, opts)
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
    local out = { list = {}, n_ok = 0, n_fail = 0, n_over = 0, n_skip = 0 }
    for _, e in ipairs(list) do
        local res = {}
        if type(e) ~= "table" or not e.key or not e.fileName then
            res.key = type(e) == "table" and e.key or "?"
            res.ok, res.err = false, "条目缺 key/fileName"
        else
            res.key, res.name = e.key, e.name or e.key
            -- 同名 key 已在装机上：整包是批量装，升级/同版本直接覆盖，但必须
            -- 报出来（真机教训：包里带了个 zaimanhua，把用户 v1.0.2 换成了
            -- v1.0.0 且无人知晓）。降级默认拦下，除非调用方传 allow_downgrade。
            local prev = self:installed()[e.key]
            if type(prev) == "table" then
                res.overwrite = true
                res.prev_version = prev.version
            end
            local ok, r, verdict = self:installLocalFile(
                dir .. "/" .. e.fileName, e.key,
                { name = e.name, version = e.version }, opts)
            res.verdict = verdict
            res.ok = ok and true or false
            if ok and res.overwrite then out.n_over = out.n_over + 1 end
            if ok then
                res.version = r.version
                out.n_ok = out.n_ok + 1
            else
                res.err = tostring(r)
                if verdict == "downgrade" then
                    res.skipped = true
                    out.n_skip = out.n_skip + 1
                else
                    out.n_fail = out.n_fail + 1
                end
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
--- 返回 (ok, err|installedEntry[, verdict])
function Sources:installFromURL(url, name, opts)
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
        version = "custom" }, base, opts)
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
