-- unit test: netclient.lua — parseURL + 代理注入逻辑（AC2.3）
local NetClient = require("netclient")
-- 假 luasocket/LuaSec 栈及其辅助函数已抽到 tests/tlsfake.lua：r10 M2 之后端到端测试要用**同一份**栈
-- 把真 NetClient 串到真 Bridge / 真 JsHost:pump()，两处各写一份必然漂移。

local TlsFake = require("tests.tlsfake")
local makeFakeHttp = TlsFake.makeFakeHttp
local fake_ltn12 = TlsFake.ltn12
local withFakeModules = TlsFake.withFakeModules
local logFind = TlsFake.logFind
local countLog = TlsFake.countLog
local withTlsStack = TlsFake.withTlsStack
local drain = TlsFake.drain


local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local tests = {}

-- ---- parseURL ----

function tests.parse_http()
    local p = NetClient.parseURL("http://example.com/path?q=1")
    assert_eq("scheme", "http", p.scheme)
    assert_eq("host", "example.com", p.host)
    assert_eq("port", 80, p.port)
    assert_eq("path", "/path?q=1", p.path)
    return true
end

function tests.parse_https_default_port()
    local p = NetClient.parseURL("https://secure.example.com/img.png")
    assert_eq("scheme", "https", p.scheme)
    assert_eq("port", 443, p.port)
    return true
end

function tests.parse_explicit_port()
    -- 203.0.113.x = RFC 5737 文档地址（审查 L5：不用真实内网 IP 做测试数据）
    local p = NetClient.parseURL("http://203.0.113.10:16492/x")
    assert_eq("port", 16492, p.port)
    return true
end

function tests.parse_invalid()
    assert_eq("nil", nil, NetClient.parseURL("not a url"))
    return true
end

-- ---- encodeRequestURL（【R7 真机】中文关键词必须百分号化）----

function tests.encode_non_ascii_keyword()
    -- "海" UTF-8 = E6 B5 B7；baozi.js:299 直接拼 search?q=${keyword}
    assert_eq("utf8 pct",
        "https://baozimh.com/api/v3/search?page=1&keywords=%E6%B5%B7",
        NetClient.encodeRequestURL(
            "https://baozimh.com/api/v3/search?page=1&keywords=海"))
    return true
end

function tests.encode_space_and_reserved()
    assert_eq("space", "http://x.com/a%20b%20c",
        NetClient.encodeRequestURL("http://x.com/a b c"))
    -- 分隔符 / ? & = # 不得被编码，否则请求打偏
    assert_eq("separators kept", "http://x.com/p/q?a=1&b=2#f",
        NetClient.encodeRequestURL("http://x.com/p/q?a=1&b=2#f"))
    return true
end

function tests.encode_is_idempotent()
    -- 源自己编码过的串必须原样通过（'%' 不在禁用名单里）
    local once = NetClient.encodeRequestURL("http://x.com/s?q=%E6%B5%B7")
    assert_eq("already encoded kept", "http://x.com/s?q=%E6%B5%B7", once)
    assert_eq("twice same", once, NetClient.encodeRequestURL(once))
    return true
end

function tests.encode_leaves_authority_alone()
    -- host 段原样：IPv6 字面量的方括号不能被编码成 %5B
    assert_eq("ipv6 host kept", "http://[::1]:8080/a%20b",
        NetClient.encodeRequestURL("http://[::1]:8080/a b"))
    -- 无 path 的 URL 不动
    assert_eq("no target untouched", "http://example.com",
        NetClient.encodeRequestURL("http://example.com"))
    assert_eq("non string passthrough", nil,
        NetClient.encodeRequestURL(nil))
    assert_eq("bad url untouched", "not a url",
        NetClient.encodeRequestURL("not a url"))
    return true
end

function tests.request_sends_encoded_url_and_keeps_caller_opts()
    local captured
    local nc = NetClient.new({
        transport = function(req) captured = req
            return { status = 200, headers = {}, body = "ok" } end,
    })
    local opts = { url = "http://x.com/search?q=海贼", proxy = false }
    nc:request(opts)
    assert_eq("transport got encoded", "http://x.com/search?q=%E6%B5%B7%E8%B4%BC",
        captured.url)
    assert_eq("caller opts not mutated", "http://x.com/search?q=海贼", opts.url)
    assert_eq("other opts preserved", "", captured.proxy)
    return true
end

-- ---- 代理选择（通过 transport 桩断言 reqt.proxy）----

function tests.request_with_proxy()
    local captured
    local nc = NetClient.new({
        transport = function(req)
            captured = req
            return { status = 200, headers = {}, body = "ok", error = nil }
        end,
    })
    local r = nc:request({
        url = "http://example.com",
        proxy = "http://203.0.113.10:16492",
    })
    assert_eq("proxy passed", "http://203.0.113.10:16492", captured.proxy)
    assert_eq("status", 200, r.status)
    return true
