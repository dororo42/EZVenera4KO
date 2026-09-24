# HANDOFF: EZVenera for KOReader — M1 审查落实 + remoteinput 交付 + 拆仓/编译决策

> 交接日期：2026-09-20（17:49）
> 来源 agent：WorkBuddy 代码审查专家会话
> 目标 agent：未指定（后续将有**其他团队审查与接手**，本档按完整对接标准编写）
> 项目根：`EZVenera_KO/`（`C:\Users\Administrator\Downloads\EZVenera_KO`）
> 前序交接：`handoffs/2026-09-20-1030-ezvenera-koreader-m1/HANDOFF.md`（M1 首份，必读）

## 当前状态摘要

自前序交接（1030）以来完成了两轮工作：

1. **M1 全量代码审查 + 20/20 落实**：1 Critical + 7 Major + 12 M/L 全部修复或显式转任务。关键修复：convert.lua EVP Init 第 5 实参改传 IV（原把 `#key` 当 IV 指针）、cookies splitSetCookie 逗号拆分、OFB 零 IV 回退、netclient ltn12/UA(`Dart/3.5 (dart:io)`)/JSON body、jshost cdef pcall + glue ArrayBuffer↔base64（Node 行为测试 10/10）、fetch-quickjs.sh pin quickjs-ng v0.17.0 + sha256（原默认 tag 404）、build-quickjs.sh 补 `BUILD_SHARED_LIBS=ON`。审查报告在本地 `reports/2026-09-20-code-review-m1.md`（reports/ 不入仓，接手团队如需请向用户索取）。
2. **remoteinput.koplugin 扫码远程输入交付（独立插件）**：K4 输入不便 + 触屏平板适配的解法。新增 6 模块（qrcode/server/qrwidget/api/main/facade），EZVenera 经 `pcall(require, "remoteinput")` 弱依赖注入「扫码远程输入」按钮。**新 ADR-007**（独立插件 + 弱依赖，见 design.md §3.6）。

**终态回归 ALL GREEN**：语法 15/15、单测 109 passed / 0 failed（lupa LuaJIT 2.1）、check_no_hold clean（15 文件全插件扫描）、verify_vendored sha256 不变。QR 编码器经 zxing-cpp 真解码 7/7（tools/qr_verify.py）。

## 用户既定决策（2026-09-20 17:49，接手方必须遵守）

1. **两个插件分别建 GitHub 仓库，暂不一起打包**：
   - `package-mrpi.sh` 保持只打 ezvenera.koplugin（已确认现状如此，勿改成联合打包）；
   - remoteinput.koplugin 要**拆出为独立仓库**（其代码本就自包含：6 个 Lua 文件 + KOReader 内建依赖，拆分成本低）；
   - 拆仓时注意：tests/ 中 `test_qrcode.lua`/`test_server.lua`/`test_api.lua`/`stubs_remote.lua` 归 remoteinput 仓；`test_proxyconf.lua` 的 remoteinput 弱依赖用例保留在 ezvenera 仓但须容错（remoteinput 仓缺失时 SKIP）。
2. **lib/libquickjs.so 编译路线**：优先 Tencent Cloud Lighthouse（Ubuntu 24.04，ap-shanghai，2C/2G，经 Lighthouse MCP OAuth 远程执行）；不行再看 Panther X2（评估见下，可行性低）。
3. **双设备测试路线**：安卓平板（KOReader Android，触屏）+ Kindle 4 并行，均需 SSH/部署通道；**用户条件具备后会通知**，届时再做部署与真机冒烟，勿提前索要设备凭据。
4. 其他团队将审查接手 → 所有决策必须可从本仓文档（design.md ADR / tasks.md / 本 handoff）追溯。
5. **源索引默认值确认（R3.4，2026-09-20 追加）**：默认索引 = `https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json`（EZVenera 官方源托管仓库；schema `[{name, fileName, key, version, description?}]`，下载 = 索引基址 + `fileName`，jsdelivr CDN 备选）；用户可在指定目录 `<data>/ezvenera/index/` 放置同 schema 的 `*.json` 合并为本地源（同 `key` 本地优先），并支持本地 `.js` 直装。详细设计 = design.md §3.7，安装确认红线 R7.2 不变。

## libquickjs.so 编译评估（接手方直接照做或重新验证）

### 路线 A：Lighthouse 北京实例（主路线，2026-09-20 已核实可用）

