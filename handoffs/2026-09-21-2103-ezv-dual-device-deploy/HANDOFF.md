# Handoff: EZVenera_KO 双机部署实测（K4 修复 + arm64 编译 + 平板崩溃排查）

## 元数据

- Created: 2026-09-21 21:02
- Source agent: Coder Manager (OpenClaw, agent:coder-manager)
- Target agent: unknown（三档全配）
- Target mode: all
- Project: <项目根>
- Branch: main
- HEAD: 766fc60（工作区有大量未提交修改 + untracked，见下）
- OS: win32（NUC-I5）

### 交接链

- **Continues from**: `handoffs/2026-09-20-1749-ezvenera-remoteinput-split/HANDOFF.md`
- **Supersedes**: 无（本次为部署阶段首个 handoff）

> 接手方：从本份读起，需要更早背景时再回溯链上前驱。

## 当前状态摘要

双机部署实测进行中。**Kindle4 (<K4>:2222, root（口令走本地环境）)**：ezvenera.koplugin + remoteinput.koplugin 已推送并加载成功（菜单出现、弹窗可用），但 JS 引擎初始化失败——根因已定位：quickjs-ng v0.17.0 不导出 `JS_ToCString`/`JS_NewCFunction`（头文件里是 static inline，实际导出 `JS_ToCStringLen2`/`JS_NewCFunction3`），jshost.lua 的 cdef 用旧符号名导致 missingSymbols 自检失败后按设计降级。**修复方案已定（方案 A：改 jshost.lua cdef 与调用），尚未写代码**。另 K4 产物 .so 在裸 luajit 下有 `pthread_once`/`clock_gettime` 符号问题（K4 glibc 2.12 老；KOReader 进程内无此问题），所以引擎验证必须经 KOReader 内部路径。**安卓测试平板 (<平板>, adb)**：remoteinput 已推送并加载（HTTP inspector 确认 `/koreader/ui/remoteinput` 存在），但用户点菜单「扫码远程输入」后 KOReader 崩溃——崩溃栈未捕获（崩溃发生在 logcat 环形缓冲之外，无 crash.log 可拉，run-as 不可用），设备已挂常驻 logcat 落盘（`/sdcard/koreader/.dbg_live.log`），**等用户再点一次即可抓栈**。**编译机 构建机 (<构建机>, ssh <构建机 ssh 别名> 免密)**：cmake 4.2.3/patchelf/NDK r27c(~/android-ndk)/crosstool-ng 已就绪；kindle5 工具链 ct-ng build 卡在源码下载（ftpmirror ~10KB/s，make-4.3 已完成，卡 linux-2.6.32.71 内核头），需换镜像预置 tarball。

## 最近提交（上下文参考）

- 766fc60 fix(gitignore): 禁止 venv 二进制文件入仓；reports/ 不入仓
- a13a63e chore(ci+handoff): CI 管道 + Rust 桥骨 + 交接套件
- 27b1b2e feat(plugin): 全部 Lua 模块 + 单测 + 审查脚本
- d7e1c2f chore(root): 项目骨架 + G0 研究 + 设计 + ADR

## 未提交修改（关键项）

