--[[
EZVenera for KOReader — runtime/jshost.lua
QuickJS 引擎宿主（LuaJIT FFI）。REQ: R1.4（优雅降级）、R6.2。

【S2/T19 桥接架构（C shim，已落地）】审查 M1 修订（LuaJIT 2.1 官方
ext_ffi_semantics #callback 原文）："Neither C vararg functions nor
functions with pass-by-value aggregate argument or result types are
supported." —— FFI 回调按值返回 JSValue（16B 结构体）全架构文档明确
不支持，纯 FFI 注册路线已废弃。现行方案 = 真 C 层 shim
（shim/ezvbridge.c → lib/libezvbridge.so，scripts/build-shim.sh）：
  - C 侧负责 JSValue 包装与按值返回（JS_NewCFunction/JS_NewStringLen），
    __ezv_post 以 JSContext opaque 存储回调（每上下文独立，多实例安全）；
  - Lua 侧回调签名降为纯指针 const char* (*)(void*, const char*)，
    属 LuaJIT FFI 文档支持范围（ADR-004 路线 C）；
  - 消息编解码逻辑统一在 _bridgeHandler，回调体内整体 pcall，
    绝不让错误跨越 C 栈帧。
shim 缺失/安装失败 → 引擎保持"可用性探测通过但初始化失败且原因明确"。

消息桥 M1 为同步返回：__ezv_post(jsonStr) → JS 字符串结果。
delay 返回 __delay_ms 标记，异步调度在 S2 后续接入。

加载探测：插件 lib/（pluginloader 已加入 package.cpath）→ 系统名。
]]

local oklog, logger = pcall(require, "logger")
if not oklog or not logger then logger = nil end
local function logwarn(...) if logger and logger.warn then logger.warn(...) end end

local JsHost = {}
JsHost.__index = JsHost

-- 与自编译 .so 锁定的 quickjs 常量（quickjs.h 值域，构建脚本固定版本）
local JS_TAG_NULL = 2
local JS_TAG_UNDEFINED = 3
local JS_TAG_EXCEPTION = 6
local JS_EVAL_TYPE_GLOBAL = 0

local QUICKJS_GLUE = [=[
// ---- 二进制桥（审查 M3，2026-09-20）：ArrayBuffer/TypedArray <-> {__bytes_b64} ----
// JS→Lua：sendMessage 前遍历消息，把二进制替换为标记表（glue 侧唯一入口）；
// Lua→JS：响应解析后递归还原 __bytes_b64 为 ArrayBuffer。
// 与 bridge.lua 的 b64wrap/b64unwrap、design.md §3.2 对齐。
// Lua→JS 同一路径还原 {__empty_array:true} → []：Lua 空表无法表达
// "数组"（luaJSON 1.3.5 会编成 {}），见 runtime/htmlparse.lua ARRAY_OPS。
var __ezv_b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
var __ezv_b64_table = null;
function __ezv_b64encode(data) {
    const u8 = new Uint8Array(data);
    let out = "";
    let i = 0;
    for (; i + 2 < u8.length; i += 3) {
        const n = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
        out += __ezv_b64_chars[(n >>> 18) & 63] + __ezv_b64_chars[(n >>> 12) & 63]
            + __ezv_b64_chars[(n >>> 6) & 63] + __ezv_b64_chars[n & 63];
    }
    const rem = u8.length - i;
    if (rem === 1) {
        out += __ezv_b64_chars[(u8[i] >>> 2) & 63] + __ezv_b64_chars[(u8[i] & 3) << 4] + "==";
    } else if (rem === 2) {
        const n2 = (u8[i] << 8) | u8[i + 1];
        out += __ezv_b64_chars[(n2 >>> 10) & 63] + __ezv_b64_chars[(n2 >>> 4) & 63]
            + __ezv_b64_chars[(n2 & 15) << 2] + "=";
    }
    return out;
}
function __ezv_b64decode(s) {
    if (__ezv_b64_table === null) {
        __ezv_b64_table = {};
        for (let i = 0; i < __ezv_b64_chars.length; i++) {
            __ezv_b64_table[__ezv_b64_chars[i]] = i;
        }
    }
    s = s.replace(/[^A-Za-z0-9+\/=]/g, "").replace(/=+$/, "");
    const out = new Uint8Array(Math.floor(s.length * 3 / 4));
    let acc = 0, bits = 0, o = 0;
    for (let i = 0; i < s.length; i++) {
        acc = ((acc << 6) | __ezv_b64_table[s[i]]) & 0xffffff;
        bits += 6;
        if (bits >= 8) { bits -= 8; out[o++] = (acc >>> bits) & 255; }
    }
    return out;   // 合法输入下 o === out.length，.buffer 即精确字节
}
function __ezv_tag_bytes(v, depth) {
    if (v === null || v === undefined) return v;
    if (v instanceof ArrayBuffer) return { __bytes_b64: __ezv_b64encode(v) };
    if (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView(v)) {
        return { __bytes_b64: __ezv_b64encode(
            new Uint8Array(v.buffer, v.byteOffset, v.byteLength)) };
    }
    if (depth > 8) return v;
    if (Array.isArray(v)) {
        const a = new Array(v.length);
        for (let i = 0; i < v.length; i++) a[i] = __ezv_tag_bytes(v[i], depth + 1);
        return a;
    }
    if (typeof v === "object") {
        const o = {};
        for (const k in v) o[k] = __ezv_tag_bytes(v[k], depth + 1);
        return o;
    }
    return v;
}
function __ezv_untag_bytes(v, depth) {
    if (v === null || typeof v !== "object") return v;
    if (v.__bytes_b64 !== undefined) return __ezv_b64decode(v.__bytes_b64).buffer;
    if (v.__empty_array === true) return [];
    if (depth > 8) return v;
    if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) v[i] = __ezv_untag_bytes(v[i], depth + 1);
        return v;
    }
    for (const k in v) v[k] = __ezv_untag_bytes(v[k], depth + 1);
    return v;
}
function sendMessage(m) {
    const r = __ezv_post(JSON.stringify(__ezv_tag_bytes(m, 0)));
    const v = (r == null) ? null : JSON.parse(r);
    if (v && v.__error) { throw new Error(v.__error); }
    const out = (v == null) ? null : __ezv_untag_bytes(v, 0);
    if (out && typeof out.__delay_ms === "number") {
        // H1（审查报告 §10/§2-H1，2026-09-25）：init.js:26-31 的 setTimeout
        // 契约是 sendMessage({delay}).then(callback)——裸对象无 .then 必炸。
        // 同步桥没有事件循环：注册进 __ezv_timers 队列，由 jshost:pump()
        // 每拍排空（eval 边界 + main.lua 周期泵）。**不得**同步 resolve：
        // setInterval 自续链会变成忙等冻结主循环。
        const t = { at: Date.now() + out.__delay_ms, fn: null };
        __ezv_timers.push(t);
        return { __delay_ms: out.__delay_ms,
                 then: function(fn) { t.fn = fn; } };
    }
    return out;
}
var __ezv_timers = [];
function __ezv_poll_timers(now_ms) {
    var fired = 0;
    var remain = [];
    for (var i = 0; i < __ezv_timers.length; i++) {
        var t = __ezv_timers[i];
        if (t.at <= now_ms && typeof t.fn === "function" && fired < 64) {
            fired++;
            try { t.fn(t); } catch (e) {}
        } else {
            remain.push(t);
        }
    }
    __ezv_timers = remain;
    return fired;
}
]=]

