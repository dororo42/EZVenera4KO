--[[
EZVenera for KOReader — netclient.lua
插件专用 HTTP 层。REQ: R2.3（per-request 代理，http+https）、R3.2（http handler 底座）。

为什么不走 NetworkMgr:setHTTPProxy（ADR-003）：
  原生全局代理只写 socket.http.PROXY（manager.lua:680-689），ssl.https /
  turbo / httpasync 都不过代理。本层对每次请求显式传 proxy：
  - http  : LuaSocket `proxy` 参数——仅非空 URL 写入 reqt.proxy；
            禁用（""/false 哨兵）= 强制直连：不传 proxy 且请求期间临时
            清空全局 socket.http.PROXY（审查 H1：空串会被 luasocket 当真值
            进入代理分支，url.parse("") 返回 nil → 索引崩溃，实测
            v3.0.0 与 master 均如此）
  - https : **不用 ssl.https**。随包 LuaSec 1.3.2 的 request 硬拒三种入参
            （common/ssl/https.lua:124-130）：
              http.PROXY or url.proxy → "proxy not supported"（真机
                  2026-09-23 报的就是这一串）
              url.redirect           → "redirect not supported"
              url.create             → "create function not permitted"
            即：带代理不行、允许跳转也不行、注入 create 也不行——这条路
            在代理环境下没有出路。改为自己经 socket.http 发 HTTPS：
            自定义 create（_tlsConn）做 裸 TCP →（有代理时）CONNECT 隧道
            → ssl.wrap → sni → dohandshake（cfg 抄 LuaSec 的 https.lua:29
            -33），请求行强制 origin-form（隧道末端是源站本身），跳转由
            _httpsRequest 限量跟随（luasocket 的 tredirect 会复用已绑定旧
            目标的 create 闭包，自动跳转会打到错误主机）。

响应模型与 Venera 契约对齐：永不抛错，返回
  { status, headers = { 小写键: "v1,v2" }, body, error }

r10 M1（非阻塞传输）：`requestAsync` 把同一条 HTTPS 路径放进 AsyncNet 协程
作业里跑。io 一路传到 `_tlsConn`，连接/握手/收发在「现在没数据」时 yield 回
UIManager 节拍，而不是原地干等 4s。要点：
  - 走的是 luasocket 自己的 HTTP 客户端，**不自写响应解析**（M0 判定）；
  - 单条作业里每次底层 socket 动作都先 `settimeout(0)`，再靠
    `AsyncNet.retry` 把 `timeout`/`wantread`/`wantwrite` 变成「等一拍再来」；
  - 取消 = 丢掉协程 + `_ezv_hard_close` + `_dropTunnel`（半截隧道绝不能留）；
  - 明文 http（`_plainRequest`）与自定义 transport **不经 create**，仍然是
    阻塞的——异步化只覆盖 HTTPS 那条真实瓶颈路径。
]]

local AsyncNet = require("runtime/asyncnet")

local NetClient = {}
NetClient.__index = NetClient

-- 审查 L7：luasocket 兜底 UA "LuaSocket 3.0" 会被部分漫画源拒绝。
-- 对齐上游 Venera 宿主（Dart HttpClient）默认 UA 形态；确切值 S1 用真实源核实。
NetClient.DEFAULT_UA = "Dart/3.5 (dart:io)"

-- URL 解析（纯 Lua，够用即可）

