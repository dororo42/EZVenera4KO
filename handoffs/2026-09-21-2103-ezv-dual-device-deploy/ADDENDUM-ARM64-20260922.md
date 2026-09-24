# EZVenera_KO — 平板 arm64 部署进展（2026-09-22 10:05）

> 接续 handoff ADDENDUM-20260922。K4 搁置（SSH 等用户唤醒设备），按用户指示转攻安卓平板。

## 已完成（本阶段）

### 1. arm64 引擎编译 ✅（144 主机，NDK r27c）

- `libquickjs.so`（arm64-v8a, android-21, 809488B stripped）+ `libezvbridge.so`（5936B，NEEDED 已改为 libquickjs.so）
- 产物：144 `~/ezv/EZVenera_KO/out-android/`，Windows 镜像 `build\android-arm64\`
- 构建脚本：`/tmp/build_arm64.sh`（cmake toolchain file 方式；坑：`$HOME` 在 ssh heredoc 中被 Windows 展开成 `C:UsersAdministrator`——脚本内**硬编码 ~ 绝对路径**；patchelf 用 NDK 自带 `llvm-patchelf`）
- 首次构建产物误为 ARM32：CMake 缓存残留（rm -rf build/quickjs-android 后重配即正确）
- 源码 sha256 校验通过（v0.17.0 tarball, 559bc4c4…）

### 2. 平板部署 ✅

- ezvenera.koplugin 全套 Lua（含修复版 jshost.lua v0.17 符号适配）+ remoteinput（socket nil 守卫版）已 adb push
- arm64 引擎 .so 已替换至 `/sdcard/koreader/plugins/ezvenera.koplugin/lib/`
- KOReader 重启后：**inspector 确认 EzVenera 对象已注册**（/koreader/ui/37，含 netclient/settings 实例），进程存活，无 NativeThread 报错

## 待验证（需用户一次点击）

- 平板菜单 → EZVenera 漫画 → **引擎与状态**：预期显示「JS 引擎: 已安装」+「加密后端: openssl」
- 若显示未安装：`adb shell "logcat -d | grep -iE 'NativeThread|ezvenera' | tail -10"` 抓降级原因（logcat 已清零待捕获）
- 引擎 OK 后：「浏览漫画源」→ 应出现 M2 提示（引擎链路全通）

## K4 侧待办（设备恢复操作后）

- 推送修复版 bridge/main/settings.lua 三文件（本地已备好）
- 验证「引擎与状态」→ 浏览漫画源 M2 提示 = K4 引擎链路全通
- 排查 remoteinput available()=false（扫码按钮）
