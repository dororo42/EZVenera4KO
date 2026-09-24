/*
 * test_shim.c — ezvbridge.c 的 C 级冒烟测试（S2/T19）
 *
 * 在本机/CI（x86_64）与 Beijing 实例上验证 shim 与 quickjs-ng v0.17.0 的
 * 端到端机制：JS → C 函数 → bridge 回调（此处用 C 函数模拟 LuaJIT 回调，
 * 两者 ABI 相同）→ C → JS 字符串同步返回。
 * 编译运行见 scripts/build-shim.sh（--test）。
 *
 * 许可：GPL-3.0。
 */

#include <stdio.h>
#include <string.h>
#include "quickjs.h"

/* ezvbridge.c 提供（与 shim 同编时直接可见，无需链接 .so） */
int ezv_install_bridge(void *ctx, void *fn);

static int g_calls = 0;

/* 模拟 Lua 侧 _bridgeHandler：纯指针签名 */
static const char *fake_bridge(void *ctx, const char *msg)
{
    (void)ctx;
    g_calls++;
    if (strcmp(msg, "{\"ping\":1}") == 0)
        return "{\"pong\":2}";
    return "{\"__error\":\"bad msg\"}";
}

static int expect_eval(JSContext *ctx, const char *code, const char *want)
{
    JSValue v = JS_Eval(ctx, code, strlen(code), "<test>",
                        JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) {
        JSValue exc = JS_GetException(ctx);
        const char *s = JS_ToCString(ctx, exc);
        printf("FAIL eval exception: %s\n", s ? s : "?");
        if (s) JS_FreeCString(ctx, s);
        JS_FreeValue(ctx, exc);
        return 1;
    }
    const char *got = JS_ToCString(ctx, v);
    int rc = 1;
    if (got && strcmp(got, want) == 0) {
        printf("PASS %s == %s\n", code, want);
        rc = 0;
    } else {
        printf("FAIL %s: expected '%s', got '%s'\n", code, want,
               got ? got : "(null)");
    }
    if (got) JS_FreeCString(ctx, got);
    JS_FreeValue(ctx, v);
    return rc;
}

int main(void)
{
    int failures = 0;

    /* ---- 场景 1：已安装回调，同步往返 ---- */
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    if (ezv_install_bridge(ctx, (void *)fake_bridge) != 0) {
        printf("FAIL ezv_install_bridge\n");
        return 1;
    }
    failures += expect_eval(ctx,
        "typeof __ezv_post === 'function'", "true");
    failures += expect_eval(ctx,
        "__ezv_post(JSON.stringify({ping:1}))", "{\"pong\":2}");
    failures += expect_eval(ctx,
        "__ezv_post('weird')", "{\"__error\":\"bad msg\"}");
    /* 非 string 实参 → JS 异常 */
    JSValue v = JS_Eval(ctx, "__ezv_post(123)", 14, "<test>",
                        JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) {
        printf("PASS __ezv_post(123) throws TypeError\n");
    } else {
        printf("FAIL __ezv_post(123) should throw\n");
        failures++;
        JS_FreeValue(ctx, v);
    }
    if (g_calls != 2) {
        printf("FAIL callback calls: expected 2, got %d\n", g_calls);
        failures++;
    }

    /* ---- 场景 2：未安装回调的新上下文 → __ezv_post 不存在 ---- */
    JSContext *ctx2 = JS_NewContext(rt);
    failures += expect_eval(ctx2,
        "typeof __ezv_post === 'undefined'", "true");

    /* ---- 场景 3：参数非法 → install 拒绝 ---- */
    if (ezv_install_bridge(NULL, (void *)fake_bridge) == -1 &&
        ezv_install_bridge(ctx2, NULL) == -1) {
        printf("PASS install rejects NULL args\n");
    } else {
        printf("FAIL install should reject NULL args\n");
        failures++;
    }

    JS_FreeContext(ctx2);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);

    if (failures == 0) {
        printf("ALL SHIM TESTS PASSED\n");
        return 0;
    }
    printf("%d shim test(s) FAILED\n", failures);
    return 1;
}
