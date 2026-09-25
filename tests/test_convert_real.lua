-- unit test: runtime/convert.lua — 真实 libcrypto 后端 NIST 向量（审查 M1/C1）
--
-- 目的：C1（EVP Init 把 #key 当 IV 指针）这类缺陷只被「注入桩」的单测
-- 放行，本文件用真实 libcrypto 跑 NIST/RFC 标准向量锁死加密行为。
--
-- 环境行为：
--   - 无 libcrypto（Windows dev / 未装 libssl-dev 的 CI）→ 整文件 SKIP，
--     run_tests.py 打印 "SKIP test_convert_real.lua (chunk returned nil)"；
--   - ubuntu + libssl-dev（见 .github/workflows/ci.yml）→ 真实执行 8 项向量。
--
-- 向量来源：NIST SP800-38A F.1-F.4（AES-128）、RFC 1321（md5）、
-- FIPS 180（sha1/sha256）、RFC 4231 TC1（HMAC-SHA256）。
local Convert = require("runtime.convert")

local c = Convert.new()   -- 自动探测 openssl 后端（与设备同路径）
if c.backend == nil then
    print("SKIP test_convert_real.lua (libcrypto unavailable"
        .. " — install libssl-dev for real-vector coverage)")
    return nil
end

local function assert_eq(label, expected, actual)
    assert(expected == actual,
        label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function unhex(s)
    local out = {}
    for i = 1, #s, 2 do
        out[#out + 1] = string.char(tonumber(s:sub(i, i + 1), 16))
    end
    return table.concat(out)
end

-- NIST SP800-38A AES-128 公共参数
local K  = unhex("2b7e151628aed2a6abf7158809cf4f3c")
local IV = unhex("000102030405060708090a0b0c0d0e0f")
local PT = unhex("6bc1bee22e409f96e93d7e117393172a")

local tests = {}

function tests.aes128_cbc_nist_vector()
    -- C1 回归锁：Init 的 IV 实参错误时此向量必然失败/崩溃
    local ct, err = c:aes("cbc", true, PT, K, IV, 16)
    assert(ct ~= nil, "enc err: " .. tostring(err))
    assert_eq("cbc ct", "7649abac8119b246cee98e9b12e9197d", Convert.hexEncode(ct))
    local pt2, derr = c:aes("cbc", false, ct, K, IV, 16)
    assert(pt2 ~= nil, "dec err: " .. tostring(derr))
    assert_eq("cbc roundtrip", PT, pt2)
    return true
end

function tests.aes128_ecb_nist_vector()
    local ct, err = c:aes("ecb", true, PT, K, nil, 16)
    assert(ct ~= nil, "err: " .. tostring(err))
    assert_eq("ecb ct", "3ad77bb40d7a3660a89ecaf32466ef97", Convert.hexEncode(ct))
    return true
end

function tests.aes128_cfb128_nist_vector()
    local ct, err = c:aes("cfb", true, PT, K, IV, 16)
    assert(ct ~= nil, "err: " .. tostring(err))
    -- blockSize=16 → cfb128（cipherName 映射）
    assert_eq("cfb128 ct", "3b3fd92eb72dad20333449f8e83cfb4a",
        Convert.hexEncode(ct))
    return true
end

function tests.aes128_ofb_nist_vector()
    local ct, err = c:aes("ofb", true, PT, K, IV, 16)
    assert(ct ~= nil, "err: " .. tostring(err))
    -- OFB 与 CFB128 的首块密文相同（同为 AES(IV) 密钥流）
    assert_eq("ofb ct", "3b3fd92eb72dad20333449f8e83cfb4a",
        Convert.hexEncode(ct))
    return true
end

function tests.aes128_ofb_no_iv_equals_zero_iv()
    -- M4 回归锁：上游 ofb 消息不带 IV → 必须以全零 IV 起始而非报错，
    -- 且 nil-IV 与显式零 IV 结果一致、可解回
    local zeros = string.rep("\0", 16)
    local ct_nil, e1 = c:aes("ofb", true, PT, K, nil, 16)
    local ct_zero, e2 = c:aes("ofb", true, PT, K, zeros, 16)
    assert(ct_nil ~= nil and ct_zero ~= nil,
        tostring(e1) .. " / " .. tostring(e2))
    assert_eq("nil iv == zero iv",
        Convert.hexEncode(ct_zero), Convert.hexEncode(ct_nil))
    local pt2, derr = c:aes("ofb", false, ct_nil, K, nil, 16)
    assert(pt2 ~= nil, "dec err: " .. tostring(derr))
    assert_eq("ofb roundtrip", PT, pt2)
    return true
end

function tests.digest_nist_vectors()
    local d1, e1 = c:digest("md5", "abc")
    assert(d1 ~= nil, tostring(e1))
    assert_eq("md5(abc)", "900150983cd24fb0d6963f7d28e17f72",
        Convert.hexEncode(d1))
    local d2, e2 = c:digest("sha1", "abc")
    assert(d2 ~= nil, tostring(e2))
    assert_eq("sha1(abc)", "a9993e364706816aba3e25717850c26c9cd0d89d",
        Convert.hexEncode(d2))
    local d3, e3 = c:digest("sha256", "abc")
    assert(d3 ~= nil, tostring(e3))
    assert_eq("sha256(abc)",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        Convert.hexEncode(d3))
    return true
end

function tests.hmac_sha256_rfc4231_tc1()
    local key = string.rep("\11", 20)   -- RFC 4231 TC1: 0x0b x20
    local mac, err = c:hmac("sha256", key, "Hi There")
    assert(mac ~= nil, tostring(err))
    assert_eq("hmac-sha256",
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        Convert.hexEncode(mac))
    return true
end

function tests.openssl_backend_self_check()
    -- M12 回归锁：opensslBackend 必须通过符号自检后才可用
    assert_eq("backend name", "openssl", c.backend.name)
    assert_eq("aes fn", "function", type(c.backend.aes))
    assert_eq("digest fn", "function", type(c.backend.digest))
    assert_eq("hmac fn", "function", type(c.backend.hmac))
    return true
end

return tests
