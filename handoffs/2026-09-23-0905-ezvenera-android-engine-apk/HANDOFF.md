# Handoff: EZVenera_KO 安卓引擎随 APK 分发落地（T-S3 完成）

## 元数据

- Created: 2026-09-23 09:05
- Source agent: Coder（GLM，本会话 = 双崩溃修复 + APK 手术会话）
- Project: C:\Users\Administrator\Downloads\EZVenera_KO
- Branch: main，HEAD: 766fc60（工作区大量未提交修改 + untracked，见下）
- OS: win32（NUC-I5）

### 交接链

- **Continues from**: `handoffs/2026-09-21-2103-ezv-dual-device-deploy/`（主 HANDOFF + 6 份 ADDENDUM）
- **本份为最新**：整合 2026-09-22 ~ 09-23 全部进展。深度历史（M1/M2/remoteinput 拆删/双机部署）按需回溯：
  - `ADDENDUM-ENGINE-APK-20260923.md` ← **前一份最新**（引擎 APK 化全记录，本文与其重叠处以本文为准）
  - `ADDENDUM-M2-20260922.md`（M2 UI + 扫码移除 + 菜单 weread 式）
  - `ADDENDUM-ANDROID-SUCCESS-20260922.md` / `ADDENDUM-ARM64-20260922.md`（构建机编译与 SELinux 攻坚）
  - `ADDENDUM-R3-VERIFY.md` / `ADDENDUM-20260922.md`（R3 审查核实、K4 工具链）

## 当前状态摘要（一段话版）

**安卓平板（安卓测试平板，Android 6，arm64）引擎链路已彻底打通**：引擎 `libquickjs.so` + `libezvbridge.so` 以零 patchelf 配方在 构建机重编，注入 fdroid KOReader APK 重签名安装（T-S3 路线），`dlopen → shim → init.js → 源 JS 注册 → navigation 调用` 全链稳定；**用户 2026-09-23 08:40 真机实测通过**（logcat 实证 PID 3731 完整链路，07:58 之后零 tombstone）。历史两大"安卓引擎死刑"根因已连根拔起：① `patchelf --set-soname` 损坏 verneed 字符串偏移（运行时读出 `""`/`"rayBuffer"` 乱串，M linker 拒载）；② pump 执行 init.js 顶层 job 触发 LuaJIT FFI 回调槽竞态（SIGSEGV @ JS_NewRuntime2+0x18，寄存器全零）——pump 现为 **no-op**，代价是 promise 型源数据（分类/搜索/阅读）暂不可用，源主页只见"搜索"项。**下一步唯一关键项：S2 异步泵**（UIManager:scheduleIn 主循环节拍泵 job）。

## 最近提交（上下文参考）

- 766fc60 fix(gitignore): 禁止 venv 二进制文件入仓；reports/ 不入仓
- a13a63e chore(ci+handoff): CI 管道 + Rust 桥骨 + 交接套件
- 27b1b2e feat(plugin): EZVenera KOReader 插件全部 Lua 模块 + 单测 + 审查脚本
- d7e1c2f chore(root): 项目骨架 + G0 研究 + 设计 + ADR + 任务分解

（**2026-09-22/23 全部工作未提交**：M2 UI、崩溃修复、扫码删除、引擎 APK 化等——建议尽快分批提交。）

## 未提交修改（关键项）

| 文件 | 改动 |
|---|---|
| `src/.../main.lua` | 安卓双 nil 崩溃修复（getBrowser/getSources 惰性 getter、datastorage 数据目录、引擎不可用降级）+ weread 式菜单 |
| `src/.../browser.lua` | M2 浏览 UI + 引擎守卫 |
| `src/.../runtime/jshost.lua` | **pump no-op（回调竞态规避）**+ eval/桥诊断日志 + R-D2v5 Android 禁 dlopen 分支（保留作无 APK 引擎时的降级提示） |
| `src/.../runtime/{sources,htmlparse}.lua`、`browser.lua`（untracked） | M2 新增：源仓库/HTML 解析 |
| `AGENTS.md`/`README.md` | 扫码移除决策、安卓优先、当前 handoff 指向 |
| `tests/` | 113 项（remoteinput 30 项已随删除） |
| untracked: `shim/`、`scripts/build-shim.sh`、`tools/`、`handoffs/` | C shim 源与交接套件 |
| `build/apk-engine/` | **APK 手术全套脚本 + 签名产物**（koreader-ezv3-signed.apk 30.5MB、patch_apk.py、build_nopatchelf.sh 等 16 个脚本） |

