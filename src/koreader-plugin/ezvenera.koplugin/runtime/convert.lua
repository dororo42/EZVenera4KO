--[[
EZVenera for KOReader — runtime/convert.lua
Venera `Convert` API 的宿主实现（对齐 pointycastle 无填充语义）。REQ: R3.3。

后端优先级：
  1) 注入 backend（单测）
  2) OpenSSL libcrypto（KOReader 随包，经 ffi）—— AES 全模式 + 摘要 + HMAC
  3) 纯 Lua 回退 —— 仅 base64/hex（加密/摘要返回明确错误）

契约对齐（研究报告 01 §3）：
  - md5/sha1/sha256/sha512 返回 raw 摘要字节（非 hex）
  - AES ECB/CBC/CFB/OFB：无填充；ECB/CBC 输入必须 16 字节对齐（错误即报错）
  - hmac(key, value, hash) → raw；hmacString → hex
  - base64 编解码、utf8 透传（JS 侧字符串经 JSON 已是 UTF-8）
  - GBK：明确不支持错误（P2，见 tasks.md T21）
]]

local Convert = {}
Convert.__index = Convert

local HEX_CHARS = "0123456789abcdef"

function Convert.hexEncode(data)
    local out = {}
    for i = 1, #data do
        local b = string.byte(data, i)
        out[i] = string.format("%02x", b)
    end
    return table.concat(out)
end

------------------------------------------------------------------------
-- 纯 Lua base64（无外部依赖，跨平台一致）
------------------------------------------------------------------------
local B64_ALPHABET =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64_DECODE = {}
for i = 1, #B64_ALPHABET do
    B64_DECODE[string.byte(B64_ALPHABET, i)] = i - 1
end