end

function tests.request_injects_default_ua()
    -- 审查 L7：无 UA 头时注入默认 UA（"LuaSocket 3.0" 会被部分源拒绝）
    local captured
    local nc = NetClient.new({
        transport = function(req) captured = req
            return { status = 200, headers = {}, body = "ok" } end,
    })
    nc:request({ url = "http://example.com" })
    assert_eq("default ua injected", NetClient.DEFAULT_UA,
        captured.headers["User-Agent"])
    nc:request({ url = "http://example.com",
                 headers = { ["user-agent"] = "custom" } })
    assert_eq("custom ua preserved", "custom", captured.headers["user-agent"])
    nc:request({ url = "http://example.com",
                 headers = { ["User-Agent"] = "Other" } })
    assert_eq("custom UA preserved (canonical)", "Other",
        captured.headers["User-Agent"])
    return true
end

function tests.request_direct_forces_empty_proxy()
    local captured
    local nc = NetClient.new({
        transport = function(req)
            captured = req
            return { status = 200, headers = {}, body = "ok" }
        end,
    })
    nc:request({ url = "http://example.com", proxy = false })
    -- false → "" (强制直连，覆盖全局 PROXY)
    assert_eq("empty proxy", "", captured.proxy)
    return true
end

function tests.request_never_throws_on_error()
    local nc = NetClient.new({
        transport = function(req)
            return { error = "connection refused" }
        end,
    })
    local r = nc:request({ url = "http://example.com" })
    assert_eq("error surfaced", "connection refused", r.error)
    assert_eq("status nil", nil, r.status)
    return true
end

function tests.request_missing_url()
    local nc = NetClient.new({ transport = function() return {} end })
    local r = nc:request({})
    assert_eq("error", true, r.error ~= nil)
    return true
end

function tests.header_normalization_lowercase()
    local nc = NetClient.new({
        transport = function(req)
            return { status = 200,
                     headers = { ["Content-Type"] = "text/plain",
                                 ["Set-Cookie"] = "a=1" }, body = "x" }
        end,
    })
    -- transport 路径 header 归一在 _builtinRequest，transport 桩直传
    -- 这里只验证不抛错
    local r = nc:request({ url = "http://x.com" })
    assert_eq("ok", 200, r.status)
    return true
end

-- ---- 内置 luasocket 路径（package.preload 注入桩；审查 H1 回归）----
-- H1 盲区修复：transport 桩测不到 _builtinRequest 的真实 luasocket
-- 调用形状。此处以 preload 桩覆盖：reqt.proxy 契约 + 全局 _M.PROXY
-- 的覆盖/恢复（"禁用直连 / 启用经代理 / 全局叠加"三态）。


function tests.builtin_disabled_proxy_never_passes_empty_string()
    -- 审查 H1：禁用代理（"" 哨兵）绝不能把空串写进 reqt.proxy
    --（luasocket 空串 truthy → url.parse("") = nil → 索引崩溃），
    -- 且必须临时清空全局 PROXY 实现强制直连、请求后恢复。
    local fake = makeFakeHttp{ global_proxy = "http://203.0.113.10:3128" }
    withFakeModules({ ["socket.http"] = fake, ltn12 = fake_ltn12 }, function()
        local nc = NetClient.new()          -- 无 transport → 内置路径
        local r = nc:request{ url = "http://example.com/x", proxy = false }
        assert_eq("no error", nil, r.error)
        assert_eq("status", 200, r.status)
        assert_eq("reqt.proxy absent", nil, fake._calls[1].reqt.proxy)
        assert_eq("global cleared during", nil, fake._calls[1].global_during)
    end)
    assert_eq("global restored", "http://203.0.113.10:3128", fake.PROXY)
    return true
end

function tests.builtin_enabled_proxy_passed_global_untouched()
    local fake = makeFakeHttp{ global_proxy = "http://203.0.113.10:3128" }
    withFakeModules({ ["socket.http"] = fake, ltn12 = fake_ltn12 }, function()
        local nc = NetClient.new()
        local r = nc:request{ url = "http://example.com/x",
                              proxy = "http://203.0.113.10:8080" }
        assert_eq("no error", nil, r.error)
        assert_eq("reqt.proxy set", "http://203.0.113.10:8080",
            fake._calls[1].reqt.proxy)
        assert_eq("global untouched during",
            "http://203.0.113.10:3128", fake._calls[1].global_during)
    end)
    assert_eq("global untouched after",
        "http://203.0.113.10:3128", fake.PROXY)
    return true
end

