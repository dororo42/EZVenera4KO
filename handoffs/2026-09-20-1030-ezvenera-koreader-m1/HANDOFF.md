# HANDOFF: EZVenera for KOReader — M1 完成

> 交接日期：2026-09-20
> 来源 agent：ZCode（本会话）
> 目标 agent：未指定（已生成三档全套：S/R/P）
> 项目根：`EZVenera_KO/`（`<项目根>`）

## 当前状态摘要

**EZVenera for KOReader** — 在 KOReader（LuaJIT）内运行 Venera/EZVenera JS 漫画源插件的移植层。

- M0：研究报告（4 份，reports/ 不入仓）、需求规格（specs/）、设计+ADR+任务（changes/）全部完成
- **M1（本里程碑）**：插件骨架（`src/koreader-plugin/ezvenera.koplugin/`）全部 Lua 模块 + 75 项单测 + 全套审查脚本（语法/无长按/vendor校验）全部通过
- M2（浏览/阅读）与 M3（modifyImage/Rust 优化再评估）待下一轮

### 关键交付物清单

| 文件 | 说明 |
|---|---|
| `src/koreader-plugin/ezvenera.koplugin/main.lua` | 插件入口 + 菜单树（全部普通菜单项，无 hold 依赖） |
| `src/koreader-plugin/ezvenera.koplugin/settings.lua` | 持久化设置封装（内存/KOReader 双后端，全单测） |
| `src/koreader-plugin/ezvenera.koplugin/proxyconf.lua` | 代理配置：校验/应用/测试/子菜单 |
| `src/koreader-plugin/ezvenera.koplugin/netclient.lua` | 插件专用 HTTP 层（per-request 代理注入，http/https/b64 二进制） |
| `src/koreader-plugin/ezvenera.koplugin/runtime/bridge.lua` | sendMessage 分发层（对齐 vendored init.js 精确字段名：type/value/isEncode/http_method/function/time等） |
| `src/koreader-plugin/ezvenera.koplugin/runtime/convert.lua` | Convert/Crypto（OpenSSL EVP cdef 扩展 + 纯 Lua base64/hex/utf8 回退） |
| `src/koreader-plugin/ezvenera.koplugin/runtime/cookies.lua` | Cookie jar（域后缀/路径/过期/Secure/持久化 JSON） |
| `src/koreader-plugin/ezvenera.koplugin/runtime/jshost.lua` | QuickJS FFI 宿主（骨架+优雅降级，需要 S2 真机验证） |
| `src/koreader-plugin/ezvenera.koplugin/vendored/init.js` | EZVenera 1520 行宿主 API（原样 vendor，GPL-3.0）；sha256 锁 pin |
| `tests/` | 7 个测试文件共 75 项（lupa LuaJIT 2.1 驱动） |
| `scripts/` | run_tests, check_syntax, check_no_hold, verify_vendored, fetch/build quickjs, package-mrpi |
| `.github/workflows/ci.yml` | CI 管道（语法→测试→无hold→vendor→cargo check） |
| `rust/ezvjs-bridge/` | Rust C ABI 桥骨架（cargo check 通过，Cargo.toml + build.rs + src/lib.rs） |
| `changes/ezvenera-koreader-port/` | 完整提案/设计/6 项 ADR/任务分解 |
| `specs/requirements.md` | 需求规格（R1-R7 + 验收标准） |

## 重要上下文（接手方必须知道）

这是所有接手方必须知道、但看代码看不出来的信息。注意：本项目的核心文件都已被 Git 跟踪，下面的路径是提交后的仓库路径——没有仓库就创建不出交接套件，这是一个循环矛盾；不过你可以相信这些文件在提交后的仓库里是存在的。

### 架构决策 — 6 项 ADR（详见 `changes/ezvenera-koreader-port/design.md`）

1. **ADR-001 引擎 = quickjs-ng**：需要交叉编译为 `lib/libquickjs.so`（koxtoolchain kindle5 目标：`arm-kindle5-linux-gnueabi` softfp/glibc2.12）。`src/koreader-plugin/ezvenera.koplugin/runtime/jshost.lua` 是 FFI 骨架（cdef 加载 + promise 泵桩 + JSON 桥）；S2 冒烟前不能跑真实的 JS 插件。备选：`rust/ezvjs-bridge/`（C 桥 crate，CC 编译 quickjs C 源后由 cargo 链接）。
2. **ADR-002 vendor init.js**：`src/koreader-plugin/ezvenera.koplugin/vendored/init.js` 锁 sha256(`b6a0d30209af3c7d7ad8056023d8b28056825135704b0122990fb59f8aa51a0a`)，修改需同步更新 `.sha256` 与版权头。校验脚本 `scripts/verify_vendored.py` 在 CI 中运行。
3. **ADR-003 自带 HTTP 代理层**：KOReader 原生 `NetworkMgr:setHTTPProxy`（`frontend/ui/network/manager.lua:680-689`）只写 `socket.http.PROXY`，ssl.https/turbo/httpasync 不过代理。所以 `src/koreader-plugin/ezvenera.koplugin/netclient.lua` 对每次请求显式传 `proxy=`；`proxy == false` 强制空串覆盖全局 PROXY（line 121）。
4. **ADR-004 Rust 推迟（P2/可选）**：KOReader 单体库已捆绑 OpenSSL + mupdf/libjpeg-turbo/lodepng/leptonica → Rust 的加密与图像动机已被覆盖。保留 `rust/ezvjs-bridge/`（C ABI cdylib，Cargo.toml + build.rs + src/lib.rs）作 JSCFunction 回调的备用 bridge——仅在 S2 失败时启用。
5. **ADR-005 无长按红线**：Kindle 4 上 `hold` = `ScreenKB+Press`（2024.07 起）但不可发现。`tests/` 中 `scripts/check_no_hold.py` 扫描全部 Lua 文件禁止 `hold_input/hold_callback` 等字段。`src/koreader-plugin/ezvenera.koplugin/proxyconf.lua` 每项都是 `callback`，零 hold 依赖。
6. **ADR-006 页图显示 = ImageViewer 图像列表**：复用 KOReader 现成非触屏键位/缩放/进度条；`plugins/opds.koplugin/opdspse.lua:96-168` 是仓库内验证过的惰性页流范式，M2 时 `reader.lua` 以此为基础。