> ✅ 2026-09-20 实测（Lighthouse MCP）：**`lhins-ni6p5t1q`（OpenClaw(龙虾)-MmNJ，ap-beijing，2C/2G/50GB SSD，公网 <IP>）RUNNING**，x86_64 / Ubuntu 24.04.4 / 根分区 27GB 可用 / 内存可用 1.2G——满足编译条件。⚠️ 实例 **2026-09-30 到期（手动续费模式）**，编译窗口 10 天，逾期需续费。
> 历史备注（已降级）：上海实例 `lhins-3esurdsa` 已于 2026-09-15 到期隔离、API 全拒，仅作记录，不再作为编译目标。

koxtoolchain 提供 **x86_64 Linux 预编译工具链**（无需在服务器上编 gcc），quickjs 本体编译极快。步骤：

```bash
# 0) 前置检查：磁盘需 ~4GB 空闲（工具链解压 ~2-3GB），2GB RAM 对 quickjs 单文件编译足够
df -h && free -h

# 1) 下载 koxtoolchain kindle5 预编译工具链（GitHub Release 的 kindle5_tc.tgz）
#    https://github.com/koreader/koxtoolchain/releases

# 2) 解压并 source 环境（生成交叉编译器 arm-kindle5-linux-gnueabi-gcc）

# 3) 源码准备：用仓库脚本（已 pin v0.17.0 + sha256，勿用未校验源码）
bash scripts/fetch-quickjs.sh

# 4) 编译：仓库脚本（注意它要求 BUILD_SHARED_LIBS=ON，已修复过）
bash scripts/build-quickjs.sh kindle
# 产物 → src/koreader-plugin/ezvenera.koplugin/lib/libquickjs.so（不入 git）

# 5) 产物验证（必做，K4 glibc 2.12 老旧）：
readelf -h libquickjs.so      # 应为 ARM 32-bit EABI
readelf -A libquickjs.so      # 不得出现 Tag_ABI_VFP_args（出现即 hardfp，K4 softfp 加载会失败）
readelf -d libquickjs.so | grep GLIBC   # 符号版本最高不得超过 GLIBC_2.12（建议 ≤2.9）
```

风险点：kindle5 工具链与 K4 的 softfp/glibc2.12 匹配性是仓库 G0 研究结论（报告 03），**以 readelf 实测为准**；若符号版本超标，换 koxtoolchain `kindle_tc`（更老目标）重试。

### 路线 B：Panther X2（RK3566，aarch64，4GB）——可行性低，结论：不推荐

- **不能直接 native 编译**：aarch64 机器 native 产出 aarch64 `.so`，Kindle 4 是 armv7 softfp，ABI 不匹配，产物无用；
- **预编译工具链跑不了**：koxtoolchain 预编译包仅提供 x86_64 版本，aarch64 上无法直接运行；
- 勉强路径只有两条：crosstool-ng 源码自建工具链（4GB ARM 上编 gcc，数小时级且易失败）或 Docker qemu-user 跑 x86_64 镜像（10-50 倍减速）。均不划算；
- **更优备选（若 Lighthouse 失败）**：GitHub Actions x86_64 runner（免费、30 分钟内可完成工具链下载+编译，且仓库已有 CI 基建）或本地 WSL2。

### 路线 C（安卓平板专属，注意这是另一个 .so）

安卓平板的 KOReader 是 **bionic/aarch64**，Kindle 的 glibc/softfp `.so` 在安卓上**加载不了**。处理方案（2026-09-20 细化，D4）：

- **一机一产物**：同一部署路径 `ezvenera.koplugin/lib/libquickjs.so`，按设备分发对应产物——Kindle 装 glibc/softfp 版，安卓装 NDK bionic 版。插件加载器按候选路径探测，无需多架构命名/加载器。
- **NDK 构建**：`build-quickjs.sh` 增 `android` target：`$NDK/toolchains/llvm/prebuilt/<host>/bin/aarch64-linux-android21-clang -fPIC -shared -O2`（quickjs-ng 对 clang/bionic 友好）；若平板装的是 **armeabi-v7a 版 KOReader APK**，还需 `-target armv7a-linux-androideabi21` 的 v7a 产物（先确认平板 APK 的 ABI 再决定要不要）。
- **待真机验证（spike 核心）**：KOReader Android 从用户插件目录（`Android/data/org.koreader.launcher/files/koreader/plugins/...`）dlopen 用户 `.so` 是否被 W^X 策略拦截——若被拦，ffi.load 路线在安卓上不可行，需回报用户再议（例如只做触屏 UI 适配、JS 引擎继续留在 Kindle 路线）。
- x86_64/host target（已有）可先用于桌面模拟冒烟，不依赖任何真机。

## 双设备部署与测试计划（等用户通知后执行）