function Convert.base64Encode(data)
    -- LuaJIT/Lua5.1 兼容（无 // 与 >> 运算符）
    local out = {}
    local len = #data
    local i = 1
    while i <= len - 2 do
        local a, b, c = string.byte(data, i, i + 2)
        local n = a * 65536 + b * 256 + c
        local q
        q = math.floor(n / 262144) % 64
        out[#out + 1] = B64_ALPHABET:sub(q + 1, q + 1)
        q = math.floor(n / 4096) % 64
        out[#out + 1] = B64_ALPHABET:sub(q + 1, q + 1)
        q = math.floor(n / 64) % 64
        out[#out + 1] = B64_ALPHABET:sub(q + 1, q + 1)
        out[#out + 1] = B64_ALPHABET:sub(n % 64 + 1, n % 64 + 1)
        i = i + 3
    end
    local remain = len - i + 1
    if remain == 1 then
        local a = string.byte(data, len)
        out[#out + 1] = B64_ALPHABET:sub(math.floor(a / 4) + 1,
            math.floor(a / 4) + 1)
        out[#out + 1] = B64_ALPHABET:sub((a % 4) * 16 + 1, (a % 4) * 16 + 1)
        out[#out + 1] = "=="
    elseif remain == 2 then
        local a, b = string.byte(data, len - 1, len)
        local n = a * 256 + b
        out[#out + 1] = B64_ALPHABET:sub(math.floor(n / 1024) + 1,
            math.floor(n / 1024) + 1)
        out[#out + 1] = B64_ALPHABET:sub(math.floor(n / 16) % 64 + 1,
            math.floor(n / 16) % 64 + 1)
        out[#out + 1] = B64_ALPHABET:sub((n % 16) * 4 + 1, (n % 16) * 4 + 1)
        out[#out + 1] = "="
    end
    return table.concat(out)
end

function Convert.base64Decode(text)
    if type(text) ~= "string" then return nil, "base64Decode: input not string" end
    text = text:gsub("[^%a%d%+/=]", "")
    local body = text:gsub("=+$", "")
    if #text % 4 ~= 0 then
        return nil, "base64Decode: length not multiple of 4"
    end
    local out = {}
    local bytes = {}
    -- acc 必须保持小（≤ 2^14），否则超出 double 53 位精度导致结果错误
    local acc, bits = 0, 0
    for i = 1, #body do
        local v = B64_DECODE[string.byte(body, i)]
        if not v then
            return nil, "base64Decode: invalid character at " .. i
        end
        acc = acc * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            bytes[#bytes + 1] = string.char(math.floor(acc / 2 ^ bits) % 256)
            acc = acc % 2 ^ bits   -- 只保留残余位，防精度溢出
        end
    end
    -- 校验填充符数量与剩余位一致（“=” 只允许出现在尾部）
    local padding = #text - #body
    if padding > 2 then
        return nil, "base64Decode: bad padding"
    end
    return table.concat(bytes)
end

------------------------------------------------------------------------
-- OpenSSL libcrypto 后端
------------------------------------------------------------------------
local DIGEST_MAP = {
    md5 = "md5", sha1 = "sha1", sha256 = "sha256", sha512 = "sha512",
}

-- mode(Venera 语义) → OpenSSL cipher 名；keylen ∈ {16,24,32} → 128/192/256
local function cipherName(mode, keylen, blocksize)
    local bits = keylen * 8
    if mode == "ecb" then return ("aes-%d-ecb"):format(bits) end
    if mode == "cbc" then return ("aes-%d-cbc"):format(bits) end
    if mode == "cfb" then
        -- pointycastle CFBBlockCipher blockSize（字节）：8 → cfb8，16 → cfb128
        if blocksize == 8 then return ("aes-%d-cfb8"):format(bits) end
        return ("aes-%d-cfb128"):format(bits)
    end
    if mode == "ofb" then
        -- 审查 L7（独立报告）：OpenSSL 只有整块 OFB（=ofb128 语义），
        -- 不存在 ofb8 变体（EVP_get_cipherbyname("aes-*-ofb8") 恒 NULL）。
        -- pointycastle 的 blockSize=8 是库内私有差异，此路恒死——
        -- 由 backend.aes 显式拒绝并注明原因，不再产出无效 cipher 名。
        return ("aes-%d-ofb"):format(bits)
    end
    return nil
end

local function opensslBackend()
    local ffi = require("ffi")
    -- 加载顺序对齐 KOReader base（ffi/crypto.lua 用 ffi.loadlib("crypto","57")）
    local candidates = {}
    local ok, loadlib = pcall(require, "ffi/loadlib")
    if ok and loadlib then
        table.insert(candidates, function() return loadlib.loadlib("crypto", "57") end)
    end
    for _, name in ipairs({ "crypto.so.57", "crypto.so.1.1", "crypto.so.3",
                             "libcrypto-1_1", "libcrypto-3", "crypto" }) do
        table.insert(candidates, function() return ffi.load(name) end)
    end
    local lib = nil
    for _, f in ipairs(candidates) do
        local okload, l = pcall(f)
        if okload and l then lib = l break end
    end
    if not lib then return nil, "libcrypto not loadable" end

    -- 逐条 cdef（审查 M12）：ffi.cdef 按调用原子生效——同块任一符号与宿主
    -- （如 KOReader ffi/crypto_h）冲突会令整块声明失效、其余符号静默缺失；
    -- 拆到单条可将损失限制在单条，末尾再符号自检兜底，缺失走纯 Lua 回退。
    local function cdef(decl)
        pcall(ffi.cdef, decl)
    end
    cdef[[ typedef struct evp_cipher_st EVP_CIPHER; ]]
    cdef[[ typedef struct evp_md_st EVP_MD; ]]
    cdef[[ typedef struct engine_st ENGINE; ]]
    cdef[[ typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX; ]]
    cdef[[ EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void); ]]
    cdef[[ void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx); ]]
    cdef[[ int EVP_MD_size(const EVP_MD *md); ]]
    cdef[[ EVP_CIPHER *EVP_get_cipherbyname(const char *name); ]]
    cdef[[ const EVP_MD *EVP_get_digestbyname(const char *name); ]]
    cdef[[ int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *ctx, int pad); ]]
    cdef[[ int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher,
                    void *impl, const void *key, const void *iv); ]]
    cdef[[ int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, void *out, int *outl,
                    const void *in, int inl); ]]
    cdef[[ int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, void *out, int *outl); ]]
    cdef[[ int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher,
                    void *impl, const void *key, const void *iv); ]]
    cdef[[ int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, void *out, int *outl,
                    const void *in, int inl); ]]
    cdef[[ int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, void *out, int *outl); ]]
    cdef[[ int EVP_Digest(const void *data, unsigned long count,
                    unsigned char *md, unsigned int *size,
                    const EVP_MD *type, void *impl); ]]
    cdef[[ unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
                    const void *data, unsigned long data_len,
                    unsigned char *md, unsigned int *md_len); ]]

    -- 符号自检（审查 M12）：任一必需符号缺失 → 返回 nil 走纯 Lua 回退，
    -- 避免运行时 nil 索引被 bridge pcall 吞成 __error、加密层静默变砖
    local REQUIRED_SYMBOLS = {
        "EVP_CIPHER_CTX_new", "EVP_CIPHER_CTX_free", "EVP_MD_size",
        "EVP_get_cipherbyname", "EVP_get_digestbyname",
        "EVP_CIPHER_CTX_set_padding",
        "EVP_EncryptInit_ex", "EVP_EncryptUpdate", "EVP_EncryptFinal_ex",
        "EVP_DecryptInit_ex", "EVP_DecryptUpdate", "EVP_DecryptFinal_ex",
        "EVP_Digest", "HMAC",
    }
    for _, sym in ipairs(REQUIRED_SYMBOLS) do
        local oksym, v = pcall(function() return lib[sym] end)
        if not oksym or v == nil then
            return nil, ("libcrypto symbol missing: %s (cdef conflict?)")
                :format(sym)
        end
    end

    local function evpProcess(isEncrypt, cipher, key, iv, data)
        local ctx = lib.EVP_CIPHER_CTX_new()
        if ctx == nil then return nil, "EVP_CIPHER_CTX_new failed" end
        local initf = isEncrypt and lib.EVP_EncryptInit_ex
                                   or lib.EVP_DecryptInit_ex
        local updf = isEncrypt and lib.EVP_EncryptUpdate
                                 or lib.EVP_DecryptUpdate
        local finf = isEncrypt and lib.EVP_EncryptFinal_ex
                                 or lib.EVP_DecryptFinal_ex
        local okret, err
        -- 审查 C1：第 5 实参必须是 iv（cdata 缓冲或 nil/ECB）。
        -- 原实现误传 #key（Lua number 经 FFI 变成野地址 0x10），
        -- CBC/CFB/OFB 在真机上会从野地址读 IV → SIGSEGV 崩掉 KOReader。
        okret = initf(ctx, cipher, nil, key, iv)
        if okret ~= 1 then err = "EVP_*Init_ex failed" end
        if not err then
            okret = lib.EVP_CIPHER_CTX_set_padding(ctx, 0)
            if okret ~= 1 then err = "set_padding(0) failed" end
        end
        local out, outl = nil, nil
        if not err then
            out = ffi.new("unsigned char[?]", #data + 32)
            outl = ffi.new("int[1]")
            okret = updf(ctx, out, outl, data, #data)
            if okret ~= 1 then err = "EVP_*Update failed" end
        end
        local total = 0
        if not err then
            total = outl[0]
            local fl = ffi.new("int[1]")
            okret = finf(ctx, out + total, fl)
            -- 审查 L8（独立报告）：Final 失败原实现静默吞掉（err 仍为 nil），
            -- 输出截断数据。无填充模式 Final 正常返回 1 且 0 字节，
            -- 返回 0 即异常，必须报错。
            if okret == 1 then
                total = total + fl[0]
            else
                err = (isEncrypt and "EVP_EncryptFinal_ex failed"
                                    or "EVP_DecryptFinal_ex failed")
            end
        end
        lib.EVP_CIPHER_CTX_free(ctx)
        if err then return nil, err end
        return ffi.string(out, total)
    end

    local backend = {}
    function backend.aes(mode, isEncrypt, data, key, iv, blocksize)
        -- 审查 L7：blockSize=8 的 OFB 是 pointycastle 专有语义，
        -- OpenSSL 无法映射，显式拒绝（原先走无效 cipher 名才失败）
        if mode == "ofb" and blocksize == 8 then
            return nil, "unsupported cipher: ofb8 (pointycastle-specific; "
                .. "OpenSSL only provides full-block OFB)"
        end
        local cipher = lib.EVP_get_cipherbyname(cipherName(mode, #key, blocksize))
        if cipher == nil then
            return nil, ("unsupported cipher: %s/%d"):format(mode, #key * 8)
        end
        if (mode == "ecb" or mode == "cbc") and #data % 16 ~= 0 then
            return nil, "no-padding AES needs 16-byte aligned input (got "
                .. #data .. ")"
        end
        -- 审查 M4：上游 ofb 消息不带 IV（vendored init.js encryptAesOfb/
        -- decryptAesOfb 无 iv 字段）。对齐 pointycastle 无 IV 流模式语义：
        -- 以全零 IV 起始。S1 用真实源核实。
        if mode == "ofb" and (iv == nil or #iv == 0) then
            iv = string.rep("\0", 16)
        end
        local keybuf = ffi.new("unsigned char[?]", #key, key)
        local ivbuf = iv and ffi.new("unsigned char[?]", #iv, iv) or nil
        return evpProcess(isEncrypt, cipher, keybuf, ivbuf, data)
    end
    function backend.digest(name, data)
        local md = lib.EVP_get_digestbyname(DIGEST_MAP[name])
        if md == nil then return nil, "unknown digest: " .. tostring(name) end
        local size = lib.EVP_MD_size(md)
        local buf = ffi.new("unsigned char[?]", size)
        if lib.EVP_Digest(data, #data, buf, nil, md, nil) ~= 1 then
            return nil, "EVP_Digest failed"
        end
        return ffi.string(buf, size)
    end
    function backend.hmac(name, key, data)
        local md = lib.EVP_get_digestbyname(DIGEST_MAP[name])
        if md == nil then return nil, "unknown digest: " .. tostring(name) end
        local keybuf = ffi.new("unsigned char[?]", #key, key)
        local buf = ffi.new("unsigned char[?]", 64)
        local r = lib.HMAC(md, keybuf, #key, data, #data, buf, nil)
        if r == nil then return nil, "HMAC failed" end
        -- 依据 md 重建长度（HMAC 未返回 md_len 时退回查询）
        local size = lib.EVP_MD_size(md)
        return ffi.string(buf, size)
    end
    backend.name = "openssl"
    return backend
end

------------------------------------------------------------------------
-- 门面
------------------------------------------------------------------------
--- 后端构建结果进程内记忆：Convert.new() 有 4 个调用点（main.lua），
--- 真机 log 实证每次 new 都会重跑 7 次 ffi.load 探测（6 条失败）+ 30 余条
--- ffi.cdef，一次会话刷出上百行 logcat，且在桥接回调所在的执行帧里反复触发
--- FFI 内部表更新。失败同样记忆（不重复探测、不重复刷日志）。
local cached_backend, cached_probed = nil, false

--- Convert.new(backend) —— backend 可注入；nil 时尝试 openssl，再退纯 Lua。
function Convert.new(backend)
    local o = setmetatable({}, Convert)
    if backend then
        o.backend = backend
    else
        if not cached_probed then
            local okb, b = pcall(opensslBackend)
            cached_backend = (okb and b) or nil
            cached_probed = true
        end
        o.backend = cached_backend
    end
    return o
end

function Convert:_requireBackend(op)
    if not self.backend then
        return nil, ("crypto backend unavailable (%s)"):format(op)
    end
    return self.backend
end

-- Convert API（参数与 init.js Convert.* 一致；data/key/iv 为 Lua 字节串）
function Convert:aes(mode, isEncrypt, data, key, iv, blocksize)
    local b = self:_requireBackend("aes." .. mode)
    if not b then return nil, "crypto backend unavailable" end
    return b.aes(mode, isEncrypt, data, key, iv, blocksize)
end

function Convert:digest(name, data)
    local b = self:_requireBackend("digest " .. name)
    if not b then return nil, "crypto backend unavailable" end
    return b.digest(name, data)
end

function Convert:hmac(name, key, data)
    local b = self:_requireBackend("hmac " .. name)
    if not b then return nil, "crypto backend unavailable" end
    return b.hmac(name, key, data)
end

Convert.hex = Convert.hexEncode
Convert.b64encode = Convert.base64Encode

function Convert.b64decode(data)
    return Convert.base64Decode(data)
end

-- utf8：Lua 字节串即 UTF-8（经 JSON 桥传递），编码=透传
function Convert:encodeUtf8(text) return text end
function Convert:decodeUtf8(bytes) return bytes end

-- GBK：P2（T21）
function Convert:encodeGbk() return nil, "GBK unsupported in this build" end
function Convert:decodeGbk() return nil, "GBK unsupported in this build" end

return Convert