| 文件 | 改动 | 原因 |
|---|---|---|
| .gitignore | 追加 /_auth*.txt /_shim* /_dl*.txt /_stage.py /_validate_repos.py /release/ | 审查 N2 防误提交（git check-ignore 已实测通过） |
| scripts/check_no_hold.py | 扫描范围扩大到 src/koreader-plugin 全插件 | 上轮审查 |
| .github/workflows/ci.yml | +libssl-dev | 真实加密向量测试 |
| src/.../proxyconf.lua | +76 行（remoteinput 弱依赖扫码按钮） | 上轮功能 |
| src/.../*.lua 多文件 | 上轮审查修复（H1/M 系） | 见 reports/2026-09-20-independent-code-review.md |
| README.md | convert.lua 表述修正 | 本轮 N6 |
| untracked: shim/ build-shim.sh test_jshost_shim.lua | 另一团队 7:08-7:33 C shim 工作 | 对方会话产出 |
| untracked: remoteinput.koplugin/ test_api.lua 等 | remoteinput 全套 | 对方会话产出 |

## 架构与关键文件

### 架构概览

Windows 主控 ──ssh:2222──> Kindle4（插件目录 /mnt/us/koreader/plugins/）；──adb──> 安卓测试平板（/sdcard/koreader/plugins/，HTTP 调试 http://<平板>:8080/koreader/）；──ssh <构建机 ssh 别名>──> Ubuntu 构建机（交叉编译机）。产物链路：构建机编译 → scp 推 K4 / adb push 推测试平板。

### 关键文件

| 文件 | 作用 | 为何重要 |
|---|---|---|
| src/koreader-plugin/ezvenera.koplugin/runtime/jshost.lua（cdef 段 L251-330、_evalRaw L411-425） | quickjs FFI 宿主 | 符号修复方案 A 主战场 |
| src/.../lib/libquickjs.so | ARM32 softfp 引擎（对方 7:33 编译） | K4 现有产物，修复后直接复用 |
| src/koreader-plugin/remoteinput.koplugin/qrwidget.lua | QR 自绘 widget | 平板崩溃疑似点 |
| scripts/build-quickjs.sh | 交叉编译入口 | 需扩展 android arm64 target |
| workspace .openclaw/tmp/k4_*.lua | K4 诊断脚本（probe/cdef/syms/deep） | 回归验证用 |
| workspace ezv-*.md/html | 审查报告、arm64 方案、部署检查单 | 上下文 |

## 已完成工作

- [x] eagle-eye-senior-dev skill 安装（含安全审查）
- [x] 代码级独立审查 + 修复 N1/N2/N3/N5/N6/N8（17 处内网 IP 洗涤）；报告在 workspace ezv-*.{md,html} 与项目 reports/2026-09-21-independent-review-fixlog.md；修复后 125/125 全绿
- [x] K4 环境侦察 + 双插件推送 + 加载验证
- [x] K4 引擎失败根因定位（v0.17 符号变更，证据链完整）
- [x] 测试平板 remoteinput 推送 + inspector 确认加载
- [x] 测试平板 HTTP 调试通道打通（读树/事件/截图；不能执行任意 Lua）
- [x] 构建机环境搭建（cmake/patchelf/NDK/crosstool-ng）
- [x] 测试平板常驻 logcat 落盘（/sdcard/koreader/.dbg_live.log）
- [ ] K4 引擎修复（方案 A）——未动代码
- [ ] 平板扫码崩溃栈捕获——等用户点击
- [ ] kindle5 工具链——卡源码下载
- [ ] arm64 产物——待工具链/源码

### 决策记录

| 决策 | 备选 | 理由 |
|---|---|---|
| K4 符号修复走方案 A（改 Lua cdef 用底层导出符号） | B 全收口进 C shim；C 锁旧版 quickjs | 改动面最小；v0.17 与 fetch 锁定版本一致；K4 产物直接复用 |
| 引擎验证走 KOReader 内部路径 | 裸 ./luajit+LD_PRELOAD | 实测裸 luajit 撞 pthread_once/clock_gettime（glibc 2.12 老）；KOReader 进程内无此问题 |
| arm64 编译放 构建机 | 本机装 NDK | 用户指定；构建机已有生态 |
| 平板崩溃用常驻 logcat 落盘 + 用户复现 | adb input tap 盲点复现 | 实测 tap 坐标不可靠；崩溃栈只有 KOReader 自身能写全 |

## 待办工作

### 立即下一步

1. **抓平板崩溃栈**：请用户在测试平板点「扫码远程输入」（≡ → 工具 → 第 2 页 → 新：扫码远程输入），然后 `adb shell "grep -iE 'luajit|FATAL|signal|KOReader' /sdcard/koreader/.dbg_live.log | tail -100"`。若 stdout 未进 logcat，找 /storage/emulated/0/koreader/crash.log。
2. **K4 引擎修复**：先在本机跑 `bash scripts/fetch-quickjs.sh`（Git Bash）拿 v0.17 源码，读 rust/ezvjs-bridge/vendor/quickjs/quickjs.h 确认 `JS_ToCStringLen2`/`JS_NewCFunction3` 精确签名；改 jshost.lua cdef + _evalRaw 两处调用 + missingSymbols 清单；scp 推 K4 重启验证「引擎与状态」页显示已安装。
3. **kindle5 工具链加速**：看 /tmp/ct_build.log 当前 wget 目标，用清华镜像（mirrors.tuna.tsinghua.edu.cn/gnu/ 及 kernel.org 镜像）预下载 tarball 放 ~/koxtoolchain/build/kindle/.build/tarballs/（同名去 .tmp-dl 后缀），ct-ng 会跳过已有文件，然后重启 `ct-ng build`。
4. **arm64 编译**（与 3 并行）：scp 项目到 构建机:~/ezv/（排除 repos/.venv/.git）；写 scripts/build-quickjs-android.sh（NDK toolchain file + ANDROID_ABI=arm64-v8a + android-21 + BUILD_SHARED_LIBS=ON），shim 用 aarch64-linux-android21-clang 编 ezvbridge.c；产物推测试平板验证。

### Blocker / 未决问题

- [ ] 平板扫码崩溃根因未知 — 需要用户配合点击一次（logcat 已落盘）
- [ ] kindle5 工具链下载极慢 — 需要换镜像（卡 linux-2.6.32.71.tar.xz）
- [ ] K4 公钥认证未生效（/root 只读；key 在 /tmp/root/.ssh + /mnt/us/.ssh-backup/restore.sh）— 非阻塞：免密 pty 可用
- [ ] K4 扫码按钮不出现（remoteinput available()=false）— 待查 socket 探测/时序

### 延后项

- M2 浏览/阅读实测（M2 里程碑）——等 arm64 引擎
- 代理连通性实测——等用户提供代理地址
- remoteinput K4→测试平板端到端——等平板崩溃修复 + K4 按钮时序修复

## 接手方必读

### 重要上下文

- **K4 BusyBox grep 不支持 -E**（-F 可用），长命令拆分或用多级 grep -F 管道。
- **K4 SSH 必须 pty 交互**：`ssh -tt -p 2222 <USER>@<K4> "cmd"`，process 工具 open pty 后 write "\n" 补免密回车。BatchMode 必失败。
- **K4 上跑 Lua 用 `cd /mnt/us/koreader && ./luajit /tmp/xxx.lua`**，不要加 LD_LIBRARY_PATH（撞 pthread 符号）。
- **测试平板 adb input tap 坐标盲点极多**（状态栏吞事件、层级深、误触翻译），UI 复现不可靠；一律 logcat 落盘 + 用户手点。
- **M2 inspector**（http://<平板>:8080/koreader/）只能浏览树/改属性/发 dispatcher 事件/截图，不能执行任意 Lua。事件注入实测可用。
- **另一团队会话仍活跃在同一工作区**（其产出 mtime 7:08-8:03），改动前先 git status。
- **vendored init.js sha256 已锁**（b6a0d302…），引擎符号修复不要动 init.js。
- **PowerShell 远程命令含 Lua `..` 拼接会被本地解析器破坏引号**——复杂 Lua 先写文件再 scp。
- read 工具被 workspaceOnly 限制；EZVenera_KO 项目文件用 exec Get-Content 读。

### 假设

- `JS_ToCStringLen2(ctx, size_t*, JSValueConst, int cesu8)` 签名来自 strings + 头文件结构推断，**修复前必须读 vendor quickjs.h 确认**。
- K4 crash.log 无插件 Lua 错误栈 = Lua 层加载成功，失败全在 FFI 层（k4_deep.lua 已证实）。
- ct-ng 产物在 ~/x-tools/arm-kindle5-linux-gnueabi/（CT_PREFIX 默认）。

### 已知坑

- ct-ng 的 gnu ftpmirror 下载 ~10KB/s，预置 tarball 是必经之路。
- K4 /root 只读；SSH key 放 /tmp 重启丢失（restore.sh 在 /mnt/us/.ssh-backup/）。
- M2 fdroid 版非 debuggable，run-as/​/data/data 不可读。
- handoff 脚本 create_handoff.py 在本机 git 环境下有 None.stdout 崩溃（已手工修补 skill 脚本）与 format 单大括号崩溃（RESUME_PROMPT 模板），本次手工填写 HANDOFF.md 绕过。

## 环境

### 构建 / 运行 / 测试命令

- 主仓检查：`cd <项目根> && tools\.venv\Scripts\python.exe scripts\check_syntax.py`（+run_tests/check_no_hold/verify_vendored，当前全绿）
- K4 推送：`scp -P 2222 -r <local> <USER>@<K4>:/mnt/us/koreader/plugins/`
- M2 推送+重启：`adb push <local> /sdcard/koreader/plugins/`；`adb shell "am force-stop org.koreader.launcher.fdroid"`；`adb shell "monkey -p org.koreader.launcher.fdroid -c android.intent.category.LAUNCHER 1"`
- 构建机：`ssh -o BatchMode=yes <构建机 ssh 别名> "<cmd>"`；监控 `tail /tmp/ct_build.log`；产物 `~/x-tools/arm-kindle5-linux-gnueabi/bin/`；NDK clang `~/android-ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang`

### 环境变量（只写名字）

- 构建机上 ct-ng 需 PATH 前置 ~/koxtoolchain/build/CT_NG_BUILD/bin

---

**安全提醒**：定稿前运行 validate_handoff.py。检测到密钥或质量分 <70 时不得交付。
