-- unit test: runtime/bridge.lua — sendMessage 分发层（对齐 vendored init.js 精确契约）
local Bridge = require("runtime.bridge")
local NetClient = require("netclient")
local Convert = require("runtime.convert")
local Cookies = require("runtime.cookies")
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local tests = {}

-- 全内存 bridge 组装
local function makeBridge(extra)
    extra = extra or {}
    local data_store = extra.data_store or {}
    local storage = {
        load = function(key) return data_store[key] or {} end,
        save = function(key, map) data_store[key] = map; return true end,
    }
    local captured_http
    local nc = extra.netclient or NetClient.new({
        transport = function(req)
            captured_http = req
            return { status = 200, headers = { ["content-type"] = "text/plain" },
                     body = "hello-body", error = nil }
        end,
    })
    local cookiejar = Cookies.new({
        json = { encode = function() return "x" end,
                 decode = function() return nil end },
        store = { load = function() return nil end, save = function() end },
    })
    local b = Bridge.new({
        settings = extra.settings or stubs.settings_memory(),
        netclient = nc,
        convert = Convert.new(stubs.fake_convert_impl()),
        cookies = cookiejar,
        storage = storage,
    })
    b._data_store = data_store
    b._captured_http = function() return captured_http end
    return b
end

-- ---- data（key=源key，data_key=槽位，值字段=data）----

function tests.save_load_delete_roundtrip()
    local b = makeBridge()
    b:handle({ method = "save_data", key = "src1", data_key = "token",
               data = "abc123" })
    local v = b:handle({ method = "load_data", key = "src1",
                         data_key = "token" })
    assert_eq("loaded", "abc123", v)
    b:handle({ method = "delete_data", key = "src1", data_key = "token" })
    local v2 = b:handle({ method = "load_data", key = "src1",
                          data_key = "token" })
    assert_eq("deleted", nil, v2)
    return true
end

function tests.data_is_per_source()
    local b = makeBridge()
    b:handle({ method = "save_data", key = "a", data_key = "t", data = 1 })
    b:handle({ method = "save_data", key = "b", data_key = "t", data = 2 })
    local va = b:handle({ method = "load_data", key = "a", data_key = "t" })
    assert_eq("source a keeps 1", 1, va)
    local vb = b:handle({ method = "load_data", key = "b", data_key = "t" })
    assert_eq("source b keeps 2", 2, vb)
    -- 槽位隔离
    local vc = b:handle({ method = "load_data", key = "a", data_key = "x" })
    assert_eq("missing slot nil", nil, vc)
    return true
end

-- ---- settings（R7：默认值不在这里补，见 jshost registerSource 的
-- ---- loadSetting 包装——只有 JS 侧才拿得到源实例的 settings 声明表）----

function tests.load_setting_stored_or_undefined_only()
    local b = makeBridge()
    -- 未设置 → nil（JSON null / JS undefined）：由 JS 包装层换成源声明的
    -- default，最终永不为 null 出现在 URL 里
    local v = b:handle({ method = "load_setting", key = "s",
                         setting_key = "quality" })
    assert_eq("unset stays unset", nil, v)
    b._data_store["s"] = { settings = { quality = "low" } }
    local v2 = b:handle({ method = "load_setting", key = "s",
                          setting_key = "quality" })
    assert_eq("stored wins", "low", v2)
    -- 用户显式存的空串不能被当成"未设置"（baozi 的 cdn_domains "" = 用图源自带域名）
    b._data_store["s"] = { settings = { quality = "" } }
    local v3 = b:handle({ method = "load_setting", key = "s",
                          setting_key = "quality" })
    assert_eq("stored empty string preserved", "", v3)
    return true
end

function tests.isLogged_derivation()
    local b = makeBridge()
    local v = b:handle({ method = "isLogged", key = "s" })
    assert_eq("fresh false", false, v)
    b._data_store["s"] = { account = { "u", "p" } }
    local v2 = b:handle({ method = "isLogged", key = "s" })
    assert_eq("account true", true, v2)
    return true
end

-- ---- http（代理注入 + 响应形状，AC2.3/AC3.4）----

function tests.http_uses_proxy_when_enabled()
    local s = stubs.settings_memory()
    s:set("proxy_enabled", true)
    -- 审查 L5：默认代理地址已清空（真机首配），显式设置后再断言
    s:set("proxy_url", "http://203.0.113.10:16492")
    local b = makeBridge({ settings = s })
    local resp, iserr = b:handle({ method = "http", http_method = "GET",
                                   url = "http://example.com/api" })
    assert_eq("no error", false, iserr)
    assert_eq("proxy set", "http://203.0.113.10:16492",
        b._captured_http().proxy)
    assert_eq("status", 200, resp.status)
    assert_eq("body", "hello-body", resp.body)
    return true
end

