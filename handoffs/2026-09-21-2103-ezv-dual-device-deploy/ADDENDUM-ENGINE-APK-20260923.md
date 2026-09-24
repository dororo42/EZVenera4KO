# EZVenera_KO — 安卓引擎随 APK 分发落地（T-S3）· 2026-09-23

> 接续 `ADDENDUM-M2-20260922.md`。本轮把 R-D2v5 判处"死刑"的安卓引擎链路
> **彻底打通**：引擎 .so 注入 KOReader APK 重签名安装，dlopen/init/eval 全链
> 稳定，并推翻了两个历史错误结论。

## 1. 结论速览

| 项 | 状态 |
|---|---|
| 引擎随 APK 分发（T-S3） | ✅ 落地：`libquickjs.so`+`libezvbridge.so` 注入 fdroid APK → zipalign → apksigner 签名 → 安装 |
| dlopen / shim / init.js / eval | ✅ 全链稳定（多次重启复现） |
| 源 JS 注册 + navigation 调用 | ✅ 三个源（包子/拷贝/再漫画）主页可开 |
| 浏览类异步数据（分类/搜索/阅读） | ⏸ 受 pump no-op 限制（见 §4），S2 范畴 |
| 回归 | syntax 12/12 · tests 113/0 · hold clean · vendor OK（src+release 同步） |

## 2. 推翻的两个历史结论（根因链）

### 2.1 "Android dlopen .so 必崩"（R-D2v5）实为 patchelf 损坏

- 现象：dlopen 报 `cannot find "" from verneed[0]` / `library "rayBuffer" not found`。
- 根因：**`patchelf --set-soname` 改写 dynstr 后，运行时 DT_STRTAB 视图与
  section 视图错位**——verneed/NEEDED 的字符串偏移在运行时读出空串或
  "arrayBuffer"中段（"rayBuffer"= 偏移+2）。readelf（section 视图）显示
  一切正常，极具迷惑性。Android 6 M linker 严格校验 verneed → 拒载。
  NDK r27 lld 本身产物无恙。
- 修复：**全程零 patchelf**。保留 CMake 原生 SONAME（`libqjs.so.0`），文件名
  仍叫 `libquickjs.so`（linker 按 NEEDED↔SONAME 匹配，与文件名无关），
  shim 自然链接产生 `NEEDED libqjs.so.0`。构建配方见 §5。
- 教训：**任何 patchelf 动过 soname 的 .so 在 Android ≤6 上都不可信**。
  K4 侧 `/tmp/build_k4.sh` 管线同样用了 patchelf——K4 引擎从未实测通过
  （SSH 断前未验证），恢复 K4 时需按本配方重建。

### 2.2 "eval 后必崩"实为 pump 的 LuaJIT 回调竞态

- 现象：`initEngine` 成功后任一次 `engine:eval` → 0.3s 内 SIGSEGV。
- tombstone（`dumpsys dropbox --print SYSTEM_TOMBSTONE` 可读！debuggerd
  "Broken pipe" 不影响 dropbox）：崩溃线程为匿名 `Thread-16xx`，
  `#00 pc 0x443f8 libquickjs.so` = **JS_NewRuntime2+0x18**，寄存器 x0-x7 全零
  ——FFI 调用参数被清零的腐败特征。
- 根因：`JsHost:eval` → `pump()` → `JS_ExecutePendingJob` 执行 init.js 顶层
  排队的 job → job 经 shim `__ezv_post` 回调进 Lua——该回调路径触发
  LuaJIT FFI 回调槽竞态 → native 崩溃。（inspector 的 zmq 处理与事件派发
  共用主循环 `processZMQs`，但崩溃线程仍为匿名线程，精确机制留 S2 复盘。）
- 修复（临时）：**pump 置 no-op**（连探测性调用都不做）。同步源方法不受
  影响；promise 型方法（Venera 源的 navigation/search 大多为 async）暂拿
  不到数据——源主页只显示"搜索"项，分类列表空。
- 正确修法（S2）：泵挂 `UIManager:scheduleIn` 主循环节拍执行（每拍泵
  N 个 job），既避免 zmq 线程一次性深泵，又让 promise 型数据流工作。

