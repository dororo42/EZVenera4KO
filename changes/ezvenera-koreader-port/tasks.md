# 任务分解：EZVenera for KOReader（G4）

> 依赖有序；每项含 REQ 锚点与验证方式。完成标准：验证方式通过 + 对抗审查过。
> 图例：✅ 本轮已完成 · 🔶 本轮部分完成 · ⬜ 待做

## M0 脚手架（本轮）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T1 | git 仓库 + 目录结构 + .gitignore（reports/ 不入库） | — | git status | ✅ |
| T2 | G0 四路研究报告（reports/） | — | 评审 | ✅ |
| T3 | specs/requirements.md（G1） | 全部 | 评审 | ✅ |
| T4 | changes/ proposal+design+tasks（G2-G4） | 全部 | 评审 | ✅ |

## M1 插件骨架 + 代理（本轮，P0 主交付）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T5 | 插件骨架：_meta.lua/main.lua/菜单树（无 hold 依赖） | R1.1-2, R5.1 | 静态走查 + hold-grep 断言 | ✅ |
| T6 | settings.lua（LuaSettings 封装 + 默认值） | R1.3, R2.2 | 单测 | ✅ |
| T7 | proxyconf.lua（校验/应用/测试/菜单） | R2.1-2.6 | 单测（校验+选择逻辑） | ✅ |
| T8 | netclient.lua（http+https per-request proxy、超时、UA、重定向） | R2.3, R3.2 | 单测（fake socket） | ✅（UA=默认注入 `Dart/3.5 (dart:io)`，2026-09-20 兑现 L7；CONNECT 路径真机待验） |
| T9 | 测试基建：python+lupa 驱动 LuaJIT 单测 | — | 本机跑通 | ✅ |
| T10 | scripts/fetch+build-quickjs.sh（kindle5 交叉 + x86_64 开发构建） | R6.1, R6.4 | 脚本审查 + bash -n | ✅（2026-09-20 修复：fetch 默认 tag 404 → pin v0.17.0 + sha256 校验；build 显式 BUILD_SHARED_LIBS=ON） |
| T11 | rust/ 配方骨架（不接关键路径，cargo check 通过） | ADR-004 | cargo check + 文档 | ✅ |
| T12 | vendored init.js 入仓 + 许可声明 + sha256 锁 | ADR-002 | verify_vendored.py 通过 | ✅ |
| T13 | jshost.lua（FFI cdef + 加载探测 + 优雅降级） | R1.4, R6.2 | 无库时降级单测；S2 冒烟待做 | 🔶（真机冒烟待做） |
| T14 | bridge.lua + convert.lua + cookies.lua + storage + 测试 | R3.2-3.3 | 单测覆盖 bridge/convert/cookies/storage | 🔶（原 ✅ 语义修正 2026-09-20：此前为**桩覆盖**；NIST/RFC 真向量由 `tests/test_convert_real.lua` 承载，CI 装 libssl-dev 后生效，无 libcrypto 环境自动 SKIP） |
| T15-T18 | — | — | （M2 待做） | ⬜ |

## 增量交付：remoteinput.koplugin 扫码远程输入（2026-09-20）

> 需求升级：K4 输入不便 + 天然适配触屏平板（KOReader Android）。评估结论：**独立插件 + 弱依赖接入**（ADR-007），不集成进 EZVenera。

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| R1 | 评估独立插件 vs 集成 + EZVenera 触屏适配核查 | — | 评估结论 + `_meta.lua` 文案触屏中性化 | ✅ |
| R2 | qrcode.lua 纯 Lua QR 编码器（ISO 18004 v1-4/EC L，GF(256) RS + 8 掩码评分，LuaJIT 位运算兼容层） | — | zxing-cpp 真解码 7/7 ALL OK（tools/qr_verify.py） | ✅ |
| R3 | server.lua 临时 HTTP 服务（luasocket 非阻塞 + scheduleIn 轮询 + 一次性 token/403 + 超时自毁） | — | fake socket 单测 10 项 | ✅ |
| R4 | qrwidget.lua 自绘 + api.lua 编排 + main.lua/remoteinput.lua facade | — | 单测 + 语法检查 | ✅ |
| R5 | EZVenera 弱依赖接入（proxyconf InputDialog 注入「扫码远程输入」按钮 + setInputText 回填） | — | 弱依赖回退单测（无插件时安全） | ✅ |
| R6 | 全量回归 + 红线复检（check_no_hold 扩为全插件扫描） + 文档同步 | — | 109 通过/0 失败；hold clean（15 文件）；vendor 校验过 | ✅ |

## Spike S2（quickjs 实机冒烟）

