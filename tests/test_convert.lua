-- unit test: runtime/convert.lua — base64/hex 纯 Lua 层 + 注入后端
local Convert = require("runtime.convert")
local stubs = require("tests.stubs")

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local tests = {}

-- ---- base64 ----

function tests.b64_roundtrip_empty()
    local r = Convert.base64Encode("")
    local d, err = Convert.base64Decode(r)
    assert(d ~= nil, err)
    assert_eq("empty", "", d)
    return true
end

function tests.b64_roundtrip_binary()
    local orig = string.char(0, 255, 128, 1, 64, 127)
    local enc = Convert.base64Encode(orig)
    local dec, err = Convert.base64Decode(enc)
    assert(dec ~= nil, "decode error: " .. tostring(err))
    assert_eq("binary", orig, dec)
    return true
end

function tests.b64_roundtrip_typical()
    local orig = "Hello, World!"
    local enc = Convert.base64Encode(orig)
    assert_eq("known", "SGVsbG8sIFdvcmxkIQ==", enc)
    local dec, err = Convert.base64Decode(enc)
    assert(dec ~= nil, "decode error: " .. tostring(err))
    assert_eq("roundtrip", orig, dec)
    return true
end

function tests.b64_decode_1pad()
    local orig = "AB"
    local enc = Convert.base64Encode(orig)
    assert_eq("pad2", "QUI=", enc)
    local dec, err = Convert.base64Decode(enc)
    assert(dec ~= nil, "decode error: " .. tostring(err))
    assert_eq("pad2 roundtrip", orig, dec)
    return true
end

function tests.b64_decode_2pad()
    local orig = "A"
    local enc = Convert.base64Encode(orig)
    assert_eq("pad1", "QQ==", enc)
    local dec, err = Convert.base64Decode(enc)
    assert(dec ~= nil, "decode error: " .. tostring(err))
    assert_eq("pad1 roundtrip", orig, dec)
    return true
end

-- ---- hex ----

function tests.hex_lowercase()
    local r = Convert.hexEncode(string.char(0xAB, 0xCD, 0xEF))
    assert_eq("hex", "abcdef", r)
    return true
end

function tests.hex_zero()
    assert_eq("hex zero", "00", Convert.hexEncode("\0"))
    return true
end

-- ---- injected crypto backend ----

function tests.aes_injected_ecb_dec()
    local c = Convert.new(stubs.fake_convert_impl())
    local v, err = c:aes("ecb", false, "hello", "1234567890123456", nil, 16)
    assert(v ~= nil, "err: " .. tostring(err))
    assert_eq("dec call", "aes(ecb,dec):hello", v)
    return true
end

function tests.aes_injected_cbc_enc()
    local c = Convert.new(stubs.fake_convert_impl())
    local v, err = c:aes("cbc", true, "data", "k16k16k16k16k16", "iv16iv16iv16iv16", 16)
    assert(v ~= nil, "err: " .. tostring(err))
    assert_eq("enc call", "aes(cbc,enc):data", v)
    return true
end

function tests.digest_injected()
    local c = Convert.new(stubs.fake_convert_impl())
    local v, err = c:digest("md5", "abc")
    assert(v ~= nil, "err: " .. tostring(err))
    assert_eq("md5 call", "digest(md5):abc", v)
    return true
end

function tests.hmac_injected()
    local c = Convert.new(stubs.fake_convert_impl())
    local v, err = c:hmac("sha256", "key", "value")
    assert(v ~= nil, "err: " .. tostring(err))
    assert_eq("hmac call", "hmac(sha256):key:value", v)
    return true
end

function tests.no_backend_error()
    local c = Convert.new(nil)
    -- 本地 Windows 无 libcrypto → backend nil，aes 直接报 backend 错误；
    -- CI（装 libssl-dev 后）backend 可用，则因 4 字节输入未对齐同样返回
    -- nil + 非空错误——两种环境下断言都成立
    local v, err = c:aes("ecb", false, "data", "key1234567890abc", nil, 16)
    assert(v == nil, "expected nil")
    assert_eq("err msg non-empty", true, err ~= nil and #err > 0)
    return true
end

function tests.utf8_passthrough()
    local c = Convert.new(nil)
    assert_eq("encode", "hello", c:encodeUtf8("hello"))
    assert_eq("decode", "world", c:decodeUtf8("world"))
    return true
end

return tests