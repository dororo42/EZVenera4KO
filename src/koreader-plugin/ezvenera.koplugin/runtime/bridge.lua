--[[
EZVenera for KOReader — runtime/bridge.lua
sendMessage 宿主 API 的 Lua 侧分发层。REQ: R3.2。

职责：把 init.js 的 sendMessage JSON 消息分派到 Lua 实现（netclient / convert /
cookies / storage …），返回 JSON 可序列化结果或 {__error = "..."}。

消息形状对齐 vendored/init.js（G6 Pass A 已逐字段核实）：
  convert : {method, type="utf8|gbk|base64|md5|sha1|sha256|sha512|hmac|
             aes-ecb|aes-cbc|aes-cfb|aes-ofb|rsa", value, key?, iv?,
             blockSize?, hash?, isEncode, isString?}
  http    : {method:'http', http_method, url, headers, data?, bytes?, extra?}
  cookie  : {method:'cookie', function:'set'|'get'|'delete', url, cookies?}
  数据    : {method:'load_data'|'save_data'|'delete_data', key:<源key>,
             data_key:<槽位>, data?}
  设置    : {method:'load_setting', key:<源key>, setting_key}
  isLogged: {method:'isLogged', key:<源key>}
  random  : {method:'random', type:'int'|'double', min, max}
  delay   : {method:'delay', time:<ms>}
  uuid    : {method:'uuid'}

字节串跨桥约定：二进制以 {__bytes_b64 = "..."} 标记；字符串原样传递。
JS→Lua 方向由 jshost 的 glue（sendMessage 前遍历标记）；Lua→JS 方向由
glue 的 __ezv_untag_bytes 还原为 ArrayBuffer（2026-09-20 实现，design.md §3.2）。
]]

local Bridge = {}
Bridge.__index = Bridge

local function b64wrap(luastring)
    local Convert = require("runtime/convert")
    return { __bytes_b64 = Convert.base64Encode(luastring) }
end

local function b64unwrap(v)
    if type(v) == "table" and v.__bytes_b64 then
        local Convert = require("runtime/convert")
        return Convert.base64Decode(v.__bytes_b64)
    end
    if type(v) == "string" then return v end
    return nil
end

-- ---- 默认按源存储：runtime/sourcedata.lua（与源参数配置界面同一份文件，
--      两边各写一份会互相看不到）----
local SourceData = require("runtime/sourcedata")
local defaultStorage = SourceData.makeStorage

-- R3-L3：uuid/random 依赖的显式播种（KOReader 启动路径不保证 randomseed）
math.randomseed(os.time() + math.floor((os.clock() % 1) * 100000))

function Bridge.new(deps)
    deps = deps or {}
    local o = setmetatable({}, Bridge)
    o.settings = deps.settings
    o.netclient = deps.netclient
    o.convert = deps.convert
    o.cookies = deps.cookies
    o.storage = deps.storage or defaultStorage()
    -- M2 T15：HTML 解析引擎（句柄表）。deps.htmlparse 供单测注入。
    if deps.htmlparse then
        o.html_engine = deps.htmlparse
    else
        local okHP, HtmlParse = pcall(require, "runtime/htmlparse")
        o.html_engine = okHP and HtmlParse.newEngine() or nil
    end
    -- json 编码器（审查 M6：http data 为对象时 JSON 化）。可注入供单测；
    -- 未注入时运行时回退 require("json")（KOReader 内建）。
    o.json = deps.json
    o.platform = deps.platform or "koreader"
    o.locale = deps.locale or "zh_CN"
    return o
end

local handlers = {}

-- ---- 数据（key=源key，data_key=槽位；save_data 的值字段为 data）----

local function sourceMap(self, sourceKey)
    if not sourceKey then return nil end
    return self.storage.load(sourceKey)
end

handlers["load_data"] = function(self, msg)
    local map = sourceMap(self, msg.key)
    return (map or {})[msg.data_key]
end

handlers["save_data"] = function(self, msg)
    if not msg.key or msg.data_key == nil then return false end
    local map = sourceMap(self, msg.key) or {}
    map[msg.data_key] = msg.data
    self.storage.save(msg.key, map)
    return true
end

handlers["delete_data"] = function(self, msg)
    local map = sourceMap(self, msg.key)
    if map and msg.data_key ~= nil then
        map[msg.data_key] = nil
        self.storage.save(msg.key, map)
    end
    return true
end

handlers["load_setting"] = function(self, msg)
    local map = sourceMap(self, msg.key)
    local v = map and map["settings"] and map["settings"][msg.setting_key]
    -- 未设置时返回 nil（→ JS 侧 undefined）：声明的 default 由 jshost 注册处
    -- 包装的 loadSetting 补齐（那里才拿得到源实例的 settings 声明表）。
    -- 这里不要改成返回 ""：会把"未设置"和"用户选了空值"混为一谈。
    return v
end