## 架构与关键文件

```
安卓产物链：构建机编译（零 patchelf）→ out-apk3/{libquickjs.so(SONAME=libqjs.so.0), libezvbridge.so(NEEDED=libqjs.so.0)}
          → patch_apk.py 注入 APK lib/arm64-v8a/ → zipalign → apksigner(ezv.keystore) → adb 卸载重装
设备运行时：ffi.load("libquickjs") → LD_LIBRARY_PATH 命中 /data/app/<pkg>-N/lib/（扁平 lib/！）
          → shim 安装 → init.js eval → 源 JS 注册 → browser 逐层 eval（每次 eval 后 pump=no-op）
```

| 文件 | 作用 |
|---|---|
| `build/apk-engine/build_nopatchelf.sh` | **引擎构建唯一正确配方**（构建机执行，直接 CC 覆盖 cmake，禁用 NDK toolchain file 版） |
| `build/apk-engine/{patch_apk.py, make_apk3.sh}` | APK 注入 + 签名流水线 |
| `src/.../runtime/jshost.lua` L542-555 | pump no-op + 根因注释（S2 落地时改回真泵） |
| `src/.../main.lua` | 菜单/浏览/管理接线（getBrowser 引擎降级逻辑） |
| 构建机: `~/ezv/EZVenera_KO/out-apk3/`、`/tmp/*.sh`、`~/ezv.keystore`（口令走环境变量，不入文档） | 构建产物/脚本/签名密钥 |

## 已完成工作（本会话 2026-09-23）

- [x] 引擎零 patchelf 重编 + ELF 全验证（SONAME/NEEDED/verneed/符号/TEXTREL）
- [x] APK 手术流水线（注入→对齐→签名→安装→nativeLibraryDir 验证）
- [x] 引擎链路实测：dlopen/init/eval/源注册/navigation 全通
- [x] 双根因定位（tombstone 符号化 + dumpsys dropbox 取证）：patchelf verneed 损坏、pump 回调竞态
- [x] pump no-op 修复 + 设备实测（用户 08:40 真机操作，零崩溃）
- [x] 设备清理（plugins 根目录散落 .so）+ 回归 113/0 + src/release 同步
- [x] 文档：ADDENDUM-ENGINE-APK-20260923.md + AGENTS.md（本份为其整合续篇）

### 决策记录（新）

| 决策 | 备选 | 理由 |
|---|---|---|
| **禁止 patchelf 改 .so**（安卓 ≤6 全线） | 改名+set-soname | set-soname 破坏 DT_STRTAB↔section 视图，verneed 读乱串；文件名与 SONAME 无需一致 |
| 引擎随 APK 分发（重签 fdroid APK） | 私有目录拷贝 dlopen | SELinux 硬禁 sdcard；私有目录路线历史崩溃混乱且被 APK 路线取代；代价=fdroid 更新失效（可接受） |
| pump 临时 no-op | 修复回调竞态 | 竞态根因在 LuaJIT 回调槽跨线程，正解是主循环节拍泵（S2）；no-op 保同步链立即可用 |
| cmake 直接 CC 覆盖（非 NDK toolchain file） | toolchain file | 实测通过路径保守沿用；toolchain file 版 R+E 段合并且未验证 |

## 待办工作

### 立即下一步（S2 异步泵——当前唯一阻塞项）

1. **设计**：`JsHost:eval` 后不再内联泵；改为 eval 时若检测到 pending job（`JS_ExecutePendingJob` 单次探测返回 >0 即崩——**不可探测！** 需改用别的信号，如 glue 侧在 promise 排队时调桥通知 Lua），通过 `UIManager:scheduleIn(0.05, pumpStep)` 逐拍泵（每拍 ≤10 job、总预算 ≤100ms），确保回调全部发生在主循环。
2. **验证路径**：浏览漫画源 → 拷贝漫画 → 主页应出现分类列表（当前空白）；搜索 → 结果列表（需真机网络，设备当前无外网，Play 服务全超时——测试前先确认网络或配代理）。
3. **回归锚点**：113 单测 + 真机 logcat（eval 四段日志 + `bridge <-` 方法名日志已在 jshost 内置）。

### Blocker / 未决

- [ ] 设备无外网（直连全超时）——搜索/分类数据流真机验证需网络恢复或代理（settings 里残留 `http://<DEV-HOST>:<PROXY-PORT>` 代理配置，可用性未验证）
- [ ] pump 竞态的精确机制（哪条线程、哪个槽）未完全复盘——S2 落地真泵时若仍崩需 debugger 级分析