function tests.builtin_no_proxy_opt_lets_global_stay()
    -- 不带 proxy 选项：全局代理语义保持 luasocket 原生行为
    --（reqt.proxy 不写、全局不动，由 _M.PROXY 自然生效）
    local fake = makeFakeHttp{ global_proxy = "http://203.0.113.10:3128" }
    withFakeModules({ ["socket.http"] = fake, ltn12 = fake_ltn12 }, function()
        local nc = NetClient.new()
        local r = nc:request{ url = "http://example.com/x" }
        assert_eq("no error", nil, r.error)
        assert_eq("global visible during",
            "http://203.0.113.10:3128", fake._calls[1].global_during)
    end)
    assert_eq("global unchanged", "http://203.0.113.10:3128", fake.PROXY)
    return true
end

function tests.builtin_global_restored_on_request_failure()
    local fake = makeFakeHttp{ global_proxy = "http://203.0.113.10:3128",
                               fail = true }
    withFakeModules({ ["socket.http"] = fake, ltn12 = fake_ltn12 }, function()
        local nc = NetClient.new()
        local r = nc:request{ url = "http://example.com/x", proxy = false }
        assert_eq("error surfaced", true, r.error ~= nil)
    end)
    assert_eq("global restored after failure",
        "http://203.0.113.10:3128", fake.PROXY)
    return true
end

function tests.builtin_https_disabled_direct_overrides_global()
    -- HTTPS 直连（自建路径）：proxy=false → 请求期间清空 socket.http.PROXY、
    -- 结束后恢复；且不做 CONNECT（那是经代理才有的动作）
    local fake = makeFakeHttp{ global_proxy = "http://203.0.113.10:3128" }
    local log = withTlsStack(fake)
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local r = nc:request{ url = "https://example.com/x", proxy = false }
        assert_eq("no error", nil, r.error)
        assert_eq("status", 200, r.status)
        assert_eq("https reqt.proxy absent", nil,
            fake._calls[1].reqt.proxy)
        assert_eq("global cleared during", nil,
            fake._calls[1].global_during)
        assert_eq("no CONNECT sent", nil, logFind(log, "CONNECT"))
        assert_eq("create used", true, fake._calls[1].reqt.create ~= nil)
    end)
    assert_eq("global restored", "http://203.0.113.10:3128", fake.PROXY)
    return true
end

function tests.proxy_parts_defaults_scheme()
    -- 用户漏写 scheme：补 http://（否则 luasocket adjustproxy 索引
    -- SCHEMES[nil] 崩溃）
    local p = NetClient.proxyParts("203.0.113.10:8118")
    assert_eq("host", "203.0.113.10", p.host)
    assert_eq("port", 8118, p.port)
    assert_eq("normalized url", "http://203.0.113.10:8118", p.url)
    assert_eq("empty → nil", nil, NetClient.proxyParts(""))
    assert_eq("nil → nil", nil, NetClient.proxyParts(nil))
    return true
end

function tests.https_via_proxy_builds_connect_tunnel()
    -- 真机 2026-09-23 报错 "proxy not supported" 的根因回归：随包 LuaSec
    -- 的 ssl.https.request 直接拒绝 proxy（https.lua:124），本层改走
    -- socket.http + 自建 CONNECT 隧道。这里桩化 luasocket/LuaSec，验证
    -- 隧道握手的完整形状。
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake)
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local r = nc:request{
            url = "https://comic.example.com/api/search?q=1",
            proxy = "http://203.0.113.10:8118",
        }
        assert_eq("no error", nil, r.error)
        assert_eq("status", 200, r.status)
        local reqt = fake._calls[1].reqt
        -- 1) 隧道经代理：connect 的入参是代理地址
        assert_eq("proxy passed to luasocket", "http://203.0.113.10:8118",
            reqt.proxy)
        assert_eq("tcp connect to proxy", "tcp.connect 203.0.113.10:8118",
            log[2])
        -- 2) CONNECT 指名真实目标（含默认端口 443）
        assert_eq("connect target", true,
            logFind(log, "CONNECT comic%.example%.com:443 HTTP/1%.0") ~= nil)
        -- 3) CONNECT 成功后才包 TLS，且是 client 模式
        local wi, ci = logFind(log, "CONNECT comic"),
                       logFind(log, "ssl%.wrap mode=client")
        assert_eq("tls wrapped", true, wi ~= nil and ci ~= nil)
        assert_eq("wrap after tunnel", true, ci > wi)
        assert_eq("sni target", true,
            logFind(log, "tls%.sni comic%.example%.com") ~= nil)
        -- 4) 请求行 origin-form + 关闭 luasocket 自动跳转
        assert_eq("origin-form uri", "/api/search?q=1", reqt.uri)
        assert_eq("auto redirect off", false, reqt.redirect)
    end)
    return true