--- 请求行/URI 里非法字节百分号化（只处理 path+query；host 段留原样，
--- IPv6 字面量带方括号）。
local function pctEncode(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        -- 空格 + 控制字符 + 非 ASCII + RFC 3986 明确禁用的标点。
        -- '%' 不在名单里：源已编码的串（%E6%B5%B7）保持幂等。
        if b < 32 or b > 126 or b == 32 or b == 34 or b == 60 or b == 62
                or b == 92 or b == 94 or b == 96 or b == 123 or b == 124
                or b == 125 then
            out[#out + 1] = string.format("%%%02X", b)
        else
            out[#out + 1] = s:sub(i, i)
        end
    end
    return table.concat(out)
end

--- 【R7 真机】Venera 的 Dart 宿主用 Uri.parse 自动做这件事，源脚本因此
--- 可以直接拼中文关键词（baozi.js:299 `search?q=${keyword}`）。我们原样
--- 发送请求行 → 中文/带空格的关键词经代理必被拒，而症状出现在很远
--- 的地方（源抛"加载失败"或 errno!=0，看不出是 URL 没编码）。
function NetClient.encodeRequestURL(url)
    if type(url) ~= "string" then return url end
    local head, target = url:match("^([%a][%w+%.%-]*://[^/]*)(.*)$")
    if not head or target == "" then return url end
    return head .. pctEncode(target)
end

function NetClient.parseURL(url)
    if type(url) ~= "string" then return nil end
    local scheme, rest = url:match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then return nil end
    local authority, path = rest:match("^([^/?#]*)(.*)$")
    if path == nil or path == "" then path = "/" end
    local userinfo, hostport = authority:match("^([^@]*)@(.+)$")
    if not hostport then hostport = authority; userinfo = nil end
    local host, port
    if hostport:sub(1, 1) == "[" then
        -- IPv6 字面量：[::1]:8080
        host, port = hostport:match("^%[([^%]]+)%]:?(%d*)$")
    else
        host, port = hostport:match("^([^:]+):?(%d*)$")
    end
    if not host or host == "" then return nil end
    port = tonumber(port)
    if not port then
        port = scheme:lower() == "https" and 443 or 80
    end
    return {
        scheme = scheme:lower(), host = host, port = port,
        path = path, userinfo = userinfo,
    }
end

function NetClient.new(deps)
    deps = deps or {}
    local o = setmetatable({}, NetClient)
    o.transport = deps.transport       -- 自定义传输（测试桩）；nil = 内置 luasocket
    -- 【ANR】block 超时是**单次阻塞操作**（连接/握手/一次 read）的上限，
    -- 真机实测健康的 TLS 握手只要 0.82-0.95s，而源站/CDN 经代理不通时要干等
    -- 到 block 才报错（2026-09-24 baozicdn：代理收 CONNECT 后不回任何 TLS 字
    -- 节 → LuaSec 返回 wantread，10s×2 次重试 = 20s）。KOReader 单线程，这段
    -- 时间整条主循环冻住，安卓 InputDispatcher 5s 就弹「无响应」。
    -- 原值 10 是照抄 LuaSec 默认，收紧到 4s：留 4 倍余量给慢而通的链路。
    o.default_timeout_block = deps.timeout_block or 4
    o.default_timeout_total = deps.timeout_total or 30
    o.max_redirects = deps.max_redirects or 5
    -- 【性能】HTTPS 隧道/连接复用。真机实测一张章节图冷路径 1.16-2.08s，
    -- 其中 TLS 握手 0.82-0.95s（占 70-80%）；同一条隧道上第二次请求只要
    -- 0.28-0.38s。一章 27 图 ≈ 40s vs 8-10s 的差别就在这里。
    o.keepalive = deps.keepalive ~= false
    o.tunnel_idle_ttl = deps.tunnel_idle_ttl or 15
    o.tunnel_max = deps.tunnel_max or 4
    o._tunnels = {}                    -- tunnelKey → { conn = , at = }
    return o
end

--- 懒加载内置依赖（KOReader 内可用；单测注入桩）
function NetClient:_libs()
    if self._libs_cache then return self._libs_cache end
    local libs = {}
    -- 审查 L1（独立报告）：pcall 失败时第二返回值是错误字符串（truthy），
    -- 原写法 `ok, libs.http = pcall(...)` 会把错误串当成模块存进去，
    -- `if not mod` 判断永不触发，报错退化为 "attempt to index a string"。
    -- 统一改为失败置 nil。
    local ok, lib
    ok, lib = pcall(require, "socket.http")
    libs.http = ok and lib or nil
    ok, lib = pcall(require, "ltn12")
    libs.ltn12 = ok and lib or nil
    ok, lib = pcall(require, "socket")
    libs.socket = ok and lib or nil
    ok, lib = pcall(require, "ssl")
    libs.ssl = ok and lib or nil
    ok, lib = pcall(require, "mime")
    libs.mime = ok and lib or nil
    ok, lib = pcall(require, "socket.url")
    libs.url = ok and lib or nil
    pcall(function() libs.socketutil = require("socketutil") end)
    self._libs_cache = libs
    return libs
end

--- 主入口。opts:
---   url (必填), method="GET", headers={}, body=nil,
---   bytes=false (保留字段：body 恒为字节串，此标志仅透传给调用方),
---   proxy=nil|string (nil=按插件设置；显式 "" 或 false = 强制直连),
---   timeout_block/timeout_total
--- 返回 { status, headers, body, error }（永不抛错）。
function NetClient:request(opts)
    local resp = { status = nil, headers = {}, body = nil, error = nil }
    if type(opts) ~= "table" or type(opts.url) ~= "string" or opts.url == "" then
        resp.error = "netclient: missing url"
        return resp
    end
    local encoded = NetClient.encodeRequestURL(opts.url)
    if encoded ~= opts.url then
        -- 不改调用方传入的表：只对本次的下发副本生效
        local copied = {}
        for k, v in pairs(opts) do copied[k] = v end
        copied.url = encoded
        opts = copied
    end
    -- M2（审查报告 §3）：永不抛错契约在 pcall 之外也要成立——
    -- method/headers 形态错误在此归一，而不是把异常抛给直连调用方
    local method = tostring(opts.method or "GET"):upper()
    local headers = {}
    if type(opts.headers) == "table" then
        for k, v in pairs(opts.headers) do
            -- L5（审查报告 §4）：键值剥离控制字符，堵 CRLF 头注入
            headers[(tostring(k):gsub("%c", ""))]
                = (tostring(v):gsub("%c", ""))
        end
    end
    -- 审查 L7：无 UA 头时注入默认（大小写不敏感探测）
    local has_ua = false
    for k in pairs(headers) do
        if k:lower() == "user-agent" then has_ua = true break end
    end
    if not has_ua then
        headers["User-Agent"] = NetClient.DEFAULT_UA
    end
    local proxy = opts.proxy
    -- false/"" = 强制直连哨兵（transport 层契约不变）；
    -- 内置路径如何安全落地该哨兵见 _builtinRequest 内 H1 处理
    if proxy == false then proxy = "" end

    local ok, result = pcall(function()
        if self.transport then
            return self.transport({
                url = opts.url, method = method, headers = headers,
                body = opts.body, proxy = proxy,
                timeout_block = opts.timeout_block or self.default_timeout_block,
                timeout_total = opts.timeout_total or self.default_timeout_total,
            })
        end
        return self:_builtinRequest(opts, method, headers, proxy)
    end)
    if not ok then
        resp.error = "netclient: " .. tostring(result)
        return resp
    end
    if type(result) ~= "table" then
        resp.error = "netclient: bad transport result"
        return resp
    end
    resp.status = result.status
    resp.headers = result.headers or {}
    resp.body = result.body
    resp.error = result.error
    return resp
end

-- 响应头归一：小写键、重复值以 "," 连接（Venera 契约，两路共用）
local function normalizeHeaders(src)
    local h = {}
    for k, v in pairs(src or {}) do
        local key = tostring(k):lower()
        if h[key] and h[key] ~= tostring(v) then
            h[key] = h[key] .. "," .. tostring(v)
        else
            h[key] = tostring(v)
        end
    end
    return h
end

--- 代理串 → {scheme, host, port, userinfo, url}；空/nil → nil。
--- 漏写 scheme 时补 http://：luasocket 的 adjustproxy 会对无 scheme 的
--- url.parse 结果取 SCHEMES[nil].create 而索引崩溃。
function NetClient.proxyParts(proxy)
    if type(proxy) ~= "string" or proxy == "" then return nil end
    local p = NetClient.parseURL(proxy)
    if p then
        p.url = proxy
        return p
    end
    p = NetClient.parseURL("http://" .. proxy)
    if p then p.url = "http://" .. proxy end
    return p
end

--- 收发（r10 M1）：io 为空 = 原阻塞调用，形状与 luasocket/LuaSec 一致；
--- io 非空 = 先按非阻塞试一次，`timeout`/`wantread`/`wantwrite` 交给
--- AsyncNet.retry 等一拍再来。obj 用 sock 本身：真机 LuaSec 的 conn 是
--- userdata 但带 getfd，而 socket.select 只吃带 getfd 的对象（数字 fd 直接
--- 抛错，M0 实测），两者同形可用。
--- 入参形状必须与 luasocket 的 conn 完全一致：`receive()`、`receive(n)`、
--- `receive("*l", prefix)` 三种真机都会用到（http.lua 的 receivestatusline 就是
--- 先 `receive(5)` 再 `receive("*l", "HTTP/")`），少转发一个入参状态行就残缺，
--- luasocket 判「坏状态行」直接抛错。LuaJIT 是 5.1 语义，嵌套闭包里拿不到
--- `...`，所以逐个显式传。
local function recv1(sock, pat, prefix)
    if pat == nil then return sock:receive() end
    if prefix == nil then return sock:receive(pat) end
    return sock:receive(pat, prefix)
end

local function xsend(io, sock, data)
    if not io then return sock:send(data) end
    return AsyncNet.retry(io, sock, "write", function() return sock:send(data) end)
end

local function xrecv(io, sock, pat, prefix)
    if not io then return recv1(sock, pat, prefix) end
    return AsyncNet.retry(io, sock, "read",
        function() return recv1(sock, pat, prefix) end)
end

--- TLS 包装（cfg 与 LuaSec ssl/https.lua:29-33 一致，verify=none 同上游）。
--- 失败时不关闭 sock（由调用方统一 close）。
--- io 非空 = 非阻塞形态（r10 M1）：settimeout(0) 后 dohandshake 会回
--- wantread/wantwrite，`want("both")` 给出该等哪一侧（M0 真机实测握手可续，
--- 续上之后同一条连接完成整笔事务）。
function NetClient.wrapTLS(libs, sock, host, timeout, io)
    if not (libs.ssl and libs.ssl.wrap) then
        return nil, "LuaSec(ssl) 不可用"
    end
    local ok, tls = pcall(libs.ssl.wrap, sock, {
        mode = "client",
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "none",
    })
    if not ok or not tls then
        return nil, "ssl.wrap 失败: " .. tostring(tls)
    end
    pcall(function() tls:sni(host) end)
    if io then
        pcall(function() tls:settimeout(0) end)
        local hok, one, herr = AsyncNet.retry(io, tls, "both",
            function() return tls:dohandshake() end)
        if not hok then
            pcall(function() tls:close() end)
            return nil, "TLS 握手失败: " .. tostring(herr or one)
        end
        return tls
    end
    if timeout then pcall(function() tls:settimeout(timeout) end) end
    local hok, one, herr = pcall(function() return tls:dohandshake() end)
    if not hok or not one then
        pcall(function() tls:close() end)
        return nil, "TLS 握手失败: " .. tostring(hok and herr or one)
    end
    return tls
end

--- 在已连通的 sock 上完成 CONNECT 握手（明文写；代理自身是 TLS 时由
--- _tlsConn 先包一层再进来）。io 非空 = 逐次收发都走非阻塞等待。
local function sendConnect(sock, host, port, auth, io)
    -- IPv6 字面量必须带方括号，否则 CONNECT 行的 host:port 有歧义
    if host:find(":") then host = "[" .. host .. "]" end
    local reqline = "CONNECT " .. host .. ":" .. tostring(port) .. " HTTP/1.0\r\n"
    if auth then
        reqline = reqline .. "Proxy-Authorization: Basic " .. auth .. "\r\n"
    end
    local sent, serr = xsend(io, sock, reqline .. "\r\n")
    if not sent then return nil, "CONNECT 发送失败: " .. tostring(serr) end
    local line, rerr = xrecv(io, sock, "*l")
    if not line then return nil, "代理未响应 CONNECT: " .. tostring(rerr) end
    -- 排空响应头（可能带质询/说明行），读到空行为止
    while true do
        local h, herr = xrecv(io, sock, "*l")
        if not h then return nil, "读取代理响应头失败: " .. tostring(herr) end
        if h == "" then break end
    end
    local code = tonumber(line:match("^HTTP/[%d%.]+%s+(%d%d%d)"))
    if not code or code < 200 or code >= 300 then
        return nil, "代理拒绝 CONNECT: " .. line
    end
    return 1
end

--- 隧道池键：代理 + 源站 host:port 任一变化都必须另开一条（CONNECT 行
--- 写死了目标，换目标复用会把请求打到上一台主机）。
function NetClient.tunnelKey(proxy, tgt)
    return (proxy and proxy.url or "-") .. "|" .. tgt.host .. ":"
        .. tostring(tgt.port)
end

local function nowSec()
    local ok, s = pcall(require, "socket")
    local gt = ok and type(s) == "table" and s.gettime or nil
    if gt then
        local tok, t = pcall(gt)
        if tok and type(t) == "number" then return t end
    end
    return os.time()
end

--- 能否把这条隧道留给下一个请求：body 必须按长度或分块读完，否则
--- luasocket 走 "读到关闭" 模式，对端已经关了；响应自己声明 close 也不行。
local function canReuseTunnel(h)
    if type(h) ~= "table" then return false end
    if not (h["content-length"] or h["Content-Length"]
            or h["transfer-encoding"] or h["Transfer-Encoding"]) then
        return false
    end
    local c = h["connection"] or h["Connection"]
    if c and tostring(c):lower():find("close") then return false end
    return true
end

function NetClient:_hasTunnel(key)
    return key ~= nil and self._tunnels[key] ~= nil
end

--- 取出空闲隧道（并认领）。超过空闲 TTL 的直接关掉当没有。
function NetClient:_takeTunnel(key)
    local e = self._tunnels[key]
    if not e then return nil end
    self._tunnels[key] = nil
    if (nowSec() - e.at) >= (self.tunnel_idle_ttl or 15) then
        pcall(function() e.conn:_ezv_hard_close() end)
        return nil
    end
    e.conn._ezv_parked = false         -- 允许本次事务结束后再入池
    return e.conn
end

--- 事务结束时的归还：不真的关闭，只挂回池里；池满则逐出最旧的一条。
function NetClient:_parkTunnel(key, conn)
    local pool = self._tunnels
    pool[key] = { conn = conn, at = nowSec() }
    conn._ezv_parked = true
    local n, oldest, oldest_at = 0, nil, nil
    for k, e in pairs(pool) do
        n = n + 1
        if not oldest or e.at < oldest_at then oldest, oldest_at = k, e.at end
    end
    if n > (self.tunnel_max or 4) and oldest and oldest ~= key then
        self:_dropTunnel(oldest)
    end
end

function NetClient:_dropTunnel(key)
    local e = self._tunnels[key]
    if not e then return end
    self._tunnels[key] = nil
    pcall(function() e.conn:_ezv_hard_close() end)
end

--- socket.http 的 create()：返回带 TLS（可选 CONNECT 隧道）的 conn 对象。
--- 目标 host/port 由闭包捕获；connect() 的入参是 luasocket 给的地址
--- （有代理时 = 代理地址，直连时 = 目标地址）。
--- conn 在 connect 前只需 settimeout/close（luasocket 的 _M.open 就用到），
--- connect 成功后按 LuaSec reg() 的做法把 TLS 对象方法逐个挂上。
--- pool_key 非空时启用隧道复用：connect 成功后 close 变成"归还入池"，
--- connect 变成 no-op，下一次同 key 请求直接拿这个 conn 用。
--- aio 非空 = 本连接挂在 AsyncNet 作业上（r10 M1）：所有系统调用都改成
--- 「非阻塞试一次 + 没数据就 yield」。注意 _aio 存在 conn 表上而不是闭包里
--- ——同一条池化隧道可能被异步作业建立、被同步请求复用（反之亦然），绑死
--- 会拿着已作废的协程句柄去 yield。
function NetClient._tlsConn(libs, tgt, proxy, timeout, nc, pool_key, idle_cap, aio)
    return function()
        if not libs.socket then return nil, "socket 不可用" end
        if pool_key and nc then
            local reused = nc:_takeTunnel(pool_key)
            if reused then
                reused._aio = aio
                if aio then aio._conn = reused end
                return reused
            end
        end
        local conn = { sock = libs.socket.tcp(), _aio = aio }
        if aio then aio._conn = conn end   -- 取消时要能硬关这条 fd（协程已不在手上）
        -- settimeout/close 在 connect 前就会被 luasocket 的 _M.open 调用；
        -- 按当前 sock 的 metatable 动态取（CONNECT 后 sock 可能已是代理 TLS
        -- 对象，用裸 socket 的 C 方法会炸）
        local function call(self, name, ...)
            local api = getmetatable(self.sock).__index
            local f = api[name]
            if not f then return nil, "conn." .. name .. " 不可用" end
            return f(self.sock, ...)
        end
        conn.settimeout = function(self, ...)
            if self._aio then return call(self, "settimeout", 0) end
            return call(self, "settimeout", ...)
        end
        conn.close = function(self) return call(self, "close") end
        conn.connect = function(self, c_host, c_port)
            local io = self._aio
            local ok, err
            if io then
                -- 必须自己钉 0：luasocket 只在 _M.open 里调一次 settimeout，
                -- 而 M0 实测「不钉 0 的 connect」就是原地等满超时
                pcall(function() self.sock:settimeout(0) end)
                ok, err = AsyncNet.retry(io, self.sock, "write", function()
                    return self.sock:connect(c_host, c_port)
                end)
            else
                ok, err = self.sock:connect(c_host, c_port)
            end
            if not ok then
                self:close()
                return nil, "连接 " .. tostring(c_host) .. ":" .. tostring(c_port)
                    .. " 失败: " .. tostring(err)
            end
            if proxy then
                if proxy.scheme == "https" then
                    local pts, perr = NetClient.wrapTLS(libs, self.sock,
                        proxy.host, timeout, io)
                    if not pts then
                        self:close()
                        return nil, perr
                    end
                    self.sock = pts
                end
                local cok, cerr = sendConnect(self.sock, tgt.host, tgt.port,
                    proxy.auth, io)
                if not cok then
                    self:close()
                    return nil, cerr
                end
            end
            local tls, terr = NetClient.wrapTLS(libs, self.sock, tgt.host,
                timeout, io)
            if not tls then
                self:close()
                return nil, terr
            end
            self.sock = tls
            local mt = getmetatable(tls).__index
            for name, method in pairs(mt) do
                if type(method) == "function" then
                    conn[name] = function(self2, ...)
                        return method(self2.sock, ...)
                    end
                end
            end
            -- 拷贝完再包一层收发：luasocket 的 http 客户端在此之后只会通过
            -- conn:send / conn:receive 碰网络，所以这两个口子就是全部阻塞点
            local method_send, method_recv = conn.send, conn.receive
            -- send 只有一个入参（http.lua 全部是 `c:send(str)`）；receive 必须
            -- 原样保住 (pattern, prefix) 两个形状，见 recv1 的注释。
            conn.send = function(self2, data)
                if not self2._aio then return method_send(self2, data) end
                return AsyncNet.retry(self2._aio, self2.sock, "write",
                    function() return method_send(self2, data) end)
            end
            conn.receive = function(self2, pat, prefix)
                local function go()
                    if pat == nil then return method_recv(self2) end
                    if prefix == nil then return method_recv(self2, pat) end
                    return method_recv(self2, pat, prefix)
                end
                if not self2._aio then return go() end
                return AsyncNet.retry(self2._aio, self2.sock, "read", go)
            end
            if pool_key and nc then
                -- 上面的方法拷贝会覆盖 conn.close / conn.settimeout，所以
                -- 池化包装必须放在它之后。connect 置 no-op：重复 CONNECT 会
                -- 把这条已经建好的隧道打死。
                conn._ezv_hard_close = function() return call(conn, "close") end
                conn.connect = function() return 1 end
                local raw_settimeout = conn.settimeout
                conn.settimeout = function(self2, t)
                    -- 异步作业一律非阻塞；复用请求的阻塞超时收紧：隧道可能被
                    -- 代理悄悄回收，而 luasocket 的 _M.open 会按 http.TIMEOUT
                    -- （60s）设值，干等会把 UI 冻住。新建隧道不受影响。
                    if self2._aio then t = 0
                    elseif idle_cap and type(t) == "number" and t > idle_cap then
                        t = idle_cap
                    end
                    return raw_settimeout(self2, t)
                end
                conn.close = function(self2)
                    if self2._ezv_parked then return 1 end
                    -- 入池即与本作业的协程解绑：下一条请求（同步或异步）
                    -- 自己认领 _aio，否则池里的连接会对着死协程 yield
                    self2._aio = nil
                    nc:_parkTunnel(pool_key, self2)
                    return 1
                end
            end
            return 1
        end
        return conn
    end
end

--- 能否跟随跳转 → 新 URL；nil = 不跟随（原样把 3xx 交回调用方）。
--- 规则对齐 luasocket 的 shouldredirect：仅 GET/HEAD、禁 https→http 降级。
function NetClient:_redirectTarget(libs, status, method, location, base_url,
                                   has_body)
    if not location or location == "" then return nil end
    if status == 303 then
        method = "GET"
    elseif status ~= 301 and status ~= 302 and status ~= 307 then
        return nil
    elseif method ~= "GET" and method ~= "HEAD" then return nil end
    -- 已经发过请求体的跳转不重复发（同 luasocket：source 不可复用）
    if has_body and status ~= 303 then return nil end
    local target = location
    if libs.url and libs.url.absolute then
        target = libs.url.absolute(base_url, location) or location
    elseif not target:match("^%a[%w+.-]*://") then
        return nil      -- 相对地址且无 socket.url 可用
    end
    local parsed = self.parseURL(target)
    if not parsed or parsed.scheme ~= "https" then return nil end
    return target
end

--- HTTPS 主路径（自建，不经 ssl.https.request：它会硬拒 proxy/redirect/
--- create 三种入参，见文件头）。proxy 语义与 _builtinRequest 一致。
function NetClient:_httpsRequest(opts, method, headers, proxy, source)
    local libs = self:_libs()
    if not libs.socket or not libs.ssl then
        return { error = "HTTPS 需要 socket 与 LuaSec(ssl)，当前不可用" }
    end
    if not libs.http then return { error = "socket.http unavailable" } end
    if not libs.ltn12 then return { error = "ltn12 unavailable" } end

    -- proxy == nil：调用方未决策 → 沿用 luasocket 的全局 PROXY 语义
    -- （proxy == "" 的强制直连已由 _builtinRequest 清空全局）
    local proxy_str = proxy
    if proxy_str == nil then proxy_str = libs.http.PROXY end
    local pp = NetClient.proxyParts(proxy_str)
    if proxy_str ~= nil and proxy_str ~= "" and not pp then
        return { error = "代理地址无效: " .. tostring(proxy_str) }
    end
    if pp and pp.userinfo and libs.mime then
        local ok, b64 = pcall(libs.mime.b64, pp.userinfo)
        if ok and type(b64) == "string" then
            pp.auth = b64:gsub("[%c%s]+", "")
        end
    end

    local timeout = libs.http.TIMEOUT or opts.timeout_block
        or self.default_timeout_block
    local idle_cap = opts.timeout_block or self.default_timeout_block
    if self.keepalive then
        -- 复用隧道要求源站事务后不关闭连接；luasocket 的默认请求头是
        -- "close, TE"（http.lua adjustheaders），必须显式覆盖。
        local has_conn = false
        for k in pairs(headers) do
            if k:lower() == "connection" then has_conn = true break end
        end
        if not has_conn then headers["Connection"] = "keep-alive" end
    end
    local url, redirects = opts.url, 0
    local cur_method, cur_source = method, source
    while true do
        local tgt = self.parseURL(url)
        if not tgt then return { error = "invalid url: " .. url } end
        local pool_key = self.keepalive and NetClient.tunnelKey(pp, tgt) or nil
        local parts = {}
        local ok, ret1, code, resheaders
        local attempt = 0
        while true do
            attempt = attempt + 1
            -- 只在第一次尝试走池；失败重试必须新建，否则会在同一条坏隧道上
            -- 反复撞墙。
            local key = (attempt == 1) and pool_key or nil
            local used_pool = self:_hasTunnel(key)
            local reqt = {
                url = url,
                method = cur_method,
                headers = headers,
                sink = self:_responseSink(libs, parts),
                -- 隧道末端是源站：请求行必须 origin-form（luasocket 有代理时
                -- 默认写绝对形式，源站会拒）
                uri = tgt.path,
                -- 自动跳转不可用（tredirect 复用绑定旧目标的 create）
                redirect = false,
                create = NetClient._tlsConn(libs, tgt, pp, timeout, self, key,
                    idle_cap, opts.aio),
            }
            if pp then reqt.proxy = pp.url end
            if cur_source then reqt.source = cur_source end

            -- 返回值语义：成功 = 1, code, headers, statusline；失败 = nil, err
            ok, ret1, code, resheaders = pcall(libs.http.request, reqt)
            if (ok and ret1 == 1) or not used_pool or attempt > 1 then break end
            self:_dropTunnel(key)
            parts = {}
        end
        if pool_key and (not ok or ret1 ~= 1
                or not canReuseTunnel(resheaders)) then
            -- 本条隧道到此为止：要么事务失败（对端状态未知，绝不能留），
            -- 要么响应无法保证 body 已按长度读完。
            self:_dropTunnel(pool_key)
        end
        if not ok then
            return { error = "request error: " .. tostring(ret1) }
        end
        if ret1 ~= 1 then
            return { error = "https" .. (pp and "(经代理) " or " ")
                .. "请求失败: " .. tostring(code or resheaders or "failed") }
        end
        local status = tonumber(code)
        local resp = { status = status, headers = normalizeHeaders(resheaders),
                       body = table.concat(parts) }
        local location = resheaders and (resheaders.location
            or resheaders.Location)
        if not status or redirects >= self.max_redirects then return resp end
        local next_url = self:_redirectTarget(libs, status, cur_method,
            location, url, cur_source ~= nil)
        if not next_url then return resp end
        url = next_url
        redirects = redirects + 1
        if status == 303 then
            cur_method, cur_source = "GET", nil
        end
    end
end

function NetClient:_builtinRequest(opts, method, headers, proxy)
    local libs = self:_libs()
    local parts = {}
    local parsed = self.parseURL(opts.url)
    if not parsed then
        return { error = "invalid url: " .. opts.url }
    end
    if not libs.ltn12 then
        return { error = "ltn12 unavailable" }
    end
    if not libs.http then
        return { error = "socket.http unavailable" }
    end

    -- 超时（socketutil 提供 block/total 双层框架，并同步 http.TIMEOUT /
    -- https.TIMEOUT；不可用时退回 TIMEOUT）
    if libs.socketutil then
        pcall(function()
            libs.socketutil:set_timeout(
                opts.timeout_block or self.default_timeout_block,
                opts.timeout_total or self.default_timeout_total)
        end)
    else
        pcall(function()
            libs.http.TIMEOUT = opts.timeout_block or self.default_timeout_block
        end)
    end

    if opts.body and #opts.body > 0
        and not headers["Content-Length"] and not headers["content-length"]
        and not headers["Transfer-Encoding"] then
        headers["Content-Length"] = tostring(#opts.body)
    end
    local source
    if opts.body and #opts.body > 0 then
        source = libs.ltn12.source.string(opts.body)
    end

    -- 审查 H1（独立报告，已对照 luasocket v3.0.0 与 master 原文核实）：
    -- http.lua 的 adjustheaders/adjustproxy 均为
    --   `local proxy = reqt.proxy or _M.PROXY; if proxy then proxy = url.parse(proxy) ...`
    -- Lua 空串为真值 → 必进代理分支；而 socket.url 对空串明确
    -- "empty url is parsed to nil"（url.lua 原文注释）→ attempt to index a
    -- nil value。因此空串绝不能写入 reqt.proxy，只能临时清空全局。
    local saved_proxy
    if proxy == "" and libs.http.PROXY ~= nil then
        -- 强制直连哨兵：临时清空 socket.http.PROXY（覆盖 KOReader 全局
        -- NetworkMgr:setHTTPProxy 写入的值），请求结束立即恢复。
        -- KOReader 单线程事件循环，无并发窗口；两条分支（http/https）统一
        -- 在此处理，HTTPS 自建路径同样受 _M.PROXY 影响（adjustproxy）。
        saved_proxy = libs.http.PROXY
        libs.http.PROXY = nil
    end

    -- pcall 保护：即使分支内抛错也必须恢复全局 PROXY 与超时（KOReader
    -- 全局状态被插件临时改动后泄漏是本层红线）
    local ok, resp = pcall(function()
        if parsed.scheme == "https" then
            return self:_httpsRequest(opts, method, headers, proxy, source)
        end
        return self:_plainRequest(opts, method, headers, proxy, parts, source)
    end)

    if saved_proxy ~= nil then libs.http.PROXY = saved_proxy end
    if libs.socketutil then
        pcall(function() libs.socketutil:reset_timeout() end)
    end
    if not ok then
        return { error = "request error: " .. tostring(resp) }
    end
    return resp
end


--- M1（审查报告 §3，2026-09-25）：响应接收 sink。socketutil.table_sink
--- 在裸 sink 上叠加**总时限**强制（KOReader socketutil.lua:98 的设计目的
--- 正是补 set_timeout 只管单次 poll 的缺口）——慢滴服务器 drip 字节时
--- total 超时能真正掐断，而不是让单线程主循环挂死。socketutil 缺失
--- （单测桩）退回裸 sink + 既有 block 超时。
function NetClient:_responseSink(libs, parts)
    local su = libs.socketutil
    if su and type(su.table_sink) == "function" then
        local ok, sink = pcall(su.table_sink, parts)
        if ok and sink then return sink end
    end
    return libs.ltn12.sink.table(parts)
end

--- 明文 HTTP（含经普通代理）：直接用 luasocket 的 proxy 参数。
function NetClient:_plainRequest(opts, method, headers, proxy, parts, source)
    local libs = self:_libs()
    local reqt = {
        url = opts.url,
        method = method,
        headers = headers,
        sink = self:_responseSink(libs, parts),  -- M1：带总时限强制
        redirect = self.max_redirects,
    }
    if source then reqt.source = source end
    if proxy ~= nil and proxy ~= "" then reqt.proxy = proxy end
    -- proxy == nil：调用方未做按请求决策 → 不写 reqt.proxy、不动全局，
    -- 保持 luasocket 原生语义（_M.PROXY 自然生效）

    -- 返回值语义（同 KOReader opdsclient 用法）：成功 = 1, code, headers,
    -- statusline；失败 = nil, err。
    local ok, ret1, code, resheaders = pcall(libs.http.request, reqt)
    if not ok then
        return { error = "request error: " .. tostring(ret1) }
    end
    if ret1 ~= 1 then
        return { error = tostring(code or resheaders or "request failed") }
    end
    return { status = tonumber(code), headers = normalizeHeaders(resheaders),
             body = table.concat(parts) }
end

--- ---------- r10 M1：非阻塞请求入口 ----------

--- 惰性建 AsyncNet 单例（每个 NetClient 一份，全局节拍一份即可）。
--- 上限 2 条在飞：低配设备上并发带来的内存/代理压力没有实测数据。
function NetClient:_asyncnet()
    if self._anet then return self._anet end
    if not AsyncNet then return nil, "runtime/asyncnet 不可用" end
    local libs = self:_libs()
    if not (libs.socket and type(libs.socket.select) == "function") then
        return nil, "socket.select 不可用（非阻塞传输需要它）"
    end
    local socket = libs.socket
    self._anet = AsyncNet.new{
        max_inflight = self.async_max_inflight or 2,
        -- 单次系统调用的等待上限沿用 block 超时：语义与同步路径一致，
        -- 差别只在于等待期间 UI 拿得到事件
        wait_sec = self.default_timeout_block,
        now = function() return socket.gettime() end,
        select = function(rs, ws, t) return socket.select(rs, ws, t) end,
    }
    return self._anet
end

--- 一拍：推进所有在飞请求。由上层泵（JsHost:pump / UIManager 节拍）调用。
function NetClient:tickAsync(budget_sec)
    if not self._anet then return nil end
    return self._anet:tick(budget_sec or self.async_slice_sec)
end

--- 在飞 + 排队的非阻塞任务数。0 表示泵可以回到慢周期（M2 的判据）。
function NetClient:asyncPending()
    if not self._anet then return 0 end
    return self._anet:pending()
end
--- 非阻塞 HTTPS 请求。与 request() 同一条代码路径，只是跑在协程里。
--- on_done(ok, resp)：resp 恒为表，形状与 request() 一致（{status,headers,
--- body} 或 {error}）。返回 job（job:cancel() 即取消），失败返回 nil, err。
--- 已知边界：scheme=http 与自定义 transport 不经 create，仍然是阻塞的。
function NetClient:requestAsync(opts, on_done)
    local anet, aerr = self:_asyncnet()
    if not anet then return nil, aerr end
    local o2 = {}
    for k, v in pairs(opts or {}) do o2[k] = v end
    local job
    job = anet:submit(function(io)
        o2.aio = io
        local r = self:request(o2)
        if type(r) ~= "table" then return nil, "netclient: 空响应" end
        if r.error then return false, r end
        return r
    end, function(ok, resp)
        if on_done then on_done(ok, resp) end
    end)
    job.cleanup = function()
        local c = job.io._conn
        if not c then return end
        c._aio = nil                      -- 协程不再持有这条连接
        if c._ezv_hard_close then
            pcall(function() c:_ezv_hard_close() end)
        else
            pcall(function() c:close() end)
        end
    end
    return job
end

return NetClient
