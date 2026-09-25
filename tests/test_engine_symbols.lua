-- unit test: quickjs cdef 符号断言（R3-H1 修复建议）
-- 在真实 libquickjs 可加载时验证 jshost.lua 所需符号全部可解析（v0.17 ABI 对齐哨兵）；
-- 无引擎产物环境（本机 Windows / CI 未构建）保守通过——CI 的 shim-engine-check job
-- 构建引擎后运行本文件即可生效。
local tests = {}

function tests.cdef_symbols_resolve_on_real_engine()
    local ffi = require("ffi")
    local decls = {
        "typedef struct JSRuntime JSRuntime;",
        "typedef struct JSContext JSContext;",
        "typedef union JSValueUnion { int32_t int32; double float64; void *ptr; } JSValueUnion;",
        "typedef struct JSValue { JSValueUnion u; int64_t tag; } JSValue;",
        "typedef JSValue JSValueConst;",
        "JSRuntime *JS_NewRuntime(void);",
        "void JS_FreeRuntime(JSRuntime *rt);",
        "JSContext *JS_NewContext(JSRuntime *rt);",
        "void JS_FreeContext(JSContext *ctx);",
        "void JS_SetMemoryLimit(JSRuntime *rt, size_t limit);",
        "JSValue JS_Eval(JSContext *ctx, const char *source, size_t source_len, const char *filename, int flags);",
        "JSValue JS_GetException(JSContext *ctx);",
        "int JS_ExecutePendingJob(JSRuntime *rt, JSContext **pctx);",
        "const char *JS_ToCStringLen2(JSContext *ctx, size_t *plen, JSValueConst val, bool cesu8);",
        "void JS_FreeCString(JSContext *ctx, const char *ptr);",
        "void JS_FreeValue(JSContext *ctx, JSValue val);",
        "JSValue JS_NewCFunction2(JSContext *ctx, JSValue (*fn)(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv), const char *name, int length, int cproto, int magic);",
        "JSValue JS_GetGlobalObject(JSContext *ctx);",
        "int JS_SetPropertyStr(JSContext *ctx, JSValueConst this_obj, const char *prop_name, JSValue val);",
        "JSValue JS_NewStringLen(JSContext *ctx, const char *buf, size_t len);",
    }
    for _, d in ipairs(decls) do
        assert(pcall(function() ffi.cdef(d) end), "cdef failed: " .. d)
    end
    -- 找真实引擎：插件 lib/（CI host 构建后落在 cpath）或系统名
    local lib
    for _, name in ipairs({ "libquickjs", "quickjs" }) do
        local okl, l = pcall(ffi.load, name)
        if okl then lib = l break end
    end
    if not lib then
        -- 无引擎产物环境：跳过（保守通过，宿主 CI job 会补真实验证）
        return true
    end
    local required = {
        "JS_NewRuntime", "JS_FreeRuntime", "JS_NewContext", "JS_FreeContext",
        "JS_SetMemoryLimit", "JS_Eval", "JS_GetException", "JS_ExecutePendingJob",
        "JS_ToCStringLen2", "JS_FreeCString", "JS_FreeValue", "JS_NewCFunction2",
        "JS_GetGlobalObject", "JS_SetPropertyStr", "JS_NewStringLen",
    }
    local missing = {}
    for _, sym in ipairs(required) do
        local oksym, v = pcall(function() return lib[sym] end)
        if not oksym or v == nil then missing[#missing + 1] = sym end
    end
    assert(#missing == 0,
        "quickjs symbols missing (v0.17 ABI mismatch?): " .. table.concat(missing, ", "))
    return true
end

return tests