| # | 任务 | REQ | 验证 | 状态 |
|---|---|---|---|---|
| T-S2a | 二进制桥真机冒烟（审查 M3）：glue 的 ArrayBuffer↔base64 转换已实现（jshost QUICKJS_GLUE，Node 侧行为测试 10/10 通过），待 quickjs 实机验证端到端 | R3.2 | 真机日志 + 加密图片源样例 | ⬜ |
| T-S2b | quickjs 实机冒烟：libquickjs.so 交叉编译（fetch tag v0.17.0）+ eval/cdef/回调 ABI 验证（T13 收尾） | R6 | 真机状态页 | 🔶（2026-09-21 C shim 落地：shim/ezvbridge.c → lib/libezvbridge.so，kindle5 softfp 三红线过；x86_64 C 级冒烟 6/6（JS→C→回调→JS 同步往返/TypeError/未装回退）；LuaJIT FFI 指针回调单测 5/5；**真机 LuaJIT 端到端待 D3**） |
| T-S2c | 桥接 C shim（审查 M1 关闭路径）：真 C 层包装 JSValue 按值返回，Lua 侧回调降为纯指针 `const char* (*)(void*, const char*)`，JSContext opaque 存回调（多实例安全） | R6.2 | scripts/build-shim.sh（host/x86_64/kindle + --test）；patchelf 改写 NEEDED libqjs.so.0→libquickjs.so；sha256 `28e06340…4580a` | ✅ |

## M3 加固（下轮后）

| # | 任务 | REQ | 验证 |
|---|---|---|---|
| T20 | modifyImage 像素管线（RGBA uint32 语义 + PNG 编码）+ 快照回归 | R3.6 | 位级一致 fixture |
| T21 | GBK 解码（lua-iconv 探测 / 内置表裁剪） | R3.3 | 样本比对 |
| T22 | httpasync 化 + 多页预取（性能） | R4 | 真机计时 |
| T23 | Rust 优化再评估（按 ADR-004 触发条件） | ADR-004 | 基准数据 |
| T24 | MRPI 打包 + 发布流程 + README 安装文档 | — | 打包产物在模拟器装载 |

## 依赖关系

T5→T6/T7→T8（骨架先行）；T9 与 T5-T8 并行；T13/T14 依赖 T10 产物（但可先用降级桩开发）；M2 依赖 M1；T20 依赖 T15；T23 依赖 M2 真机基线数据。

## 交付决策与待办（2026-09-20 17:49，用户指令）

> 详细配方与评估见 `handoffs/2026-09-20-1749-ezvenera-remoteinput-split/HANDOFF.md`。

| # | 事项 | 说明 | 验证 | 状态 |
|---|---|---|---|---|
| D1 | 两插件分别建 GitHub 仓库，暂不一起打包 | remoteinput 拆独立仓（随迁 test_qrcode/test_server/test_api/stubs_remote）；package-mrpi.sh 保持只打 ezvenera | 两仓 CI 各自绿 | ⬜ |
| D2 | lib/libquickjs.so 编译 | **主路线 = 北京实例 `lhins-ni6p5t1q`（ap-beijing，2026-09-20 核实：RUNNING，x86_64/Ubuntu 24.04/27GB 可用盘，⚠️ 2026-09-30 到期需续费）**，koxtoolchain kindle5 预编译工具链；上海实例已过期隔离（信息降级，仅历史参考）；备选 GitHub Actions/WSL | readelf：ARM EABI、无 Tag_ABI_VFP_args、GLIBC ≤2.12 | ⬜ |
| D3 | 双设备部署测试 | 安卓平板 + Kindle 4，SSH 通道；**等用户通知后执行**，凭据不入仓 | 真机冒烟：remoteinput 独立入口 → ezvenera 代理+扫码回填 → S1/S2 | ⬜ |
| D4 | 安卓 .so spike | 一机一产物：Kindle 用 glibc/softfp 版，安卓用 **NDK bionic/arm64 版**（`aarch64-linux-android21-clang -fPIC -shared`，build-quickjs.sh 增 `android` target；若平板装的是 armeabi-v7a APK 还需 v7a 产物）；部署路径同为 `lib/libquickjs.so`（按设备分发，不需多架构加载器）；待验：KOReader Android 从用户插件目录 dlopen（W^X） | android-arm64 .so 在 KOReader Android ffi.load 成功 | ⬜ |
| D5 | 源索引确认（R3.4，M2） | 默认索引 = `https://raw.githubusercontent.com/WEP-56/EZvenera-config/main/index.json`（schema `[{name,fileName,key,version,description?}]`，下载 = 基址+fileName，jsdelivr CDN 备选）；本地源 = `<data>/ezvenera/index/*.json` 合并、同 key 本地优先 + 本地 `.js` 直装（design §3.7） | sources.lua M2 实现后：拉取官方索引→安装→本地 json 合并用例 | ⬜ |

> **D2 完成记录（2026-09-20 19:40）**：产物已入库 `src/koreader-plugin/ezvenera.koplugin/lib/libquickjs.so`（436464 B，strip 后，sha256 `1055dfcb…70b7d6041`，不入 git）。北京实例 `lhins-ni6p5t1q` + koxtoolchain kindle5（2026.08，资源名 `kindle5.tar.zst`）+ quickjs-ng v0.17.0 MinSizeRel。readelf 实测：ARM EABI5、e_flags `0x05000200`（EF_ARM_ABI_FLOAT_SOFT，无 hardfp 位）、GLIBC 仅 2.4（≤2.12）、`JS_*` 导出齐全；本地 sha256 链 + ELF 复核 PASS，仓库回归 ALL GREEN（109/0、15/15、hold clean、vendor 不变）。传输 = 实例临时端口 + 防火墙临时规则 + 本地 PowerShell 直拉（详见 handoff D2 记录）。顺带修复 build-quickjs.sh：quickjs-ng CMake 产物名实为 `libqjs.so.0.17.0`，原脚本检查 `libquickjs.so` 必失败。
