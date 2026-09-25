# EZVenera KOReader — 安卓平板（arm64）部署实测报告 · 2026-09-22

> **结论先行：安卓引擎链路全通。** 在安卓测试平板（Android 6 / arm64 / fdroid KOReader v2026.07.1）上，ezvenera.koplugin 的 JS 引擎（quickjs-ng v0.17 + C shim）完成加载、桥接安装与初始化，「浏览漫画源」弹出预期的「M2 里程碑」提示 = 引擎链路（私有目录拷贝 → dlopen → shim 安装 → JS init）全部打通。K4 按用户指示暂停；安卓扫码输入按用户决策移除。

---

## 1. 实测验证链（时间线）

| 时刻 | 事件 | 结果 |
|---|---|---|
| 09:53 | 构建机 NDK r27c 交叉编译 arm64 引擎 | ✅ libquickjs.so (857KB) + libezvbridge.so |
| 10:00 | adb push 全套 Lua + 引擎到 /sdcard/koreader/plugins/ | ✅ 文件就位 |
| 10:15 | 首次引擎探测 | ❌ SELinux avc denied（sdcardfs execute） |
| 10:27 | 根因确认：内核 audit `avc: denied { execute } ... sdcardfs` | 定性为平台硬约束 |
| 10:43 | jshost.lua 增加 Android 私有目录回退（方案 R-D2） | 代码落地 |
| 13:48 | 私有目录 libquickjs.so 加载**成功**（进入 crypto 探测） | 引擎本体通过 |
| 14:01 | shim 私有加载失败 `library "" not found` | 定位：依赖解析 |
| 14:09 | SONAME 修正（libqjs.so.0 → libquickjs.so）+ shim 重编（无 RPATH） | 依赖命中 |
| 14:17 | 补 `ezv_install_bridge` cdef（v0.17 重构时丢失） | 桥安装 |
| 14:27 | **「漫画浏览界面属 M2 里程碑」弹出** | ✅ **全链贯通** |

## 2. 攻克的四层平台障碍（全部有实测证据）

1. **SELinux W^X**（Android 6 测试机）：`/storage` 可写存储禁止 dlopen（`avc: denied { execute } tcontext=u:object_r:sdcardfs:s0 permissive=0`）。
   解法：jshost.lua `probeLib`/`probeShim` 增加 Android 分支——用 KOReader 进程权限（app uid）`os.execute cp` 把 .so 拷进 app 私有目录 `/data/data/org.koreader.launcher.fdroid/files/ezvlib/`（Android <10 的 untrusted_app 允许从私有目录 dlopen），再加载副本。私有目录可写性用 `touch .probe` 探针实测确认。
2. **SONAME 错配**：CMake 产物 SONAME=`libqjs.so.0`，而 shim 的 NEEDED 已改为 `libquickjs.so` → linker 无法命中已加载库，转而按名字搜索（sdcard 又被拒）。解法：`patchelf --set-soname libquickjs.so`。
3. **RPATH $ORIGIN**：Android 6 linker 不支持且无用（私有目录同目录依赖不可搜），重编 shim 移除。
4. **cdef 丢失**：`ezv_install_bridge` 符号声明在 v0.17 重构中遗漏，`ffi.load` 绝对路径加载后索引符号报 missing declaration。解法：`_registerBridge` 顶部补 `ffi.cdef[[int ezv_install_bridge(void* ctx, void* fn);]]`（pcall 幂等）。

以上全部沉淀在 `jshost.lua`（src + release 同步），**非 Android 平台零影响**（分支由 `Device:isAndroid()` 门控）。

## 3. 按用户决策的产品裁剪

- **安卓扫码输入移除**：`proxyconf.lua` 的「扫码远程输入」按钮加平台门控——仅电子墨水设备（kindle 等）显示，Android 跳过 remoteinput 探测。
- **K4 双插件暂停**：K4 侧 SSH 半休眠（WiFi 省电）无法操作，所有 K4 待办冻结；已推上机的 jshost/引擎产物保留（恢复 SSH 后可直接复用本报告 §2 的修复链验证）。

## 4. 回归与质量

- 主仓：syntax 16/16 · tests **126/0** · hold clean(16) · vendored SHA256 match
- release 双仓：同步全部修复（jshost v0.17 符号 + Android 回退 + cdef 补丁 + proxyconf 门控 + remoteinput socket 守卫）
- 测试平板实机：插件注册（inspector 确认）→ 引擎探测 → 桥安装 → JS init → 菜单交互，无崩溃、无 script error
- 残留 benign 噪音：linker `readlink Permission denied` / `unused DT entry`（Android 6 linker 已知无害告警，不影响加载）

## 5. 剩余事项

| 项 | 状态 |
|---|---|
| M2「浏览漫画源」真实 UI（M2 里程碑本体） | 下一里程碑：漫画源列表/详情/图片阅读页 |
| 测试平板 crypto 后端显示（openssl vs 回退） | 引擎状态页已实现，待用户菜单确认显示值 |
| K4 引擎验证 | 冻结（设备恢复后按 §2 链路复验，jshost 已是最新） |
| remoteinput 测试平板扫码端到端 | 按决策移除（代码保留，门控隐藏） |
| 代理连通性实测 | 等代理地址 |

## 6. 构建复现（构建机）

```bash
# arm64 引擎
cmake -DCMAKE_TOOLCHAIN_FILE=$HOME/android-ndk/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-21 \
  -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=MinSizeRel <quickjs-src>
# SONAME 修正
patchelf --set-soname libquickjs.so out-android/libquickjs.so
# shim（无 RPATH）
aarch64-linux-android21-clang -shared -fPIC shim/ezvbridge.c \
  -o out-android/libezvbridge.so -Lbuild/quickjs-android -l:libqjs.so \
  -Wl,-soname,libezvbridge.so
patchelf --replace-needed libqjs.so.0 libquickjs.so out-android/libezvbridge.so
```
部署：`adb push` 到 `/sdcard/koreader/plugins/ezvenera.koplugin/`，重启 KOReader 即可（首次引擎探测自动完成私有目录拷贝）。