### 已知坑和限制

- **消息形状差异（关键！）**：vendor 的 `vendored/init.js` 中 sendMessage 实际字段是 `{type, value, isEncode}`（表驱动），而非 `{function, arguments}`（数组驱动）。我的 bridge.lua（`src/koreader-plugin/ezvenera.koplugin/runtime/bridge.lua`）已精确对齐——G6 Pass A 逐字段核实，修改时务必对照 vendored init.js 而非研究报告。
- **convert.lua 的 opensslBackend**（`src/koreader-plugin/ezvenera.koplugin/runtime/convert.lua`）：使用 `ffi.loadlib("crypto","57")` + 回退链。本机（Windows）无 libcrypto → 自动回退纯 Lua（base64/hex），加密/摘要返回明确错误。真机 `libkoreader-monolibtic.so` 内有 `EVP_*`，但 `EVP_aes_128_cbc/ecb/cfb/ofb` 是否可用由编译时的 OpenSSL 版本决定——S1 spike 验证。
- **cookies.lua 的 hostOf()**（`src/koreader-plugin/ezvenera.koplugin/runtime/cookies.lua:18-22`）：必须先检查 nil 再用 `:gsub`。已在 M1 修复。
- **jshost.lua**：FFI 回调 JSCFunction 在 ARM softfp 上未验证。S2 如果失败→回退 Rust ezvjs-bridge。
- **Kindle 4 长按**：`ScreenKB+Press` 自 KOReader 2024.07 起可用，但不可发现。插件设计完全走普通菜单。
- **bridge.lua 的 source_decl 注入尚未连接**：（`bridge.lua` line 生成的 source_decl）必须在 jshost:registerSource 调用时注入；因 M1 无真实引擎所以未联调。
- **cookie jar 持久化路径**：`DataStorage:getDataDir() ../ezvenera/cookies.json`——需在真机验证。

### 工具链检测

- **Python 3.12+**：主运行器（lupa 依赖，已装 `tools/.venv/`）
- **LuaJIT 2.1**：通过 lupa 提供，与 KOReader 同运行时
- **Rust 1.98**：可选（cargo check 通过）
- **koxtoolchain kindle5**：仅引擎构建需要
- 无 Node、无真正的 Lua 解释器

## 立即下一步

接手后按顺序：

1. **Spike S1 — 加密证真（1 天）**：在 KOReader 真机（或 x86 模拟环境）ffi.load monolibtic，跑 AES-128-CBC NIST 向量 + jm.js 实际模式通过 `convert.lua`。EVP 符号缺失则调 base 子模块的 OpenSSL 版本。
2. **Spike S2 — quickjs-ng 实机（2-3 天）**：
   a. `scripts/fetch-quickjs.sh`
   b. koxtoolchain kindle5 编译 `lib/libquickjs.so`
   c. 真机 `ffi.load` 跑 `class/async-await/Map/Promise.all` 冒烟
   d. 验证 Lua→C→JS→Lua 回调往返不崩，RSS 增量 <2MB
3. **M2 — 浏览与阅读（下轮主力，~3 周）**：
   a. `htmlparse.lua`（Lua 选择器 + 真实页面 fixture）
   b. `sources.lua`（索引/安装/更新/删除）
   c. `browser.lua`（源列表→搜索→详情→章节→D-pad 全可达）
   d. `reader.lua`（页流惰性 ImageViewer + 全刷抖动 + 失败重试）
4. **x86_64 引擎冒烟**：`README.md`「快速原型」路径，在开发机上跑通 vendored init.js + 一个简单插件。

## 已识别的技术债务

- `netclient.lua` 需要使用 `proxy=false` → `""` 覆盖全局 PROXY 的路径——但 KOReader 内全局 PROXY 默认 nil，实际行为是每次请求传 `proxy=nil`（不影响）。已在 `request()` 中正确实现（line 121-123 `_builtinRequest` 分层）。
- `bridge.lua` 的 `source_decl` 注入尚未连接（jshost:registerSource 会把解析的元数据注入 bridge，但 M1 无真实引擎所以未联调）。
- cookie jar 持久化使用 `DataStorage:getDataDir() ../ezvenera/cookies.json`——需在真机验证路径。

## 禁止迁移

- `.env`、SSH 私钥、token、浏览器登录态
- `reports/`（研究档案，用户要求不进仓）
- `.git/`、`tools/.venv/`、`build/`、`target/`、`dist/`
- 原始对话记录（本会话的聊天日志不外传）

## 交接链

无前序交接。此为首份。