handlers["isLogged"] = function(self, msg)
    -- 判定规则唯一来源见 runtime/sourcedata.lua（界面与桥必须同答案）
    return SourceData.isLoggedMap(sourceMap(self, msg.key))
end

-- ---- http（http_method 为动词字段；data 为请求体；bytes 决定 body 形态）----

handlers["http"] = function(self, msg)
    if not msg.url then return { __error = "http: missing url" } end
    local headers = {}
    for k, v in pairs(msg.headers or {}) do
        headers[k] = v
    end
    -- cookie 合并（Venera：jar cookie 与插件头合并）。
    -- 审查 M9：结果只保留一个 cookie 头（大写规范形），删除小写键，
    -- 否则 luasocket 会发出两条 Cookie 头，部分服务端只取第一条导致鉴权异常。
    local cookieheader = self.cookies and self.cookies:headerFor(msg.url)
    if cookieheader then
        local existing = headers["cookie"] or headers["Cookie"]
        headers["Cookie"] = existing and (existing .. "; " .. cookieheader)
            or cookieheader
        headers["cookie"] = nil
    end
    -- 审查 M6：请求体形态收口。init.js sendRequest 对 data 不做类型约束，
    -- 不少源直接传 JS 对象（JSON 体）或数字——原实现仅认字符串/
    -- {__bytes_b64}，对象形态被静默丢弃成空 body（接口神秘 4xx）。
    local body
    local dtype = type(msg.data)
    if dtype == "string" then
        body = msg.data
    elseif dtype == "table" and msg.data.__bytes_b64 ~= nil then
        body = b64unwrap(msg.data)
    elseif dtype == "table" or dtype == "number" or dtype == "boolean" then
        local jsonenc = self.json
        if not jsonenc then
            local okj, jsonmod = pcall(require, "json")
            if okj and jsonmod then jsonenc = jsonmod end
        end
        if jsonenc then
            local oke, s = pcall(function() return jsonenc.encode(msg.data) end)
            if oke and type(s) == "string" then body = s end
        end
        -- json 不可用/编码失败 → body 保持 nil（空 body），不抛错
    end
    local proxy = nil
    if self.settings then
        proxy = (self.settings:isProxyEnabled())
            and self.settings:getProxyURL() or ""
        -- 显式禁用也传空串：不受 KOReader 全局 PROXY 影响（ADR-003）
    end
    local resp = self.netclient:request({
        url = msg.url,
        method = msg.http_method or "GET",
        headers = headers,
        body = body,
        proxy = proxy,
    })
    -- 记录 set-cookie
    if self.cookies then
        pcall(function()
            self.cookies:storeFromResponse(msg.url, resp.headers)
        end)
    end
    local out = { status = resp.status, headers = resp.headers,
                  error = resp.error }
    if resp.body ~= nil then
        if msg.bytes then
            out.body = b64wrap(resp.body)
        else
            out.body = resp.body
        end
    end
    return out
end

-- ---- convert（type 分派；二进制一律 {__bytes_b64} 标记）----

handlers["convert"] = function(self, msg)
    local C = self.convert
    if not C then return { __error = "convert backend unavailable" } end
    local t = msg.type
    local v = msg.value
    local isEncode = msg.isEncode == true

    local function bytesOrErr(d, err)
        if d == nil then return { __error = err or "convert failed" } end
        return b64wrap(d)
    end

    if t == "utf8" then
        -- encode: JS 字符串（JSON 内已是 UTF-8 字节串）→ ArrayBuffer
        -- decode: ArrayBuffer → 字符串
        if isEncode then
            return b64wrap(tostring(v))
        end
        return C:decodeUtf8(b64unwrap(v) or "")
    elseif t == "gbk" then
        return { __error = "GBK unsupported in this build (T21)" }
    elseif t == "base64" then
        if isEncode then
            local raw = b64unwrap(v)
            if raw == nil then
                return { __error = "encodeBase64: bad input" }
            end
            return C.base64Encode(raw)
        end
        local d, err = C.base64Decode(v)
        if d == nil then return { __error = err or "decodeBase64 failed" } end
        return b64wrap(d)
    elseif t == "md5" or t == "sha1" or t == "sha256" or t == "sha512" then
        local d, err = C:digest(t, b64unwrap(v) or "")
        return bytesOrErr(d, err)
    elseif t == "hmac" then
        local d, err = C:hmac(msg.hash, b64unwrap(msg.key) or "",
                              b64unwrap(v) or "")
        if d == nil then return { __error = err or "hmac failed" } end
        if msg.isString then return C.hexEncode(d) end
        return b64wrap(d)
    elseif t == "rsa" then
        return { __error = "RSA decrypt not implemented in this build (T14)" }
    elseif type(t) == "string" and t:match("^aes%-") then
        local mode = t:match("^aes%-(%a+)$")
        local iv = nil
        if mode == "cbc" or mode == "cfb" then
            iv = b64unwrap(msg.iv)
        end
        local blocksize = tonumber(msg.blockSize) or 16
        local d, err = C:aes(mode, isEncode, b64unwrap(v) or "",
                             b64unwrap(msg.key) or "", iv, blocksize)
        return bytesOrErr(d, err)
    end
    return { __error = "convert: unknown type " .. tostring(t) }