## 3. APK 手术流程（可复现）

1. `adb pull /data/app/org.koreader.launcher.fdroid-*/base.apk`（单 APK、
   lib/*.so 全 DEFLATE ⇒ extractNativeLibs=true，安装器解压到
   `/data/app/<pkg>-N/lib/arm64/`（注意：**扁平 lib/，非 lib/arm64/**），
   该目录在 LD_LIBRARY_PATH 内，`ffi.load("libquickjs")` 按名直接命中）。
2. 144 编引擎对（§5），python3 zipfile 重打 APK：剥 `META-INF/*.{SF,RSA}` +
   `MANIFEST.MF`，注入 `lib/arm64-v8a/{libquickjs.so,libezvbridge.so}`。
3. `apt install apksigner zipalign`（sudo 密码<REDACTED> `zipalign -f 4` →
   `keytool` 生成 ezv.keystore → `apksigner sign`（v1+v2）。
4. `adb uninstall`（签名变更必须卸载重装；/sdcard/koreader 数据全保留）→
   `adb install`。
- 代价：fdroid 自动更新失效（签名不符），后续 KOReader 升级需重打。
  产物留存：`build/apk-engine/koreader-ezv3-signed.apk`（30.5MB）。

## 4. 安卓链路当前行为（2026-09-23 终态）

- 菜单：工具 → EZVenera 漫画（weread 式 sorting_hint 生效，位置正常）
- 浏览漫画源 → 源列表（包子/拷贝/再漫画）→ 点源 → 源主页打开（仅"搜索"
  项；分类数据为 promise 型，待 S2 泵）——**全程无崩溃**
- 管理漫画源 → 索引/已装源管理正常（纯 Lua）
- 引擎与状态：JS 引擎=已安装（libquickjs）、加密后端=openssl
- 残留 benign：linker `readlink Permission denied`/`unable to get realpath`
  警告（华为 Android 6 全局行为，不影响加载）

## 5. 引擎构建配方（144：/tmp/build_old_recipe.sh + build_nopatchelf.sh）

```bash
# cmake（直接 CC 覆盖，不用 NDK toolchain file——toolchain file 版产物
# R+E 段合并，未验证是否也受影响，保守起见沿用实测通过的直接 CC 法）
cmake -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_C_COMPILER=$TC/aarch64-linux-android21-clang \
  -DCMAKE_CXX_COMPILER=$TC/aarch64-linux-android21-clang++ \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-21 \
  -DCMAKE_ANDROID_NDK=$NDK ../../rust/ezvjs-bridge/vendor/quickjs
make -j$(nproc) || true          # 测试可执行文件可失败，libqjs.so 会产出
cp libqjs.so libquickjs.so       # 仅改名，SONAME 保持 libqjs.so.0
llvm-strip --strip-unneeded libquickjs.so
# shim：自然链接（NEEDED=libqjs.so.0），零 patchelf
aarch64-linux-android21-clang -shared -fPIC -O2 -I<quickjs-src> \
  shim/ezvbridge.c -o libezvbridge.so -L. -l:libqjs.so \
  -Wl,-soname,libezvbridge.so
llvm-strip --strip-unneeded libezvbridge.so
```
产物（out-apk3）：libquickjs.so 809768B（sha256 bfde7448…）、
libezvbridge.so 5712B（cf059336…）。

## 6. 遗留与下一步

1. **S2 异步泵（最高优先）**：UIManager:scheduleIn 主循环节拍泵 job，
   恢复 navigation/search/loadEp 等 promise 型数据流 → 完整浏览/阅读闭环。
2. jshost 诊断日志（eval 四段/桥方法/pump 注释）保留，S2 落地后可精简。
3. K4 恢复时：按 §5 重编（放弃旧 patchelf 管线），走 sdcard lib/ 绝对路径
   dlopen（Linux 无 SELinux 限制，glibc 校验 verneed 是否同样严格需实测）。
4. 设备当前无外网（Play 服务连不通）；真机网络/代理实测待环境恢复。
5. `adb shell dumpsys dropbox --print SYSTEM_TOMBSTONE` 是该设备上读 native
   崩溃回溯的唯一可靠途径（debuggerd broken pipe），务必优先使用。