function tests.http_verb_field_is_http_method()
    local b = makeBridge()
    b:handle({ method = "http", http_method = "POST", url = "http://x.com" })
    assert_eq("verb passed", "POST", b._captured_http().method)
    return true
end

function tests.http_forces_direct_when_disabled()
    local b = makeBridge()
    b:handle({ method = "http", url = "http://example.com" })
    assert_eq("empty string override", "", b._captured_http().proxy)
    return true
end

function tests.http_request_body_unwrapped()
    local b = makeBridge()
    b:handle({ method = "http", url = "http://x.com",
               data = { __bytes_b64 = Convert.base64Encode("payload") } })
    assert_eq("body unwrapped", "payload", b._captured_http().body)
    return true
end

function tests.http_request_body_object_jsonified()
    -- 审查 M6：JS 对象形态的 data 必须 JSON 序列化为请求体（不再静默丢弃）
    local b = makeBridge()
    b.json = { encode = function(v) return "jsonified" end }
    b:handle({ method = "http", http_method = "POST", url = "http://x.com",
               data = { a = 1 } })
    assert_eq("table body", "jsonified", b._captured_http().body)
    b:handle({ method = "http", http_method = "POST", url = "http://x.com",
               data = 42 })
    assert_eq("number body", "jsonified", b._captured_http().body)
    return true
end

function tests.http_cookie_header_single()
    -- 审查 M9：jar cookie 与插件 Cookie 头合并后只保留一个 cookie 头
    local b = makeBridge()
    b.cookies:setCookies("http://example.com/", {
        { name = "jar", value = "1", domain = "example.com", path = "/" },
    })
    b:handle({ method = "http", url = "http://example.com/",
               headers = { Cookie = "a=1" } })
    local h = b._captured_http().headers
    assert_eq("lowercase removed", nil, h["cookie"])
    assert_eq("merged single", "a=1; jar=1", h["Cookie"])
    return true
end

function tests.http_bytes_mode_base64()
    local b = makeBridge()
    local resp = b:handle({ method = "http", url = "http://example.com",
                            bytes = true })
    assert_eq("wrapped", "table", type(resp.body))
    local raw = Convert.base64Decode(resp.body.__bytes_b64)
    assert_eq("decoded", "hello-body", raw)
    return true
end

function tests.http_missing_url_error()
    local b = makeBridge()
    local v, err = b:handle({ method = "http" })
    assert_eq("is error", true, err)
    return true
end

-- ---- convert（对齐 init.js 精确字段：type/value/isEncode/...）----

function tests.convert_encodeBase64()
    local b = makeBridge()
    local v, err = b:handle({ method = "convert", type = "base64",
        value = { __bytes_b64 = Convert.base64Encode("raw") },
        isEncode = true })
    assert_eq("string result", Convert.base64Encode("raw"), v)
    return true
end

function tests.convert_decodeBase64()
    local b = makeBridge()
    local v, err = b:handle({ method = "convert", type = "base64",
        value = Convert.base64Encode("raw"), isEncode = false })
    assert_eq("wrapped", "table", type(v))
    assert_eq("decoded", "raw", Convert.base64Decode(v.__bytes_b64))
    return true
end

function tests.convert_utf8_roundtrip()
    local b = makeBridge()
    local enc = b:handle({ method = "convert", type = "utf8",
                           value = "hello", isEncode = true })
    assert_eq("enc is bytes marker", "table", type(enc))
    local dec = b:handle({ method = "convert", type = "utf8",
                           value = enc, isEncode = false })
    assert_eq("dec is string", "hello", dec)
    return true
end

function tests.convert_digest()
    local b = makeBridge()
    local v, err = b:handle({ method = "convert", type = "md5",
        value = { __bytes_b64 = Convert.base64Encode("abc") },
        isEncode = true })
    assert(v ~= nil and v.__bytes_b64 ~= nil, "err: " .. tostring(err))
    local raw = Convert.base64Decode(v.__bytes_b64)
    assert_eq("digest call", "digest(md5):abc", raw)
    return true
end

function tests.convert_hmac_string()
    local b = makeBridge()
    local v = b:handle({ method = "convert", type = "hmac",
        value = { __bytes_b64 = Convert.base64Encode("value") },
        key = { __bytes_b64 = Convert.base64Encode("key") },
        hash = "sha256", isEncode = true, isString = true })
    -- isString=true → 返回 raw 摘要的 hex 字符串
    assert_eq("hex hmac", Convert.hexEncode("hmac(sha256):key:value"), v)
    return true
end

function tests.convert_aes_ecb_dec()
    local b = makeBridge()
    local v, err = b:handle({ method = "convert", type = "aes-ecb",
        value = { __bytes_b64 = Convert.base64Encode("data16data16da") },
        key = { __bytes_b64 = Convert.base64Encode("1234567890123456") },
        isEncode = false })
    local raw = Convert.base64Decode(v.__bytes_b64)
    assert_eq("aes ecb dec", "aes(ecb,dec):data16data16da", raw)
    return true