end

-- ---- cookie（动作字段为 function）----

handlers["cookie"] = function(self, msg)
    local action = msg["function"]
    if action == "set" then
        local n = self.cookies:setCookies(msg.url, msg.cookies or {})
        return n
    elseif action == "get" then
        local list = self.cookies:getCookies(msg.url)
        for _, ck in ipairs(list) do
            ck.httpOnly = ck.httpOnly or false
            ck.secure = ck.secure or false
        end
        -- init.js:595-605 getCookies 声明 Promise<Cookie[]>，源侧常直接
        -- .map/.find → 空结果必须是 []（见 runtime/htmlparse.lua ARRAY_OPS）
        if #list == 0 then return { __empty_array = true } end
        return list
    elseif action == "delete" then
        return self.cookies:deleteCookies(msg.url)
    end
    return { __error = "cookie: unknown action " .. tostring(action) }
end

-- ---- misc ----

handlers["log"] = function(self, msg)
    -- EZVenera 语义：丢弃（engine:109-110）
    return nil
end

handlers["random"] = function(self, msg)
    local lo, hi = tonumber(msg.min) or 0, tonumber(msg.max) or 1
    if msg.type == "int" then
        return math.random(math.floor(lo), math.floor(hi))
    end
    return lo + math.random() * (hi - lo)
end

handlers["uuid"] = function(self, msg)
    -- 时间版 v1（与 EZVenera 的 time-based UUID v1 语义近似即可）
    local t = os.time() * 1000000 + math.floor((os.clock() % 1) * 1000000)
    local hex = string.format("%012x", t % 281474976710656)  -- 2^48
    return hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-1"
        .. string.format("%03x", math.random(0, 4095)) .. "-8"
        .. string.format("%03x", math.random(0, 4095)) .. "-"
        .. string.format("%012x", math.random(0, 281474976710655))
end

handlers["delay"] = function(self, msg)
    -- init.js: {method:'delay', time:<ms>}；jshost 转 setTimeout 异步（S2）
    return { __delay_ms = tonumber(msg.time) or 0 }
end

handlers["getLocale"] = function(self, msg) return self.locale end
handlers["getPlatform"] = function(self, msg) return self.platform end

handlers["setClipboard"] = function(self, msg)
    -- KOReader v2026 规范 API 是 Device.input.*（旧 getClipboard/
    -- setInputClipboard 不存在，源侧剪贴板功能此前静默失效）
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.input
            and Device.input.setClipboardText then
        local okc = pcall(function()
            Device.input.setClipboardText(tostring(msg.text or ""))
        end)
        return okc
    end
    return nil
end

handlers["getClipboard"] = function(self, msg)
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.input
            and Device.input.getClipboardText then
        local okt, txt = pcall(function()
            return Device.input.getClipboardText()
        end)
        if okt then return txt end
    end
    return nil
end

-- ---- 桩（明确错误 / 上游同语义 null）----

handlers["html"] = function(self, msg)
    if not self.html_engine then
        return { __error = "html parser unavailable (htmlparse load failed)" }, true
    end
    return self.html_engine:handle(msg)
end

handlers["image"] = function(self, msg)
    return { __error = "image ops not available in this build (M3, T20)" }
end

handlers["compute"] = function(self, msg)
    return { __error = "compute() pool not supported on koreader" }
end

handlers["UI"] = function(self, msg)
    return nil  -- 与 EZVenera engine:142-143 一致：未实现，静默 null
end

--- 主分派。msg 为已解码 table（含 method）。返回 (value, is_error)。
function Bridge:handle(msg)
    if type(msg) ~= "table" or not msg.method then
        return { __error = "bridge: bad message" }, true
    end
    local h = handlers[msg.method]
    if not h then
        return { __error = "bridge: unknown method " .. tostring(msg.method) },
            true
    end
    local ok, result = pcall(h, self, msg)
    if not ok then
        return { __error = "bridge handler error: " .. tostring(result) }, true
    end
    -- 审查 L11（独立报告）：`__error` 是桥保留标记，但 load_data 等返回的
    -- 业务数据理论上可能恰好带同名字段，被误判为桥错误并在 JS 侧抛异常。
    -- 收紧判定：仅当 __error 是表中【唯一】键时才判为错误——所有桥错误
    -- 返回恒为 { __error = "..." } 单键形状，业务数据撞上同形（只有
    -- __error 一个字段的 JSON 对象）属病态情形，误伤面可忽略。
    if type(result) == "table" and result.__error ~= nil then
        local first = next(result)
        if next(result, first) == nil then
            return result, true
        end
    end
    return result, false
end

return Bridge
