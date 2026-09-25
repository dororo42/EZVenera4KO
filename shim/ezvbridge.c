/*
 * ezvbridge.c — EZVenera for KOReader × quickjs-ng 桥接 shim（S2/T19）
 *
 * 背景（审查 M1，LuaJIT 2.1 官方 ext_ffi_semantics#callback）：
 *   FFI 回调按值返回 JSValue（16 字节聚合体）属全架构文档明确不支持，
 *   纯 FFI 注册 __ezv_post 的路线已废弃。本 shim 以真 C 层接管 JSValue
 *   生命周期，Lua 侧回调签名降为纯指针：
 *       const char* (*)(void *ctx, const char *msgstr)
 *   —— 指针入/指针出均为 LuaJIT FFI 文档支持范围（ADR-004 路线 C）。
 *
 * 职责：
 *   1. ezv_install_bridge(ctx, fn)：注册全局 JS 函数 __ezv_post(str)->str，
 *      fn 存入 JSContext opaque（每上下文独立，无全局态，多引擎实例安全）。
 *   2. js_ezv_post：JS 调用进入时把 argv[0]（必须为 string）转为 C 字符串，
 *      同步调 Lua 回调取回响应，经 JS_NewStringLen 拷贝后按值返回 JSValue
 *      （此处由真 C 完成聚合返回，LuaJIT 只见指针）。
 *
 * 缓冲区契约：
 *   Lua 回调返回的 char* 仅需在本次调用内存活 —— JS_NewStringLen 立即
 *   拷贝内容；LuaJIT 回调返回的字符串缓冲由其内部管理，语义恰好匹配。
 *   回调内禁止抛错跨越 C 栈帧（Lua 侧已整体 pcall 包裹）。
 *
 * 许可：GPL-3.0（与本项目一致）。编译见 scripts/build-shim.sh。
 */

#include <string.h>
#include "quickjs.h"

typedef const char *(*ezv_bridge_cb)(void *ctx, const char *msgstr);

/* 注册到 JS 的全局函数：__ezv_post(msg : string) -> string */
static JSValue js_ezv_post(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    (void)this_val;
    (void)argc;

    ezv_bridge_cb cb = (ezv_bridge_cb)JS_GetContextOpaque(ctx);
    if (!cb)
        return JS_ThrowInternalError(ctx,
            "ezvenera: bridge handler not installed");

    if (argc < 1 || !JS_IsString(argv[0]))
        return JS_ThrowTypeError(ctx, "ezv_post: expects a string argument");

    const char *msg = JS_ToCString(ctx, argv[0]);
    if (!msg)
        return JS_EXCEPTION;

    const char *resp = cb(ctx, msg);   /* LuaJIT FFI 回调（纯指针签名） */
    JS_FreeCString(ctx, msg);

    if (!resp)
        return JS_ThrowInternalError(ctx,
            "ezvenera: bridge handler returned NULL");

    /* 立即拷贝：Lua 侧缓冲区生命周期到此为止即可 */
    return JS_NewStringLen(ctx, resp, strlen(resp));
}

/*
 * 由 Lua 侧（jshost.lua _registerBridge）调用：
 *   vctx = JSContext*（Lua 侧 FFI cdata 指针透传）
 *   fn   = Lua 回调（ffi.cast 为 ezv_bridge_cb 签名的 cdata）
 * 成功返回 0；参数非法或注册失败返回 -1。
 */
int ezv_install_bridge(void *vctx, void *fn)
{
    JSContext *ctx = (JSContext *)vctx;
    if (!ctx || !fn)
        return -1;

    JSValue f = JS_NewCFunction(ctx, js_ezv_post, "__ezv_post", 1);
    if (JS_IsException(f))
        return -1;

    JS_SetContextOpaque(ctx, fn);

    JSValue g = JS_GetGlobalObject(ctx);
    if (JS_IsException(g)) {
        JS_FreeValue(ctx, f);
        return -1;
    }

    /* JS_SetPropertyStr 消费 f 的引用（成功/失败皆由其释放），勿再 FreeValue */
    int rc = JS_SetPropertyStr(ctx, g, "__ezv_post", f);
    JS_FreeValue(ctx, g);

    return (rc < 0) ? -1 : 0;
}
