//! EZVenera for KOReader — quickjs-ng C ABI bridge
//!
//! 状态：骨架（Spike S2 验证前为“不可编译，文档+接口先行”）。
//! 编译前提：`scripts/fetch-quickjs.sh`（vendor/quickjs/）→
//! `scripts/build-quickjs.sh` 或本 crate 的 build.rs 通过 cc crate 编译。
//!
//! 交叉编译到 Kindle 用 `armv7-unknown-linux-musleabi`（softfp, 静态 musl）：
//!   rustup target add armv7-unknown-linux-musleabi
//!   cargo build --release --target armv7-unknown-linux-musleabi
//! 目标文件 `target/armv7-unknown-linux-musleabi/release/libezvjs_bridge.so`
//! → 复制到 `src/koreader-plugin/ezvenera.koplugin/lib/` 作为备选 FFI 路径。
//!
//! 架构决策：这是 LuaJIT ffi 桥的回退方案（ADR-004）。
//! 当纯 ffi 的 JSCFunction 回调在 ARM softfp 上不可行时启用本 crate。

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

// 占位——真实实现需 vendored quickjs C 头通过 build.rs 编译
// use quickjs_sys::{JSRuntime, JSContext, JSValue};

/// Opaque runtime 句柄
pub struct EzVjsRuntime {
    // rt: *mut JSRuntime,
    // ctx: *mut JSContext,
    // bridge_fn: Option<extern "C" fn(msg: *const c_char) -> *mut c_char>,
}

/// 创建运行时。返回句柄供其它函数使用；null 时失败。
/// 调用方负责 ezvjs_destroy。
#[no_mangle]
pub extern "C" fn ezvjs_new(memlimit: usize) -> *mut EzVjsRuntime {
    let _ = memlimit;
    // TODO: JSRuntime::new, create context, set memory limit
    std::ptr::null_mut()
}

/// 执行 JS 代码。0 = 正常（result.str 由 *out_buf→size 返回），
/// <0 = 异常（result.str 包含错误信息）。
/// out_buf 由调用方预分配（建议 4096 字节）并以 null 终止返回；
/// out_size 置为实际长度（不含终止符）。
#[no_mangle]
pub extern "C" fn ezvjs_eval(
    rt: *mut EzVjsRuntime,
    code: *const c_char,
    out_buf: *mut c_char,
    out_size: *mut usize,
) -> c_int {
    if rt.is_null() || code.is_null() { return -1; }
    let _code = unsafe { CStr::from_ptr(code) };
    let _ = (out_buf, out_size);
    // TODO: JS_Eval, JS_ToCString → copy to out_buf
    -1
}

/// 执行 pending jobs（promise 回调），返回 job 数。
#[no_mangle]
pub extern "C" fn ezvjs_pump(rt: *mut EzVjsRuntime) -> c_int {
    let _ = rt;
    0
}

/// 设置 sendMessage 回调（JS 调用 __ezv_post 时触发）。
/// cb 签名：接收 JSON 字符串、返回 JSON 结果字符串（由 ezvjs_free_string 释放）。
#[no_mangle]
pub extern "C" fn ezvjs_set_bridge(
    rt: *mut EzVjsRuntime,
    cb: Option<extern "C" fn(msg: *const c_char) -> *mut c_char>,
) {
    if rt.is_null() { return; }
    // unsafe { (*rt).bridge_fn = cb; }
    let _ = cb;
}

/// 释放由 ezvjs_bridge_callback 分配的结果字符串。
#[no_mangle]
pub extern "C" fn ezvjs_free_string(s: *mut c_char) {
    if s.is_null() { return; }
    unsafe { drop(CString::from_raw(s)); }
}

/// 销毁运行时。
#[no_mangle]
pub extern "C" fn ezvjs_destroy(rt: *mut EzVjsRuntime) {
    if rt.is_null() { return; }
    // TODO: JS_FreeContext, JS_FreeRuntime
    unsafe { drop(Box::from_raw(rt)) }
}