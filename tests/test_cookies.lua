-- unit test: runtime/cookies.lua — jar 语义（域后缀/路径/过期/形状）
local Cookies = require("runtime.cookies")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local tests = {}

local now = 1000000
local function makeJar()
    local fakeJson = {
        encode = function(v) return "encoded" end,
        decode = function(s) return nil end,
    }
    local store = { load = function() return nil end, save = function() end }
    return Cookies.new({ json = fakeJson, store = store,
        now = function() return now end })
end

function tests.set_get_roundtrip()
    local jar = makeJar()
    jar:setCookies("http://example.com/page", {
        { name = "sid", value = "abc", domain = "example.com", path = "/" },
    })
    local got = jar:getCookies("http://example.com/page")
    assert_eq("count", 1, #got)
    assert_eq("name", "sid", got[1].name)
    assert_eq("value", "abc", got[1].value)
    return true
end

function tests.leading_dot_matches_subdomain()
    local jar = makeJar()
    jar:setCookies("http://a.example.com/", {
        { name = "k", value = "v", domain = ".example.com", path = "/" },
    })
    assert_eq("self match", 1, #jar:getCookies("http://example.com/"))
    assert_eq("subdomain match", 1, #jar:getCookies("http://deep.a.example.com/"))
    assert_eq("other domain no match", 0, #jar:getCookies("http://other.com/"))
    return true
end

function tests.path_prefix_rule()
    local jar = makeJar()
    jar:setCookies("http://example.com/admin/", {
        { name = "a", value = "1", domain = "example.com", path = "/admin" },
    })
    assert_eq("under path", 1, #jar:getCookies("http://example.com/admin/x"))
    assert_eq("outside path", 0, #jar:getCookies("http://example.com/other"))
    return true
end

function tests.expiry_purge()
    local jar = makeJar()
    jar:setCookies("http://example.com/", {
        { name = "exp", value = "1", domain = "example.com", path = "/",
          expires = (now + 10) * 1000 },   -- 已过期（now 秒 → ms 基准）
    })
    -- expires 语义：毫秒；now()*1000=1e9 > expires? 设置 now 大一点再测
    now = 2000000
    local got = jar:getCookies("http://example.com/")
    assert_eq("expired dropped", 0, #got)
    now = 1000000
    return true
end

function tests.cross_domain_copy_shape()
    -- ehentai 流程：getCookies → 改 domain → setCookies
    local jar = makeJar()
    jar:setCookies("https://forums.e-hentai.org/", {
        { name = "MemberCookie", value = "u:x", domain = "e-hentai.org",
          path = "/", secure = true },
    })
    local got = jar:getCookies("https://forums.e-hentai.org/")
    assert_eq("found", 1, #got)
    assert_eq("has fields", true,
        got[1].name ~= nil and got[1].domain ~= nil
        and got[1].secure ~= nil and got[1].expires ~= nil)
    got[1].domain = ".exhentai.org"
    jar:setCookies("https://exhentai.org/", got)
    assert_eq("copied", 1, #jar:getCookies("https://exhentai.org/"))
    return true
end

function tests.headerFor_format()
    local jar = makeJar()
    jar:setCookies("http://example.com/", {
        { name = "a", value = "1", domain = "example.com", path = "/" },
        { name = "b", value = "2", domain = "example.com", path = "/" },
    })
    local h = jar:headerFor("http://example.com/")
    assert_eq("joined", "a=1; b=2", h)
    return true
end

function tests.secure_not_sent_over_http()
    local jar = makeJar()
    jar:setCookies("http://example.com/", {
        { name = "s", value = "1", domain = "example.com", path = "/",
          secure = true },
    })
    assert_eq("http no secure", 0, #jar:getCookies("http://example.com/"))
    assert_eq("https has it", 1, #jar:getCookies("https://example.com/"))
    return true
end

function tests.store_from_response_multi()
    local jar = makeJar()
    jar:storeFromResponse("http://example.com/x", {
        ["set-cookie"] = "k1=v1; Path=/; Domain=example.com",
    })
    assert_eq("stored", 1, #jar:getCookies("http://example.com/"))
    return true
end

function tests.store_from_response_comma_joined_multi()
    -- 审查 M2：luasocket 把多条 Set-Cookie 逗号合并成一条，解析端必须拆回，
    -- 否则第二条及以后静默丢失（登录 cookie 不全）
    local jar = makeJar()
    jar:storeFromResponse("http://example.com/x", {
        ["set-cookie"] =
            "k1=v1; Path=/, k2=v2; Domain=example.com; Path=/, k3=v3; Path=/",
    })
    local got = jar:getCookies("http://example.com/")
    assert_eq("all three stored", 3, #got)
    local seen = {}
    for _, ck in ipairs(got) do seen[ck.name] = ck.value end
    assert_eq("k1", "v1", seen["k1"])
    assert_eq("k2", "v2", seen["k2"])
    assert_eq("k3", "v3", seen["k3"])
    return true
end

function tests.store_from_response_expires_with_comma()
    -- 审查 M2：Expires 的 "Wed, 21 Oct" 内嵌逗号不能被拆成两条
    local jar = makeJar()
    jar:storeFromResponse("http://example.com/x", {
        ["set-cookie"] =
            "sess=abc; Path=/; Expires=Wed, 21 Oct 2095 07:28:00 GMT",
    })
    local got = jar:getCookies("http://example.com/")
    assert_eq("single cookie", 1, #got)
    assert_eq("name", "sess", got[1].name)
    assert_eq("value", "abc", got[1].value)
    -- 审查 M8：Expires 必须真正解析成功（不再回退 -1 永不过期）
    assert_eq("expires parsed", true,
        got[1].expires ~= nil and got[1].expires > 0)
    return true
end

function tests.parse_http_date_rfc1123()
    -- 审查 M8 回归锁：原正则 "%a+,s*" 少一个 %，永远解析失败
    local t = Cookies.parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT")
    assert_eq("rfc1123 parsed", true, t ~= nil and t > 0)
    local t2 = Cookies.parseHttpDate("Wed, 21 Oct 2095 07:28:00 GMT")
    assert_eq("rfc1123 parsed 2", true, t2 ~= nil and t2 > 0)
    assert_eq("garbage nil", nil, Cookies.parseHttpDate("not a date"))
    assert_eq("non-string nil", nil, Cookies.parseHttpDate(nil))
    return true
end

return tests