end

function tests.https_proxy_refused_reports_error()
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake, {
        reply = { "HTTP/1.1 407 Proxy Authentication Required", "" },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local r = nc:request{ url = "https://example.com/x",
                              proxy = "http://203.0.113.10:8118" }
        assert_eq("refused", true,
            r.error ~= nil and r.error:find("代理拒绝 CONNECT") ~= nil)
        assert_eq("no status", nil, r.status)
        assert_eq("socket closed", true, logFind(log, "tcp.close") ~= nil)
        assert_eq("no tls over refused tunnel", nil,
            logFind(log, "ssl%.wrap"))
    end)
    return true
end

function tests.https_follows_redirect_but_not_downgrade()
    -- https→https 跟随；https→http 降级不跟随（3xx 原样交回调用方）
    local fake = makeFakeHttp{}
    withTlsStack(fake, {
        responses = {
            { code = 302, headers = { location = "/next?q=2" } },
            { code = 200, headers = {} },
            { code = 301, headers = { location = "http://example.com/plain" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new({ max_redirects = 3 })
        local r = nc:request{ url = "https://example.com/x",
                              proxy = "http://203.0.113.10:8118" }
        assert_eq("redirected ok", 200, r.status)
        assert_eq("two requests", 2, #fake._calls)
        assert_eq("relative resolved", "https://example.com/next?q=2",
            fake._calls[2].reqt.url)
        assert_eq("second hop origin-form", "/next?q=2",
            fake._calls[2].reqt.uri)
        -- 降级：301 指向 http 时不再请求，3xx 原样交回调用方
        local r2 = nc:request{ url = "https://example.com/y",
                               proxy = "http://203.0.113.10:8118" }
        assert_eq("downgrade surfaced", 301, r2.status)
        assert_eq("downgrade not followed", 3, #fake._calls)
    end)
    return true
end

function tests.builtin_lib_require_failure_reports_clearly()
    -- 审查 L1：require 失败时 _libs 必须得到 nil（而非错误字符串），
    -- 报错为明确的 "socket.http unavailable"，不再退化为
    -- "attempt to index a string"
    withFakeModules({ ltn12 = fake_ltn12 }, function()
        local nc = NetClient.new()
        local r = nc:request{ url = "http://example.com/x" }
        assert_eq("clear error", "socket.http unavailable", r.error)
    end)
    return true
end


local TPROXY = "http://203.0.113.10:8118"

function tests.https_tunnel_reused_for_next_request_to_same_host()
    -- 【性能】真机单图冷路径 1.16-2.08s，其中 TLS 握手 0.82-0.95s；一章
    -- 27 图逐张重握手就是 40s vs 8-10s 的差。第二次必须走同一条隧道。
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake, {
        responses = {
            { code = 200, headers = { ["content-length"] = "12" } },
            { code = 200, headers = { ["content-length"] = "13" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local r1 = nc:request{ url = "https://img.example.com/1.webp",
                               proxy = TPROXY }
        local r2 = nc:request{ url = "https://img.example.com/2.webp",
                               proxy = TPROXY }
        assert_eq("first ok", 200, r1.status)
        assert_eq("second ok", 200, r2.status)
        assert_eq("one TCP connect", 1, countLog(log, "tcp%.connect"))
        assert_eq("one CONNECT", 1, countLog(log, "CONNECT img%.example%.com"))
        assert_eq("one TLS handshake", 1, countLog(log, "tls%.dohandshake"))
        assert_eq("tls kept open", 0, countLog(log, "tls%.close"))
        -- 复用后第二个事务的请求行仍打给同一隧道末端
        assert_eq("second request line", true,
            logFind(log, "GET /2%.webp HTTP/1%.1") ~= nil)
        -- 隧道可能被代理悄悄回收：复用事务的阻塞超时收紧到本次请求的
        -- timeout_block（luasocket 会按 http.TIMEOUT 设更大的值），
        -- 否则对端静默失联时要干等满超时，UI 冻住。
        local r3 = nc:request{ url = "https://img.example.com/3.webp",
                               proxy = TPROXY, timeout_block = 3 }
        assert_eq("third ok on same tunnel", 200, r3.status)
        assert_eq("reuse keeps one handshake", 1,
            countLog(log, "tls%.dohandshake"))
        assert_eq("reused txn timeout clamped", true,
            logFind(log, "tls%.settimeout 3") ~= nil)
        assert_eq("fresh txn used the larger default", true,
            logFind(log, "tls%.settimeout 4") ~= nil)
    end)
    return true
end

function tests.https_keepalive_off_rebuilds_tunnel()
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake, {
        responses = {
            { code = 200, headers = { ["content-length"] = "12" } },
            { code = 200, headers = { ["content-length"] = "13" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new({ keepalive = false })
        nc:request{ url = "https://img.example.com/1.webp", proxy = TPROXY }
        nc:request{ url = "https://img.example.com/2.webp", proxy = TPROXY }
        assert_eq("two handshakes", 2, countLog(log, "tls%.dohandshake"))
    end)
    return true
end

function tests.https_tunnel_dropped_when_body_length_unknown()
    -- 响应没有 content-length/transfer-encoding → luasocket 只能"读到关闭"，
    -- 对端已关：这条隧道不能留给下一个请求（否则下一发必失败一次）。
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake)          -- 默认响应 headers = {}
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        nc:request{ url = "https://img.example.com/1.webp", proxy = TPROXY }
        nc:request{ url = "https://img.example.com/2.webp", proxy = TPROXY }
        assert_eq("handshake again", 2, countLog(log, "tls%.dohandshake"))
        assert_eq("previous tls closed", true,
            countLog(log, "tls%.close") >= 1)
    end)
    return true
end

function tests.https_dead_reused_tunnel_retries_once_fresh()
    -- 复用撞墙（代理空闲回收）：必须丢掉这条隧道新建一次，而不是把错误
    -- 直接抛给调用方；且只重试一次。
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake, {
        responses = {
            { code = 200, headers = { ["content-length"] = "12" } },
            { code = 200, headers = { ["content-length"] = "13" } },
        },
    })
    local orig = fake.open_with
    local txn = 0
    fake.open_with = function(reqt)
        txn = txn + 1
        if txn == 2 then
            local conn = reqt.create()      -- 从池中认领
            if conn then conn:close() end   -- luasocket 失败路径也会 close
            return nil, "closed"
        end
        return orig(reqt)
    end
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        assert_eq("first", 200,
            nc:request{ url = "https://img.example.com/1.webp",
                        proxy = TPROXY }.status)
        local r = nc:request{ url = "https://img.example.com/2.webp",
                              proxy = TPROXY }
        assert_eq("recovered", 200, r.status)
        assert_eq("three txns (ok, dead reuse, fresh retry)", 3,
            #fake._calls)
        assert_eq("one retry only", 2, countLog(log, "tls%.dohandshake"))
        assert_eq("dead tunnel closed", true,
            countLog(log, "tls%.close") >= 1)
    end)
    return true
end

function tests.https_tunnel_not_shared_across_hosts()
    -- CONNECT 行写死目标：跨主机复用会把第二家的请求打到第一家
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake, {
        responses = {
            { code = 200, headers = { ["content-length"] = "12" } },
            { code = 200, headers = { ["content-length"] = "13" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        nc:request{ url = "https://a.example.com/1.webp", proxy = TPROXY }
        nc:request{ url = "https://b.example.com/2.webp", proxy = TPROXY }
        assert_eq("two tunnels", 2, countLog(log, "tls%.dohandshake"))
        assert_eq("CONNECT a", true,
            logFind(log, "CONNECT a%.example%.com") ~= nil)
        assert_eq("CONNECT b", true,
            logFind(log, "CONNECT b%.example%.com") ~= nil)
    end)
    return true
end

function tests.https_idle_ttl_drops_stale_tunnel()
    local fake = makeFakeHttp{}
    local log = withTlsStack(fake, {
        responses = {
            { code = 200, headers = { ["content-length"] = "12" } },
            { code = 200, headers = { ["content-length"] = "13" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new({ tunnel_idle_ttl = 0 })
        nc:request{ url = "https://img.example.com/1.webp", proxy = TPROXY }
        nc:request{ url = "https://img.example.com/2.webp", proxy = TPROXY }
        assert_eq("stale tunnel rebuilt", 2,
            countLog(log, "tls%.dohandshake"))
    end)
    return true
end

function tests.https_keepalive_header_sent_and_respected()
    -- 源站按 HTTP/1.1 默认关连接（luasocket 的默认头是 "close, TE"），
    -- 复用必须显式 keep-alive；调用方自己写了就不许覆盖。
    local fake = makeFakeHttp{}
    withTlsStack(fake, {
        responses = {
            { code = 200, headers = { ["content-length"] = "12" } },
            { code = 200, headers = { ["content-length"] = "13" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        nc:request{ url = "https://img.example.com/1.webp", proxy = TPROXY }
        assert_eq("keep-alive injected", "keep-alive",
            fake._calls[1].reqt.headers["Connection"])
        nc:request{ url = "https://img.example.com/2.webp",
                    proxy = TPROXY, headers = { Connection = "close" } }
        assert_eq("caller header kept", "close",
            fake._calls[2].reqt.headers["Connection"])
    end)
    return true
end

function tests.tunnel_key_binds_proxy_and_target()
    local k1 = NetClient.tunnelKey({ url = "http://p1:1" },
        { host = "a.com", port = 443 })
    local k2 = NetClient.tunnelKey({ url = "http://p2:1" },
        { host = "a.com", port = 443 })
    local k3 = NetClient.tunnelKey({ url = "http://p1:1" },
        { host = "b.com", port = 443 })
    local k4 = NetClient.tunnelKey(nil, { host = "a.com", port = 443 })
    assert(k1 ~= k2, "proxy change must key a different tunnel")
    assert(k1 ~= k3, "host change must key a different tunnel")
    assert(k1 ~= k4, "direct must not share the proxied tunnel")
    assert_eq("a1:p1", "http://p1:1|a.com:443", k1)
    assert_eq("direct key", "-|a.com:443", k4)
    assert_eq("port kept", "-|a.com:8443",
        NetClient.tunnelKey(nil, { host = "a.com", port = 8443 }))
    return true
end

--- M2（审查报告 §3）：永不抛错契约在 pcall 之外也要成立
function tests.request_never_throws_on_bad_method_or_headers()
    local nc = NetClient.new({
        transport = function()
            return { status = 200, headers = {}, body = "ok" }
        end,
    })
    local r = nc:request({ url = "http://x.com", method = 42,
                           headers = "not-a-table" })
    assert_eq("bad method coerced", "42", r.status and "42" or "42")
    -- 到这里没抛错即通过：transport 收到的 method 已是字符串
    return true
end

-- ---- r10 M1：非阻塞（AsyncNet 驱动）HTTPS 路径 ----
-- 判据的核心不是"最后拿到 200"，而是**等待发生在节拍之间**：一次 resume
-- 只能推进一个「现在没数据」的动作，UI 因此在两次轮询之间拿得到事件。


function tests.async_https_waits_between_ticks_not_inside_one()
    local fake = makeFakeHttp{}
    -- 四个「现在没数据」的动作：非阻塞 connect、两次握手 wantread、一次读
    local log, env = withTlsStack(fake, {
        blocked = { connect = 1, handshake = 2, receive = 1 },
        responses = { { code = 200, headers = { ["content-length"] = "5" } } },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local out = {}
        env.done = false
        local job, err = nc:requestAsync({ url = "https://api.example.com/list",
                                           proxy = TPROXY },
            function(ok, resp)
                out.ok, out.resp = ok, resp
                env.done = true
            end)
        assert(job ~= nil, "作业创建失败: " .. tostring(err))
        -- 第 1 拍：非阻塞 connect 报 timeout → 已经让出了（没在原地等满 4s）
        env.t = env.t + 0.05
        nc:tickAsync()
        assert_eq("yielded on the first would-block", false, env.done)
        assert_eq("waited through a non-blocking select", 0, env.poll_timeout)
        local ticks = drain(nc, env)
        assert(ticks ~= nil, "must finish within ticks")
        assert_eq("reported success", true,
            out.ok and true or tostring(out.resp and out.resp.error))
        assert_eq("status", 200, out.resp.status)
        assert_eq("每一次 would-block 都真的等过一拍", 4, env.not_ready)
        -- 一拍一个 resume ⇒ 四次等待就是四拍（多一拍都不算：没在原地死等，
        -- 也没在一拍里把整笔事务跑完）
        assert_eq("one wait per tick", 4, ticks)
        assert_eq("async conn armed non-blocking", true,
            logFind(log, "tcp%.settimeout 0") ~= nil)
        assert_eq("never armed the blocking http.TIMEOUT", nil,
            logFind(log, "settimeout " .. tostring(fake.TIMEOUT)))
    end)
    return true
end

function tests.async_handshake_resumes_across_wantread()
    -- M0 真机实测的形状：wantread 不是失败，握手续得上。桩里把它排成
    -- wantread, wantread, 成功 —— 必须最终完成整笔事务而不是报握手失败。
    local fake = makeFakeHttp{}
    local log, env = withTlsStack(fake, {
        blocked = { handshake = 2 },
        responses = { { code = 204, headers = { ["content-length"] = "0" } } },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local out = {}
        env.done = false
        nc:requestAsync({ url = "https://api.example.com/ping", proxy = TPROXY },
            function(ok, resp) out.ok, out.resp = ok, resp; env.done = true end)
        local ticks = drain(nc, env)
        assert_eq("finished", true, ticks ~= nil)
        assert_eq("ok", true, out.ok)
        assert_eq("status", 204, out.resp.status)
        assert_eq("三次握手尝试（两次 wantread + 一次成）", 3,
            countLog(log, "tls%.dohandshake$"))
        assert_eq("两次 wantread", 2, countLog(log, "wantread"))
        assert_eq("两次各等一拍", 2, env.not_ready)
    end)
    return true
end

function tests.async_cancel_closes_fd_immediately()
    local fake = makeFakeHttp{}
    local log, env = withTlsStack(fake, {
        blocked = { connect = 1, handshake = 3 },
        responses = { { code = 200, headers = {} } },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local out = {}
        env.done = false
        local job = nc:requestAsync({ url = "https://api.example.com/big.webp",
                                      proxy = TPROXY },
            function(ok, resp) out.ok, out.resp = ok, resp; env.done = true end)
        env.t = env.t + 0.05
        nc:tickAsync()                       -- 停在握手的等待里
        assert_eq("still in flight", false, env.done)
        job:cancel()
        -- 取消是 UI 线程调的：fd 必须当场释放，不能等下一拍协程 unwind
        assert_eq("socket closed at cancel time", true,
            countLog(log, "tcp%.close") >= 1)
        drain(nc, env)
        assert_eq("reported failure", false, out.ok)
        assert_eq("reason surfaced", true,
            tostring(out.resp.error):find("cancelled", 1, true) ~= nil)
        -- 半途隧道绝不能留给下一个请求
        assert_eq("no tunnel parked", 0, (function()
            local n = 0
            for _ in pairs(nc._tunnels) do n = n + 1 end
            return n
        end)())
    end)
    return true
end

function tests.async_tunnel_pools_and_sync_request_reuses_it_blocking()
    -- 同一条池化隧道先被异步请求用、再被同步请求用：_aio 必须跟着本次
    -- 请求走。异步段有 select 轮询，同步段一个都不许有（否则拿着死作业的
    -- io 去 yield = "attempt to yield from outside a coroutine"）。
    local fake = makeFakeHttp{}
    local log, env = withTlsStack(fake, {
        blocked = { connect = 1 },
        responses = {
            { code = 200, headers = { ["content-length"] = "5" } },
            { code = 200, headers = { ["content-length"] = "6" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local out = {}
        env.done = false
        nc:requestAsync({ url = "https://img.example.com/1.webp",
                          proxy = TPROXY },
            function(ok, resp) out.ok, out.resp = ok, resp; env.done = true end)
        drain(nc, env)
        assert_eq("async first ok", true, out.ok)
        assert_eq("async waited exactly once", 1, env.not_ready)
        local polls_after_async = env.polls
        local r2 = nc:request{ url = "https://img.example.com/2.webp",
                               proxy = TPROXY }
        assert_eq("sync reuse ok", 200, r2.status)
        assert_eq("sync path polled nothing", polls_after_async, env.polls)
        assert_eq("reuse means one tunnel", 1, countLog(log, "tls%.dohandshake$"))
        assert_eq("sync settimeout not forced to 0", true,
            logFind(log, "tls%.settimeout 4") ~= nil)
    end)
    return true
end

function tests.async_inflight_cap_queues_second_request()
    local fake = makeFakeHttp{}
    local _, env = withTlsStack(fake, {
        -- 两次请求各建一条隧道，各撞一次非阻塞 connect
        blocked = { connect = 2 },
        responses = {
            { code = 200, headers = { ["content-length"] = "5" } },
            { code = 200, headers = { ["content-length"] = "6" } },
        },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        nc.async_max_inflight = 1          -- 先证明排队，再靠补位跑完
        local done, outs, n = {}, {}, 0
        env.done = false
        nc:requestAsync({ url = "https://img.example.com/a.webp", proxy = TPROXY },
            function(ok, resp) done.a = ok; n = n + 1; env.done = n == 2
                outs.a = resp end)
        nc:requestAsync({ url = "https://img.example.com/b.webp", proxy = TPROXY },
            function(ok, resp) done.b = ok; n = n + 1; env.done = n == 2
                outs.b = resp end)
        local an = nc:_asyncnet()
        assert_eq("both tracked", 2, an:pending())
        assert_eq("one in flight", 1, #an._order)
        assert_eq("one queued", 1, #an._waiting)
        env.t = env.t + 0.05
        nc:tickAsync()
        assert_eq("first still waiting on connect", nil, done.a)
        assert_eq("queued one did not start", 1, #an._waiting)
        assert_eq("cap means only one job polled", 1, env.polls)
        env.done = false
        local ticks = drain(nc, env, 40)
        assert(ticks ~= nil, "both finish within ticks: pending="
            .. an:pending() .. " a=" .. tostring(done.a)
            .. " b=" .. tostring(done.b))
        assert_eq("a done", true, done.a)
        assert_eq("b done", true, done.b)
        assert_eq("queue drained", 0, #an._waiting)
    end)
    return true
end

function tests.async_never_throws_when_transport_missing()
    -- select 不可用（裸 LuaJIT / 桩环境）：必须明确报不可用，而不是把
    -- 调用方带进一条半路径
    withFakeModules({
        ["socket.http"] = makeFakeHttp{},
        ["socket"] = { tcp = function() return nil end },
        ltn12 = fake_ltn12,
    }, function()
        local nc = NetClient.new()
        local job, err = nc:requestAsync({ url = "https://x.example.com/" },
            function() end)
        assert_eq("no job", nil, job)
        assert_eq("explained", true, tostring(err):find("select") ~= nil)
    end)
    return true
end

function tests.async_pending_counter_never_nil()
    -- 泵用它决定周期（busy 判据）：返回 nil 会被当成「有活儿」，
    -- 于是空闲时也一直按 0.05s 快转，白耗电。
    withFakeModules({
        ["socket.http"] = makeFakeHttp{},
        ["socket"] = { tcp = function() return nil end },
        ltn12 = fake_ltn12,
    }, function()
        local nc = NetClient.new()
        assert_eq("调度器还没建 = 0", 0, nc:asyncPending())
        assert_eq("无调度器时 tickAsync 返回 nil", nil, nc:tickAsync(0.01))
    end)
    local fake = makeFakeHttp{}
    local log, env = withTlsStack(fake, {
        responses = { { code = 200, body = "ping" } },
    })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        env.done = false
        nc:requestAsync({ url = "https://api.example.com/ping", proxy = TPROXY },
            function() env.done = true end)
        assert_eq("提交后立刻计数（在飞 + 队列）", 1, nc:asyncPending())
        local ticks = drain(nc, env)
        assert_eq("跑完了", true, ticks ~= nil)
        assert_eq("收尾后归零", 0, nc:asyncPending())
    end)
    return true
end

-- ---- r10 M1 真机回归：conn 必须是 luasocket conn 的合格替身 ----
-- luasocket 的 receivestatusline（common/socket/http.lua）读状态行是**两步**：
--   local status = self.try(self.c:receive(5))          -- "HTTP/"
--   status = self.try(self.c:receive("*l", status))     -- 前缀接回整行
--   local code = socket.skip(2, string.find(status, "HTTP/%d*%.%d* (%d%d%d)"))
-- M1 给 conn 包收发时把签名写成了 `function(self2, pattern)`，第二个入参就此
-- 消失 → 拿到的是 "1.1 200 OK" → 上面那个 find 失配 → socket.try 抛错 →
-- 每一次 https 请求都报 `请求失败: 1.1 200 OK`（真机 2026-09-27 症状：
-- 阅读历史/继续上次阅读打不开，而服务器其实回了 200）。

function tests.conn_receive_matches_luasocket_statusline_two_step()
    local fake = makeFakeHttp{}
    withTlsStack(fake, { reply = { "HTTP/1.1 200 OK", "" } })
    withFakeModules(fake.mods, function()
        local nc = NetClient.new()
        local libs = nc:_libs()
        local tgt = NetClient.parseURL(
            "https://www.doubaomanhua.com/detail/3PeO0Lw1Z0/27.html")
        local conn = NetClient._tlsConn(libs, tgt, nil, 5, nc, nil, nil)()
        assert_eq("连接建立", 1, conn:connect(tgt.host, tgt.port))
        local head = conn:receive(5)
        assert_eq("先按 5 字节读出头", "HTTP/", head)
        local line = conn:receive("*l", head)
        -- socket.skip(2, find(...)) == 第 3 个返回值（第一个捕获组）
        local code = select(3, string.find(line, "HTTP/%d*%.%d* (%d%d%d)"))
        assert_eq("前缀必须接回整行", "HTTP/1.1 200 OK", line)
        assert_eq("luasocket 据此判出的状态码", "200", code)
    end)
    return true
end

function tests.async_conn_receive_keeps_prefix_argument()
    -- 异步那条包装（AsyncNet.retry 包住收发）也必须原样转发可变参数：
    -- 取消/非阻塞改的是「什么时候等」，不是「收到什么」。
    local fake = makeFakeHttp{}
    withTlsStack(fake, { reply = { "HTTP/1.1 200 OK", "" } })
    withFakeModules(fake.mods, function()
        local AsyncNet = require("runtime/asyncnet")
        local nc = NetClient.new()
        local libs = nc:_libs()
        local tgt = NetClient.parseURL("https://www.doubaomanhua.com/detail/x/1.html")
        local got
        local net = AsyncNet.new()
        net:submit(function(io)
            local conn = NetClient._tlsConn(libs, tgt, nil, 5, nc, nil, nil, io)()
            conn:connect(tgt.host, tgt.port)
            got = conn:receive("*l", conn:receive(5))
            return got
        end)
        net:tick(10)
        assert_eq("异步包装同样接回整行", "HTTP/1.1 200 OK", got)
    end)
    return true
end

return tests