end

function tests.convert_aes_cbc_iv_passed()
    local captured
    local b = makeBridge({
        netclient = NetClient.new({ transport = function()
            return { status = 200, headers = {}, body = "" } end }),
    })
    -- 注入一个记录 iv 的 fake backend
    b.convert = Convert.new({
        name = "fake",
        aes = function(mode, isEnc, data, key, iv, bs)
            captured = { mode = mode, isEnc = isEnc, iv = iv, bs = bs }
            return "ok"
        end,
        digest = function() return "d" end,
        hmac = function() return "h" end,
    })
    b:handle({ method = "convert", type = "aes-cbc",
        value = { __bytes_b64 = Convert.base64Encode("data") },
        key = { __bytes_b64 = Convert.base64Encode("k16k16k16k16k16") },
        iv = { __bytes_b64 = Convert.base64Encode("iv16iv16iv16iv16") },
        isEncode = false })
    -- 审查 M10：原实现对 captured.iv 零断言（死测试），补上守卫
    assert_eq("iv passed", "iv16iv16iv16iv16", captured.iv)
    return true
end

function tests.convert_ofb_blocksize_from_field()
    -- 审查 M10/M4：改名自 convert_ofb_no_iv_blocksize_from_field——
    -- 「ofb 无 IV」是上游契约（init.js 不发 iv 字段），不是预期语义本身；
    -- zero-IV 行为由 convert 后端实现并由 test_convert_real.lua 锁定
    local captured
    local b = makeBridge()
    b.convert = Convert.new({
        name = "fake",
        aes = function(mode, isEnc, data, key, iv, bs)
            captured = { mode = mode, iv = iv, bs = bs }
            return "x"
        end,
        digest = function() return "d" end,
        hmac = function() return "h" end,
    })
    b:handle({ method = "convert", type = "aes-ofb",
        value = { __bytes_b64 = Convert.base64Encode("d") },
        key = { __bytes_b64 = Convert.base64Encode("k") },
        blockSize = 8, isEncode = true })
    assert_eq("ofb has no iv from message", nil, captured.iv)
    assert_eq("blocksize 8", 8, captured.bs)
    return true
end

function tests.convert_unknown_type_error()
    local b = makeBridge()
    local v, err = b:handle({ method = "convert", type = "noSuchThing" })
    assert_eq("is error", true, err)
    return true
end

-- ---- 桩与错误 ----

function tests.html_handler_m2()
    -- M2 T15：html handler 已接入 htmlparse 引擎（句柄语义）
    local b = makeBridge()
    local v, err = b:handle({ method = "html", ["function"] = "parse",
        key = 1, data = "<div id=\"m\">x</div>" })
    assert_eq("parse ok", true, err == false and v == true)
    local k, err2 = b:handle({ method = "html", ["function"] = "querySelector",
        key = 1, query = "#m" })
    assert_eq("querySelector hits", true, err2 == false and k ~= nil)
    return true
end

function tests.ui_returns_null_like_upstream()
    local b = makeBridge()
    local v, err = b:handle({ method = "UI" })
    assert_eq("null no error", false, err)
    assert_eq("nil", nil, v)
    return true
end

function tests.unknown_method_error()
    local b = makeBridge()
    local v, err = b:handle({ method = "nonexistent" })
    assert_eq("error", true, err)
    return true
end

function tests.bad_message_error()
    local b = makeBridge()
    local v, err = b:handle({})
    assert_eq("error", true, err)
    return true
end

-- ---- cookie（动作字段为 function，对齐 init.js:583-613）----

function tests.cookie_set_get()
    local b = makeBridge()
    b:handle({ method = "cookie", ["function"] = "set",
               url = "http://example.com",
               cookies = { { name = "k", value = "1" } } })
    local v, err = b:handle({ method = "cookie", ["function"] = "get",
                              url = "http://example.com" })
    assert_eq("no err", false, err)
    assert_eq("got 1", 1, #v)
    assert_eq("name", "k", v[1].name)
    return true
end

-- ---- 随机/UUID/misc（type/time 字段）----

function tests.random_int_uses_type_field()
    local b = makeBridge()
    local v = b:handle({ method = "random", type = "int", min = 3, max = 3 })
    assert_eq("int", 3, v)
    return true
end

function tests.delay_uses_time_field()
    local b = makeBridge()
    local v = b:handle({ method = "delay", time = 250 })
    assert_eq("marker", 250, v.__delay_ms)
    return true
end

function tests.uuid_shape()
    local b = makeBridge()
    local v = b:handle({ method = "uuid" })
    assert_eq("string", "string", type(v))
    assert_eq("len", true, #v == 36)
    return true
end

function tests.platform_locale()
    local b = makeBridge()
    local p = b:handle({ method = "getPlatform" })
    assert_eq("platform", "koreader", p)
    return true
end

return tests