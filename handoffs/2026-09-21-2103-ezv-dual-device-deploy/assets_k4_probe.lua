-- K4 引擎修复前探针：确认 quickjs-ng v0.17 实际 tag 常量 + 关键符号可用性
local ffi = require("ffi")
ffi.cdef[[
typedef struct JSRuntime JSRuntime;
typedef struct JSContext JSContext;
typedef union JSValueUnion { int32_t int32; double float64; void *ptr; } JSValueUnion;
typedef struct JSValue { JSValueUnion u; int64_t tag; } JSValue;
typedef JSValue JSValueConst;
JSRuntime *JS_NewRuntime(void);
void JS_FreeRuntime(JSRuntime *rt);
JSContext *JS_NewContext(JSRuntime *rt);
void JS_FreeContext(JSContext *ctx);
void JS_FreeValue(JSContext *ctx, JSValue val);
JSValue JS_Eval(JSContext *ctx, const char *source, size_t source_len, const char *filename, int flags);
const char *JS_ToCStringLen2(JSContext *ctx, size_t *plen, JSValueConst val, int cesu8);
void JS_FreeCString(JSContext *ctx, const char *ptr);
JSValue JS_NewCFunction3(JSContext *ctx, JSValue (*fn)(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv), const char *name, int length, int cproto, JSValueConst data_val);
JSValue JS_GetGlobalObject(JSContext *ctx);
int JS_SetPropertyStr(JSContext *ctx, JSValueConst this_obj, const char *prop_name, JSValue val);
]]
local okl, lib = pcall(ffi.load, "/mnt/us/koreader/plugins/ezvenera.koplugin/lib/libquickjs.so")
print("quickjs load = " .. tostring(okl))
if not okl then return end

local rt = lib.JS_NewRuntime()
local ctx = lib.JS_NewContext(rt)
print("ctx ok = " .. tostring(ctx ~= nil))

local function tag(code)
    local v = lib.JS_Eval(ctx, code, #code, "t", 0)
    local t = v.tag
    lib.JS_FreeValue(ctx, v)
    return t
end
print("tag int      = " .. tag("1+1"))
print("tag null     = " .. tag("null"))
print("tag undef    = " .. tag("undefined"))
print("tag bool     = " .. tag("true"))
print("tag float    = " .. tag("1.5"))
print("tag string   = " .. tag("'x'"))
print("tag object   = " .. tag("({})"))
local ve = lib.JS_Eval(ctx, "syntax !!", 9, "t", 0)
print("tag exception= " .. ve.tag)
lib.JS_FreeValue(ctx, ve)

-- JS_ToCStringLen2 实测
local len = ffi.new("size_t[1]")
local v = lib.JS_Eval(ctx, "'hello world'", 13, "t", 0)
local s = lib.JS_ToCStringLen2(ctx, len, v, 0)
print("ToCStringLen2 = " .. (s ~= nil and ffi.string(s, len[0]) or "NIL") .. " len=" .. len[0])
lib.JS_FreeCString(ctx, s)
lib.JS_FreeValue(ctx, v)

-- JS_NewCFunction3 符号解析测试（不调用，只验 dlsym）
local okn, vn = pcall(function() return lib.JS_NewCFunction3 end)
print("dlsym JS_NewCFunction3 = " .. tostring(okn))

-- shim 全链路：装桥 → typeof __ezv_post → 真实往返
local sh = ffi.load("/mnt/us/koreader/plugins/ezvenera.koplugin/lib/libezvbridge.so")
ffi.cdef[[ int ezv_install_bridge(void *vctx, void *fn); ]]
local cb = ffi.cast("const char* (*)(void*, const char*)", function(_, m)
    return '{"pong":2}'
end)
local rc = sh.ezv_install_bridge(ctx, cb)
print("install rc = " .. tostring(rc))
if rc == 0 then
    local v2 = lib.JS_Eval(ctx, "typeof __ezv_post", 17, "t", 0)
    local s2 = lib.JS_ToCStringLen2(ctx, len, v2, 0)
    print("typeof __ezv_post = " .. ffi.string(s2, len[0]))
    lib.JS_FreeCString(ctx, s2)
    lib.JS_FreeValue(ctx, v2)
    local v3 = lib.JS_Eval(ctx, '__ezv_post(JSON.stringify({ping:1}))', 37, "t", 0)
    local s3 = lib.JS_ToCStringLen2(ctx, len, v3, 0)
    print("roundtrip = " .. (s3 ~= nil and ffi.string(s3, len[0]) or "NIL"))
    lib.JS_FreeCString(ctx, s3)
    lib.JS_FreeValue(ctx, v3)
end
print("=== PROBE_END ===")