| 设备 | 通道（待确认） | 冒烟顺序 |
|---|---|---|
| Kindle 4 | usbNetwork SSH / MRPI zip | ① remoteinput 独立入口（工具→扫码远程输入，不依赖 ezvenera）→ ② ezvenera 代理设置+扫码回填 → ③ S1 加密向量 → ④ S2 quickjs FFI 冒烟 |
| 安卓平板 | adb / 局域网 SSH（待用户提供） | 同上顺序；另需先解决 android-arm64 .so（路线 C spike） |

准备项（接手方可提前做）：写 `scripts/deploy-ssh.sh`（参数化 host/port/path，scp 同步 `*.koplugin/`，Windows Git Bash 兼容）；凭据**不要**入仓，走用户本地环境。

## 关键文件索引（本轮新增/修改）

| 文件 | 说明 |
|---|---|
| `src/koreader-plugin/remoteinput.koplugin/qrcode.lua` | 纯 Lua QR 编码器（ISO 18004 v1-4/EC L；LuaJIT `bit` 兼容层） |
| `src/koreader-plugin/remoteinput.koplugin/server.lua` | 临时 HTTP 服务（luasocket 非阻塞 + scheduleIn 轮询 + 一次性 token/403/超时自毁/动态端口） |
| `src/koreader-plugin/remoteinput.koplugin/qrwidget.lua` | QR 自绘控件（blitbuffer） |
| `src/koreader-plugin/remoteinput.koplugin/api.lua` | 编排（依赖全注入，可测） |
| `src/koreader-plugin/remoteinput.koplugin/main.lua` / `remoteinput.lua` | 入口 + facade（`_setInstance` 注入模式） |
| `src/koreader-plugin/ezvenera.koplugin/proxyconf.lua` | 唯一接入点：InputDialog 注入扫码按钮，弱依赖回退 |
| `tools/qr_verify.py` | QR 端到端验证（lupa 渲染 → zxing-cpp 解码，7/7） |
| `tests/test_qrcode.lua` / `test_server.lua` / `test_api.lua` / `stubs_remote.lua` | remoteinput 测试三件套 + 桩（拆仓时随迁） |
| `changes/ezvenera-koreader-port/design.md` | §3.6 机制 + **ADR-007**（拆仓依据） |
| `changes/ezvenera-koreader-port/tasks.md` | R1-R6 交付记录 |
| `reports/2026-09-20-code-review-m1.md` | 审查报告（本地，不入仓） |

## qrcode.lua 的三个历史坑（改代码前必读）

1. **RS 生成多项式**：p·x 项与 a·p 项曾写反；手证 ec=2 应得 `{1,3,2}`。现实现 `ng[1]=g[1]` 后 `ng[j] = bxor((j<=#g and g[j] or 0), gmul(g[j-1], a))`，勿"简化"回去；
2. **format info 放置**：必须 LSB-first（对齐 qrcode 库 `setup_type_info` 源码），MSB-first 会 14/31 处全错；
3. **timing 图案起点**：0-based (6,8) 是**暗**格（`i % 2 == 1`）。
   回归锚点：`tools/qr_verify.py` 必须保持 7/7 ALL OK。

## 立即下一步（接手后按序）

1. **GitHub 拆仓**：建 remoteinput 独立仓库（GPL-3.0 + README + CI：check_syntax/run_tests 子集）；ezvenera 仓保持现状；两仓互不打包。
2. ~~**Lighthouse 编译 libquickjs.so**~~ ✅ **已完成（2026-09-20，产物已入库，记录见上）**；后续同类编译（如 D4 安卓 .so）沿用路线 A 配方与传输通道。
3. **等用户通知** → 双设备 SSH 部署 + 真机冒烟（顺序见上表）；安卓路径先做路线 C spike。
4. **Spike S1 → S2 → M2**（S1/S2/M2 细节见前序 handoff，仍然有效）。

## 禁止迁移 / 禁止操作

- `.env`、SSH 私钥、token、设备凭据、浏览器登录态、**TENCENTCLOUD_SECRET_ID/KEY**（一律走 MCP/OAuth，不入仓不入文档）
- `reports/`（研究/审查档案，用户要求不入仓）
- `.git/`、`tools/.venv/`、`build/`、`target/`、`dist/`、`lib/*.so`
- 原始对话记录
- 配置路径禁止 `hold_input`/`hold_callback`（ADR-005 红线，`check_no_hold.py` 现扫描**全部** `.koplugin`）
- 修改 `vendored/init.js` 必须同步 `.sha256` 与版权头（ADR-002）

## 交接链

- 前序：`handoffs/2026-09-20-1030-ezvenera-koreader-m1/`（M1 首份：架构决策/已知坑/工具链检测仍有效）
- 本份：审查落实 + remoteinput 交付 + 拆仓/编译/双设备决策