-- 与 EZVenera parser:26-50 相同的行扫描类检测
local function lineScanClass(jscode)
    local normalized = jscode:gsub("\r\n", "\n")
    local classname
    for line in normalized:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:sub(1, 6) == "class " then
            if not trimmed:find("extends%s+ComicSource") then
                return nil, "missing ComicSource class"
            end
            classname = trimmed:match("^class%s+([%w_]+)%s+extends")
            break
        end
    end
    if not classname then
        return nil, "no 'class X extends ComicSource' line found"
    end
    return classname
end

--- 剥掉 ESM 包装语法，返回 (纯脚本代码, 剥掉的行数)。
--- 为什么必须剥：registerSource 是把整段源塞进 `(()=>{ … })()` 用
--- JS_Eval(GLOBAL) 求值的，而 `import` / `export` 按 JS 规范只允许出现在
--- Module 顶层，函数体内出现就是硬 SyntaxError。上游 EZvenera-config 的
--- .js 是 `class X extends ComicSource` 纯脚本（无 export），但移植流水线
--- 与社区源普遍输出 ESM 形式（末尾 `export default XxxSource;`，甚至
--- `export default class X extends ComicSource`）——2026-09-24 核查一份
--- 31 个源的移植包，31/31 都带 export 尾行，不剥就是整包注册失败。
--- 只做「去掉包装行/包装关键字」这一件事：逐行锚定，其余字节原样保留；
--- 一行都没剥时直接返回入参本体，保证无 export 的老源逐字节不变。
local function stripModuleSyntax(jscode)
    local dropped = 0
    local out = {}
    -- gmatch 前补一个 \n，保证最后一行（可能没有换行符）也被扫到
    for line in (jscode .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$")
        local repl
        if t:match("^export%s+default%s+class%s") then
            -- `export default class X extends ComicSource {` → 留 `class X …`
            repl = t:gsub("^export%s+default%s+", "")
        elseif t:match("^export%s+default%s+[%w_$.]+%s*;?$")
                or t:match("^export%s*{[^{}]*}%s*;?$")
                or t:match("^import%s*{[^{}]*}%s*from%s*['\"].-['\"]%s*;?$")
                or t:match("^import%s+[%w_$.]+%s+from%s*['\"].-['\"]%s*;?$") then
            -- 纯包装行（默认导出标识 / 具名导出 / 静态 import）→ 整行去掉
            repl = ""
        end
        if repl ~= nil then
            dropped = dropped + 1
            if repl ~= "" then table.insert(out, repl) end
        else
            table.insert(out, line)
        end
    end
    if dropped == 0 then return jscode, 0 end
    -- 只在真的动过时才重组（顺带把 CRLF 归一成 LF，求值语义不变）
    return (table.concat(out, "\n"):gsub("\r\n", "\n")), dropped
end

--- 求值前的统一入口：剥 ESM 包装 + 找源类名。
--- 返回 (script, classname) 或 (nil, err)。暴露给单测直接覆盖四条 ESM 形态。
function JsHost.normalizeSourceJs(jscode)
    if type(jscode) ~= "string" or jscode == "" then
        return nil, "empty source"
    end
    local script = stripModuleSyntax(jscode)
    local classname, err = lineScanClass(script)
    if not classname then return nil, err end
    return script, classname
end

--- Android 平台探测（R-D2）：SELinux 拒绝从 sdcard dlopen（avc denied，
--- M2 实测 2026-09-22），但 Android <10 的 untrusted_app 域允许从 app 私有
--- 目录 /data/data/<pkg>/files 加载。进程 uid 即 app，os.execute 拷贝可行。
--- 流程：常规探测失败 → 若 android.isAndroid() → 拷 lib/*.so 到私有目录
--- → 重试。API29+ 设备上私有目录 dlopen 也被禁时，拷贝无害、失败原因不变。
local function androidPrivateDir()
    -- launcher 进程私有目录（app uid 可写；fdroid 包名固定）。
    -- R-D2v4：不 fork/exec（os.execute 在 LuaJIT+FFI 进程内 SIGSEGV 实测
    -- 2026-09-22 21:54），mkdir 用 lfs，可写性用 io.open 探针。
    local oklfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local candidates = {
        "/data/data/org.koreader.launcher.fdroid/files/ezvlib",
        "/data/data/org.koreader.launcher/files/ezvlib",
    }
    for _, d in ipairs(candidates) do
        if oklfs and lfs and lfs.mkdir then
            pcall(lfs.mkdir, d)
        end
        local probe = d .. "/.probe"
        local f = io.open(probe, "w")
        if f then
            f:write("1")
            f:close()
            os.remove(probe)
            return d
        end
    end
    return nil
end


local function probeLib()
    local ffi = require("ffi")
    local candidates = {
        "libquickjs",  -- 链接器默认路径 = APK lib/arm64（T-S3 分发的匹配引擎）
        "quickjs",
        "ezvenera/libquickjs",
    }
    -- 【真机崩溃 RCA 2026-09-25】插件目录候选已**整体移除**：
    -- package.cpath 含 <plugin>/lib/?.so（pluginloader.lua:243），一旦
    -- 设备上残留旧版 libquickjs.so（如 2026-09-22 的 857KB 本地产物），
    -- 它会以同名遮蔽 APK 注入的匹配引擎——旧引擎 + 新泵双参 ABI =
    -- SIGSEGV fault addr 0x0（tombstone：#00 libquickjs+e3f8 ← #01
    -- libluajit，与 R-D2v5 签名一致）。引擎只信 APK / 系统路径；
    -- 桌面开发请用 LD_LIBRARY_PATH 或 luarocks 安装。
    local lib_err
    for _, name in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            return lib, name
        end
        lib_err = tostring(lib)
    end
    -- R-D2v5（2026-09-22 22:04 三次 SIGSEGV 实锤后最终处置）：Android 上
    -- 禁用运行时 dlopen 引擎——sdcard 被 SELinux 拒（avc denied execute），
    -- 私有目录副本 dlopen 直接 SIGSEGV（Android 6 厂商 ROM linker，死亡点
    -- ffi.load 本身、无 Lua 栈）。引擎在 Android 需随 APK 分发（T-S3）。
    -- 索引/安装/清单管理为纯 Lua，不受影响。
    local DeviceOK, Device = pcall(require, "device")
    if DeviceOK and Device and Device.isAndroid and Device:isAndroid() then
        return nil, "Android 平台引擎需随 APK 分发（SELinux 禁止从存储"
            .. "加载 .so；私有目录 dlopen 触发系统 linker 崩溃）。"
            .. "源管理功能不受影响。"
    end
    return nil, "libquickjs not found (tried: " .. table.concat(candidates, ", ")
        .. "); last: " .. tostring(lib_err)
end

--- 探测桥接 C shim（S2/T19，lib/libezvbridge.so，由 shim/ezvbridge.c 编译）
local function probeShim()
    local ffi = require("ffi")
    -- 【同 RCA】插件目录候选移除：旧 libezvbridge.so 遮蔽 APK 版 =
    -- shim/引擎版本错配（与 probeLib 同一根因，2026-09-25 真机 SIGSEGV）
    local candidates = {
        "libezvbridge",   -- 链接器默认路径 = APK lib/arm64
        "ezvenera/libezvbridge",
    }
    for _, name in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            return lib, name
        end
    end
    -- Android 回退：私有目录副本重试（R-D2，同 probeLib）
    local DeviceOK, Device = pcall(require, "device")
    if DeviceOK and Device and Device.isAndroid and Device:isAndroid() then
        local privpath = androidPrivateDir()
        if privpath then
            local okp, libp = pcall(ffi.load, privpath .. "/libezvbridge.so")
            if okp and libp then
                return libp, privpath .. "/libezvbridge.so"
            end
            logger.warn("ezvenera: private shim dlopen failed:", tostring(libp))
        end
    end
    return nil, "libezvbridge (C shim) not found (tried: "
        .. table.concat(candidates, ", ") .. ")"
end

function JsHost.new(opts)
    opts = opts or {}
    local o = setmetatable({}, JsHost)
    o.lib = opts.lib
    o.libname = opts.libname
    o.shim = opts.shim          -- S2/T19：可注入假 shim 供单测
    o.memlimit = opts.memlimit or 8 * 1024 * 1024
    o.initialized = false
    o.available = nil   -- nil=未探测
    o.reason = nil
    o.sources = {}      -- key → meta
    return o
end

function JsHost:status()
    if self.available == nil then
        self:_probe()
    end
    return {
        available = self.available,
        libname = self.libname,
        reason = self.reason,
        initialized = self.initialized,
        sources = self.sources,
    }
end

function JsHost:_probe()
    if self.lib == nil then
        local lib, name = probeLib()
        if not lib then
            self.available = false
            self.reason = name
            return false
        end
        self.lib = lib
        self.libname = name
    end
    self.available = true
    return true
end

-- 逐条 cdef（审查 M12）：ffi.cdef 按调用原子生效——同块任一符号与已加载的
-- KOReader 同名声明冲突会令整块失效、其余符号静默缺失。拆到单条后由
-- missingSymbols 在 init 时兜底自检（缺失 → 明确降级，不做隐性变砖）。
local function cdefAll(ffi)
    local function cdef(decl)
        pcall(ffi.cdef, decl)
    end
    cdef[[ typedef struct JSRuntime JSRuntime; ]]
    cdef[[ typedef struct JSContext JSContext; ]]
    cdef[[ typedef union JSValueUnion {
            int32_t int32;
            double float64;
            void *ptr;
            int32_t short_big_int;
        } JSValueUnion; ]]
    cdef[[ typedef struct JSValue {
            JSValueUnion u;
            int64_t tag;
        } JSValue; ]]
    cdef[[ typedef JSValue JSValueConst; ]]
    cdef[[ JSRuntime *JS_NewRuntime(void); ]]
    cdef[[ void JS_FreeRuntime(JSRuntime *rt); ]]
    cdef[[ JSContext *JS_NewContext(JSRuntime *rt); ]]
    cdef[[ void JS_FreeContext(JSContext *ctx); ]]
    cdef[[ void JS_SetMemoryLimit(JSRuntime *rt, size_t limit); ]]
    cdef[[ JSValue JS_Eval(JSContext *ctx, const char *source, size_t source_len,
                    const char *filename, int flags); ]]
    cdef[[ JSValue JS_GetException(JSContext *ctx); ]]
    -- 【ABI 红线】quickjs-ng 真实签名是双参 (rt, JSContext **pctx)。
    -- 曾按单参声明：arm64 第二实参寄存器为垃圾指针，仅当确有 job 可执行时
    -- quickjs 写 *pctx → 野指针 SIGSEGV（即历史"pump 回调竞态"真相，
    -- 见 2026-09-23 独立评估报告 R1）。pctx 一律显式传 NULL。
    cdef[[ int JS_ExecutePendingJob(JSRuntime *rt, JSContext **pctx); ]]
    cdef[[ const char *JS_ToCStringLen2(JSContext *ctx, size_t *plen,
                    JSValueConst val, bool cesu8); ]]
    cdef[[ void JS_FreeCString(JSContext *ctx, const char *ptr); ]]
    cdef[[ void JS_FreeValue(JSContext *ctx, JSValue val); ]]
    cdef[[ JSValue JS_NewCFunction2(JSContext *ctx, JSValue (*fn)
                    (JSContext *ctx, JSValueConst this_val, int argc,
                     JSValueConst *argv), const char *name, int length,
                    int cproto, int magic); ]]
    cdef[[ JSValue JS_GetGlobalObject(JSContext *ctx); ]]
    cdef[[ int JS_SetPropertyStr(JSContext *ctx, JSValueConst this_obj,
                          const char *prop_name, JSValue val); ]]
    cdef[[ JSValue JS_NewStringLen(JSContext *ctx, const char *buf, size_t len); ]]
end

local REQUIRED_JS_SYMBOLS = {
    "JS_NewRuntime", "JS_FreeRuntime", "JS_NewContext", "JS_FreeContext",
    "JS_SetMemoryLimit", "JS_Eval", "JS_GetException", "JS_ExecutePendingJob",
    "JS_ToCStringLen2", "JS_FreeCString", "JS_FreeValue", "JS_NewCFunction2",
    "JS_GetGlobalObject", "JS_SetPropertyStr", "JS_NewStringLen",
}

--- 必需符号自检；返回缺失清单（nil = 全部可用）
local function missingSymbols(lib)
    local missing = {}
    for _, name in ipairs(REQUIRED_JS_SYMBOLS) do
        local ok, v = pcall(function() return lib[name] end)
        if not ok or v == nil then missing[#missing + 1] = name end
    end
    if #missing == 0 then return nil end
    return table.concat(missing, ", ")
end

function JsHost:init(bridge, json, init_js_code)
    if self.initialized then return true end
    if not self:status().available then
        return false, self.reason
    end
    local ffi = require("ffi")
    cdefAll(ffi)
    -- 审查 M12：cdef 冲突可能导致符号静默缺失，init 前显式自检
    local missing = missingSymbols(self.lib)
    if missing then
        self.reason = "quickjs symbols missing: " .. missing
        self.available = false
        return false, self.reason
    end
    -- 【ABI 红线 · 仅 64 位成立】quickjs-ng v0.17.0 quickjs.h:171-177 在
    -- `INTPTR_MAX < INT64_MAX`（即 32 位构建）时自动开启 JS_NAN_BOXING，
    -- 彼时 JSValue 是裸 uint64_t 且 tag 在高 32 位；上面的 struct cdef 与
    -- JS_TAG_* 常量按 "u + int64 tag" 布局写死。32 位上继续用会把值载荷当
    -- 指针交给 JS_FreeValue → 对任意地址做减一写 → 表现为 LuaJIT GC 表
    -- 指针被破坏后的 SIGSEGV。恢复 Kindle 32 位构建（build-quickjs.sh
    -- kindle 目标）时必须先按 NaN-boxed 形式重写这层绑定。
    if ffi.sizeof("void *") < 8 then
        self.reason = "32-bit LuaJIT: quickjs JSValue is NaN-boxed there, " ..
            "struct bindings refused (see jshost.lua ABI note)"
        self.available = false
        return false, self.reason
    end
    self.bridge = bridge
    local okjson, jsonmod = pcall(require, "json")
    self.json = json or (okjson and jsonmod or nil)
    if not self.json then
        self.reason = "json module unavailable"
        self.available = false
        return false, self.reason
    end
    self.rt = self.lib.JS_NewRuntime()
    if self.rt == nil then
        self.reason = "JS_NewRuntime failed"
        self.available = false
        return false, self.reason
    end
    self.lib.JS_SetMemoryLimit(self.rt, self.memlimit)
    self.ctx = self.lib.JS_NewContext(self.rt)
    if self.ctx == nil then
        self.reason = "JS_NewContext failed"
        self.available = false
        return false, self.reason
    end
    local okb, errb = self:_registerBridge()
    if not okb then
        self.reason = errb
        return false, self.reason
    end
    local okg, errg = self:_evalRaw(QUICKJS_GLUE)
    if not okg then
        self.reason = "glue eval failed: " .. tostring(errg)
        return false, self.reason
    end
    if init_js_code then
        local ok, err = self:_evalRaw(init_js_code)
        if not ok then
            self.reason = "init.js failed: " .. tostring(err)
            return false, self.reason
        end
    end
    self.initialized = true
    return true
end

--- 桥消息处理（S2 C shim 复用）：JSON 字符串进 → JSON 字符串出。
--- 永不抛错；错误以 {__error=...} 形状编码进返回值（glue 侧识别抛 Error）。
function JsHost:_bridgeHandler(msgstr)
    local json = self.json
    local okd, msg = pcall(function() return json.decode(msgstr) end)
    if not okd or type(msg) ~= "table" then
        return json.encode({ __error = "bridge: bad JSON" })
    end
    -- 真机排查锚（R5）：只记 method 时一条 "html" 日志对应几十种 op，
    -- 无法定位失败的选择器。op 名与 query 一并落 logcat（截断防刷屏）。
    local sub = msg["function"]
    if sub then
        sub = tostring(sub) .. (msg.query
            and (" q=" .. tostring(msg.query):sub(1, 60)) or "")
    end
    -- R7 锚：源拿到的域名/状态码决定"URL 拼错还是站点拒绝"，光看 method 名
    -- 排查不动（本轮 "https://nullnull" 就是靠这两个字段定位的）。
    local detail = ""
    if msg.url then
        -- L7（审查报告 §4）：只记 host+path，剥查询串（token/session 常驻其中）
        local scrubbed = tostring(msg.url):gsub("^([^?]+).*$", "%1")
        detail = detail .. " url=" .. scrubbed:sub(1, 100)
    end
    if msg.setting_key then
        detail = detail .. " k=" .. tostring(msg.setting_key)
    end
    logwarn("ezvenera bridge <-", tostring(msg.method), sub or "", detail)
    local value, iserr = self.bridge:handle(msg)
    if msg.method == "load_setting" or msg.method == "http" then
        local r
        if type(value) == "table" then
            r = iserr and tostring(value.__error)
                or ("status=" .. tostring(value.status))
        elseif value == nil then
            r = "<unset>"
        else
            r = tostring(value)
        end
        logwarn("ezvenera bridge ->", tostring(msg.method), r:sub(1, 100))
    end
    local out
    if iserr then
        out = { __error = (value and value.__error) or "bridge error" }
    else
        out = value
    end
    local oke, encoded = pcall(function() return json.encode(out) end)
    if not oke then
        return json.encode({ __error = "bridge: encode failed" })
    end
    if encoded == nil then return "null" end
    return encoded
end

--- 注册 __ezv_post(jsonStr)→string 全局 C 函数并桥到 bridge:handle。
--- 返回 ok, err。
--- 【S2/T19 已落地】架构（对照审查 M1，LuaJIT 2.1 ext_ffi_semantics#callback）：
--- 按 JSValue（聚合体）返回的 FFI 回调全架构文档明确不支持，故由真 C 层
--- shim（shim/ezvbridge.c → lib/libezvbridge.so）负责：
---   - C 侧 JS_NewCFunction 注册 __ezv_post、JS_NewStringLen 包装按值返回；
---   - 回调经 JSContext opaque 存取（每上下文独立，无全局态）；
---   - Lua 侧回调签名降为纯指针 const char* (*)(void*, const char*)，
---     在 LuaJIT FFI 支持范围内；回调体整体 pcall，绝不向 C 栈抛错。
--- shim 缺失 → 返回明确原因（引擎降级语义不变）。
function JsHost:_registerBridge()
    local ffi = require("ffi")
    -- shim 符号声明（绝对路径 ffi.load 的库对象索引符号必须有 cdef，
    -- Android 私有目录回退加载后直接索引会报 missing declaration）
    pcall(function()
        ffi.cdef[[ int ezv_install_bridge(void *ctx, void *fn); ]]
    end)
    if self.shim == nil then
        local shim, name = probeShim()
        if not shim then
            return false, name .. "; rebuild via scripts/build-shim.sh "
                .. "(S2/T19)"
        end
        self.shim = shim
        self.shimname = name
    end
    -- LuaJIT 回调：指针入/指针出。必须锚定在 self 上防 GC 回收，
    -- dispose 时显式 :free()。
    self._shim_cb = ffi.cast("const char* (*)(void*, const char*)",
        function(_, msgptr)
            local ok, resp = pcall(function()
                return self:_bridgeHandler(ffi.string(msgptr))
            end)
            if not ok or type(resp) ~= "string" then
                return '{"__error":"bridge: lua callback error"}'
            end
            return resp
        end)
    local rc = self.shim.ezv_install_bridge(self.ctx, self._shim_cb)
    if rc ~= 0 then
        self._shim_cb:free()
        self._shim_cb = nil
        return false, "ezv_install_bridge failed (C shim rejected install)"
    end
    return true
end

function JsHost:_evalRaw(code)
    local ffi = require("ffi")
    local val = self.lib.JS_Eval(self.ctx, code, #code, "<ezvenera>",
        JS_EVAL_TYPE_GLOBAL)
    if val.tag == JS_TAG_EXCEPTION then
        local exc = self.lib.JS_GetException(self.ctx)
        local s = self.lib.JS_ToCStringLen2(self.ctx, nil, exc, false)
        local result = (s ~= nil) and ffi.string(s) or "unknown JS exception"
        if s ~= nil then self.lib.JS_FreeCString(self.ctx, s) end
        self.lib.JS_FreeValue(self.ctx, exc)
        return false, result
    end
    local s = self.lib.JS_ToCStringLen2(self.ctx, nil, val, false)
    local result = (s ~= nil) and ffi.string(s) or nil
    if s ~= nil then self.lib.JS_FreeCString(self.ctx, s) end
    self.lib.JS_FreeValue(self.ctx, val)
    return true, result
end

--- 执行 JS 代码，返回 ok, result_string/err
function JsHost:eval(code)
    if not self.initialized then
        return false, "engine not initialized"
    end
    local ok, result = self:_evalRaw(code)
    if ok then
        local executed, drained = self:pump()
        if not drained then
            logwarn("ezvenera eval: job queue not drained after", executed,
                "jobs (cap hit or job error)")
        end
    end
    return ok, result
end

-- 单次 pump 的 job 上限：防病态源 setInterval 自续链把同步泵变成死循环。
JsHost.PUMP_MAX_JOBS = 2000

--- 泵出 promise 微任务队列（同步排空）。返回 (executed, drained)。
--- 【2026-09-23 独立评估 R1 + 真机 tombstone 修正】两处 ABI 约束，缺一即崩：
---   1. 真实原型是双参 `int JS_ExecutePendingJob(JSRuntime*, JSContext**)`
---      （quickjs-ng v0.17.0 quickjs.c:2526）。旧 cdef 只声明单参 → arm64 上
---      x1 残留寄存器垃圾 → 野指针写入 → SIGSEGV。
---   2. **pctx 不得传 NULL**：v0.17.0 的"无 job"分支写作
---      `if (list_empty(&rt->job_list)) { *pctx = NULL; return 0; }`
---      —— 无条件解引用。首次探测（队列为空）即 fault addr 0x0 崩溃
---      （真机 tombstone：#00 libquickjs.so+0xe3f8 ← #01 libluajit.so）。
--- 因此每次 pump 复用宿主持有的合法 JSContext*[1] 出参（self._pctx，
--- 挂在 host 上防 GC）。泵内 job 经 shim 回调再入 Lua 与 JS_Eval 期间的
--- 回调再入是同一机制，真机已验证稳定。
function JsHost:_drainJobs(max_jobs)
    if not (self.initialized and self.rt) then return 0, true end
    local cap = max_jobs or self.PUMP_MAX_JOBS
    local pctx = self._pctx
    if not pctx then
        pctx = require("ffi").new("JSContext *[1]")
        self._pctx = pctx          -- 挂在 host 上防 GC
    end
    local executed = 0
    while executed < cap do
        local ok, rc = pcall(function()
            return self.lib.JS_ExecutePendingJob(self.rt, pctx)
        end)
        if not ok or rc == nil then return executed, true end
        if rc == 0 then return executed, true end
        if rc < 0 then
            self:_consumeJobError()
            return executed, false
        end
        executed = executed + 1
    end
    return executed, false
end

-- 单拍定时器上限：与 job 上限同理，防风暴。
JsHost.EZV_TIMERS_PER_PUMP = 64

--- 排空到期 JS 定时器（H1）：glue 的 __ezv_timers 由 sendMessage(delay)
--- 注册（then() 挂回调），这里按 due 触发。eval 缺失（单测桩）时安全为 0。
function JsHost:_pollTimers()
    if not (self.initialized and self.ctx) then return 0 end
    local ok, fired = pcall(function()
        local okr, res = self:_evalRaw("__ezv_poll_timers(Date.now())")
        if okr and res ~= nil then return tonumber(res) or 0 end
        return 0
    end)
    if not ok then return 0 end
    return fired
end

--- 泵 = promise 微任务 + 到期定时器。返回 (executed, drained)。
--- drained=false 表示本拍触顶（job 或 timer），还有积压。
function JsHost:pump(max_jobs)
    local executed, drained = self:_drainJobs(max_jobs)
    local fired = self:_pollTimers()
    return executed, drained and (fired < self.EZV_TIMERS_PER_PUMP)
end

--- job 抛错（JS_ExecutePendingJob 返回 -1）：读出挂起异常并记日志，
--- 防止残留异常污染后续 eval 的判定。
function JsHost:_consumeJobError()
    local ffi = require("ffi")
    pcall(function()
        local exc = self.lib.JS_GetException(self.ctx)
        if exc.tag ~= JS_TAG_EXCEPTION and exc.tag ~= JS_TAG_UNDEFINED
                and exc.tag ~= JS_TAG_NULL then
            local s = self.lib.JS_ToCStringLen2(self.ctx, nil, exc, false)
            logwarn("ezvenera pump: job threw:",
                s ~= nil and ffi.string(s) or "?")
            if s ~= nil then self.lib.JS_FreeCString(self.ctx, s) end
        end
        self.lib.JS_FreeValue(self.ctx, exc)
    end)
end

-- 审查 L3：key 先转义反斜杠再转义引号（只转义引号时，含 \ 的 key 会
-- 把 \" 的反斜杠当字面量，破坏拼接 eval 的字符串字面量）
local function jsStringEscape(s)
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

--- JSON null 的 Lua 哨兵**是 truthy**：cjson 给 lightuserdata，KOReader 的
--- `json` 模块给一个 function（真机 logcat 实证：源没声明 account 时
--- `attempt to index local 'acc' (a function value)`，源菜单直接抛错 →
--- 里面唯一的「删除源」项永远点不到）。
--- 所以在解码出口统一清成 nil，UI 侧只写普通 Lua 判定。
local function isNullSentinel(v)
    local t = type(v)
    return t == "nil" or t == "function" or t == "userdata" or t == "thread"
end

--- 就地剥掉表里所有 null 哨兵（递归，深度上限防自引用爆栈）
local function stripNulls(v, depth)
    if type(v) ~= "table" or (depth or 0) >= 8 then return v end
    for k, x in pairs(v) do
        if isNullSentinel(x) then
            v[k] = nil
        else
            stripNulls(x, (depth or 0) + 1)
        end
    end
    return v
end

JsHost.isNullSentinel = isNullSentinel
JsHost.stripNulls = stripNulls

--- 注册一个 Venera 源插件（对齐 EZVenera parser 语义）。
--- 返回 ok, meta|err。meta = {key, name, version, url}
function JsHost:registerSource(jscode)
    if not self.initialized then
        return false, "engine not initialized"
    end
    local script, classname = JsHost.normalizeSourceJs(jscode)
    if not script then
        return false, "parse: " .. tostring(classname)
    end
    local wrapper = ("(()=>{ %s; this.__ez_temp_source = new %s(); })()")
        :format(script, classname)
    local ok, err2 = self:eval(wrapper)
    if not ok then
        return false, "eval: " .. tostring(err2)
    end
    local okm, meta_json = self:eval([[
        (()=>{ const s = this.__ez_temp_source;
        return JSON.stringify({ key: s.key, name: s.name,
            version: s.version, url: s.url }); })()
    ]])
    if not okm or not meta_json or meta_json == "undefined" then
        return false, "meta: " .. tostring(meta_json)
    end
    local okd, meta = pcall(function()
        return self.json.decode(meta_json)
    end)
    if not okd or type(meta) ~= "table" then return false, "meta: bad JSON" end
    stripNulls(meta)
    if type(meta.key) ~= "string" or meta.key == ""
            or type(meta.name) ~= "string" or meta.name == "" then
        return false, "meta: bad JSON"
    end
    -- 全局注册（EZVenera: ComicSource.sources[key] = instance）
    -- M3（审查报告 §3）：注册赋值与 init() 的 eval 结果必须检查——
    -- key 含控制字符等会让 eval 变 SyntaxError，静默吞掉后源会以
    -- "已安装"假象进列表，随后所有操作报误导性的 "source not registered"。
    local escaped_key = jsStringEscape(meta.key)
    local okr, errr = self:eval(
        ('ComicSource.sources["%s"] = this.__ez_temp_source;')
        :format(escaped_key))
    if not okr then
        return false, "register failed: " .. tostring(errr)
    end
    self.sources[meta.key] = meta
    -- 【R7 真机】loadSetting 宿主侧补默认值。Venera 语义是
    -- 「已存值 → 源声明的 default → 空串」，任何一级都不该是 null，
    -- 而源脚本对此依赖极强：baozi.js:507 判的是 `loadSetting("cdn_domains") === ""`，
    -- 拿到 null 时模板串把域名拼成 "https://nullnull/…"（真机 logcat
    -- "image fetch failed: https://null"），整章图片全废。
    -- 声明表就在实例的 settings 字段上（class 字段，非 static），故在注册处
    -- 一次性包装，不必让 Lua 去解析 JS 声明。
    -- 包装失败必须让注册失败：静默降级会把 null 拼进源的 URL，症状出现在
    -- 很远之后（图片全灰/搜索报错），现场再也追不回真正的因。
    local patch_code = ([[
(() => {
  const s = ComicSource.sources["%s"];
  if (!s || s.__ezv_settings_patched) return;
  const decl = s.settings || {};
  const orig = s.loadSetting;
  s.loadSetting = function (k) {
    const v = orig.call(this, k);
    if (v !== undefined && v !== null) return v;
    const d = decl[k];
    if (d) {
      if (d.default !== undefined) return d.default;
      if (d.defaultValue !== undefined) return d.defaultValue;
    }
    return "";
  };
  s.__ezv_settings_patched = true;
})()
]]):format(escaped_key)
    local okp, errp = self:eval(patch_code)
    if not okp then
        return false, "settings patch failed: " .. tostring(errp)
    end
    -- init()（EZVenera 50ms 延迟近似为立即+泵）
    local has_init = ('typeof ComicSource.sources["%s"].init === "function"')
        :format(escaped_key)
    local okh, res = self:eval(has_init)
    if okh and res == "true" then
        local oki, erri = self:eval(
            ('ComicSource.sources["%s"].init()'):format(escaped_key))
        if not oki then
            -- init 失败不算注册失败（源可能只是网络探测失败），但要留痕
            local logger = require("logger")
            if logger and logger.warn then
                logger.warn("[ezvenera] source init failed:",
                    meta.key, tostring(erri))
            end
        end
    end
    return true, meta
end

--- 源在 JS 侧声明的参数表 + 账号能力。声明只存在于实例上（`settings = {…}`
--- 是 class 字段），Lua 侧唯一取法是一次 eval。
--- 过滤规则对齐上游 plugin_source_parser.dart::_parseSettings：
--- 只认 select/switch/input，其它类型静默跳过（不然后续 UI 无从渲染）。
local SCHEMA_SNIPPET = [[
(() => {
  const s = ComicSource.sources["%s"];
  if (!s) return JSON.stringify({ __error: "source not registered" });
  const out = { settings: [], account: null };
  const decl = s.settings || {};
  for (const k of Object.keys(decl)) {
    const d = decl[k];
    if (!d || typeof d !== "object") continue;
    const t = d.type;
    if (t !== "select" && t !== "switch" && t !== "input") continue;
    const opt = [];
    if (Array.isArray(d.options)) {
      for (const o of d.options) {
        if (o && typeof o === "object") {
          opt.push({ value: String(o.value),
                     text: o.text != null ? String(o.text) : String(o.value) });
        } else {
          opt.push({ value: String(o), text: String(o) });
        }
      }
    }
    out.settings.push({
      key: k,
      title: d.title != null ? String(d.title) : k,
      type: t,
      def: d.default,
      options: opt,
      validator: typeof d.validator === "string" ? d.validator : null,
    });
  }
  const a = s.account;
  if (a && typeof a === "object") {
    out.account = {
      login: typeof a.login === "function",
      logout: typeof a.logout === "function",
      website: typeof a.loginWebsite === "string" ? a.loginWebsite : null,
      register: typeof a.registerWebsite === "string"
        ? a.registerWebsite : null,
    };
  }
  return JSON.stringify(out);
})()
]]

--- 返回 (info|nil, err)。
--- info = { settings = { {key,title,type,def,options,validator}, … },
---          account = { login, logout, website } | nil }
function JsHost:sourceInfo(jsKey)
    if not self.initialized then return nil, "engine not initialized" end
    if not jsKey then return nil, "missing source key" end
    local ok, res = self:eval(SCHEMA_SNIPPET:format(jsStringEscape(jsKey)))
    if not ok then return nil, tostring(res) end
    if not res or res == "undefined" then return nil, "no schema" end
    local okd, info = pcall(function() return self.json.decode(res) end)
    if not okd or type(info) ~= "table" then
        return nil, "bad schema JSON: " .. tostring(res):sub(1, 160)
    end
    if info.__error then return nil, tostring(info.__error) end
    -- account 为 null（多数源没有账号能力）时这里是哨兵，不剥掉的话
    -- 源菜单在 `acc.login` 上抛错（见 isNullSentinel 注释）
    return stripNulls(info)
end

--- 用源声明的 validator（ECMAScript 正则）校验输入。
--- 语义照上游 sources_page.dart:677 `RegExp(validator).hasMatch(value)`。
--- 正则在引擎里跑，Lua 侧不引第三方正则库（LuaJIT 模式语法不通用）。
--- 返回 (ok|nil, err)：ok=false 表示不匹配；nil 表示无法判定（放行）。
function JsHost:testSettingValue(pattern, value)
    if not self.initialized then return nil, "engine not initialized" end
    -- JSON 字面量即合法 JS 字面量，且转义规则由 json 库统一负责；
    -- 用 Lua 的 %q 会把 Lua 转义（\z、\ 加换行）带进 JS 源码。
    local okp, pj = pcall(function() return self.json.encode(pattern) end)
    local okv, vj = pcall(function() return self.json.encode(tostring(value)) end)
    if not okp or type(pj) ~= "string"
            or not okv or type(vj) ~= "string" then
        return nil, "encode failed"
    end
    local code = ([[
(() => {
  try {
    const re = new RegExp(%s);
    return JSON.stringify({ ok: re.test(%s) });
  } catch (e) { return JSON.stringify({ __error: String(e) }); }
})()
]]):format(pj, vj)
    local ok, res = self:eval(code)
    if not ok then return nil, tostring(res) end
    local okd, v = pcall(function() return self.json.decode(res) end)
    if not okd or type(v) ~= "table" or v.__error then
        return nil, tostring(v and v.__error or res)
    end
    return v.ok == true
end

function JsHost:dispose()
    if self._shim_cb then
        self._shim_cb:free()
        self._shim_cb = nil
    end
    if self.ctx then self.lib.JS_FreeContext(self.ctx) self.ctx = nil end
    if self.rt then self.lib.JS_FreeRuntime(self.rt) self.rt = nil end
    self.initialized = false
end

return JsHost