### 延后项

- K4 冻结（恢复时按 ADDENDUM-ENGINE-APK §5 零 patchelf 配方重编 kindle 目标；旧 /tmp/build_k4.sh 管线用了 patchelf 不可信；glibc 对损坏 verneed 的容忍度需实测）
- T20/T21（modifyImage 像素管线、GBK 解码）→ M3
- jshost 诊断日志精简（S2 落地后）
- 全部工作 git 提交（建议按"扫码删除/M2 UI/崩溃修复/引擎APK化"分批）

## 接手方必读

### 重要上下文

- **读 native 崩溃**：`adb shell "dumpsys dropbox --print SYSTEM_TOMBSTONE"`（debuggerd "Broken pipe" 坏了，dropbox 完好；tombstone 只有 2 帧不可靠，符号化用 构建机上未 strip 的 `build/quickjs-android-old/libqjs.so` + llvm-symbolizer）。
- **inspector 陷阱**：`/koreader/` HTTP inspector 可浏览对象/调方法（`?/arg` 单参、`?/arg1/arg2` 多参、**路径参数传不进**）；方法调用与事件派发跑在 zmq 主循环（processZMQs），但历史上 pump 崩溃线程为匿名 Thread-16xx——inspector 驱动引擎测试有竞态伪影，**关键验证必须用户真机点击**。
- **adb input tap 坐标盲点多**（估算偏移可达 200px）——UI 自动化不可靠，一律"用户手点 + logcat/截图取证"。
- **nativeLibraryDir 是扁平 `/data/app/<pkg>-N/lib/`**（非 lib/arm64/），安装号 -N 每次重装会变。
- **该测试平板 force-stop/kill 不可靠**——重启 app 后必须验证新 PID + "loading libluajit-launcher" 日志。
- **构建机通道**：`ssh build-host-tunnel`（免密可用）；sudo 密码走本地环境；`apt` 已装 apksigner/zipalign；NDK r27c 在 `~/android-ndk`。
- **构建机上 heredoc 陷阱**：`$HOME` 会被 Windows 展开成 `C:Users...`——脚本一律写本地文件 scp 过去执行（build/apk-engine/ 内有全套现成脚本）。
- **K4 BusyBox grep 无 -E**；K4 SSH 需 pty（`ssh -tt -p 2222 <USER>@<KINDLE-HOST>`，免密）——K4 冻结中，恢复前不用管。

### 假设

- fdroid KOReader 后续版本升级需重打 APK（签名不符无法覆盖安装）；lib/ 注入与重签流程已脚本化，可重复。
- `build/apk-engine/koreader-ezv3-signed.apk` 与设备当前安装一致（sha256 见 ADDENDUM-ENGINE-APK §5）。
- 设备 `/sdcard/koreader/` 数据（插件/设置/已装源：包子 1.1.6、拷贝 1.4.2、再漫画 1.0.2）在卸载重装后保留。

## 环境

### 构建 / 运行 / 测试命令

- 主仓检查：`tools\.venv\Scripts\python.exe scripts\check_syntax.py` + `run_tests.py` + `check_no_hold.py` + `verify_vendored.py`（当前 12/12 · 113/0 · clean · match）
- 引擎重编（构建机）：`scp build\apk-engine\build_nopatchelf.sh build-host-tunnel:/tmp/ && ssh build-host-tunnel "bash /tmp/build_nopatchelf.sh"`（先跑 build_old_recipe.sh 产出 build/quickjs-android-old/）
- APK 重打：`bash /tmp/make_apk3.sh`（构建机）→ scp 回 → `adb uninstall org.koreader.launcher.fdroid && adb install xxx.apk`
- 设备推送 Lua：`adb push src\koreader-plugin\ezvenera.koplugin\<f> /sdcard/koreader/plugins/ezvenera.koplugin/<f>` → force-stop + monkey 重启（`org.koreader.launcher.fdroid`）
- inspector：`adb forward tcp:18080 tcp:8080` → `curl http://<IP>:18080/koreader/`

---

**安全提醒**：定稿前如有 validate_handoff.py（agent-handoff-delivery skill 侧）可跑则跑；检测到密钥或质量分 <70 不得交付。本 handoff 不含任何凭据（构建机 sudo 密码按用户口头提供使用，不入仓——见红线 6）。
